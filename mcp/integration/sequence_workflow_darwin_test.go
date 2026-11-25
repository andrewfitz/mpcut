package integration

import (
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"testing"
)

func checkSequenceSourceRangesAndQueue(t *testing.T, call func(string, object, string) object, dir string, inspectQueue func([]string)) {
	t.Helper()
	source := filepath.Join(dir, "media.mov")
	other := filepath.Join(dir, "alternate source.mov")
	data, err := os.ReadFile(source)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(other, data, 0600); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "Source range workflow.cut")
	doc := `{"format":"mpcut","schema_version":9,"kind":"sequence","clips":[{"id":"original","file":"media.mov","from":"0","to":"1001/2500"}]}`
	if err := os.WriteFile(path, []byte(doc), 0600); err != nil {
		t.Fatal(err)
	}
	handle := call("project_open", object{"project_path": path, "operation_id": "open-source-ranges"}, "")["project_handle"]
	readArgs := object{"project_handle": handle}
	state := func() object { return call("project_editor_state_read", readArgs, "") }
	eventually(t, "source range project ready", func() bool {
		current := state()
		return current["total"] == float64(1) && current["can_edit"] == true
	})
	mutate := func(tool, operationID string, args object) object {
		t.Helper()
		args["project_handle"], args["operation_id"], args["expected_revision"] = handle, operationID, state()["revision"]
		return call(tool, args, "")
	}
	mark := func(operationID, from, to string) {
		t.Helper()
		mutate("timeline_selection_set", operationID+"-in", object{"action": "mark_in", "space": "sequence", "time": from})
		mutate("timeline_selection_set", operationID+"-out", object{"action": "mark_out", "space": "sequence", "time": to})
	}
	queueEntry := func() object {
		t.Helper()
		entries := call("export_queue_list", readArgs, "")["ranges"].([]any)
		if len(entries) != 1 {
			t.Fatalf("expected one queued range, got %v", entries)
		}
		return entries[0].(object)
	}

	firstRange := object{"file": source, "from": "0", "to": "1001/10000"}
	secondRange := object{"file": other, "from": "1001/30000", "to": "1001/10000"}
	mutate("source_select_save", "save-unused-media-select", object{"id": "alternate", "name": "Alternate source", "range": secondRange})
	original := state()
	insert := object{"from": "0", "to": "0", "ranges": []object{firstRange, {"select_id": "alternate"}, firstRange}}
	mutate("sequence_source_ranges_apply", "insert-source-ranges", insert)
	inserted := state()
	clips := inserted["clips"].([]any)
	if len(clips) != 4 || clips[0].(object)["id"] == clips[2].(object)["id"] ||
		clips[3].(object)["id"] != original["clips"].([]any)[0].(object)["id"] {
		t.Fatalf("expected three inserted occurrences before the original: %v", clips)
	}
	firstPath := clips[0].(object)["file"].(string)
	secondPath := clips[1].(object)["file"].(string)
	for got, want := range map[string]string{firstPath: source, secondPath: other} {
		resolved, err := filepath.EvalSymlinks(got)
		if err != nil || resolved != want {
			t.Fatalf("clip path %q resolved to %q (%v), want %q", got, resolved, err, want)
		}
	}
	insert["expected_revision"], insert["operation_id"] = original["revision"], "stale-source-ranges"
	call("sequence_source_ranges_apply", insert, "stale_revision")
	call("sequence_source_ranges_apply", object{"project_handle": handle, "operation_id": "invalid-source-range",
		"expected_revision": inserted["revision"], "from": "0", "to": "1001/30000",
		"ranges": []object{firstRange, {"file": source, "from": "0", "to": "1000"}}}, "invalid_source_range")
	if after := state(); after["revision"] != inserted["revision"] || !reflect.DeepEqual(after["clips"], clips) {
		t.Fatalf("rejected range application changed the sequence: %v", after)
	}
	mutate("history_undo", "undo-source-ranges", object{})
	if got := state()["clips"]; !reflect.DeepEqual(got, original["clips"]) {
		t.Fatalf("one undo did not restore the original sequence: %v", got)
	}
	mutate("history_redo", "redo-source-ranges", object{})
	if got := state()["clips"]; !reflect.DeepEqual(got, clips) {
		t.Fatalf("redo did not recover the same repeated occurrences: %v", got)
	}
	mutate("sequence_source_ranges_apply", "replace-first-source-range",
		object{"from": "0", "to": "1001/10000", "ranges": []object{secondRange}})
	replaced := state()["clips"].([]any)
	if len(replaced) != len(clips) || replaced[0].(object)["source_from"] != secondRange["from"] ||
		replaced[0].(object)["source_to"] != secondRange["to"] || replaced[1].(object)["id"] != clips[1].(object)["id"] {
		t.Fatalf("replacement did not preserve adjacent occurrences: %v", replaced)
	}
	mutate("history_undo", "undo-replace-first-source-range", object{})
	if got := state()["clips"]; !reflect.DeepEqual(got, clips) {
		t.Fatalf("one undo did not restore the replaced occurrence: %v", got)
	}
	beforeMoveHistory := call("history_read", readArgs, "")
	mapArgs := object{"project_handle": handle, "expected_revision": state()["revision"],
		"space": "source", "file": firstPath, "from": "1001/30000", "to": "1001/15000"}
	beforeMoveMap := call("timeline_editor_range_map", mapArgs, "")["mapping"].(object)
	mapArgs["file"] = source
	if absolutePathMap := call("timeline_editor_range_map", mapArgs, "")["mapping"]; !reflect.DeepEqual(absolutePathMap, beforeMoveMap) {
		t.Fatalf("absolute input path %q and reported path %q mapped differently: %v vs %v",
			source, firstPath, absolutePathMap, beforeMoveMap)
	}
	pieces := beforeMoveMap["pieces"].([]any)
	if len(pieces) != 3 {
		t.Fatalf("expected the partial source interval to map into all three uses: %v", beforeMoveMap)
	}
	for i, want := range []object{
		{"from": "1001/30000", "to": "1001/15000"},
		{"from": "1001/5000", "to": "7007/30000"},
		{"from": "3003/10000", "to": "1001/3000"},
	} {
		if got := pieces[i].(object)["output"]; !reflect.DeepEqual(got, want) {
			t.Fatalf("source interval use %d mapped to %v, want %v", i, got, want)
		}
	}

	mark("capture-source-ranges", "1001/30000", "1001/7500")
	mutate("export_queue_range_add", "queue-source-ranges", object{})
	captured := queueEntry()
	want := []any{
		object{"kind": "clip", "file": firstPath, "from": "1001/30000", "to": "1001/10000"},
		object{"kind": "clip", "file": secondPath, "from": "1001/30000", "to": "1001/15000"},
	}
	if !reflect.DeepEqual(captured["items"], want) {
		t.Fatalf("queue did not capture the original clipped source ranges in order: got %v, want %v", captured["items"], want)
	}
	mutate("sequence_clip_edit", "move-alternate-first", object{"action": "move", "occurrence": clips[1].(object)["id"], "slot": 0})
	if moved := state()["clips"].([]any); moved[0].(object)["id"] != clips[1].(object)["id"] {
		t.Fatalf("alternate source did not move to the first slot: %v", moved)
	}
	afterMoveHistory := call("history_read", readArgs, "")
	mapArgs["expected_revision"] = state()["revision"]
	mapArgs["history_token"], mapArgs["history_index"] = afterMoveHistory["history_token"], beforeMoveHistory["cursor"]
	if historical := call("timeline_editor_range_map", mapArgs, "")["mapping"]; !reflect.DeepEqual(historical, beforeMoveMap) {
		t.Fatalf("historical mapping changed after reorder: before=%v after=%v", beforeMoveMap, historical)
	}
	compareArgs := object{"project_handle": handle, "expected_revision": mapArgs["expected_revision"],
		"history_index": mapArgs["history_index"], "history_token": beforeMoveHistory["history_token"]}
	call("history_editor_compare", compareArgs, "stale_history")
	compareArgs["history_token"] = afterMoveHistory["history_token"]
	comparison := call("history_editor_compare", compareArgs, "")["comparison"].(object)
	movedID := clips[1].(object)["document_id"]
	var describedMove bool
	for _, row := range comparison["changes"].([]any) {
		change := row.(object)
		before, hadBefore := change["before"].(object)
		after, hasAfter := change["after"].(object)
		if hadBefore && hasAfter && before["id"] == movedID && after["id"] == movedID {
			describedMove = before["index"] == float64(1) && after["index"] == float64(0) &&
				reflect.DeepEqual(change["fields"], []any{"order", "output_range"})
		}
	}
	if comparison["before_duration"] != comparison["after_duration"] || !describedMove {
		t.Fatalf("comparison failed to report the reorder at unchanged duration: %v", comparison)
	}
	compareArgs["history_index"] = len(afterMoveHistory["actions"].([]any)) + 1
	call("history_editor_compare", compareArgs, "revision_unavailable")
	if current := queueEntry(); !reflect.DeepEqual(current, captured) {
		t.Fatalf("timeline reorder changed the queue snapshot: before=%v after=%v", captured, current)
	}
	call("project_window_focus", readArgs, "")
	inspectQueue([]string{firstPath, "00:00.033 – 00:00.100", secondPath, "00:00.033 – 00:00.067"})
	eventually(t, "queue sheet dismissed", func() bool { return state()["can_edit"] == true })
	mutate("export_queue_entry_rename", "rename-source-range-queue", object{"id": captured["id"], "name": "Alternate edit"})
	named := queueEntry()
	if named["name"] != "Alternate edit" || !reflect.DeepEqual(named["items"], want) {
		t.Fatalf("rename changed captured media or failed to update the name: %v", named)
	}
	mark("revised-source-ranges", "0", "1001/7500")
	mutate("export_queue_entry_revise", "replace-source-range-queue", object{"id": captured["id"], "mode": "replace"})
	revised := queueEntry()
	want = []any{
		object{"kind": "clip", "file": secondPath, "from": "1001/30000", "to": "1001/10000"},
		object{"kind": "clip", "file": firstPath, "from": "0", "to": "1001/15000"},
	}
	if revised["id"] != captured["id"] || revised["name"] != named["name"] || !reflect.DeepEqual(revised["items"], want) {
		t.Fatalf("queue replacement failed to retain its identity and recapture the new order: %v", revised)
	}
	mark("extended-source-ranges", "0", "1001/5000")
	mutate("export_queue_entry_revise", "extend-source-range-queue", object{"id": revised["id"], "mode": "extend"})
	extended := queueEntry()
	if extended["id"] != captured["id"] || extended["name"] != named["name"] || extended["to"] != "1001/5000" {
		t.Fatalf("queue extension failed to preserve entry identity and extend the bounds: %v", extended)
	}
}

func checkNativeCutMovementPrompt(t *testing.T, call func(string, object, string) object, dir string, inspectPrompt func() bool) {
	t.Helper()
	_, file, _, _ := runtime.Caller(0)
	source, err := os.ReadFile(filepath.Join(filepath.Dir(file), "../../Tests/MPCutAppTests/Fixtures/SmartTrim-GOP.mp4"))
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "gop.mp4"), source, 0600); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "Cut movement prompt.cut")
	doc := `{"format":"mpcut","schema_version":9,"kind":"sequence","clips":[{"id":"gop","file":"gop.mp4","from":"0","to":"2"}]}`
	if err := os.WriteFile(path, []byte(doc), 0600); err != nil {
		t.Fatal(err)
	}
	handle := call("project_open", object{"project_path": path, "operation_id": "open-tier-prompt"}, "")["project_handle"]
	read := func() object { return call("project_editor_state_read", object{"project_handle": handle}, "") }
	var state object
	eventually(t, "cut movement project ready", func() bool {
		state = read()
		return state["total"] == float64(1) && state["can_edit"] == true
	})
	id := state["clips"].([]any)[0].(object)["id"]
	call("timeline_item_split", object{"project_handle": handle, "expected_revision": state["revision"],
		"operation_id": "split-before-tier-prompt", "occurrence": id, "space": "sequence", "time": "18/25"}, "")
	state = read()
	call("timeline_selection_set", object{"project_handle": handle, "expected_revision": state["revision"],
		"operation_id": "select-before-tier-prompt", "action": "select", "occurrence": id}, "")
	call("project_window_focus", object{"project_handle": handle}, "")
	if !inspectPrompt() {
		t.Skip("accessibility permission unavailable for native tier prompt")
	}
	eventually(t, "native nearest keyframe edit", func() bool {
		current := read()
		if current["total"] != float64(1) || current["can_edit"] != true {
			return false
		}
		retained := current["clips"].([]any)[0].(object)
		return retained["source_from"] == "1" && retained["source_to"] == "2"
	})
}
