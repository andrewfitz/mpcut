package integration

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

func copyTestBundle(t *testing.T, directory, socketDirectory string) string {
	t.Helper()
	copyPath := filepath.Join(directory, "MPCut QA.app")
	domain := "com.mpcut.mcp-smoke." + filepath.Base(socketDirectory)
	userTemp, err := exec.Command("/usr/bin/getconf", "DARWIN_USER_TEMP_DIR").Output()
	tempDirectory := strings.TrimSpace(string(userTemp))
	if err != nil || !filepath.IsAbs(tempDirectory) {
		t.Fatalf("locate the macOS temporary directory: %q, %v", userTemp, err)
	}
	run := func(name string, args ...string) {
		t.Helper()
		if data, err := exec.Command(name, args...).CombinedOutput(); err != nil {
			t.Fatalf("%s failed: %v %s", name, err, data)
		}
	}
	run("/usr/bin/ditto", *bundlePath, copyPath)
	run("/usr/bin/plutil", "-replace", "CFBundleIdentifier", "-string", domain, filepath.Join(copyPath, "Contents/Info.plist"))
	run("/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", copyPath)
	t.Cleanup(func() { _ = exec.Command("/usr/bin/defaults", "delete", domain).Run() })
	// AppKit writes temporary restoration state under the system temp directory
	// even when ApplePersistenceIgnoreState is set and the app home is isolated.
	t.Cleanup(func() {
		if err := os.RemoveAll(filepath.Join(tempDirectory, domain+".savedState")); err != nil {
			t.Errorf("remove isolated AppKit state: %v", err)
		}
	})
	return copyPath
}

func TestControlSetting(t *testing.T) {
	if *bundlePath == "" {
		t.Skip("supply -bundle to exercise Settings")
	}
	dir := t.TempDir()
	socketDirectory, err := os.MkdirTemp("/tmp", "mpcut-test-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(socketDirectory) })
	isolatedEndpoint := "MPCUT_TEST_SOCKET_DIRECTORY=" + filepath.Base(socketDirectory)
	preferencesDomain := "com.mpcut.test-preferences." + filepath.Base(socketDirectory)
	copyPath := copyTestBundle(t, dir, socketDirectory)
	t.Cleanup(func() { _ = exec.Command("/usr/bin/defaults", "delete", preferencesDomain).Run() })
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	socket := filepath.Join(socketDirectory, "control.sock")
	if pid, err := socketPeer(socket); err == nil {
		t.Fatalf("existing MPCut listener pid %d; leaving it untouched", pid)
	}
	start := func() *exec.Cmd {
		t.Helper()
		app := exec.CommandContext(ctx, filepath.Join(copyPath, "Contents/MacOS/MPCut"), "-ApplePersistenceIgnoreState", "YES", "-NSQuitAlwaysKeepsWindows", "NO")
		app.Env = append(os.Environ(), "CFFIXED_USER_HOME="+dir, isolatedEndpoint)
		app.Stderr = os.Stderr
		if err := app.Start(); err != nil {
			t.Fatal(err)
		}
		return app
	}
	app := start()
	defer func() { _ = app.Process.Kill(); _ = app.Wait() }()
	helper := exec.Command(filepath.Join(copyPath, "Contents/Helpers/mpcut-mcp"))
	helper.Env = append(os.Environ(), isolatedEndpoint)
	client := mcp.NewClient(&mcp.Implementation{Name: "mpcut-settings-smoke", Version: "1"}, nil)
	session, err := client.Connect(ctx, &mcp.CommandTransport{Command: helper}, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	checkAccess := func(enabled bool) {
		t.Helper()
		result, err := session.CallTool(ctx, &mcp.CallToolParams{Name: "project_windows_list", Arguments: object{}})
		if err != nil || result.IsError == enabled {
			t.Fatalf("project_windows_list with control enabled=%t: %v, %v", enabled, result, err)
		}
		if !enabled {
			detail, ok := result.StructuredContent.(object)
			if !ok || detail["code"] != "app_unavailable" {
				t.Fatalf("unexpected disabled response: %v", result.StructuredContent)
			}
		}
	}
	checkAccess(false)
	_, sourceFile, _, _ := runtime.Caller(0)
	toggle := func() {
		t.Helper()
		cmd := exec.CommandContext(ctx, "xcrun", "swift", filepath.Join(filepath.Dir(sourceFile), "testdata/press_menu.swift"), strconv.Itoa(app.Process.Pid), "toggle-control")
		data, err := cmd.CombinedOutput()
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) && exitErr.ExitCode() == 77 {
			t.Skip("AX permission unavailable for Settings")
		}
		if err != nil {
			t.Fatalf("toggle: %v %s", err, data)
		}
	}
	waitForListener := func() {
		t.Helper()
		eventually(t, "Settings enabling test app listener", func() bool {
			pid, err := socketPeer(socket)
			if err == nil && pid != app.Process.Pid {
				t.Fatalf("unexpected listener owned by pid %d", pid)
			}
			return err == nil
		})
	}
	toggle()
	waitForListener()
	checkAccess(true)
	eventually(t, "Settings preference saved", func() bool {
		out, err := exec.Command("/usr/bin/defaults", "read", preferencesDomain, "automation_local_mcp_enabled").Output()
		return err == nil && strings.TrimSpace(string(out)) == "1"
	})
	_ = app.Process.Kill()
	_ = app.Wait()
	app = start()
	waitForListener()
	checkAccess(true)
	toggle()
	eventually(t, "Settings revoking listener", func() bool { _, err := socketPeer(socket); return err != nil })
	checkAccess(false)
	t.Log("isolated native Settings enabled control, preserved it through relaunch and revoked it for the same connected MCP client")
}
