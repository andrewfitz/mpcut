// Run on a macOS desktop with a packaged test bundle:
// cd mcp && go test -v ./integration -run '^TestLiveBundle$' -count=1 -args -bundle=/absolute/path/MPCut.app
package integration

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"runtime"
	"strconv"
	"syscall"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

var bundlePath = flag.String("bundle", "", "absolute path to the packaged MPCut.app")

type object = map[string]any

func socketPeer(path string) (int, error) {
	c, err := net.DialTimeout("unix", path, time.Second)
	if err != nil {
		return 0, err
	}
	defer c.Close()
	raw, err := c.(*net.UnixConn).SyscallConn()
	if err != nil {
		return 0, err
	}
	var pid int
	var sockErr error
	err = raw.Control(func(fd uintptr) {
		// macOS sys/un.h defines SOL_LOCAL = 0 and LOCAL_PEERPID = 2.
		pid, sockErr = syscall.GetsockoptInt(int(fd), 0, 2)
	})
	if err != nil {
		return 0, err
	}
	return pid, sockErr
}

func eventually(t *testing.T, label string, inspect func() bool) {
	t.Helper()
	deadline := time.Now().Add(20 * time.Second)
	for {
		if inspect() {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", label)
		}
		time.Sleep(100 * time.Millisecond)
	}
}

func TestLiveBundle(t *testing.T) {
	if *bundlePath == "" {
		t.Skip("supply -bundle to exercise a local macOS application")
	}
	if !filepath.IsAbs(*bundlePath) {
		t.Fatal("-bundle requires an absolute path")
	}
	socketDirectory, err := os.MkdirTemp("/tmp", "mpcut-test-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(socketDirectory) })
	socket := filepath.Join(socketDirectory, "control.sock")
	isolatedEndpoint := "MPCUT_TEST_SOCKET_DIRECTORY=" + filepath.Base(socketDirectory)
	dir, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	_, sourceFile, _, _ := runtime.Caller(0)
	media, err := os.ReadFile(filepath.Join(filepath.Dir(sourceFile), "../../Tests/MPCutAppTests/Fixtures/ProRes-2997.mov"))
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "media.mov"), media, 0600); err != nil {
		t.Fatal(err)
	}
	writeProject := func(name string) string {
		path := filepath.Join(dir, name+".cut")
		doc := `{"format":"mpcut","schemaVersion":1,"kind":"sequence","clips":[{"id":"clip","file":"media.mov","from":"0","to":"1001/2500"}]}`
		if err := os.WriteFile(path, []byte(doc), 0600); err != nil {
			t.Fatal(err)
		}
		return path
	}
	pathA, pathB := writeProject("First window"), writeProject("Second window")
	if err := os.MkdirAll(filepath.Join(dir, "Library", "Preferences"), 0700); err != nil {
		t.Fatal(err)
	}

	contents := filepath.Join(*bundlePath, "Contents")
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	app := exec.CommandContext(ctx, filepath.Join(contents, "MacOS", "MPCut"),
		"-localMCPEnabled", "YES", "-historyLimit", "50", "-useAnalysisSidecars", "NO",
		"-timelineSnapTarget", "off", "-minimumPause", "0.5", "-leavePause", "0",
		"-ApplePersistenceIgnoreState", "YES", "-NSQuitAlwaysKeepsWindows", "NO")
	app.Env = append(os.Environ(), "CFFIXED_USER_HOME="+dir, isolatedEndpoint)
	app.Stderr = os.Stderr
	if err := app.Start(); err != nil {
		t.Fatal(err)
	}
	var ownedSocket os.FileInfo
	defer func() {
		_ = app.Process.Kill()
		_ = app.Wait()
		if fi, err := os.Lstat(socket); err == nil && ownedSocket != nil && os.SameFile(fi, ownedSocket) {
			_ = os.Remove(socket)
		}
	}()
	eventually(t, "isolated app socket", func() bool {
		pid, err := socketPeer(socket)
		if err != nil {
			return false
		}
		if pid != app.Process.Pid {
			t.Fatalf("socket belongs to another app (pid %d); aborting", pid)
		}
		ownedSocket, err = os.Lstat(socket)
		return err == nil
	})

	helper := exec.Command(filepath.Join(contents, "Helpers", "mpcut-mcp"))
	helper.Env = append(os.Environ(), isolatedEndpoint)
	helper.Stderr = os.Stderr
	client := mcp.NewClient(&mcp.Implementation{Name: "mpcut-integration", Version: "1"}, nil)
	session, err := client.Connect(ctx, &mcp.CommandTransport{Command: helper}, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	if got := session.InitializeResult().ProtocolVersion; got != "2026-07-28" {
		t.Fatalf("protocol = %q", got)
	}
	tools := map[string]bool{}
	for tool, err := range session.Tools(ctx, nil) {
		if err != nil {
			t.Fatal(err)
		}
		tools[tool.Name] = true
	}
	for _, name := range []string{"list_projects", "open_project", "get_editor_state", "split_at", "undo", "redo", "save_project"} {
		if !tools[name] {
			t.Fatalf("missing tool %s", name)
		}
	}
	t.Logf("MCP %s, %d advertised tools", session.InitializeResult().ProtocolVersion, len(tools))

	requireSocketOwner := func(t *testing.T) {
		t.Helper()
		if pid, err := socketPeer(socket); err != nil || pid != app.Process.Pid {
			t.Fatalf("test app no longer owns socket: pid=%d err=%v", pid, err)
		}
	}
	rawCall := func(t *testing.T, name string, args object) *mcp.CallToolResult {
		t.Helper()
		requireSocketOwner(t)
		result, err := session.CallTool(ctx, &mcp.CallToolParams{Name: name, Arguments: args})
		if err != nil {
			t.Fatalf("%s transport: %v", name, err)
		}
		return result
	}
	toolCaller := func(t *testing.T) func(string, object, string) object {
		return func(name string, args object, expectedError string) object {
			t.Helper()
			result := rawCall(t, name, args)
			body, ok := result.StructuredContent.(map[string]any)
			if !ok || result.IsError != (expectedError != "") || (result.IsError && body["code"] != expectedError) {
				t.Fatalf("%s returned %+v (%+v), expected error %q", name, result.StructuredContent, result.Content, expectedError)
			}
			return body
		}
	}
	call := toolCaller(t)
	open := func(path string) object {
		t.Helper()
		handle := call("open_project", object{"path": path, "operationID": "open-" + filepath.Base(path)}, "")["project"]
		var state object
		eventually(t, "loaded "+filepath.Base(path), func() bool {
			state = call("get_editor_state", object{"project": handle}, "")
			return state["total"] == float64(1) && state["busy"] == false
		})
		return state
	}
	a := open(pathA)
	frameTime := "1001/30000"
	checkReviewFrame(t, rawCall(t, "review_frame", object{"project": a["project"], "space": "sequence", "time": frameTime}),
		object{"space": "sequence", "time": frameTime, "sourceTime": frameTime})
	t.Log("verified indexed review-frame time and decoded JPEG over MCP")
	b := open(pathB)
	if a["project"] == b["project"] {
		t.Fatal("two documents resolved to the same project")
	}
	state := func(project any) object { return call("get_editor_state", object{"project": project}, "") }
	call("focus_project", object{"project": b["project"]}, "")
	id := a["clips"].([]any)[0].(map[string]any)["id"]
	edit := object{"project": a["project"], "expectedRevision": a["revision"], "operationID": "split-a",
		"occurrence": id, "space": "sequence", "time": "1001/6000"}
	first := call("split_at", edit, "")
	again := call("split_at", edit, "")
	if !reflect.DeepEqual(first, again) || state(a["project"])["total"] != float64(2) {
		t.Fatalf("duplicate split did not replay: first=%v second=%v", first, again)
	}
	edit["operationID"] = "stale-split"
	call("split_at", edit, "stale_revision")
	undo := func(name string, expectedClips float64) {
		cur := state(a["project"])
		call(name, object{"project": a["project"], "expectedRevision": cur["revision"], "operationID": name + "-a"}, "")
		if next := state(a["project"]); next["total"] != expectedClips {
			t.Fatalf("after %s expected %.0f clips, got %v", name, expectedClips, next)
		}
	}
	undo("undo", 1)
	edit["operationID"] = "split-a"
	if replay := call("split_at", edit, ""); !reflect.DeepEqual(replay, first) || state(a["project"])["total"] != float64(1) {
		t.Fatalf("retry after undo reapplied the cut: %v", replay)
	}
	undo("redo", 2)
	runGUIProbe := func(t *testing.T, script, argument string) bool {
		t.Helper()
		requireSocketOwner(t)
		probe := exec.CommandContext(ctx, "xcrun", "swift", filepath.Join(filepath.Dir(sourceFile), "testdata", script),
			strconv.Itoa(app.Process.Pid), argument)
		output, err := probe.CombinedOutput()
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) && exitErr.ExitCode() == 77 {
			t.Log("AX permission unavailable; native GUI probe skipped")
			return false
		}
		if err != nil {
			t.Fatalf("%s failed: %v %s", argument, err, output)
		}
		return true
	}
	call("focus_project", object{"project": a["project"]}, "")
	for _, step := range []struct {
		menu  string
		count float64
	}{{"Undo Split Clip", 1}, {"Redo Split Clip", 2}} {
		if !runGUIProbe(t, "press_menu.swift", step.menu) {
			break
		}
		eventually(t, step.menu, func() bool { return state(a["project"])["total"] == step.count })
		t.Logf("native GUI Edit menu: %s", step.menu)
	}
	after := state(a["project"])
	exported := filepath.Join(dir, "Unsaved snapshot.cut")
	job := call("convert_live_project", object{"project": a["project"], "expectedRevision": after["revision"], "operationID": "snapshot-a", "output": exported}, "")
	eventually(t, "live interchange job", func() bool {
		status := call("live_job_status", object{"project": a["project"], "job": job["job"]}, "")
		switch status["state"] {
		case "running":
			return false
		case "succeeded":
			return true
		default:
			t.Fatalf("live conversion failed: %v", status)
			return false
		}
	})
	for path, count := range map[string]int{pathA: 1, exported: 2} {
		data, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		var doc struct{ Clips []json.RawMessage }
		if err := json.Unmarshal(data, &doc); err != nil || len(doc.Clips) != count {
			t.Fatalf("clip count for %s, want %d: %s", path, count, data)
		}
	}
	t.Log("live interchange job wrote the unsaved revision; original file retained its single clip")
	call("save_project", object{"project": a["project"], "expectedRevision": after["revision"], "operationID": "save-a"}, "")
	data, err := os.ReadFile(pathA)
	if err != nil {
		t.Fatal(err)
	}
	var saved struct {
		Clips   []json.RawMessage
		History struct{ Undo []struct{ Action string } }
	}
	if err := json.Unmarshal(data, &saved); err != nil || len(saved.Clips) != 2 || len(saved.History.Undo) != 1 || saved.History.Undo[0].Action != "Split Clip" {
		t.Fatalf("saved native history mismatch: %s (decode error %v)", data, err)
	}
	if next := state(b["project"]); next["revision"] != b["revision"] || next["total"] != float64(1) || next["dirty"] != false {
		t.Fatalf("other window changed: %v", next)
	}
	t.Log("verified two windows, native split, deduplication, stale edit rejection, undo/redo, save and persisted Split Clip history")
	checkFileWorkflows(t, call, dir)
	t.Run("LiveWaveform", func(t *testing.T) {
		call := toolCaller(t)
		audioPath := filepath.Join(dir, "Audio project.cut")
		doc := `{"format":"mpcut","schemaVersion":1,"kind":"sequence","clips":[{"id":"mic","file":"Interview Room.wav","from":"0","to":"1"}]}`
		if err := os.WriteFile(audioPath, []byte(doc), 0600); err != nil {
			t.Fatal(err)
		}
		audio := call("open_project", object{"path": audioPath, "operationID": "open-audio"}, "")["project"]
		sources := call("analysis_state", object{"project": audio}, "")["sources"].(map[string]any)["items"].([]any)
		if len(sources) != 1 {
			t.Fatalf("expected single audio source: %v", sources)
		}
		source := sources[0].(map[string]any)
		wave := call("get_waveform", object{"project": audio, "source": source["source"], "stream": source["audioStreams"].([]any)[0], "columns": 2}, "")
		want := []any{0.25, -0.5}
		if !reflect.DeepEqual(wave["low"], want) || !reflect.DeepEqual(wave["high"], want) {
			t.Fatalf("live envelope %v, want %v", wave, want)
		}
		t.Log("live waveform matches exact positive and negative source amplitudes from file inspection")
	})
	t.Run("MulticamReplay", func(t *testing.T) {
		checkMulticamWorkflows(t, toolCaller(t), func(t *testing.T, args, want object) {
			t.Helper()
			checkReviewFrame(t, rawCall(t, "review_frame", args), want)
		}, dir)
	})
	t.Run("StillAuthoring", func(t *testing.T) {
		checkStillAuthoring(t, toolCaller, rawCall, runGUIProbe, dir)
	})
	t.Run("CloseReplayAndSavedHistory", func(t *testing.T) {
		checkClosedProjectHistory(t, toolCaller(t), pathA, a["project"])
	})
	t.Run("SilenceToQueueExport", func(t *testing.T) {
		checkSilenceToQueue(t, toolCaller(t), dir, b["project"])
	})
	t.Run("PackagedWalkthrough", func(t *testing.T) {
		checkPackagedWalkthrough(t, ctx, contents, b["project"].(string), filepath.Join(dir, "media.mov"), isolatedEndpoint, requireSocketOwner)
	})
	t.Run("ExactJSONNumbers", func(t *testing.T) {
		checkExactNumbers(t, b["project"], func(name string, args object) (*mcp.CallToolResult, error) {
			requireSocketOwner(t)
			return session.CallTool(ctx, &mcp.CallToolParams{Name: name, Arguments: args})
		})
	})
}
