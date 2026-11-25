package integration

import (
	"maps"
	"reflect"
	"testing"
)

func checkClosedProjectHistory(t *testing.T, call func(string, object, string) object, path string, project any) {
	t.Helper()
	before := call("project_editor_state_read", object{"project_handle": project}, "")
	if before["dirty"] != false {
		t.Fatalf("saved project is dirty: %v", before)
	}
	readArgs := object{"project_handle": project}
	if shown := call("history_panel_show", readArgs, ""); shown["history_visible"] != true {
		t.Fatalf("history sheet did not open: %v", shown)
	}
	saveArgs := object{"project_handle": project, "expected_revision": before["revision"], "operation_id": "save-after-history"}
	call("project_save", saveArgs, "busy")
	if hidden := call("history_panel_close", readArgs, ""); hidden["history_visible"] != false {
		t.Fatalf("history sheet did not close: %v", hidden)
	}
	saveArgs["operation_id"] = "save-after-history-closed"
	call("project_save", saveArgs, "")
	args := object{"project_handle": project, "expected_revision": before["revision"], "operation_id": "close-saved"}
	cancel := maps.Clone(args)
	cancel["operation_id"] = "cancel-close-saved"
	cancel["changes"] = "cancel"
	if cancelled := call("project_close", cancel, ""); cancelled["closed"] != false {
		t.Fatalf("cancelled close must leave the window open: %v", cancelled)
	}
	closed := call("project_close", args, "")
	if closed["closed"] != true || closed["project_handle"] != project || closed["revision"] != before["revision"] {
		t.Fatalf("expected a successful native close: %v", closed)
	}
	call("project_editor_state_read", object{"project_handle": project}, "project_closed")

	opened := call("project_open", object{"project_path": path, "operation_id": "reopen-saved"}, "")
	handle, ok := opened["project_handle"].(string)
	if !ok || handle == "" || handle == project {
		t.Fatalf("reopened project must have a fresh live handle: %v", opened)
	}
	reopened := call("project_editor_state_read", object{"project_handle": handle}, "")
	if reopened["total"] != float64(2) || reopened["dirty"] != false {
		t.Fatalf("reopen did not restore the saved sequence: %v", reopened)
	}
	history := call("history_read", object{"project_handle": handle}, "")
	if !reflect.DeepEqual(history["actions"], []any{"Split Clip"}) || history["cursor"] != float64(1) {
		t.Fatalf("reopen did not restore active native history: %v", history)
	}
	if again := call("project_close", args, ""); !reflect.DeepEqual(again, closed) {
		t.Fatalf("identical close did not replay its receipt: first=%v second=%v", closed, again)
	}
	retry := maps.Clone(args)
	retry["changes"] = "discard"
	call("project_close", retry, "project_closed")
	retry["operation_id"] = "fresh-close-on-expired-handle"
	call("project_close", retry, "project_closed")
	if state := call("project_editor_state_read", object{"project_handle": handle}, ""); state["revision"] != reopened["revision"] {
		t.Fatalf("retry affected the reopened project: %v", state)
	}
	t.Log("verified cancelled close, exact retry after native close and saved history after reopening")
}
