//go:build linux

package main

import (
	"bufio"
	"bytes"
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/xtls/libxray/share"
	"github.com/xtls/libxray/xray"
)

// The root supervisor must keep running the binary pkexec approved even when
// a same-user process replaces the file at its path (portable bundle in $HOME).
func TestPinnedExecutableSurvivesReplacement(t *testing.T) {
	run := "-test.run=^TestPinnedExecutableSurvivesReplacement$"
	switch os.Getenv("ELARNI_PIN_TEST") {
	case "print":
		fmt.Print("original")
		os.Exit(0)
	case "pin":
		file, path, err := pinnedLinuxExecutable()
		if err != nil {
			os.Exit(2)
		}
		defer file.Close()
		_, _ = bufio.NewReader(os.Stdin).ReadString('\n')
		command := exec.Command(path, run)
		command.Env = append(os.Environ(), "ELARNI_PIN_TEST=print")
		output, _ := command.Output()
		os.Stdout.Write(output)
		os.Exit(0)
	}
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	binary, err := os.ReadFile(self)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "elarni-core")
	if err := os.WriteFile(path, binary, 0o755); err != nil {
		t.Fatal(err)
	}
	child := exec.Command(path, run)
	child.Env = append(os.Environ(), "ELARNI_PIN_TEST=pin")
	input, err := child.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	var output bytes.Buffer
	child.Stdout = &output
	if err := child.Start(); err != nil {
		t.Fatal(err)
	}
	replacement := path + ".new"
	if err := os.WriteFile(replacement, []byte("#!/bin/sh\necho replaced\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(replacement, path); err != nil {
		t.Fatal(err)
	}
	input.Write([]byte("\n"))
	input.Close()
	if err := child.Wait(); err != nil {
		t.Fatal(err)
	}
	if output.String() != "original" {
		t.Fatalf("supervisor child ran %q, want the pinned original", output.String())
	}
}

// The root service and a desktop user's Connect must not run two tunnels: each
// tunnel's traffic matches the other's policy rule.
func TestLinuxVPNLockAdmitsOneTunnelPerMachine(t *testing.T) {
	path := filepath.Join(t.TempDir(), "elarni-vpn.lock")
	first, err := acquireLinuxVPNLock(path)
	if err != nil {
		t.Fatal(err)
	}
	if second, err := acquireLinuxVPNLock(path); err == nil || err.Error() != "vpn_guard_busy" {
		if second != nil {
			second.Close()
		}
		t.Fatalf("a second tunnel was admitted: %v", err)
	}
	first.Close()
	again, err := acquireLinuxVPNLock(path)
	if err != nil {
		t.Fatal("the lock outlived its tunnel", err)
	}
	again.Close()
}

// A worker for the supervisor and broker tests: this test binary in fixture mode.
func TestLinuxWorkerFixture(t *testing.T) {
	mode := os.Getenv("ELARNI_LINUX_WORKER_FIXTURE")
	if mode == "" {
		return
	}
	input := bufio.NewReader(os.Stdin)
	command, err := linuxReadCommand(input)
	if err != nil || command.Action != "start" || mode == "fail" {
		os.Exit(1)
	}
	if linuxWriteFrame(os.Stdout, linuxReply{Ready: true, Adapter: command.Network.Name}) != nil {
		os.Exit(1)
	}
	if mode == "events" {
		_ = linuxWriteFrame(os.Stdout, linuxReply{Logs: []xray.LogEntry{{Seq: 1, Level: "info", Text: "fixture"}}})
		_ = linuxWriteFrame(os.Stdout, linuxReply{Lost: true})
	}
	_, _ = io.Copy(io.Discard, input) // until the owner closes the input
	os.Exit(0)
}

func linuxWorkerFixture(mode string) *exec.Cmd {
	command := exec.Command(os.Args[0], "-test.run=^TestLinuxWorkerFixture$")
	command.Env = append(os.Environ(), "ELARNI_LINUX_WORKER_FIXTURE="+mode)
	return command
}

// Regression: a start failure or a worker that ended by itself (its core stopped)
// ended the root supervisor, so the next connect asked for polkit consent again.
func TestLinuxSupervisorOutlivesFailedAndLostTunnels(t *testing.T) {
	for _, block := range []bool{false, true} {
		t.Run(fmt.Sprint("blockWithoutVPN=", block), func(t *testing.T) {
			lock := filepath.Join(t.TempDir(), "vpn.lock")
			var calls []string
			var mu sync.Mutex
			call := func(format string, values ...any) {
				mu.Lock()
				defer mu.Unlock()
				calls = append(calls, fmt.Sprintf(format, values...))
			}
			took := func() []string {
				mu.Lock()
				defer mu.Unlock()
				taken := calls
				calls = nil
				return taken
			}
			modes := []string{"fail", "run", "run"}
			workers := make(chan *linuxChild, len(modes))
			reserved := 0
			host := linuxTunnelHost{
				lock: func() (*os.File, error) { return acquireLinuxVPNLock(lock) },
				reserve: func() (linuxNetwork, error) {
					reserved++
					network := linuxNetwork{Name: fmt.Sprintf("rv%012d", reserved), Table: 12000 + reserved, Priority: 12000 + reserved, Mark: 0x52560000 | uint32(12000+reserved), DNSPort: 5353}
					call("reserve %s", network.Name)
					return network, nil
				},
				cleanup: func(network linuxNetwork) error { call("cleanup %s", network.Name); return nil },
				forget:  func(network linuxNetwork) { call("forget %s", network.Name) },
				worker: func(events func(linuxReply)) (*linuxChild, error) {
					child, err := startLinuxChild(linuxWorkerFixture(modes[0]), events)
					modes = modes[1:]
					workers <- child
					return child, err
				},
			}
			commands, closed, replies := make(chan linuxCommand), make(chan struct{}), make(chan linuxReply, 4)
			done := make(chan int, 1)
			go func() {
				done <- superviseLinuxTunnels(context.Background(), commands, closed, func(reply linuxReply) error { replies <- reply; return nil }, os.Getuid(), host)
			}()
			reply := func() linuxReply {
				t.Helper()
				select {
				case reply := <-replies:
					return reply
				case <-time.After(10 * time.Second):
					t.Fatal("the supervisor did not answer")
					return linuxReply{}
				}
			}
			order := func(command linuxCommand) {
				t.Helper()
				select {
				case commands <- command:
				case code := <-done:
					t.Fatalf("the supervisor exited with %d before %s", code, command.Action)
				}
			}
			request := vpnRequest{Config: linuxConfigFixture}
			if block {
				request.RoutePolicy = &share.WindowsRoutePolicy{IncludedRoutes: []string{"0.0.0.0/0"}, BlockWithoutVPN: true}
			}
			start := linuxCommand{Action: "start", Request: request}
			stop := linuxCommand{Action: "stop"}
			want := func(stage string, expected ...string) {
				t.Helper()
				if got := took(); fmt.Sprint(got) != fmt.Sprint(expected) {
					t.Fatalf("%s: host calls %v, want %v", stage, got, expected)
				}
			}
			locked := func() bool {
				file, err := acquireLinuxVPNLock(lock)
				if err == nil {
					file.Close()
				}
				return err != nil
			}

			order(start)
			if got := reply(); got.Ready || got.Error != "vpn_start_failed" {
				t.Fatalf("failed start answered %+v", got)
			}
			if block {
				// What the failed start installed stays as the kill switch.
				want("failed start", "reserve rv000000000001")
			} else {
				want("failed start", "reserve rv000000000001", "cleanup rv000000000001", "cleanup rv000000000001", "forget rv000000000001")
			}
			if locked() != block {
				t.Fatal("the tunnel lock does not follow the kept network")
			}
			<-workers

			order(start)
			if got := reply(); !got.Ready || got.Adapter != "rv000000000002" {
				t.Fatalf("the next start answered %+v", got)
			}
			if block {
				want("second start", "cleanup rv000000000001", "forget rv000000000001", "reserve rv000000000002")
			} else {
				want("second start", "reserve rv000000000002")
			}
			worker := <-workers
			_ = worker.command.Process.Kill() // its core stopped
			if got := reply(); !got.Lost {
				t.Fatalf("a lost tunnel was reported as %+v", got)
			}
			if block {
				want("lost tunnel")
			} else {
				want("lost tunnel", "cleanup rv000000000002", "cleanup rv000000000002", "forget rv000000000002")
			}
			if locked() != block {
				t.Fatal("the tunnel lock does not follow the kept network")
			}

			// The app's cleanup stop after a loss keeps the kill switch.
			order(stop)
			if got := reply(); !got.Ready {
				t.Fatalf("idle stop answered %+v", got)
			}
			want("idle stop")

			order(start)
			if got := reply(); !got.Ready || got.Adapter != "rv000000000003" {
				t.Fatalf("reconnect answered %+v", got)
			}
			if block {
				want("reconnect", "cleanup rv000000000002", "forget rv000000000002", "reserve rv000000000003")
			} else {
				want("reconnect", "reserve rv000000000003")
			}
			order(stop)
			if got := reply(); !got.Ready {
				t.Fatalf("stop answered %+v", got)
			}
			want("stop", "cleanup rv000000000003", "cleanup rv000000000003", "forget rv000000000003")
			if locked() {
				t.Fatal("a stopped tunnel kept the lock")
			}
			close(closed)
			select {
			case code := <-done:
				if code != 0 {
					t.Fatalf("exit %d", code)
				}
			case <-time.After(10 * time.Second):
				t.Fatal("the supervisor outlived its owner")
			}
		})
	}
}

// Regression: a frame with only log lines (metrics off) or a tunnel loss was taken
// for the reply to the next command.
func TestLinuxBrokerTellsEventsFromReplies(t *testing.T) {
	events := make(chan linuxReply, 4)
	child, err := startLinuxChild(linuxWorkerFixture("events"), func(reply linuxReply) { events <- reply })
	if err != nil {
		t.Fatal(err)
	}
	defer child.stop()
	reply, err := child.request(linuxCommand{Action: "start", Network: linuxNetwork{Name: "rv000000000001"}}, 10*time.Second)
	if err != nil || !reply.Ready {
		t.Fatal("start failed", err)
	}
	for _, want := range []string{"logs", "lost"} {
		select {
		case event := <-events:
			if want == "logs" && len(event.Logs) != 1 || want == "lost" && !event.Lost {
				t.Fatalf("event %+v, want %s", event, want)
			}
		case <-time.After(10 * time.Second):
			t.Fatalf("no %s event", want)
		}
	}
	if child.up.Load() {
		t.Fatal("a lost tunnel still reads as up")
	}
	select {
	case <-child.done:
		t.Fatal("events ended the child")
	default:
	}
}
