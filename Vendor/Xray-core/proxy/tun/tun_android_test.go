//go:build android

package tun

import (
	"testing"

	"golang.org/x/sys/unix"
)

// Real Android descriptor operations: a traffic test cannot catch a second
// Close accidentally closing a newly allocated descriptor with the same number.
func TestAndroidTunDescriptorOwnership(t *testing.T) {
	if err := SetAndroidTunFD(-1); err != nil {
		t.Fatal(err)
	}
	if _, err := NewTun(&Config{}); err == nil {
		t.Fatal("missing descriptor accepted")
	}
	if err := SetAndroidTunFD(0); err == nil {
		t.Fatal("stdin accepted")
	}
	var pipe [2]int
	if err := unix.Pipe(pipe[:]); err != nil {
		t.Fatal(err)
	}
	defer unix.Close(pipe[0])
	defer unix.Close(pipe[1])
	if err := SetAndroidTunFD(pipe[0]); err != nil {
		t.Fatal(err)
	}
	value, err := NewTun(&Config{})
	if err != nil {
		t.Fatal(err)
	}
	owned := value.(*AndroidTun).fd
	if owned == pipe[0] {
		t.Fatal("borrowed descriptor was not duplicated")
	}
	if _, err := NewTun(&Config{}); err == nil {
		t.Fatal("descriptor consumed twice")
	}
	if err := value.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := unix.FcntlInt(uintptr(owned), unix.F_GETFD, 0); err == nil {
		t.Fatal("owned descriptor leaked")
	}
	if _, err := unix.FcntlInt(uintptr(pipe[0]), unix.F_GETFD, 0); err != nil {
		t.Fatal("borrowed descriptor closed", err)
	}
	if err := unix.Dup3(pipe[0], owned, unix.O_CLOEXEC); err != nil {
		t.Fatal(err)
	}
	defer unix.Close(owned)
	if err := value.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := unix.FcntlInt(uintptr(owned), unix.F_GETFD, 0); err != nil {
		t.Fatal("second Close closed a reused descriptor", err)
	}
}

func TestAndroidTunPendingDescriptorCleanup(t *testing.T) {
	if err := SetAndroidTunFD(-1); err != nil {
		t.Fatal(err)
	}
	var pipe [2]int
	if err := unix.Pipe(pipe[:]); err != nil {
		t.Fatal(err)
	}
	defer unix.Close(pipe[0])
	defer unix.Close(pipe[1])
	if err := SetAndroidTunFD(pipe[0]); err != nil {
		t.Fatal(err)
	}
	if err := SetAndroidTunFD(pipe[0]); err == nil {
		t.Fatal("unconsumed descriptor overwritten")
	}
	if err := SetAndroidTunFD(-1); err != nil {
		t.Fatal(err)
	}
	if _, err := NewTun(&Config{}); err == nil {
		t.Fatal("cleared descriptor accepted")
	}
	if _, err := unix.FcntlInt(uintptr(pipe[0]), unix.F_GETFD, 0); err != nil {
		t.Fatal(err)
	}
}
