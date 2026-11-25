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
	doc := `{"format":"mpcut","schema_version":9,"kind":"multicam","reference_angle_id":"wide",
		"group_range":{"from":"0","to":"1001/2500"},
		"angles":[{"id":"wide","file":"media.mov"},{"id":"close","file":"close.mov"}],
		"audio":{"mode":"none"},"switches":[{"group_time":"0","angle_id":"wide"}],
		"assembly":[{"from":"0","to":"1001/5000"},{"from":"0","to":"1001/5000"}]}`
	if err := os.WriteFile(path, []byte(doc), 0600); err != nil {
		t.Fatal(err)
	}

	handle := call("project_open", object{"project_path": path, "operation_id": "open-replays"}, "")["project_handle"]
	state := func() object { return call("project_editor_state_read", object{"project_handle": handle}, "") }
	var lastSources []any
	ready := false
	t.Cleanup(func() {
		if !ready {
			t.Logf("last multicam index state: %v", lastSources)
		}
	})
	eventually(t, "multicam indexes", func() bool {
		lastSources = call("multicam_state_read", object{"project_handle": handle, "section": "sources"}, "")["sources"].([]any)
		for _, source := range lastSources {
			entry := source.(map[string]any)
			if entry["issue"] != nil && entry["index_progress"] == nil {
				t.Fatalf("multicam source indexing failed: %v", entry)
			}
			if entry["available"] != true || entry["indexed"] != true || entry["issue"] != nil {
				return false
			}
		}
		ready = len(lastSources) == 2 && state()["can_edit"] == true
		return ready
	})
	before := state()
	occurrences := before["occurrences"].([]any)
	if len(occurrences) != 2 {
		t.Fatal("expected two repeated group ranges", before)
	}
	checkReplayAngleOverride(t, call, checkFrame, handle, before)
	before = state()
	// Focus an ordinary window and keep using the multicam document handle.
	for _, entry := range call("project_windows_list", object{}, "")["projects"].([]any) {
		other := entry.(map[string]any)["project_handle"]
		if other != handle {
			call("project_window_focus", object{"project_handle": other}, "")
			break
		}
	}
	split := call("timeline_item_split", object{"project_handle": handle, "expected_revision": before["revision"], "operation_id": "split-replay",
		"space": "assembly", "occurrence": 1, "time": "1001/3750"}, "")
	after := state()["occurrences"].([]any)
	if split["boundary"] != "1001/3750" || len(after) != 3 || !reflect.DeepEqual(after[0], occurrences[0]) {
		t.Fatalf("split the wrong replay: %v %v", split, after)
	}
	cameraEdit := call("multicam_camera_take", object{"project_handle": handle, "expected_revision": split["revision"], "operation_id": "switch-replays",
		"camera_number": 2, "group_time": "1001/30000"}, "")
	if cameraEdit["angle_id"] != "close" || cameraEdit["space"] != "group" || cameraEdit["history_retained"] != true ||
		cameraEdit["group_time"] != "1001/30000" || cameraEdit["group_until"] != "1001/2500" {
		t.Fatalf("unexpected switch interval: %v", cameraEdit)
	}
	// Two output positions map to frame two in the same group interval.
	for i, clock := range []string{"1001/15000", "1001/3750"} {
		beforeReview := state()
		checkFrame(t, object{"project_handle": handle, "space": "assembly", "time": clock},
			object{"space": "assembly", "angle_id": "close", "group_time": "1001/15000", "source_time": "1001/15000"})
		if afterReview := state(); afterReview["playhead"] != beforeReview["playhead"] || afterReview["revision"] != beforeReview["revision"] {
			t.Fatalf("review moved the multicam playhead or changed the edit: before=%v, after=%v", beforeReview, afterReview)
		}
		position := call("timeline_playhead_seek", object{"project_handle": handle, "space": "assembly", "time": clock, "occurrence": i * 2}, "")
		if position["angle_id"] != "close" || position["group_time"] != "1001/15000" || position["occurrence"] != float64(i*2) {
			t.Fatalf("switch did not affect both replays: %v", position)
		}
	}
	position := call("timeline_playhead_seek", object{"project_handle": handle, "space": "group", "time": "1001/15000",
		"occurrence": 2, "expected_revision": cameraEdit["revision"]}, "")
	if position["space"] != "assembly" || position["time"] != "1001/3750" || position["occurrence"] != float64(2) {
		t.Fatalf("group seek did not resolve the requested replay: %v", position)
	}
	history := call("history_read", object{"project_handle": handle}, "")["actions"]
	if !reflect.DeepEqual(history, []any{"Split Assembly Range", "Take Camera"}) {
		t.Fatalf("unexpected native multicam history: %v", history)
	}
	undo := call("history_undo", object{"project_handle": handle, "expected_revision": cameraEdit["revision"], "operation_id": "undo-replay-switch"}, "")
	switches := call("multicam_state_read", object{"project_handle": handle, "section": "switches"}, "")["switches"].([]any)
	if len(switches) != 1 || switches[0].(map[string]any)["angle_id"] != "wide" {
		t.Fatalf("undo failed to restore opening camera: %v", switches)
	}
	call("history_undo", object{"project_handle": handle, "expected_revision": undo["revision"], "operation_id": "undo-replay-split"}, "")
	if !reflect.DeepEqual(state()["occurrences"], occurrences) {
		t.Fatal("undo failed to restore repeated ranges")
	}
	t.Log("verified targeted multicam switch across repeated replays, review JPEGs, occurrence-scoped split, native history and undo")
}

func checkReplayAngleOverride(t *testing.T, call func(string, object, string) object,
	checkFrame func(*testing.T, object, object), handle any, before object) {
	t.Helper()
	read := func() object {
		return call("project_editor_state_read", object{"project_handle": handle}, "")
	}
	sync := call("multicam_sync_suggest", object{"project_handle": handle, "expected_revision": before["revision"],
		"source_id": "close", "metadata_only": true}, "")["report"].(object)
	suggestions := sync["suggestions"].([]any)
	zero := object{"numerator": float64(0), "denominator": float64(1)}
	if sync["reference_source_id"] != "wide" || sync["waveform_requested"] != false || len(suggestions) != 1 ||
		suggestions[0].(object)["source_id"] != "close" || !reflect.DeepEqual(suggestions[0].(object)["current_offset"], zero) {
		t.Fatalf("unexpected metadata-only sync report: %v", sync)
	}
	suggestion := suggestions[0].(object)
	if !reflect.DeepEqual(suggestion["metadata_offset"], zero) && suggestion["metadata_issue"] == nil {
		t.Fatalf("identical recordings should suggest zero offset or explain missing metadata: %v", suggestion)
	}
	coverage := call("multicam_state_read", object{"project_handle": handle, "section": "switch_coverage",
		"angle_id": "close", "group_time": "1001/30000"}, "")["switch_coverage"].(object)
	if coverage["angle_id"] != "close" || !reflect.DeepEqual(coverage["group"], object{"from": "1001/30000", "to": "1001/2500"}) {
		t.Fatalf("unexpected proposed switch coverage: %v", coverage)
	}
	if coverage["picture"].(object)["status"] != "covered" || coverage["audio"].(object)["status"] != "unrouted" {
		t.Fatalf("coverage did not distinguish usable picture from the unrouted audio lane: %v", coverage)
	}
	if after := read(); after["revision"] != before["revision"] || after["playhead"] != before["playhead"] {
		t.Fatalf("proposed switch coverage changed the project: %v", after)
	}
	call("multicam_assembly_edit", object{"project_handle": handle, "expected_revision": before["revision"],
		"operation_id": "angle-second-replay", "action": "angle_set", "occurrence": 1, "angle_id": "close"}, "")
	after := read()
	occurrences := after["occurrences"].([]any)
	if occurrences[0].(object)["angle_id"] != nil || occurrences[1].(object)["angle_id"] != "close" {
		t.Fatalf("override did not target the second replay: %v", occurrences)
	}
	for _, check := range []struct{ time, angle string }{{"1001/15000", "wide"}, {"1001/3750", "close"}} {
		checkFrame(t, object{"project_handle": handle, "space": "assembly", "time": check.time},
			object{"angle_id": check.angle, "group_time": "1001/15000", "source_time": "1001/15000"})
	}
	call("history_undo", object{"project_handle": handle, "expected_revision": after["revision"],
		"operation_id": "undo-angle-second-replay"}, "")
	if restored := read(); !reflect.DeepEqual(restored["occurrences"], before["occurrences"]) {
		t.Fatalf("undo did not restore both replays: %v", restored)
	}
}

func checkMulticamRecordingGap(t *testing.T, call func(string, object, string) object,
	checkFrame func(*testing.T, object, object), dir string) {
	t.Helper()
	camera, err := os.ReadFile(filepath.Join(dir, "media.mov"))
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "camera-restart.mov"), camera, 0600); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "Recording restart.cut")
	doc := `{"format":"mpcut","schema_version":9,"kind":"multicam","reference_angle_id":"wide",
		"group_range":{"from":"0","to":"1001/2500"},
		"angles":[{"id":"wide","file":"media.mov","group_coverage":{"from":"0","to":"1001/7500"},
			"additional_recordings":[{"id":"wide-restart","file":"camera-restart.mov","offset":"1001/5000",
				"group_coverage":{"from":"1001/5000","to":"1001/2500"}}]}],
		"audio":{"mode":"none"},"switches":[{"group_time":"0","angle_id":"wide"}]}`
	if err := os.WriteFile(path, []byte(doc), 0600); err != nil {
		t.Fatal(err)
	}
	handle := call("project_open", object{"project_path": path, "operation_id": "open-restarted-angle"}, "")["project_handle"]
	eventually(t, "both recordings of a logical angle indexed", func() bool {
		sources := call("multicam_state_read", object{"project_handle": handle, "section": "sources"}, "")["sources"].([]any)
		return len(sources) == 2 && sources[0].(object)["indexed"] == true && sources[1].(object)["indexed"] == true
	})
	checkFrame(t, object{"project_handle": handle, "space": "group", "time": "1001/30000"},
		object{"angle_id": "wide", "source_time": "1001/30000"})
	call("review_editor_frame_read", object{"project_handle": handle, "space": "group", "time": "1001/6000"}, "no_frame")
	checkFrame(t, object{"project_handle": handle, "space": "group", "time": "7007/30000"},
		object{"angle_id": "wide", "source_id": "wide-restart", "source_time": "1001/30000"})
	coverage := call("multicam_state_read", object{"project_handle": handle, "section": "switch_coverage",
		"angle_id": "wide", "group_time": "0"}, "")["switch_coverage"].(object)["picture"].(object)
	want := []any{object{"from": "1001/7500", "to": "1001/5000"}}
	if coverage["status"] != "gaps" || !reflect.DeepEqual(coverage["missing"], want) {
		t.Fatalf("coverage did not report the recording restart gap: %v", coverage)
	}
}
