package integration

import (
	"context"
	"crypto/rand"
	"errors"
	"fmt"
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

// A separately identified copy gives this Settings test its own cfprefsd domain.
// The live editing test exercises the original signed output without any copy.
func TestControlSetting(t *testing.T) {
	if *bundlePath == "" {
		t.Skip("supply -bundle to exercise Settings")
	}
	dir := t.TempDir()
	copyPath := filepath.Join(dir, "MPCut QA.app")
	run := func(name string, args ...string) {
		t.Helper()
		if data, err := exec.Command(name, args...).CombinedOutput(); err != nil {
			t.Fatalf("%s failed: %v %s", name, err, data)
		}
	}
	suffix := make([]byte, 8)
	if _, err := rand.Read(suffix); err != nil {
		t.Fatal(err)
	}
	domain := fmt.Sprintf("com.mpcut.mcp-smoke.%x", suffix)
	run("/usr/bin/ditto", *bundlePath, copyPath)
	run("/usr/bin/plutil", "-replace", "CFBundleIdentifier", "-string", domain, filepath.Join(copyPath, "Contents/Info.plist"))
	run("/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", copyPath)
	defer exec.Command("/usr/bin/defaults", "delete", domain).Run()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	socket := fmt.Sprintf("/tmp/mpcut-%d/control.sock", os.Getuid())
	if pid, err := socketPeer(socket); err == nil {
		t.Fatalf("existing MPCut listener pid %d; leaving it untouched", pid)
	}
	start := func() *exec.Cmd {
		t.Helper()
		app := exec.CommandContext(ctx, filepath.Join(copyPath, "Contents/MacOS/MPCut"), "-ApplePersistenceIgnoreState", "YES", "-NSQuitAlwaysKeepsWindows", "NO")
		app.Env = append(os.Environ(), "CFFIXED_USER_HOME="+dir)
		app.Stderr = os.Stderr
		if err := app.Start(); err != nil {
			t.Fatal(err)
		}
		return app
	}
	app := start()
	defer func() { _ = app.Process.Kill(); _ = app.Wait() }()
	helper := exec.Command(filepath.Join(copyPath, "Contents/Helpers/mpcut-mcp"))
	client := mcp.NewClient(&mcp.Implementation{Name: "mpcut-settings-smoke", Version: "1"}, nil)
	session, err := client.Connect(ctx, &mcp.CommandTransport{Command: helper}, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	checkAccess := func(enabled bool) {
		t.Helper()
		result, err := session.CallTool(ctx, &mcp.CallToolParams{Name: "list_projects", Arguments: object{}})
		if err != nil || result.IsError == enabled {
			t.Fatalf("list_projects with control enabled=%t: %v, %v", enabled, result, err)
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
		out, err := exec.Command("/usr/bin/defaults", "read", domain, "localMCPEnabled").Output()
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
