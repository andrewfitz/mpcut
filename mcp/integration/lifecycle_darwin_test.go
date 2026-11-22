package integration

import (
	"maps"
	"reflect"
	"testing"
)

func checkClosedProjectHistory(t *testing.T, call func(string, object, string) object, path string, project any) {
	t.Helper()
	before := call("get_editor_state", object{"project": project}, "")
	if before["dirty"] != false {
		t.Fatalf("saved project is dirty: %v", before)
	}
	args := object{"project": project, "expectedRevision": before["revision"], "operationID": "close-saved"}
	cancel := maps.Clone(args)
	cancel["operationID"] = "cancel-close-saved"
	cancel["changes"] = "cancel"
	if cancelled := call("close_project", cancel, ""); cancelled["closed"] != false {
		t.Fatalf("cancelled close must leave the window open: %v", cancelled)
	}
	closed := call("close_project", args, "")
	if closed["closed"] != true || closed["project"] != project || closed["revision"] != before["revision"] {
		t.Fatalf("expected a successful native close: %v", closed)
	}
	call("get_editor_state", object{"project": project}, "project_closed")

	opened := call("open_project", object{"path": path, "operationID": "reopen-saved"}, "")
	handle, ok := opened["project"].(string)
	if !ok || handle == "" || handle == project {
		t.Fatalf("reopened project must have a fresh live handle: %v", opened)
	}
	reopened := call("get_editor_state", object{"project": handle}, "")
	if reopened["total"] != float64(2) || reopened["dirty"] != false {
		t.Fatalf("reopen did not restore the saved sequence: %v", reopened)
	}
	history := call("get_history", object{"project": handle}, "")
	if !reflect.DeepEqual(history["actions"], []any{"Split Clip"}) || history["cursor"] != float64(1) {
		t.Fatalf("reopen did not restore active native history: %v", history)
	}
	if again := call("close_project", args, ""); !reflect.DeepEqual(again, closed) {
		t.Fatalf("identical close did not replay its receipt: first=%v second=%v", closed, again)
	}
	retry := maps.Clone(args)
	retry["changes"] = "discard"
	call("close_project", retry, "project_closed")
	retry["operationID"] = "fresh-close-on-expired-handle"
	call("close_project", retry, "project_closed")
	if state := call("get_editor_state", object{"project": handle}, ""); state["revision"] != reopened["revision"] {
		t.Fatalf("retry affected the reopened project: %v", state)
	}
	t.Log("verified cancelled close, exact retry after native close and saved history after reopening")
}
