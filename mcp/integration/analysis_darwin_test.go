package integration

import (
	"encoding/binary"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func checkSilenceToQueue(t *testing.T, call func(string, object, string) object, dir string, otherProject any) {
	t.Helper()
	source := filepath.Join(dir, "Two Takes.wav")
	writeAudioFixture(t, source, audioPlateau{fixtureSampleRate, 8192},
		audioPlateau{2 * fixtureSampleRate, 0}, audioPlateau{fixtureSampleRate, -16384})
	project := call("new_project", object{"operationID": "new-two-takes", "paths": []string{source}}, "")["project"]
	state := func() object { return call("get_editor_state", object{"project": project}, "") }
	original := state()["clips"]
	if clips := original.([]any); len(clips) != 1 || clips[0].(object)["sequenceTo"] != "4" {
		t.Fatalf("new audio project did not import four seconds: %v", original)
	}
	mutate := func(name, id string, fields object) object {
		fields["project"] = project
		fields["operationID"] = id
		fields["expectedRevision"] = state()["revision"]
		return call(name, fields, "")
	}
	mutate("configure_silence", "two-takes-config", object{"thresholdDB": -45})
	scan := mutate("scan_analysis", "two-takes-scan", object{"kind": "silence"})
	eventually(t, "native silence scan", func() bool {
		status := call("analysis_job_status", object{"project": project, "job": scan["job"]}, "")
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
	call("analysis_job_status", object{"project": otherProject, "job": scan["job"]}, "unknown_job")
	pauses := func() []any {
		return call("list_pauses", object{"project": project}, "")["items"].([]any)
	}
	detected := pauses()
	if len(detected) != 1 {
		t.Fatalf("expected one interior digital-silence interval: %v", detected)
	}
	pause := detected[0].(object)
	quiet := object{"from": "1", "to": "3"}
	if !reflect.DeepEqual(pause["range"], quiet) || !reflect.DeepEqual(pause["removal"], quiet) {
		t.Fatalf("expected to remove exactly the two silent seconds: %v", pause)
	}
	mutate("review_pause", "two-takes-protect", object{"action": "protect", "pause": pause["id"]})
	if kept := pauses()[0].(object); kept["protected"] != true || kept["removal"] != nil {
		t.Fatalf("pause protection did not remove the proposed cut: %v", kept)
	}
	mutate("review_pause", "two-takes-unprotect", object{"action": "unprotect", "pause": pause["id"]})
	queued := mutate("apply_pauses", "two-takes-queue", object{"mode": "queue"})
	if queued["queueCount"] != float64(2) || !reflect.DeepEqual(state()["clips"], original) {
		t.Fatalf("queuing takes changed the timeline or produced the wrong count: %v", queued)
	}
	queue := call("get_export_queue", object{"project": project}, "")
	ranges := queue["ranges"].([]any)
	if queue["coordinateSpace"] != "sequence" || len(ranges) != 2 ||
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
		started := mutate("export_queue", id, object{"output": output, "container": "wav", "mode": "copy", "tracks": "audio", "dryRun": dryRun})
		call("live_job_status", object{"project": otherProject, "job": started["job"]}, "unknown_job")
		var status object
		eventually(t, id, func() bool {
			status = call("live_job_status", object{"project": project, "job": started["job"]}, "")
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
		if status["inputRevision"] != started["inputRevision"] {
			t.Fatalf("revision changed in export receipt: %v, %v", started, status)
		}
		return status
	}
	plan := export("two-takes-preflight", true)
	if entries, err := os.ReadDir(output); err != nil || len(entries) != 0 || len(plan["outputs"].([]any)) != 0 {
		t.Fatalf("take dry-run created outputs: %v %v (%v)", entries, plan, err)
	}
	modified := mutate("apply_pauses", "two-takes-shorten", object{"mode": "shorten"})
	shorter := state()
	if clips := shorter["clips"].([]any); len(clips) != 2 || clips[1].(object)["sequenceTo"] != "2" || modified["revision"] != shorter["revision"] {
		t.Fatalf("shorten returned without the expected committed edit: %v %v", modified, shorter)
	}
	want := []any{filepath.Join(output, "Two Takes-001.wav"), filepath.Join(output, "Two Takes-002.wav")}
	actual := export("two-takes-export", false)
	if !reflect.DeepEqual(plan["result"].(object)["destinations"], want) || !reflect.DeepEqual(actual["outputs"], want) {
		t.Fatalf("take export destinations or order differ from plan: %v %v", plan, actual)
	}
	checkPCMPlateau(t, want[0].(string), 8192)
	checkPCMPlateau(t, want[1].(string), -16384)
	history := call("get_history", object{"project": project}, "")["actions"].([]any)
	if len(history) == 0 || history[len(history)-1] != "Shorten Pauses" {
		t.Fatalf("shorten did not create a native history entry: %v", history)
	}
	mutate("undo", "two-takes-undo", object{})
	restored := state()
	if !reflect.DeepEqual(restored["clips"], original) {
		t.Fatal("Undo did not restore the original unshortened WAV occurrence")
	}
	call("close_project", object{"project": project, "expectedRevision": restored["revision"],
		"operationID": "two-takes-close-without-decision"}, "unsaved_changes")
	mutate("close_project", "two-takes-discard", object{"changes": "discard"})
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
