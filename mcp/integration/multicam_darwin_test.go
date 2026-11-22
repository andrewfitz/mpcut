package integration

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

// Exercise the same group interval twice. A camera switch belongs to the group,
// whereas a split targets exactly one occurrence of the group in the assembly.
func checkMulticamWorkflows(t *testing.T, call func(name string, args object, expectedError string) object,
	checkFrame func(*testing.T, object, object), dir string) {
	t.Helper()
	camera, err := os.ReadFile(filepath.Join(dir, "media.mov"))
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "close.mov"), camera, 0600); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "Replays.cut")
	doc := `{"format":"mpcut","schemaVersion":1,"kind":"multicam","referenceAngle":"wide",
		"range":{"from":"0","to":"1001/2500"},
		"angles":[{"id":"wide","file":"media.mov"},{"id":"close","file":"close.mov"}],
		"audio":{"mode":"none"},"switches":[{"at":"0","angle":"wide"}],
		"assembly":[{"from":"0","to":"1001/5000"},{"from":"0","to":"1001/5000"}]}`
	if err := os.WriteFile(path, []byte(doc), 0600); err != nil {
		t.Fatal(err)
	}

	handle := call("open_project", object{"path": path, "operationID": "open-replays"}, "")["project"]
	state := func() object { return call("get_editor_state", object{"project": handle}, "") }
	var lastSources []any
	ready := false
	t.Cleanup(func() {
		if !ready {
			t.Logf("last multicam index state: %v", lastSources)
		}
	})
	eventually(t, "multicam indexes", func() bool {
		lastSources = call("get_multicam", object{"project": handle, "section": "sources"}, "")["sources"].([]any)
		for _, source := range lastSources {
			entry := source.(map[string]any)
			if entry["issue"] != nil && entry["indexProgress"] == nil {
				t.Fatalf("multicam source indexing failed: %v", entry)
			}
			if entry["available"] != true || entry["indexed"] != true || entry["issue"] != nil {
				return false
			}
		}
		ready = len(lastSources) == 2 && state()["canEdit"] == true
		return ready
	})
	before := state()
	occurrences := before["occurrences"].([]any)
	if len(occurrences) != 2 {
		t.Fatal("expected two repeated group ranges", before)
	}
	// Focus an ordinary window and keep using the multicam document handle.
	for _, entry := range call("list_projects", object{}, "")["projects"].([]any) {
		other := entry.(map[string]any)["project"]
		if other != handle {
			call("focus_project", object{"project": other}, "")
			break
		}
	}
	split := call("split_at", object{"project": handle, "expectedRevision": before["revision"], "operationID": "split-replay",
		"space": "assembly", "occurrence": 1, "time": "1001/3750"}, "")
	after := state()["occurrences"].([]any)
	if split["boundary"] != "1001/3750" || len(after) != 3 || !reflect.DeepEqual(after[0], occurrences[0]) {
		t.Fatalf("split the wrong replay: %v %v", split, after)
	}
	cameraEdit := call("set_camera_at", object{"project": handle, "expectedRevision": split["revision"], "operationID": "switch-replays",
		"number": 2, "time": "1001/30000"}, "")
	if cameraEdit["angle"] != "close" || cameraEdit["space"] != "group" || cameraEdit["historyRetained"] != true ||
		cameraEdit["time"] != "1001/30000" || cameraEdit["until"] != "1001/2500" {
		t.Fatalf("unexpected switch interval: %v", cameraEdit)
	}
	// Two output positions map to frame two in the same group interval.
	for i, clock := range []string{"1001/15000", "1001/3750"} {
		beforeReview := state()
		checkFrame(t, object{"project": handle, "space": "assembly", "time": clock},
			object{"space": "assembly", "angle": "close", "groupTime": "1001/15000", "sourceTime": "1001/15000"})
		if afterReview := state(); afterReview["playhead"] != beforeReview["playhead"] || afterReview["revision"] != beforeReview["revision"] {
			t.Fatalf("review moved the multicam playhead or changed the edit: before=%v, after=%v", beforeReview, afterReview)
		}
		position := call("seek", object{"project": handle, "space": "assembly", "time": clock, "occurrence": i * 2}, "")
		if position["angle"] != "close" || position["groupTime"] != "1001/15000" || position["occurrence"] != float64(i*2) {
			t.Fatalf("switch did not affect both replays: %v", position)
		}
	}
	position := call("seek", object{"project": handle, "space": "group", "time": "1001/15000",
		"occurrence": 2, "expectedRevision": cameraEdit["revision"]}, "")
	if position["space"] != "assembly" || position["time"] != "1001/3750" || position["occurrence"] != float64(2) {
		t.Fatalf("group seek did not resolve the requested replay: %v", position)
	}
	history := call("get_history", object{"project": handle}, "")["actions"]
	if !reflect.DeepEqual(history, []any{"Split Assembly Range", "Switch Camera"}) {
		t.Fatalf("unexpected native multicam history: %v", history)
	}
	undo := call("undo", object{"project": handle, "expectedRevision": cameraEdit["revision"], "operationID": "undo-replay-switch"}, "")
	switches := call("get_multicam", object{"project": handle, "section": "switches"}, "")["switches"].([]any)
	if len(switches) != 1 || switches[0].(map[string]any)["angle"] != "wide" {
		t.Fatalf("undo failed to restore opening camera: %v", switches)
	}
	call("undo", object{"project": handle, "expectedRevision": undo["revision"], "operationID": "undo-replay-split"}, "")
	if !reflect.DeepEqual(state()["occurrences"], occurrences) {
		t.Fatal("undo failed to restore repeated ranges")
	}
	t.Log("verified targeted multicam switch across repeated replays, review JPEGs, occurrence-scoped split, native history and undo")
}
