package main

import (
	"net/http"
	"net/http/httptest"
	"os"
	"regexp"
	"runtime"
	"testing"
)

func TestSubscriptionFetchIdentifiesHostPlatform(t *testing.T) {
	// Release bumps edit pubspec.yaml, so the User-Agent version is checked against it.
	pubspec, err := os.ReadFile("../../../../pubspec.yaml")
	if err != nil {
		t.Fatal(err)
	}
	version := regexp.MustCompile(`(?m)^version:\s*(\d+\.\d+\.\d+)\+\d+\s*$`).FindSubmatch(pubspec)
	if version == nil {
		t.Fatal("pubspec.yaml has no app version")
	}
	headers := make(chan http.Header, 1)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		headers <- r.Header.Clone()
		_, _ = w.Write([]byte("fixture"))
	}))
	defer server.Close()
	request := fetchRequest{URL: server.URL, InstallationID: "fixture-installation"}
	warning, err := fetchFeed(request)
	if err != nil {
		t.Fatal(err)
	}
	request.ApprovedChain = warning.(map[string]any)["warning"].(map[string]any)["chain"].([]string)
	if _, err := fetchFeed(request); err != nil {
		t.Fatal(err)
	}
	got := <-headers
	osName := map[string]string{"linux": "Linux", "windows": "Windows", "darwin": "macOS"}[runtime.GOOS]
	if osName == "" {
		osName = runtime.GOOS
	}
	if want := "Elarni/" + string(version[1]) + " (Xray; " + osName + ")"; got.Get("X-Device-OS") != osName || got.Get("User-Agent") != want {
		t.Fatalf("got OS=%q UA=%q, want OS=%q UA=%q", got.Get("X-Device-OS"), got.Get("User-Agent"), osName, want)
	}
}
