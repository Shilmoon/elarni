//go:build elarni_diagnostics

package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"time"

	"github.com/xtls/xray-core/common/flightrecorder"
)

// A diagnostic build records from process start without the Settings switch and adds a
// --diagnostics-export switch. Set by the diagnostic builder, without changing the release app's identity.
var diagnosticBuild = "0"

func diagnosticsMain() (bool, int) {
	directory := os.Getenv("ELARNI_DIAGNOSTICS_DIR")
	if directory == "" {
		cache, err := os.UserCacheDir()
		if err == nil {
			directory = filepath.Join(cache, "Elarni", "Diagnostics")
		}
	}
	err := diagnosticsCommand(flightrecorder.Request{Action: "start", Directory: directory, Role: "helper"})
	build, _ := strconv.ParseInt(diagnosticBuild, 10, 64)
	flightrecorder.Record(flightrecorder.Event{Name: "diagnostic_build", Values: map[string]int64{"build_id": build}})
	if len(os.Args) > 1 && os.Args[1] == "--diagnostics-export" {
		if len(os.Args) > 3 || err != nil {
			fmt.Fprintln(os.Stderr, "diagnostics unavailable or invalid export arguments")
			return true, 1
		}
		var destination string
		if len(os.Args) == 3 {
			destination = os.Args[2]
		} else {
			executable, executableErr := os.Executable()
			if executableErr != nil {
				return true, 1
			}
			destination = filepath.Join(filepath.Dir(executable), "Elarni-diagnostics-"+time.Now().UTC().Format("20060102-150405.000000000")+".zip")
		}
		if diagnosticsCommand(flightrecorder.Request{Action: "export", Destination: destination}) != nil {
			fmt.Fprintln(os.Stderr, "diagnostic export failed; choose a new absolute filename")
			return true, 1
		}
		fmt.Fprintln(os.Stdout, "Share this file:", destination)
		return true, 0
	}
	return false, 0
}
