package integration

import (
	"bytes"
	"crypto/rand"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

const fixtureSampleRate = 48000

type audioPlateau struct {
	samples int
	level   int16
}

// The signs and lengths of the plateaus identify which samples made it into an output.
func writeAudioFixture(t *testing.T, path string, plateaus ...audioPlateau) {
	t.Helper()
	var dataBytes uint32
	for _, plateau := range plateaus {
		dataBytes += uint32(plateau.samples * 2)
	}
	var wave bytes.Buffer
	word := func(value uint16) { wave.Write(binary.LittleEndian.AppendUint16(nil, value)) }
	size := func(value uint32) { wave.Write(binary.LittleEndian.AppendUint32(nil, value)) }
	wave.WriteString("RIFF")
	size(36 + dataBytes)
	wave.WriteString("WAVEfmt ")
	size(16)
	word(1) // PCM
	word(1) // mono
	size(fixtureSampleRate)
	size(fixtureSampleRate * 2)
	word(2)
	word(16)
	wave.WriteString("data")
	size(dataBytes)
	for _, plateau := range plateaus {
		for range plateau.samples {
			word(uint16(plateau.level))
		}
	}
	if err := os.WriteFile(path, wave.Bytes(), 0600); err != nil {
		t.Fatal(err)
	}
}

func fileOperationID() string {
	var b [16]byte
	rand.Read(b[:])
	b[6] = (b[6] & 15) | 64
	b[8] = (b[8] & 63) | 128
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[:4], b[4:6], b[6:8], b[8:10], b[10:])
}

func checkFileWorkflows(t *testing.T, call func(string, object, string) object, dir string) {
	t.Helper()
	source := filepath.Join(dir, "Interview Room.wav")
	destination := filepath.Join(dir, "Reordered selects.wav")
	writeAudioFixture(t, source, audioPlateau{fixtureSampleRate / 2, 8192}, audioPlateau{fixtureSampleRate / 2, -16384})

	run := func(tool string, args object, wantState string) object {
		t.Helper()
		args["operation_id"] = fileOperationID()
		first := call(tool, args, "")
		id, ok := first["job_id"].(string)
		if !ok || id == "" {
			t.Fatalf("%s did not start a job: %v", tool, first)
		}
		if retry := call(tool, args, ""); retry["job_id"] != id {
			t.Fatalf("%s duplicated job: %v", tool, retry)
		}
		var result object
		eventually(t, tool, func() bool {
			job := call("file_job_status_read", object{"job_id": id}, "")
			switch job["state"] {
			case "running", "cancelling":
				return false
			case wantState:
				result, ok = job["result"].(object)
				if !ok {
					t.Fatalf("%s missing terminal result: %v", tool, job)
				}
				return true
			default:
				t.Fatalf("%s unexpected job state: %v", tool, job)
				return false
			}
		})
		if tool == "export_file_clips_join" && args["dry_run"] == true {
			// Read the same native report across a byte boundary, as clients must
			// for reports too large to return inline in file_job_status_read.
			var data []byte
			for {
				page := call("file_job_result_read", object{"job_id": id, "offset": len(data), "limit": 512}, "")
				chunk, err := base64.StdEncoding.DecodeString(page["base64"].(string))
				if err != nil || len(chunk) == 0 {
					t.Fatalf("invalid result chunk: %v", page)
				}
				data = append(data, chunk...)
				if page["next_offset"] != float64(len(data)) {
					t.Fatalf("invalid next offset: %v", page)
				}
				if page["done"] == true {
					break
				}
			}
			var report object
			if err := json.Unmarshal(data, &report); err != nil || !reflect.DeepEqual(result, report) {
				t.Fatalf("paged report differs from inline report: %v", err)
			}
		}
		return result
	}
	checkWaveform := func(path string, duration float64, levels []any) {
		t.Helper()
		result := run("waveform_file_envelope_read", object{"file": path, "columns": 2, "no_sidecar": true}, "succeeded")
		env, ok := result["envelope"].(object)
		if !ok || env["to"] != duration || !reflect.DeepEqual(env["low"], levels) || !reflect.DeepEqual(env["high"], levels) {
			t.Fatalf("unexpected signed waveform: %v", result)
		}
	}
	blipSource := filepath.Join(dir, "Quiet with one click.wav")
	writeAudioFixture(t, blipSource, audioPlateau{fixtureSampleRate, 0},
		audioPlateau{fixtureSampleRate * 3 / 10, 8192}, audioPlateau{fixtureSampleRate, 0})
	for _, check := range []struct {
		limit  float64
		pauses int
	}{{0.30, 1}, {0.29, 2}, {0, 2}} {
		report := run("silence_file_scan", object{"file": blipSource, "silence_max_blip_seconds": check.limit, "silence_min_pause_seconds": 0.5, "silence_threshold_db": -40}, "succeeded")
		pauses, ok := report["pauses"].([]any)
		if !ok || len(pauses) != check.pauses || report["max_blip_seconds"] != check.limit {
			t.Fatalf("silence_file_scan at %.2f seconds: %v", check.limit, report)
		}
	}
	// Replay the scanned boundaries through a plan and a write, including the
	// padding on both sides of the bridged click.
	interview := filepath.Join(dir, "Padded interview.wav")
	shortened := filepath.Join(dir, "Shortened interview.wav")
	writeAudioFixture(t, interview, audioPlateau{fixtureSampleRate, 8192}, audioPlateau{fixtureSampleRate, 0},
		audioPlateau{fixtureSampleRate * 3 / 10, 4096}, audioPlateau{fixtureSampleRate, 0}, audioPlateau{fixtureSampleRate, -8192})
	scan := run("silence_file_scan", object{"file": interview, "silence_max_blip_seconds": 0.3,
		"silence_min_pause_seconds": 0.5, "silence_padding_per_side_seconds": 0.2, "silence_threshold_db": -40}, "succeeded")
	replay := object{"report": scan, "output": shortened}
	run("silence_file_plan", replay, "succeeded")
	if _, err := os.Stat(shortened); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("silence plan published its destination: %v", err)
	}
	run("silence_file_export", replay, "succeeded")
	envelope := run("waveform_file_envelope_read", object{"file": shortened, "columns": 1}, "succeeded")["envelope"].(object)
	if envelope["to"] != 2.4 {
		t.Fatalf("shortened duration with 0.2 seconds on each side: %v", envelope)
	}
	checkWaveform(source, 1, []any{0.25, -0.5})
	edit := object{"output": destination, "file": source, "clips": []object{{"from": "3/4", "to": "1"}, {"from": "0", "to": "1/4"}}}
	args := object{"edit": edit, "dry_run": true, "no_sidecar": true}
	plan := run("export_file_clips_join", args, "succeeded")
	if _, err := os.Stat(destination); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("dry-run destination: %v", err)
	}
	args["dry_run"] = false
	actual := run("export_file_clips_join", args, "succeeded")
	if actual["ok"] != true || actual["mode"] != "copy" || actual["output"] != destination || !reflect.DeepEqual(actual["segments"], plan["segments"]) {
		t.Fatalf("export differs from plan: %v", actual)
	}
	checkWaveform(destination, 0.5, []any{-0.5, 0.25})
	if collision := run("export_file_clips_join", args, "failed"); collision["ok"] != false {
		t.Fatalf("existing output accepted: %v", collision)
	}
	checkWaveform(destination, 0.5, []any{-0.5, 0.25})
	t.Log("verified native file analysis, dry-run, WAV export, reordered samples, duplicate jobs, and output collision protection")
}
