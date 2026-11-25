package integration

import (
	"encoding/binary"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func checkSilenceToQueue(t *testing.T, call func(string, object, string) object, dir string, otherProject any, inspectJoin func()) {
	t.Helper()
	source := filepath.Join(dir, "Two Takes.wav")
	writeAudioFixture(t, source, audioPlateau{fixtureSampleRate, 8192},
		audioPlateau{8 * fixtureSampleRate / 10, 0}, audioPlateau{3 * fixtureSampleRate / 10, 4096},
		audioPlateau{9 * fixtureSampleRate / 10, 0}, audioPlateau{fixtureSampleRate, -16384})
	project := call("project_create", object{"operation_id": "new-two-takes", "paths": []string{source}}, "")["project_handle"]
	state := func() object { return call("project_editor_state_read", object{"project_handle": project}, "") }
	original := state()["clips"]
	if clips := original.([]any); len(clips) != 1 || clips[0].(object)["sequence_to"] != "4" {
		t.Fatalf("new audio project did not import four seconds: %v", original)
	}
	mutate := func(name, id string, fields object) object {
		fields["project_handle"] = project
		fields["operation_id"] = id
		fields["expected_revision"] = state()["revision"]
		return call(name, fields, "")
	}
	call("preferences_set", object{"operation_id": "two-takes-config", "key": "silence_max_blip_seconds", "value": 0}, "")
	mutate("silence_editor_threshold_set", "two-takes-threshold", object{"silence_threshold_db": -45})
	scan := mutate("silence_editor_scan", "two-takes-scan", object{})
	eventually(t, "native silence scan", func() bool {
		status := call("analysis_job_status_read", object{"project_handle": project, "job_id": scan["job_id"]}, "")
		switch status["status"] {
		case "succeeded":
			return true
		case "running":
			return false
		default:
			t.Fatalf("silence scan failed: %v", status)
			return false
		}
	})
	call("analysis_job_status_read", object{"project_handle": otherProject, "job_id": scan["job_id"]}, "unknown_job")
	pauses := func() []any {
		return call("silence_editor_pauses_list", object{"project_handle": project}, "")["items"].([]any)
	}
	separated := pauses()
	if len(separated) != 2 {
		t.Fatalf("expected the 300 ms blip to separate two pauses when disabled: %v", separated)
	}
	mutate("silence_editor_pause_review", "two-takes-before-merge", object{
		"action": "set_retained", "pause": separated[0].(object)["id"], "retained_seconds": 0.4,
	})
	call("preferences_set", object{"operation_id": "two-takes-join", "key": "silence_max_blip_seconds", "value": 0.30}, "")
	configured := call("analysis_editor_state_read", object{"project_handle": project}, "")
	if configured["silence_max_blip_seconds"] != 0.30 {
		t.Fatalf("silence_max_blip_seconds readback differs from configured value: %v", configured)
	}
	eventually(t, "updated pause plan", func() bool {
		return call("analysis_editor_state_read", object{"project_handle": project}, "")["silence_ready"] == true
	})
	detected := pauses()
	if len(detected) != 2 || detected[0].(object)["requested_retained_seconds"] != 0.4 ||
		!reflect.DeepEqual(detected[0].(object)["range"], separated[0].(object)["range"]) {
		t.Fatalf("expected redetection to preserve the exact reviewed pause: %v", detected)
	}
	mutate("silence_editor_pause_review", "two-takes-reset-before-merge", object{
		"action": "reset_retained", "pause": detected[0].(object)["id"],
	})
	detected = pauses()
	if len(detected) != 1 {
		t.Fatalf("expected one pause containing the 300 ms blip: %v", detected)
	}
	pause := detected[0].(object)
	quiet := object{"from": "1", "to": "3"}
	if pause["requested_retained_seconds"] != nil || !reflect.DeepEqual(pause["range"], quiet) ||
		!reflect.DeepEqual(pause["removal"], quiet) {
		t.Fatalf("expected to remove exactly the two silent seconds: %v", pause)
	}
	call("preferences_set", object{"operation_id": "two-takes-padding", "key": "silence_padding_per_side_seconds", "value": 0.25}, "")
	padded := pauses()[0].(object)
	if !reflect.DeepEqual(padded["removal"], object{"from": "5/4", "to": "11/4"}) {
		t.Fatalf("expected a quarter second of silence on each side: %v", padded)
	}
	call("preferences_set", object{"operation_id": "two-takes-zero-padding", "key": "silence_padding_per_side_seconds", "value": 0}, "")
	pause = pauses()[0].(object)
	mutate("silence_editor_pause_review", "two-takes-protect", object{"action": "protect", "pause": pause["id"]})
	if kept := pauses()[0].(object); kept["protected"] != true || kept["removal"] != nil {
		t.Fatalf("pause protection did not remove the proposed cut: %v", kept)
	}
	mutate("silence_editor_pause_review", "two-takes-unprotect", object{"action": "unprotect", "pause": pause["id"]})
	override := mutate("silence_editor_pause_review", "two-takes-override", object{
		"action": "set_retained", "pause": pause["id"], "retained_seconds": 0.5,
	})
	if override["retained_seconds"] != 0.5 || override["requested_retained_seconds"] != 0.5 {
		t.Fatalf("unexpected retained-duration result: %v", override)
	}
	mutate("silence_editor_pause_review", "two-takes-reset", object{"action": "reset_retained", "pause": pause["id"]})
	mutate("silence_editor_take_boundary_edit", "two-takes-divider", object{"action": "add", "position": "1/2"})
	candidates := call("silence_editor_take_candidates_list", object{"project_handle": project}, "")["items"].([]any)
	if len(candidates) != 3 || candidates[1].(object)["manual_start"] != true ||
		!reflect.DeepEqual(candidates[1].(object)["range"], object{"from": "1/2", "to": "1"}) {
		t.Fatalf("unexpected take candidates: %v", candidates)
	}
	mutate("silence_editor_take_boundary_edit", "two-takes-remove-divider", object{"action": "remove", "position": "1/2"})
	queued := mutate("silence_editor_takes_queue", "two-takes-queue", object{})
	if queued["queue_count"] != float64(2) || !reflect.DeepEqual(state()["clips"], original) {
		t.Fatalf("queuing takes changed the timeline or produced the wrong count: %v", queued)
	}
	queue := call("export_queue_list", object{"project_handle": project}, "")
	ranges := queue["ranges"].([]any)
	if queue["coordinate_space"] != "sequence" || len(ranges) != 2 ||
		ranges[0].(object)["from"] != "0" || ranges[0].(object)["to"] != "1" ||
		ranges[1].(object)["from"] != "3" || ranges[1].(object)["to"] != "4" {
		t.Fatalf("unexpected queued ranges: %v", queue)
	}
	output := filepath.Join(dir, "Exported Takes")
	if err := os.Mkdir(output, 0700); err != nil {
		t.Fatal(err)
	}
	export := func(id string, dryRun bool) object {
		t.Helper()
		tool := "export_queue_render"
		if dryRun {
			tool = "export_queue_plan"
		}
		started := mutate(tool, id, object{"output": output, "container": "wav", "mode": "copy", "tracks": "audio"})
		call("export_editor_job_status_read", object{"project_handle": otherProject, "job_id": started["job_id"]}, "unknown_job")
		var status object
		eventually(t, id, func() bool {
			status = call("export_editor_job_status_read", object{"project_handle": project, "job_id": started["job_id"]}, "")
			switch status["state"] {
			case "succeeded":
				return true
			case "running":
				return false
			default:
				t.Fatalf("take export failed: %v", status)
				return false
			}
		})
		if status["input_revision"] != started["input_revision"] {
			t.Fatalf("revision changed in export receipt: %v, %v", started, status)
		}
		return status
	}
	plan := export("two-takes-preflight", true)
	if entries, err := os.ReadDir(output); err != nil || len(entries) != 0 || len(plan["outputs"].([]any)) != 0 {
		t.Fatalf("take dry-run created outputs: %v %v (%v)", entries, plan, err)
	}
	modified := mutate("silence_editor_pauses_shorten", "two-takes-shorten", object{})
	shorter := state()
	if clips := shorter["clips"].([]any); len(clips) != 2 || clips[1].(object)["sequence_to"] != "2" || modified["revision"] != shorter["revision"] {
		t.Fatalf("shorten returned without the expected committed edit: %v %v", modified, shorter)
	}
	retained := shorter["clips"].([]any)
	if retained[0].(object)["document_id"] == retained[1].(object)["document_id"] || shorter["notice"] != nil {
		t.Fatalf("shorten did not produce a recoverable sequence with distinct authored clip IDs: %v", shorter)
	}
	eventually(t, "shortened timeline ready to preview", func() bool { return state()["can_edit"] == true })
	join := mutate("timeline_editor_join_preview", "two-takes-preview-join",
		object{"before_clip_id": shorter["clips"].([]any)[1].(object)["id"]})
	if join["clock"] != "sequence" || join["position"] != "1" || join["review_open"] != true {
		t.Fatalf("join preview did not open around the first retained edit: %v", join)
	}
	mutate("silence_editor_pause_review", "two-takes-close-join-review", object{"action": "done"})
	eventually(t, "join review closed", func() bool {
		current := state()
		return current["modal"] == false && current["can_edit"] == true
	})
	mutate("timeline_selection_set", "two-takes-select-join", object{
		"action": "select", "occurrence": shorter["clips"].([]any)[1].(object)["id"],
	})
	if selected := state()["selected_clip"]; selected != retained[1].(object)["id"] {
		t.Fatalf("native join needs the right-hand clip selected, got %v", selected)
	}
	call("project_window_focus", object{"project_handle": project}, "")
	inspectJoin()
	if current := state(); current["revision"] != shorter["revision"] || !reflect.DeepEqual(current["clips"], shorter["clips"]) {
		t.Fatalf("auditioning a join changed the timeline: %v", current)
	}
	want := []any{filepath.Join(output, "Two Takes-001.wav"), filepath.Join(output, "Two Takes-002.wav")}
	actual := export("two-takes-export", false)
	if !reflect.DeepEqual(plan["result"].(object)["destinations"], want) || !reflect.DeepEqual(actual["outputs"], want) {
		t.Fatalf("take export destinations or order differ from plan: %v %v", plan, actual)
	}
	checkPCMPlateau(t, want[0].(string), 8192)
	checkPCMPlateau(t, want[1].(string), -16384)
	history := call("history_read", object{"project_handle": project}, "")["actions"].([]any)
	if len(history) == 0 || history[len(history)-1] != "Shorten Pauses" {
		t.Fatalf("shorten did not create a native history entry: %v", history)
	}
	mutate("history_undo", "two-takes-undo", object{})
	restored := state()
	if !reflect.DeepEqual(restored["clips"], original) {
		t.Fatal("Undo did not restore the original unshortened WAV occurrence")
	}
	call("project_close", object{"project_handle": project, "expected_revision": restored["revision"],
		"operation_id": "two-takes-close-without-decision"}, "unsaved_changes")
	mutate("project_close", "two-takes-discard", object{"changes": "discard"})
	t.Log("verified silence protection, native take queue, dry-run, lossless WAV output, shortening and Undo")
}

// Decode the WAV's PCM chunks independently of MPCut's waveform or file-job reports.
func checkPCMPlateau(t *testing.T, path string, level int16) {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if len(data) < 12 || string(data[:4]) != "RIFF" || string(data[8:12]) != "WAVE" {
		t.Fatalf("%s is not a RIFF WAV", path)
	}
	var hasFormat, hasSamples bool
	for data = data[12:]; len(data) >= 8; {
		kind := string(data[:4])
		size := int(binary.LittleEndian.Uint32(data[4:8]))
		end := 8 + size + size%2
		if end > len(data) {
			t.Fatalf("%s WAV chunk %q exceeds available bytes", path, kind)
		}
		chunk := data[8 : 8+size]
		switch kind {
		case "fmt ":
			hasFormat = len(chunk) >= 16 && binary.LittleEndian.Uint16(chunk[0:2]) == 1 &&
				binary.LittleEndian.Uint16(chunk[2:4]) == 1 && binary.LittleEndian.Uint32(chunk[4:8]) == fixtureSampleRate &&
				binary.LittleEndian.Uint16(chunk[14:16]) == 16
		case "data":
			if len(chunk) != 2*fixtureSampleRate {
				t.Fatalf("%s WAV had %d sample bytes, want %d", path, len(chunk), 2*fixtureSampleRate)
			}
			for i := 0; i < len(chunk); i += 2 {
				if value := int16(binary.LittleEndian.Uint16(chunk[i : i+2])); value != level {
					t.Fatalf("%s sample %d = %d, want %d", path, i/2, value, level)
				}
			}
			hasSamples = true
		}
		data = data[end:]
	}
	if !hasFormat || !hasSamples {
		t.Fatalf("%s must contain mono 48 kHz PCM and a data chunk", path)
	}
}
