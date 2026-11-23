package integration

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func checkTranscriptMCP(t *testing.T, call func(string, object, string) object, dir string) {
	t.Helper()
	fixture := func(name, text string) string {
		t.Helper()
		path := filepath.Join(dir, name)
		if err := os.WriteFile(path, []byte(text), 0600); err != nil {
			t.Fatal(err)
		}
		return path
	}
	asset := filepath.Join(dir, "Transcript room.wav")
	writeAudioFixture(t, asset, audioPlateau{4 * fixtureSampleRate, 512})
	path := fixture("Transcript fixture.cut", `{"format":"mpcut","schema_version":3,"kind":"sequence","clips":[{"id":"first","file":"Transcript room.wav","from":"0","to":"4"},{"id":"again","file":"Transcript room.wav","from":"0","to":"4"}]}`)
	var cues strings.Builder
	for second := 0; second < 4; second++ {
		fmt.Fprintf(&cues, "%d\n00:00:%02d,250 --> 00:00:%02d,750\nThe same quote.\n\n", second+1, second, second)
	}
	subtitles := fixture("Transcript room.srt", cues.String())

	open := func(operation string) any {
		t.Helper()
		project := call("project_open", object{"project_path": path, "operation_id": operation}, "")["project_handle"]
		eventually(t, "transcript fixture media indexing", func() bool {
			state := call("project_editor_state_read", object{"project_handle": project}, "")
			return state["busy"] == false && state["total"] == float64(2)
		})
		return project
	}
	project := open("open-transcript-mcp")
	inspect := func() object { return call("transcript_editor_attachments_list", object{"project_handle": project}, "") }
	empty := inspect()
	inventory := call("transcript_tracks_list", object{"project_handle": project, "limit": 1}, "")
	if inventory["total"] != float64(1) || inventory["recognition_duration_seconds"] != float64(4) {
		t.Fatalf("repeated clip should list its input once: %v", inventory)
	}
	arguments := object{"project_handle": project, "expected_revision": empty["revision"],
		"expected_transcript_revision": empty["transcript_revision"], "operation_id": "import-transcript-mcp",
		"path": subtitles, "format": "srt", "origin": "0",
		"bindings": []object{{"track_id": "source", "file": asset, "audio_stream_index": 0}}}
	imported := call("transcript_editor_attachment_import", arguments, "")
	if replay := call("transcript_editor_attachment_import", arguments, ""); !reflect.DeepEqual(imported, replay) {
		t.Fatalf("import did not replay its exact receipt: first=%v replay=%v", imported, replay)
	}
	if imported["revision"] != empty["revision"] || imported["transcript_revision"] == empty["transcript_revision"] ||
		imported["attachment_id"] == nil || imported["result_id"] == nil {
		t.Fatalf("import did not update the independent transcript stamp: %v", imported)
	}
	searchArgs := object{"project_handle": project, "query": "THE SAME QUOTE",
		"space": "current_cut", "limit": 1, "expected_revision": imported["revision"],
		"expected_transcript_revision": imported["transcript_revision"], "result_id": imported["result_id"]}
	search := call("transcript_editor_words_search", searchArgs, "")
	if search["total"] != float64(8) || search["next_offset"] != float64(1) {
		t.Fatalf("unexpected first search page: %v", search)
	}
	searchArgs["offset"] = 4
	repeat := call("transcript_editor_words_search", searchArgs, "")
	row := func(page object) object {
		t.Helper()
		items := page["items"].([]any)
		if len(items) != 1 {
			t.Fatalf("search page has %d items: %v", len(items), page)
		}
		return items[0].(object)["words"].([]any)[0].(object)
	}
	firstShot, repeatShot := row(search), row(repeat)
	if firstShot["word_id"] != repeatShot["word_id"] || firstShot["id"] == repeatShot["id"] {
		t.Fatalf("repeat should preserve the word ID and have its own occurrence ID: %v %v", firstShot, repeatShot)
	}
	evidence := call("transcript_editor_word_evidence_read", object{"project_handle": project, "word_id": firstShot["word_id"], "limit": 1}, "")
	if evidence["total"] != float64(0) {
		t.Fatalf("external cue should have no provider observations: %v", evidence)
	}
	binding := func() object {
		page := call("transcript_editor_bindings_list", object{"project_handle": project, "limit": 1}, "")
		if page["total"] != float64(1) {
			t.Fatalf("expected one stream binding: %v", page)
		}
		return page["items"].([]any)[0].(object)
	}
	if got := binding(); got["source_status"] != "available" {
		t.Fatalf("explicit source binding is unavailable: %v", got)
	}

	destination := filepath.Join(dir, "Current cut captions.vtt")
	job := call("transcript_editor_attachment_export", object{"project_handle": project, "expected_revision": imported["revision"],
		"expected_transcript_revision": imported["transcript_revision"], "result_id": imported["result_id"],
		"operation_id": "export-transcript-mcp", "format": "vtt", "path": destination}, "")
	eventually(t, "current-cut transcript export", func() bool {
		result := call("export_editor_job_status_read", object{"project_handle": project, "job_id": job["job_id"]}, "")
		switch result["state"] {
		case "running":
			return false
		case "succeeded":
			return true
		default:
			t.Fatalf("transcript export failed: %v", result)
			return false
		}
	})
	if data, err := os.ReadFile(destination); err != nil || !strings.Contains(string(data), "00:00:04.250 --> 00:00:04.750") {
		t.Fatalf("transcript export lost the repeated cue: %v\n%s", err, data)
	}
	call("project_save", object{"project_handle": project, "expected_revision": imported["revision"], "operation_id": "save-transcript-mcp"}, "")
	fileArgs := object{"operation_id": fileOperationID(),
		"request": object{"project_path": path, "query": "the same quote", "space": "current_cut", "offset": 4, "limit": 1}}
	fileJob := call("transcript_file_words_search", fileArgs, "")
	if replay := call("transcript_file_words_search", fileArgs, ""); replay["job_id"] != fileJob["job_id"] {
		t.Fatalf("saved-file transcript replay returned another job: %v %v", fileJob, replay)
	}
	eventually(t, "saved-file transcript search", func() bool {
		job := call("file_job_status_read", object{"job_id": fileJob["job_id"]}, "")
		switch job["state"] {
		case "running":
			return false
		case "succeeded":
			page := job["result"].(object)
			if page["total"] != float64(8) || row(page)["word_id"] != repeatShot["word_id"] {
				t.Fatalf("saved-file transcript result differs from live search: %v", page)
			}
			return true
		default:
			t.Fatalf("file transcript job failed: %v", job)
			return false
		}
	})
	call("project_close", object{"project_handle": project, "expected_revision": imported["revision"],
		"operation_id": "close-transcript-mcp", "changes": "discard"}, "")
	call("transcript_editor_attachments_list", object{"project_handle": project}, "project_closed")
	project = open("reopen-transcript-mcp")
	if got := inspect(); got["total"] != float64(1) || got["result_id"] != imported["result_id"] {
		t.Fatalf("reopen lost the imported attachment: %v", got)
	}
	offline := filepath.Join(dir, "Transcript room offline.wav")
	if err := os.Rename(asset, offline); err != nil {
		t.Fatal(err)
	}
	defer os.Rename(offline, asset)
	if got := binding(); got["source_status"] != "offline" {
		t.Fatalf("missing media should differ from a missing transcript asset: %v", got)
	}
	t.Log("verified live transcript import, replay, repeated occurrences, paged evidence, subtitle export and saved-file search")
}

func checkTranscriptProvider(t *testing.T, call func(string, object, string) object, dir, helper, fixture string) {
	t.Helper()
	media := filepath.Join(dir, "Provider source.wav")
	writeAudioFixture(t, media, audioPlateau{fixtureSampleRate, 8192})
	writeAudioFixture(t, filepath.Join(dir, "Provider source B.wav"), audioPlateau{fixtureSampleRate, 4096})
	saved := filepath.Join(dir, "Provider source.cut")
	if err := os.WriteFile(saved, []byte(`{"format":"mpcut","schema_version":3,"kind":"sequence","clips":[{"id":"source","file":"Provider source.wav","from":"0","to":"1"},{"id":"source-b","file":"Provider source B.wav","from":"0","to":"1"}]}`), 0600); err != nil {
		t.Fatal(err)
	}
	project := call("project_open", object{"project_path": saved, "operation_id": "open-provider-fixture"}, "")["project_handle"]
	eventually(t, "provider fixture indexing", func() bool {
		state := call("project_editor_state_read", object{"project_handle": project}, "")
		return state["busy"] == false && state["total"] == float64(2)
	})
	call("transcript_provider_capabilities_read", object{"project_handle": project}, "transcript_helper_unavailable")
	handoff := call("transcript_file_job_prepare", object{"operation_id": fileOperationID(),
		"request": object{"project_path": saved, "job_directory": filepath.Join(dir, "file-transcript-handoff")}}, "")
	eventually(t, "saved-file handoff without a provider", func() bool {
		job := call("file_job_status_read", object{"job_id": handoff["job_id"]}, "")
		switch job["state"] {
		case "running":
			return false
		case "succeeded":
			result := job["result"].(object)
			if result["state"] != "prepared" || len(result["sessions"].([]any)) != 2 || job["progress_event"] == nil {
				t.Fatalf("saved-file handoff omitted prepared input or progress: %v", job)
			}
			return true
		default:
			t.Fatalf("file staging should work without a provider: %v", job)
			return false
		}
	})
	python, err := exec.LookPath("python3")
	if err != nil {
		t.Skip("Python 3 is required for the stub provider")
	}
	data, err := os.ReadFile(fixture)
	if err != nil {
		t.Fatal(err)
	}
	// Darwin cannot use a shell-based pyenv shim as another script's interpreter.
	executable, err := exec.Command(python, "-c", "import os, sys; print(os.path.realpath(sys.executable))").Output()
	if err != nil {
		t.Fatalf("discover real Python interpreter: %v", err)
	}
	interpreter := strings.TrimSpace(string(executable))
	if !filepath.IsAbs(interpreter) {
		t.Fatalf("Python reported an invalid executable path: %q", interpreter)
	}
	_, body, _ := strings.Cut(string(data), "\n")
	if err := os.WriteFile(helper, []byte("#!"+interpreter+"\n"+body), 0700); err != nil {
		t.Fatal(err)
	}
	capabilities := call("transcript_provider_capabilities_read", object{"project_handle": project}, "")
	if capabilities["session_schema_version"] != float64(1) {
		t.Fatalf("provider session capabilities unavailable: %v", capabilities)
	}
	inspect := func() object { return call("transcript_editor_attachments_list", object{"project_handle": project}, "") }
	start := func(engine string) object {
		t.Helper()
		state := inspect()
		args := object{"project_handle": project, "expected_revision": state["revision"],
			"expected_transcript_revision": state["transcript_revision"], "operation_id": fileOperationID(),
			"policy": "restart", "options": object{"engine": engine}}
		job := call("transcript_editor_job_start", args, "")
		if other := call("transcript_editor_job_start", args, ""); other["job_id"] != job["job_id"] {
			t.Fatalf("provider job replay produced an unexpected receipt: %v", other)
		}
		return job
	}
	jobStatus := func(id any) object {
		t.Helper()
		// Poll durable list since a new job's first record is written by its worker.
		records := call("transcript_editor_jobs_list", object{"project_handle": project}, "")["items"].([]any)
		for _, candidate := range records {
			if candidate.(object)["job_id"] == id {
				return call("transcript_editor_job_status_read", object{"project_handle": project, "job_id": id, "limit": 1}, "")
			}
		}
		return object{}
	}
	id := start("speaker-test")["job_id"]
	eventually(t, "partial result attached", func() bool {
		status := jobStatus(id)
		if status["state"] == "failed" || status["attachment_error"] != nil {
			t.Fatalf("stub helper could not publish a partial session: %v", status)
		}
		if status["state"] != "partial" || status["attached"] != true {
			return false
		}
		item := status["items"].([]any)[0].(object)
		if track := item["track"].(object); track["state"] != "failed" || item["fingerprint"] == nil {
			t.Fatalf("partial result lost failed track evidence: %v", item)
		}
		return true
	})
	call("transcript_editor_job_retry", object{"project_handle": project, "job_id": id, "operation_id": fileOperationID()}, "")
	eventually(t, "retry result attached", func() bool {
		status := jobStatus(id)
		if status["state"] == "failed" || status["attachment_error"] != nil {
			t.Fatalf("retry failed: %v", status)
		}
		return status["state"] == "completed" && status["attached"] == true
	})
	page := call("transcript_editor_words_search", object{"project_handle": project, "query": "ready", "limit": 1}, "")
	if page["total"] != float64(2) || inspect()["total"] != float64(2) {
		t.Fatalf("retry should expose one recognized word per source and avoid duplicate attachments: %v", page)
	}
	pin := inspect()
	call("project_save", object{"project_handle": project, "expected_revision": pin["revision"], "operation_id": fileOperationID()}, "")
	eventually(t, "saved transcription acknowledgement", func() bool { return jobStatus(id)["saved_attachment"] == true })
	pin = inspect()
	oldAttempt := jobStatus(id)["attempt_id"]
	if oldAttempt == nil {
		t.Fatal("completed transcript status omitted the attempt identity")
	}
	reconcile := object{"project_handle": project, "attachment_id": pin["attachment_id"],
		"result_id": pin["result_id"], "operation_id": fileOperationID(), "expected_revision": pin["revision"],
		"expected_transcript_revision": pin["transcript_revision"].(float64) - 1}
	call("transcript_editor_job_reconcile", reconcile, "stale_transcript_plan")
	reconcile["operation_id"] = fileOperationID()
	reconcile["expected_transcript_revision"] = pin["transcript_revision"]
	receipt := call("transcript_editor_job_reconcile", reconcile, "")
	if receipt["job_id"] != id || !reflect.DeepEqual(receipt, call("transcript_editor_job_reconcile", reconcile, "")) {
		t.Fatalf("completed-job retry did not replay the same durable job receipt: %v", receipt)
	}
	eventually(t, "completed job can reconcile", func() bool {
		status := jobStatus(id)
		if status["state"] == "failed" || status["attachment_error"] != nil {
			t.Fatalf("completed-job retry failed: %v", status)
		}
		if status["state"] == "completed" && status["attached"] == true {
			if status["attempt_id"] == nil || status["attempt_id"] == oldAttempt {
				t.Fatalf("reconciliation returned the previous completion: %v", status)
			}
			return true
		}
		return false
	})
	hold := start("hold")["job_id"]
	eventually(t, "waiting stub provider", func() bool {
		status := jobStatus(hold)
		return status["state"] == "running"
	})
	call("transcript_editor_job_cancel", object{"project_handle": project, "job_id": hold, "operation_id": fileOperationID()}, "")
	eventually(t, "cancelled provider result", func() bool { return jobStatus(hold)["state"] == "cancelled" })
	other := call("project_create", object{"operation_id": "provider-scope-check"}, "")["project_handle"]
	call("transcript_editor_job_status_read", object{"project_handle": other, "job_id": id}, "transcript_job_not_found")
	t.Log("verified missing helper, durable provider receipt, partial coverage, retry, unique attachments, cancellation and project ownership")
}

func checkTranscriptProjectMCP(t *testing.T, call func(string, object, string) object, dir string) {
	t.Helper()
	write := func(name, value string) string {
		t.Helper()
		path := filepath.Join(dir, name)
		if err := os.WriteFile(path, []byte(value), 0600); err != nil {
			t.Fatal(err)
		}
		return path
	}
	path := write("Transcript project-wide.cut", `{"format":"mpcut","schema_version":3,"kind":"sequence","clips":[{"id":"z","file":"Z interview.wav","from":"0","to":"2"},{"id":"a","file":"A interview.wav","from":"0","to":"2"}]}`)
	type media struct{ file, subtitle string }
	var inputs []media
	// Attach in the opposite order from the cut. Each JSON transcript emits the same word IDs and
	// generic source track ID, so neither can be used as a project-wide key.
	for _, name := range []string{"A", "Z"} {
		file := filepath.Join(dir, name+" interview.wav")
		writeAudioFixture(t, file, audioPlateau{2 * fixtureSampleRate, 2048})
		inputs = append(inputs, media{file, write(name+" interview.json", fmt.Sprintf(
			`{"source":"%s interview.wav","duration_seconds":2,"metadata":{},"segments":[{"start":0.25,"end":0.75,"words":[{"text":"Same","start":0.25,"end":0.4},{"text":" phrase","start":0.4,"end":0.55},{"text":" %s","start":0.55,"end":0.75}]}]}`, name, name))})
	}
	project := call("project_open", object{"project_path": path, "operation_id": "open-project-wide-transcripts"}, "")["project_handle"]
	eventually(t, "project-wide fixture indexing", func() bool {
		state := call("project_editor_state_read", object{"project_handle": project}, "")
		return state["busy"] == false && state["total"] == float64(2)
	})
	inventory := call("transcript_tracks_list", object{"project_handle": project}, "")
	trackID := inventory["items"].([]any)[0].(object)["track"].(object)["id"]
	subset := call("transcript_tracks_list", object{"project_handle": project,
		"options": object{"selected_tracks": []any{trackID}}}, "")
	if subset["total"] != float64(2) || subset["recognition_duration_seconds"] != float64(2) {
		t.Fatalf("track inventory ignored the requested recognition scope: %v", subset)
	}
	read := func(tool string, input object, expectedError string) object {
		t.Helper()
		input["project_handle"] = project
		return call(tool, input, expectedError)
	}
	ids := make([]any, 0, len(inputs))
	for _, input := range inputs {
		stamp := read("transcript_editor_attachments_list", object{}, "")
		result := call("transcript_editor_attachment_import", object{"project_handle": project, "operation_id": fileOperationID(),
			"expected_revision": stamp["revision"], "expected_transcript_revision": stamp["transcript_revision"],
			"path": input.subtitle, "format": "json", "origin": "1/4",
			"bindings": []object{{"track_id": "source", "file": input.file, "audio_stream_index": 0, "offset": "0"}},
		}, "")
		ids = append(ids, result["attachment_id"])
	}
	first := read("transcript_editor_words_read", object{"space": "current_cut", "limit": 1}, "")
	if first["total"] != float64(6) || first["next_offset"] != float64(1) || first["result_id"] != nil {
		t.Fatalf("project-wide page should report both attachments: %v", first)
	}
	obtain := func(page object) object {
		t.Helper()
		return page["items"].([]any)[0].(object)
	}
	second := read("transcript_editor_words_read", object{"space": "current_cut", "limit": 1, "offset": 3,
		"expected_revision": first["revision"], "expected_transcript_revision": first["transcript_revision"],
		"expected_attachment_results": first["attachment_results"]}, "")
	z, a := obtain(first), obtain(second)
	if z["attachment_id"] != ids[1] || a["attachment_id"] != ids[0] || z["word_id"] != a["word_id"] ||
		z["id"] == a["id"] || z["clip_id"] != "z" || a["clip_id"] != "a" {
		t.Fatalf("clock order or attachment namespace lost: %v %v", z, a)
	}
	if got := read("transcript_editor_words_search", object{"query": "same phrase", "limit": 1, "clip_id": "a"}, ""); got["total"] != float64(1) {
		t.Fatalf("project-wide search did not respect the clip filter: %v", got)
	}
	if got := read("transcript_editor_words_search", object{"query": "Z same"}, ""); got["total"] != float64(0) {
		t.Fatalf("phrase search joined independent recordings: %v", got)
	}
	if got := read("transcript_editor_occurrences_locate", object{"word_id": z["word_id"]}, ""); got["total"] != float64(2) {
		t.Fatalf("project-wide locate lost one scoped word: %v", got)
	}
	if got := read("transcript_editor_occurrences_locate", object{"occurrence_id": a["id"]}, ""); got["total"] != float64(1) || obtain(got)["attachment_id"] != ids[0] {
		t.Fatalf("project-wide occurrence ID resolved incorrectly: %v", got)
	}
	if got := read("transcript_editor_takes_compare", object{"query": "same phrase"}, ""); got["total"] != float64(2) {
		t.Fatalf("project-wide comparison did not include both attachments: %v", got)
	}
	if got := read("transcript_editor_edits_suggest", object{"filler_terms": []string{"same"}}, ""); got["total"] != float64(2) {
		t.Fatalf("project-wide suggestions did not include both attachments: %v", got)
	}
	if got := read("transcript_editor_script_align", object{"script": "same phrase"}, ""); obtain(got)["candidate_count"] != float64(2) {
		t.Fatalf("script summary lost candidates: %v", got)
	}
	if got := read("transcript_editor_script_candidates_list", object{"script": "same phrase", "beat": 0, "limit": 1, "offset": 1}, ""); got["total"] != float64(2) {
		t.Fatalf("script candidate page lost candidates: %v", got)
	}
	if got := read("transcript_editor_coverage_read", object{"space": "current_cut"}, ""); got["coverage_available"] != true {
		t.Fatalf("current cut coverage unavailable: %v", got)
	} else {
		for _, row := range got["items"].([]any) {
			if row.(object)["reason"] == "unbound" {
				t.Fatalf("one attachment should cover the other attachment's unbound route: %v", got)
			}
		}
	}
	source := read("transcript_editor_coverage_read", object{"space": "source", "track_limit": 1}, "")
	sourceTracks, hasTracks := source["tracks"].(object)
	if source["coverage_available"] != true || source["space"] != "source" || !hasTracks ||
		sourceTracks["total"] != float64(2) || sourceTracks["next_offset"] != float64(1) {
		t.Fatalf("source coverage did not page its independent track statuses: %v", source)
	}
	laterSource := read("transcript_editor_coverage_read", object{"space": "source", "track_limit": 1, "track_offset": sourceTracks["next_offset"],
		"expected_transcript_revision": source["transcript_revision"], "expected_attachment_results": source["attachment_results"]}, "")
	firstTrack, laterTrack := obtain(sourceTracks), obtain(laterSource["tracks"].(object))
	if firstTrack["attachment_id"] == laterTrack["attachment_id"] || firstTrack["coverage"] != "recognized" ||
		laterTrack["coverage"] != "recognized" || firstTrack["bounds"] == nil || laterTrack["bounds"] == nil {
		t.Fatalf("source track statuses lost their binding, recognition state or bounds: %v %v", firstTrack, laterTrack)
	}
	read("transcript_editor_word_evidence_read", object{"word_id": z["word_id"]}, "transcript_attachment_required")
	pinA := read("transcript_editor_attachments_list", object{"attachment_id": ids[0]}, "")
	call("transcript_editor_selection_mark", object{"project_handle": project, "attachment_id": ids[0], "result_id": pinA["result_id"],
		"expected_revision": pinA["revision"], "expected_transcript_revision": pinA["transcript_revision"], "operation_id": fileOperationID(),
		"selection": object{"attachment_id": ids[1], "first_word_id": z["word_id"]}}, "stale_transcript_plan")
	call("transcript_editor_attachment_bind", object{"project_handle": project, "attachment_id": ids[0], "result_id": pinA["result_id"],
		"expected_revision": pinA["revision"], "expected_transcript_revision": pinA["transcript_revision"], "operation_id": fileOperationID(),
		"bindings": []object{{"track_id": "source", "file": inputs[0].file, "audio_stream_index": 0, "offset": "1/4"}}}, "")
	read("transcript_editor_words_read", object{"expected_transcript_revision": first["transcript_revision"], "expected_attachment_results": first["attachment_results"]},
		"stale_transcript_plan")
	pinA = read("transcript_editor_attachments_list", object{"attachment_id": ids[0]}, "")
	if origin := obtain(pinA)["import_origin"].(object); origin["numerator"] != float64(1) || origin["denominator"] != float64(4) {
		t.Fatalf("bind with omitted origin changed the clock: %v", origin)
	}
	out := filepath.Join(dir, "Project-wide transcript.txt")
	job := call("transcript_editor_attachment_export", object{"project_handle": project, "path": out, "format": "text",
		"expected_revision": pinA["revision"], "expected_transcript_revision": pinA["transcript_revision"], "operation_id": fileOperationID()}, "")
	eventually(t, "project-wide transcript export", func() bool {
		result := call("export_editor_job_status_read", object{"project_handle": project, "job_id": job["job_id"]}, "")
		if result["state"] == "failed" {
			t.Fatalf("project-wide export failed: %v", result)
		}
		return result["state"] == "succeeded"
	})
	data, err := os.ReadFile(out)
	if err != nil || !strings.Contains(string(data), "Same phrase Z\nSame phrase A") {
		t.Fatalf("project-wide export is missing one source or reordered the cut: %s %v", data, err)
	}
	call("project_save", object{"project_handle": project, "expected_revision": pinA["revision"], "operation_id": fileOperationID()}, "")
	help := call("cli_help_read", object{"topic": "transcript", "operation_id": fileOperationID()}, "")
	eventually(t, "transcript help", func() bool {
		job := call("file_job_status_read", object{"job_id": help["job_id"]}, "")
		if job["state"] == "failed" {
			t.Fatalf("cli_help_read transcript failed: %v", job)
		}
		return job["state"] == "succeeded"
	})
	fileJob := call("transcript_file_words_read", object{"operation_id": fileOperationID(),
		"request": object{"project_path": path, "space": "current_cut", "offset": 3, "limit": 1}}, "")
	eventually(t, "saved project-wide read", func() bool {
		result := call("file_job_status_read", object{"job_id": fileJob["job_id"]}, "")
		if result["state"] == "failed" {
			t.Fatalf("saved project-wide read failed: %v", result)
		}
		if result["state"] != "succeeded" {
			return false
		}
		live := obtain(read("transcript_editor_words_read", object{"space": "current_cut", "offset": 3, "limit": 1}, ""))
		saved := obtain(result["result"].(object))
		for _, key := range []string{"attachment_id", "word_id", "clip_id", "range", "track_id"} {
			if !reflect.DeepEqual(live[key], saved[key]) {
				t.Fatalf("live and saved project disagreed on %s: %v %v", key, live, saved)
			}
		}
		return true
	})
}
