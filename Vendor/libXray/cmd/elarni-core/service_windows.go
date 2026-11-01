//go:build windows

package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"strconv"
	"strings"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/svc"
	"golang.org/x/sys/windows/svc/mgr"
)

// The ElarniVPN service stands in for the consent prompt, for the accounts an
// administrator allowed: it starts this build's helper as SYSTEM for their
// broker. It runs from the protected helper copy and serves only brokers of
// the same build, so what the helper trusts is unchanged.
const (
	vpnServiceName = "ElarniVPN"
	vpnServicePipe = `\\.\pipe\Elarni-VPN-Service`
)

var errVPNServiceUnavailable = errors.New("vpn_service_unavailable")

type serviceRequest struct {
	Action string `json:"action"`
	Pipe   string `json:"pipe,omitempty"`
}

type serviceReply struct {
	Handle uint64 `json:"handle,omitempty"` // the helper process, in the broker's own handle table
	Error  string `json:"error,omitempty"`
}

type vpnServiceHooks struct {
	own   string // this build's digest
	start func(pipe string, broker uint32) (windows.Handle, error)
	clear func() error
}

// canonicalUserSID admits only account SIDs (local, domain and Entra ID ones);
// a group or well-known SID such as Everyone would let every account in.
func canonicalUserSID(text string) (string, error) {
	sid, err := windows.StringToSid(text)
	if err != nil || sid.String() != text || !strings.HasPrefix(text, "S-1-5-21-") && !strings.HasPrefix(text, "S-1-12-1-") {
		return "", errors.New("invalid_account")
	}
	return text, nil
}

// serviceCommandUsers reads the allowed accounts from the service's command
// line, which only administrators can change and every user can read.
func serviceCommandUsers(line string) []string {
	arguments, err := windows.DecomposeCommandLine(line)
	if err != nil || len(arguments) != 3 || arguments[1] != "--service" {
		return nil
	}
	var users []string
	for _, user := range strings.Split(arguments[2], ",") {
		if _, err := canonicalUserSID(user); err == nil {
			users = append(users, user)
		}
	}
	return users
}

func changeServiceUsers(users []string, add bool, user string) ([]string, error) {
	user, err := canonicalUserSID(user)
	if err != nil {
		return nil, err
	}
	changed := slices.DeleteFunc(slices.Clone(users), func(existing string) bool { return existing == user })
	if add {
		changed = append(changed, user)
	}
	slices.Sort(changed)
	return changed, nil
}

func vpnServicePipeSDDL(users []string) string {
	sddl := "D:P(A;;GA;;;SY)(A;;GA;;;BA)"
	for _, user := range users {
		sddl += "(A;;GRGW;;;" + user + ")"
	}
	return sddl
}

// vpnServiceSDDL is the default service DACL plus start rights for the allowed accounts.
func vpnServiceSDDL(users []string) string {
	sddl := "D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWLOCRRC;;;IU)(A;;CCLCSWLOCRRC;;;SU)"
	for _, user := range users {
		sddl += "(A;;CCLCSWRPLOCRRC;;;" + user + ")"
	}
	return sddl
}

// serveVPNService answers brokers on name until stop is set. ready runs once
// the first instance exists, so the service reports Running only when brokers
// can reach it.
func serveVPNService(name string, users []string, hooks vpnServiceHooks, stop windows.Handle, ready func()) error {
	descriptor, err := windows.SecurityDescriptorFromString(vpnServicePipeSDDL(users))
	if err != nil {
		return err
	}
	attributes := windows.SecurityAttributes{Length: uint32(unsafe.Sizeof(windows.SecurityAttributes{})), SecurityDescriptor: descriptor}
	path, err := windows.UTF16PtrFromString(name)
	if err != nil {
		return err
	}
	create := func(flags uint32) (windows.Handle, error) {
		return windows.CreateNamedPipe(path, windows.PIPE_ACCESS_DUPLEX|windows.FILE_FLAG_OVERLAPPED|flags,
			windows.PIPE_TYPE_BYTE|windows.PIPE_READMODE_BYTE|windows.PIPE_WAIT|windows.PIPE_REJECT_REMOTE_CLIENTS,
			windows.PIPE_UNLIMITED_INSTANCES, 4096, 4096, 0, &attributes)
	}
	// The first instance claims the name, and one stays open from then on, so
	// no other program can take the name over.
	handle, err := create(windows.FILE_FLAG_FIRST_PIPE_INSTANCE)
	if err != nil {
		return err
	}
	event, err := windows.CreateEvent(nil, 1, 0, nil)
	if err != nil {
		windows.CloseHandle(handle)
		return err
	}
	defer windows.CloseHandle(event)
	ready()
	for {
		connected, err := awaitServiceClient(handle, event, stop)
		if !connected {
			windows.CloseHandle(handle)
			return err
		}
		next, err := create(0)
		if err != nil {
			windows.CloseHandle(handle)
			return err
		}
		answerServiceClient(handle, users, hooks)
		handle = next
	}
}

// awaitServiceClient reports false once stop is set.
func awaitServiceClient(handle, event, stop windows.Handle) (bool, error) {
	// The kernel keeps this pointer while the connect is pending.
	overlap := &windows.Overlapped{HEvent: event}
	var pin runtime.Pinner
	pin.Pin(overlap)
	defer pin.Unpin()
	windows.ResetEvent(event)
	switch err := windows.ConnectNamedPipe(handle, overlap); {
	// A client that already left fails its read.
	case err == nil, errors.Is(err, windows.ERROR_PIPE_CONNECTED), errors.Is(err, windows.ERROR_NO_DATA):
		return true, nil
	case !errors.Is(err, windows.ERROR_IO_PENDING):
		return false, err
	}
	state, err := windows.WaitForMultipleObjects([]windows.Handle{event, stop}, false, windows.INFINITE)
	if err == nil && state == windows.WAIT_OBJECT_0 {
		return true, nil
	}
	var transferred uint32
	windows.CancelIoEx(handle, overlap)
	windows.GetOverlappedResult(handle, overlap, &transferred, true)
	return false, err
}

func answerServiceClient(handle windows.Handle, users []string, hooks vpnServiceHooks) {
	pipe := os.NewFile(uintptr(handle), "elarni-vpn-service")
	defer pipe.Close()
	// A stalled broker holds up the next one only briefly.
	if pipe.SetDeadline(time.Now().Add(5*time.Second)) != nil {
		return
	}
	var request serviceRequest
	if readFrame(pipe, &request) != nil {
		return
	}
	reply, child := answerServiceRequest(handle, users, hooks, request)
	if child != 0 {
		defer windows.CloseHandle(child)
	}
	if writeFrame(pipe, reply) != nil {
		if child != 0 {
			windows.TerminateProcess(child, 1)
		}
		return
	}
	// The broker closes its end once it has read the reply.
	pipe.Read(make([]byte, 1))
}

// answerServiceRequest also returns the started helper, which the caller ends
// if the reply cannot be delivered.
func answerServiceRequest(handle windows.Handle, users []string, hooks vpnServiceHooks, request serviceRequest) (serviceReply, windows.Handle) {
	rejected := serviceReply{Error: "vpn_service_rejected"}
	var pid uint32
	if windows.GetNamedPipeClientProcessId(handle, &pid) != nil {
		return rejected, 0
	}
	client, err := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION|windows.PROCESS_DUP_HANDLE, false, pid)
	if err != nil {
		return rejected, 0
	}
	defer windows.CloseHandle(client)
	var token windows.Token
	if windows.OpenProcessToken(client, windows.TOKEN_QUERY, &token) != nil {
		return rejected, 0
	}
	user, err := token.GetTokenUser()
	token.Close()
	if err != nil || !slices.Contains(users, user.User.Sid.String()) {
		return rejected, 0
	}
	image := make([]uint16, 32768)
	length := uint32(len(image))
	if windows.QueryFullProcessImageName(client, 0, &image[0], &length) != nil {
		return rejected, 0
	}
	digest, err := fileDigest(windows.UTF16ToString(image[:length]))
	if err != nil {
		return rejected, 0
	}
	// Another build's broker asks for consent; its helper install re-points the service.
	if digest != hooks.own {
		return serviceReply{Error: "vpn_service_outdated"}, 0
	}
	switch request.Action {
	case "clearGuard":
		if hooks.clear() != nil {
			return serviceReply{Error: "vpn_service_failed"}, 0
		}
		return serviceReply{}, 0
	case "start":
		// The helper's arguments are only this pipe name and the broker's PID.
		if !strings.HasPrefix(request.Pipe, vpnPipePrefix) || !assetRevision.MatchString(strings.TrimPrefix(request.Pipe, vpnPipePrefix)) {
			return rejected, 0
		}
		child, err := hooks.start(request.Pipe, pid)
		if err != nil {
			return serviceReply{Error: "vpn_service_failed"}, 0
		}
		var target windows.Handle
		if err := windows.DuplicateHandle(windows.CurrentProcess(), child, client, &target,
			windows.SYNCHRONIZE|windows.PROCESS_TERMINATE|windows.PROCESS_QUERY_LIMITED_INFORMATION, false, 0); err != nil {
			windows.TerminateProcess(child, 1)
			windows.CloseHandle(child)
			return serviceReply{Error: "vpn_service_failed"}, 0
		}
		return serviceReply{Handle: uint64(target)}, child
	}
	return rejected, 0
}

// startVPNChild runs this helper for the broker, as the elevated prompt would.
func startVPNChild(pipe string, broker uint32) (windows.Handle, error) {
	executable, err := os.Executable()
	if err != nil {
		return 0, err
	}
	application, _ := windows.UTF16PtrFromString(executable)
	line, _ := windows.UTF16PtrFromString(windows.ComposeCommandLine([]string{executable, "--vpn-child", pipe, strconv.FormatUint(uint64(broker), 10)}))
	directory, _ := windows.UTF16PtrFromString(filepath.Dir(executable))
	startup := windows.StartupInfo{Cb: uint32(unsafe.Sizeof(windows.StartupInfo{}))}
	var process windows.ProcessInformation
	if err := windows.CreateProcess(application, line, nil, nil, false, windows.CREATE_NO_WINDOW, nil, directory, &startup, &process); err != nil {
		return 0, err
	}
	windows.CloseHandle(process.Thread)
	return process.Process, nil
}

type vpnService struct{ users []string }

func (service vpnService) Execute(_ []string, requests <-chan svc.ChangeRequest, status chan<- svc.Status) (bool, uint32) {
	status <- svc.Status{State: svc.StartPending}
	executable, err := os.Executable()
	if err != nil {
		return false, 1
	}
	own, err := fileDigest(executable)
	if err != nil {
		return false, 1
	}
	stop, err := windows.CreateEvent(nil, 1, 0, nil)
	if err != nil {
		return false, 1
	}
	defer windows.CloseHandle(stop)
	hooks := vpnServiceHooks{own: own, start: startVPNChild, clear: func() error { return clearStaleGuard(releaseGuard) }}
	ready := make(chan struct{})
	done := make(chan error, 1)
	go func() { done <- serveVPNService(vpnServicePipe, service.users, hooks, stop, func() { close(ready) }) }()
	select {
	case <-ready:
	case <-done:
		return false, 1
	}
	status <- svc.Status{State: svc.Running, Accepts: svc.AcceptStop | svc.AcceptShutdown}
	for {
		select {
		case <-done:
			return false, 1
		case request := <-requests:
			switch request.Cmd {
			case svc.Interrogate:
				status <- request.CurrentStatus
			case svc.Stop, svc.Shutdown:
				status <- svc.Status{State: svc.StopPending}
				windows.SetEvent(stop)
				<-done
				return false, 0
			}
		}
	}
}

func runVPNService(list string) int {
	if service, err := svc.IsWindowsService(); err != nil || !service {
		return 1
	}
	users := strings.Split(list, ",")
	for _, user := range users {
		if _, err := canonicalUserSID(user); err != nil {
			return 1
		}
	}
	if svc.Run(vpnServiceName, vpnService{users}) != nil {
		return 1
	}
	return 0
}

// openVPNService opens the service with only the rights an unelevated account
// may hold; mgr's own Connect asks for full control of the service manager.
func openVPNService(name string, access uint32) (*mgr.Service, func(), error) {
	manager, err := windows.OpenSCManager(nil, nil, windows.SC_MANAGER_CONNECT)
	if err != nil {
		return nil, nil, errVPNServiceUnavailable
	}
	path, _ := windows.UTF16PtrFromString(name)
	handle, err := windows.OpenService(manager, path, access)
	if err != nil {
		windows.CloseServiceHandle(manager)
		return nil, nil, errVPNServiceUnavailable
	}
	return &mgr.Service{Name: name, Handle: handle}, func() {
		windows.CloseServiceHandle(handle)
		windows.CloseServiceHandle(manager)
	}, nil
}

// vpnServiceProcess starts the service when it is stopped and returns its PID.
// Without the service, or for an account it does not allow, it fails at once.
func vpnServiceProcess(name string) (uint32, error) {
	service, closeService, err := openVPNService(name, windows.SERVICE_START|windows.SERVICE_QUERY_STATUS)
	if err != nil {
		return 0, err
	}
	defer closeService()
	started := false
	for deadline := time.Now().Add(15 * time.Second); time.Now().Before(deadline); time.Sleep(100 * time.Millisecond) {
		status, err := service.Query()
		if err != nil {
			return 0, errVPNServiceUnavailable
		}
		switch status.State {
		case svc.Running:
			return status.ProcessId, nil
		case svc.Stopped:
			if started {
				return 0, errVPNServiceUnavailable
			}
			if err := service.Start(); err != nil && !errors.Is(err, windows.ERROR_SERVICE_ALREADY_RUNNING) {
				return 0, errVPNServiceUnavailable
			}
			started = true
		}
	}
	return 0, errVPNServiceUnavailable
}

func askServicePipe(name string, server uint32, request serviceRequest) (serviceReply, error) {
	path, err := windows.UTF16PtrFromString(name)
	if err != nil {
		return serviceReply{}, errVPNServiceUnavailable
	}
	var handle windows.Handle
	for deadline := time.Now().Add(5 * time.Second); ; time.Sleep(50 * time.Millisecond) {
		// Anonymous SQOS: whoever serves this name cannot act as this account.
		handle, err = windows.CreateFile(path, windows.GENERIC_READ|windows.GENERIC_WRITE, 0, nil, windows.OPEN_EXISTING,
			windows.FILE_FLAG_OVERLAPPED|windows.SECURITY_SQOS_PRESENT|windows.SECURITY_ANONYMOUS, 0)
		if err == nil {
			break
		}
		// Busy while it answers another broker.
		if !errors.Is(err, windows.ERROR_PIPE_BUSY) && !errors.Is(err, windows.ERROR_FILE_NOT_FOUND) || time.Now().After(deadline) {
			return serviceReply{}, errVPNServiceUnavailable
		}
	}
	pipe := os.NewFile(uintptr(handle), "elarni-vpn-service-client")
	defer pipe.Close()
	// An allowed account's program may serve the name too; only the service is asked.
	var peer uint32
	if windows.GetNamedPipeServerProcessId(handle, &peer) != nil || peer != server {
		return serviceReply{}, errors.New("vpn_service_rejected")
	}
	var reply serviceReply
	if pipe.SetDeadline(time.Now().Add(15*time.Second)) != nil || writeFrame(pipe, request) != nil || readFrame(pipe, &reply) != nil {
		return serviceReply{}, errVPNServiceUnavailable
	}
	if reply.Error != "" {
		return serviceReply{}, errors.New(reply.Error)
	}
	return reply, nil
}

// askVPNService sends request to the running service, starting it first.
func askVPNService(request serviceRequest) (serviceReply, error) {
	server, err := vpnServiceProcess(vpnServiceName)
	if err != nil {
		return serviceReply{}, err
	}
	return askServicePipe(vpnServicePipe, server, request)
}

func currentAccount() (string, error) {
	user, err := windows.GetCurrentProcessToken().GetTokenUser()
	if err != nil {
		return "", err
	}
	return user.User.Sid.String(), nil
}

func vpnServiceStatus() any {
	enabled := false
	if account, err := currentAccount(); err == nil {
		if service, closeService, err := openVPNService(vpnServiceName, windows.SERVICE_QUERY_CONFIG); err == nil {
			if config, err := service.Config(); err == nil {
				enabled = slices.Contains(serviceCommandUsers(config.BinaryPathName), account)
			}
			closeService()
		}
	}
	return map[string]any{"enabled": enabled}
}

// setVPNService allows or stops allowing this account behind one consent prompt.
func setVPNService(payload json.RawMessage) (any, error) {
	var request struct {
		Enabled bool `json:"enabled"`
	}
	decoder := json.NewDecoder(bytes.NewReader(payload))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&request) != nil {
		return nil, errors.New("invalid_vpn_request")
	}
	account, err := currentAccount()
	if err != nil {
		return nil, errors.New("vpn_service_failed")
	}
	helper, err := windowsHelper()
	if err != nil {
		return nil, err
	}
	change := "remove"
	if request.Enabled {
		change = "add"
	}
	if err := runElevated(helper, "--vpn-service "+change+" "+account); err != nil {
		return nil, err
	}
	return vpnServiceStatus(), nil
}

// changeVPNService runs elevated, from this build's helper or the MSI's copy of it.
func changeVPNService(add bool, account string) error {
	executable, err := os.Executable()
	if err != nil {
		return err
	}
	root, err := windowsHelperRoot()
	if err != nil {
		return err
	}
	digest, err := fileDigest(executable)
	if err != nil {
		return err
	}
	directory := helperDirectory(root, digest)
	helper := filepath.Join(directory, "elarni-core.exe")
	if add && !helperInstalled(directory, "elarni-core.exe", "wintun.dll") {
		return errors.New("helper_missing")
	}
	manager, service, line, release, err := installedVPNService()
	if err != nil {
		return err
	}
	defer release()
	// Removing an account leaves the others on the build they had.
	if arguments, err := windows.DecomposeCommandLine(line); !add && err == nil && len(arguments) > 0 {
		helper = arguments[0]
	}
	users, err := changeServiceUsers(serviceCommandUsers(line), add, account)
	if err != nil {
		return err
	}
	return pointVPNService(manager, service, helper, users)
}

// installedVPNService opens the service with full control while elevated, with
// its command line; service is nil when there is none.
func installedVPNService() (*mgr.Mgr, *mgr.Service, string, func(), error) {
	manager, err := mgr.Connect()
	if err != nil {
		return nil, nil, "", nil, err
	}
	service, err := manager.OpenService(vpnServiceName)
	if errors.Is(err, windows.ERROR_SERVICE_DOES_NOT_EXIST) {
		return manager, nil, "", func() { manager.Disconnect() }, nil
	}
	if err != nil {
		manager.Disconnect()
		return nil, nil, "", nil, err
	}
	config, err := service.Config()
	if err != nil {
		service.Close()
		manager.Disconnect()
		return nil, nil, "", nil, err
	}
	return manager, service, config.BinaryPathName, func() { service.Close(); manager.Disconnect() }, nil
}

func removeVPNService() error {
	manager, service, _, release, err := installedVPNService()
	if err != nil {
		return err
	}
	defer release()
	return pointVPNService(manager, service, "", nil)
}

// pointVPNService stops the service and points it at helper for users; with no
// users left it is deleted.
func pointVPNService(manager *mgr.Mgr, service *mgr.Service, helper string, users []string) error {
	if service != nil {
		stopVPNService(service)
	}
	if len(users) == 0 {
		if service == nil {
			return nil
		}
		return service.Delete()
	}
	if service == nil {
		created, err := manager.CreateService(vpnServiceName, helper, mgr.Config{DisplayName: "Elarni VPN",
			Description: "Connects Elarni's system-wide VPN without a consent prompt, for the accounts an administrator allowed."},
			"--service", strings.Join(users, ","))
		if err != nil {
			return err
		}
		defer created.Close()
		service = created
	} else {
		config, err := service.Config()
		if err != nil {
			return err
		}
		config.BinaryPathName = windows.ComposeCommandLine([]string{helper, "--service", strings.Join(users, ",")})
		config.StartType = mgr.StartManual
		if err := service.UpdateConfig(config); err != nil {
			return err
		}
	}
	descriptor, err := windows.SecurityDescriptorFromString(vpnServiceSDDL(users))
	if err != nil {
		return err
	}
	dacl, _, err := descriptor.DACL()
	if err != nil {
		return err
	}
	return windows.SetSecurityInfo(service.Handle, windows.SE_SERVICE, windows.DACL_SECURITY_INFORMATION, nil, nil, dacl, nil)
}

func stopVPNService(service *mgr.Service) {
	status, err := service.Control(svc.Stop)
	for deadline := time.Now().Add(10 * time.Second); err == nil && status.State != svc.Stopped && time.Now().Before(deadline); {
		time.Sleep(100 * time.Millisecond)
		status, err = service.Query()
	}
}
