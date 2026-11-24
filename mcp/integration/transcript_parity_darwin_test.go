package integration

import (
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

var transcriptFixturePath = flag.String("transcript-fixture", "", "generated interview fixture directory for multicam transcript parity")

type transcriptProjectSnapshot struct {
	Files []string
	Clips []struct {
		ID   string
		File savedTranscriptPath
		From string
		To   string
	}
	History struct {
		Undo []struct{ Action string }
		Redo []struct{ Action string }
	}
	Transcripts struct {
		Revision    uint64
		Attachments []struct {
			ID    string
			Asset struct {
				File   savedTranscriptPath
				SHA256 string
			}
		}
	}
}

type savedTranscriptPath struct {
	path  string
	index *int
}

func (p *savedTranscriptPath) UnmarshalJSON(data []byte) error {
	if len(data) != 0 && data[0] == '"' {
		return json.Unmarshal(data, &p.path)
	}
	return json.Unmarshal(data, &p.index)
}

func (p *savedTranscriptPath) expand(t *testing.T, files []string) {
	t.Helper()
	if p.index == nil {
		return
	}
	if *p.index < 0 || *p.index >= len(files) {
		t.Fatalf("invalid file index %d in saved project", *p.index)
	}
	p.path = files[*p.index]
	p.index = nil
}

func readTranscriptProject(t *testing.T, path string) transcriptProjectSnapshot {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var project transcriptProjectSnapshot
	if err := json.Unmarshal(data, &project); err != nil {
		t.Fatalf("decode saved project %s: %v", path, err)
	}
	for i := range project.Clips {
		project.Clips[i].File.expand(t, project.Files)
	}
	for i := range project.Transcripts.Attachments {
		project.Transcripts.Attachments[i].Asset.File.expand(t, project.Files)
	}
	return project
}

func checkTranscriptEditParity(t *testing.T, ctx context.Context, contents, dir string,
	call func(string, object, string) object, rebindInGUI func(*testing.T) bool) {
	t.Helper()
	dir, err := os.MkdirTemp(dir, "transcript-parity-")
	if err != nil {
		t.Fatal(err)
	}
	cli := func(action string, request object, expectedError string) object {
		t.Helper()
		return callTranscriptCLI(t, ctx, filepath.Join(contents, "Helpers/mpcut"), action, request, expectedError)
	}
	makeFile := func(name, data string) string {
		t.Helper()
		path := filepath.Join(dir, name)
		if err := os.WriteFile(path, []byte(data), 0600); err != nil {
			t.Fatal(err)
		}
		return path
	}
	const original = `{"format":"mpcut","schema_version":3,"kind":"sequence","clips":[{"id":"clip","file":"parity.wav","from":"0","to":"4"}]}`
	const nativeWords = `{"source":"parity.wav","duration_seconds":4,"sample_zero":{"numerator":0,"denominator":1},
	  "speaker_names":["Guest"],"metadata":{},"segments":[{"start":0,"end":4,"speaker":0,"words":[
	    {"text":"Keep","start":0.25,"end":0.5},
	    {"text":"remove","start":1,"end":2},
	    {"text":"this","start":2.5,"end":3.5}
	  ]}]}`
	var words, originalBytes string
	if *transcriptFixturePath != "" {
		copyTranscriptFixture(t, dir, "parity.wav", "parity-words.json", "parity.cut")
		body, err := os.ReadFile(filepath.Join(dir, "parity.cut"))
		if err != nil {
			t.Fatal(err)
		}
		words, originalBytes = filepath.Join(dir, "parity-words.json"), string(body)
	} else {
		writeAudioFixture(t, filepath.Join(dir, "parity.wav"),
			audioPlateau{fixtureSampleRate, 4000}, audioPlateau{fixtureSampleRate, -4000},
			audioPlateau{2 * fixtureSampleRate, 8000})
		words, originalBytes = makeFile("parity-words.json", nativeWords), original
	}
	cliPath, livePath := makeFile("cli.cut", originalBytes), makeFile("live.cut", originalBytes)
	for _, path := range []string{cliPath, livePath} {
		cli("attachment import", object{"project_path": path, "transcript": words, "audio_stream_index": 0, "in_place": true}, "")
	}
	seed := readTranscriptProject(t, livePath)
	if len(seed.Transcripts.Attachments) != 1 {
		t.Fatalf("expected one imported transcript: %+v", seed)
	}
	attachment := seed.Transcripts.Attachments[0]
	if attachment.Asset.SHA256 == "" {
		t.Fatal("saved attachment has no result identity")
	}
	page := cli("words read", object{"project_path": cliPath, "space": "current_cut", "limit": 1, "offset": 1}, "")
	items, ok := page["items"].([]any)
	if !ok || len(items) != 1 || items[0].(object)["word_id"] != "s0-w1" ||
		page["total"] != float64(3) || page["next_offset"] != float64(2) {
		t.Fatalf("bounded CLI read did not return the second word and continuation: %v", page)
	}

	selection := object{"first_word_id": "s0-w1", "space": "current_cut"}
	edit := object{"action": "delete", "selections": []object{selection}, "boundary_policy": "exact"}
	filePlan := filepath.Join(dir, "delete-review.json")
	fileReview := cli("edit plan", object{"project_path": cliPath, "request": edit, "output": filePlan}, "")
	cli("edit apply", object{"project_path": cliPath, "plan_file": filePlan, "in_place": true}, "")

	live := call("project_open", object{"project_path": livePath, "operation_id": "open-transcript-parity"}, "")["project_handle"]
	state := func() object { return call("project_editor_state_read", object{"project_handle": live}, "") }
	eventually(t, "indexed transcript parity project", func() bool {
		status := state()
		return status["total"] == float64(1) && status["busy"] == false
	})
	stamp := func(operation string) object {
		inspection := call("transcript_editor_attachments_list", object{"project_handle": live}, "")
		return object{"project_handle": live, "operation_id": operation,
			"attachment_id": attachment.ID, "result_id": attachment.Asset.SHA256,
			"expected_revision": state()["revision"], "expected_transcript_revision": inspection["transcript_revision"]}
	}
	plan := stamp("plan-transcript-parity")
	plan["edit"] = edit
	reviewed := call("transcript_editor_edit_plan", plan, "")
	for _, field := range []string{"boundaries", "previous_duration", "duration", "history_action"} {
		if !reflect.DeepEqual(fileReview[field], reviewed[field]) {
			t.Fatalf("reviewed %s differs: CLI %v, live MCP %v", field, fileReview[field], reviewed[field])
		}
	}
	id, ok := reviewed["plan_id"].(string)
	if !ok || id == "" {
		t.Fatalf("MCP plan omitted its identity: %v", reviewed)
	}
	apply := stamp("apply-transcript-parity")
	apply["plan_id"] = id
	applied := call("transcript_editor_edit_apply", apply, "")
	if replay := call("transcript_editor_edit_apply", apply, ""); !reflect.DeepEqual(replay, applied) {
		t.Fatalf("operation replay returned a different result: first=%v, replay=%v", applied, replay)
	}
	call("project_save", object{"project_handle": live, "expected_revision": state()["revision"], "operation_id": "save-transcript-parity"}, "")
	cliSaved := readTranscriptProject(t, cliPath)
	liveSaved := readTranscriptProject(t, livePath)
	if !reflect.DeepEqual(cliSaved.Clips, liveSaved.Clips) {
		t.Fatalf("CLI saved ranges %v differ from live MCP ranges %v", cliSaved.Clips, liveSaved.Clips)
	}
	if len(cliSaved.Clips) != 2 || cliSaved.Clips[0].File.path == "" || cliSaved.Clips[1].File != cliSaved.Clips[0].File ||
		cliSaved.Clips[0].From != "0" || cliSaved.Clips[0].To != "1" ||
		cliSaved.Clips[1].From != "2" || cliSaved.Clips[1].To != "4" {
		t.Fatalf("expected half-open retained ranges [0,1) and [2,4), got %v", cliSaved.Clips)
	}
	if len(cliSaved.History.Undo) != 1 || len(cliSaved.History.Redo) != 0 ||
		!reflect.DeepEqual(cliSaved.History, liveSaved.History) {
		t.Fatalf("expected exactly one identical undo, got CLI %+v and MCP %+v", cliSaved.History, liveSaved.History)
	}
	call("history_undo", object{"project_handle": live, "expected_revision": state()["revision"], "operation_id": "undo-transcript-parity"}, "")
	call("project_save", object{"project_handle": live, "expected_revision": state()["revision"], "operation_id": "save-transcript-undo"}, "")
	undone := readTranscriptProject(t, livePath)
	if !reflect.DeepEqual(undone.Clips, seed.Clips) || len(undone.History.Redo) != 1 ||
		!reflect.DeepEqual(undone.Transcripts.Attachments, seed.Transcripts.Attachments) {
		t.Fatalf("undo did not restore the original timeline with its attachment: %+v", undone)
	}
	staleRequest := stamp("plan-before-transcript-rebind")
	staleRequest["edit"] = edit
	stalePlan := call("transcript_editor_edit_plan", staleRequest, "")
	beforeRebind := state()
	call("project_window_focus", object{"project_handle": live}, "")
	if rebindInGUI(t) {
		t.Log("adjusted the transcript track offset through the native binding sheet")
	} else {
		bind := stamp("rebind-transcript-parity")
		bind["bindings"] = []object{{"track_id": "source", "file": "parity.wav", "audio_stream_index": 0, "offset": "1/4"}}
		call("transcript_editor_attachment_bind", bind, "")
	}
	afterRebind := state()
	if afterRebind["revision"] != beforeRebind["revision"] || !reflect.DeepEqual(afterRebind["clips"], beforeRebind["clips"]) {
		t.Fatalf("rebinding the clock changed the timeline: before=%v after=%v", beforeRebind, afterRebind)
	}
	newLocation := call("transcript_editor_occurrences_locate", object{"project_handle": live, "word_id": "s0-w0", "space": "source"}, "")
	shifted := newLocation["items"].([]any)
	if len(shifted) != 1 || !reflect.DeepEqual(shifted[0].(object)["range"], object{"from": "1/2", "to": "3/4"}) {
		t.Fatalf("rebind did not shift the word by exactly 1/4 second: %v", newLocation)
	}
	staleApply := stamp("stale-apply-transcript-parity")
	staleApply["plan_id"] = stalePlan["plan_id"]
	call("transcript_editor_edit_apply", staleApply, "stale_transcript_plan")
	afterRefusal := state()
	if afterRefusal["revision"] != afterRebind["revision"] || !reflect.DeepEqual(afterRefusal["clips"], afterRebind["clips"]) {
		t.Fatalf("stale transcript plan changed the timeline: before=%v after=%v", afterRebind, afterRefusal)
	}

	correction := stamp("correct-transcript-parity")
	correction["change"] = object{"replace_text": object{"text": "Corrected"}}
	correction["selection"] = object{"first_word_id": "s0-w0", "space": "source"}
	call("transcript_editor_words_correct", correction, "")
	checkWord := func(want string) {
		t.Helper()
		page := call("transcript_editor_occurrences_locate", object{"project_handle": live, "word_id": "s0-w0", "space": "source"}, "")
		rows := page["items"].([]any)
		if len(rows) != 1 || rows[0].(object)["text"] != want || rows[0].(object)["range"] == nil {
			t.Fatalf("expected transcript text %q, got %v", want, page)
		}
	}
	checkWord("Corrected")
	call("history_undo", object{"project_handle": live, "expected_revision": state()["revision"], "operation_id": "undo-transcript-correction"}, "")
	checkWord("Keep")
	call("history_redo", object{"project_handle": live, "expected_revision": state()["revision"], "operation_id": "redo-transcript-correction"}, "")
	checkWord("Corrected")
	call("project_save", object{"project_handle": live, "expected_revision": state()["revision"], "operation_id": "save-transcript-correction"}, "")
	call("project_close", object{"project_handle": live, "expected_revision": state()["revision"], "operation_id": "close-transcript-correction"}, "")
	live = call("project_open", object{"project_path": livePath, "operation_id": "reopen-transcript-correction"}, "")["project_handle"]
	eventually(t, "reopened transcript correction", func() bool {
		return state()["total"] == float64(1) && state()["busy"] == false
	})
	checkWord("Corrected")

	cli("edit plan", object{"project_path": cliPath, "action": "delete", "first_word_id": "s0-w0", "output": filePlan + ".stale.json"}, "")
	cli("attachment bind", object{"project_path": cliPath, "origin": "1/4", "in_place": true}, "")
	beforeStaleFile, err := os.ReadFile(cliPath)
	if err != nil {
		t.Fatal(err)
	}
	cli("edit apply", object{"project_path": cliPath, "plan_file": filePlan + ".stale.json", "in_place": true}, "stale_transcript_plan")
	afterStaleFile, err := os.ReadFile(cliPath)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(beforeStaleFile, afterStaleFile) {
		t.Fatal("stale CLI plan changed the saved project bytes")
	}
	t.Log("verified exact retained ranges, persisted undo, correction replay, and stale-plan rejection through packaged CLI and live MCP")
}

func callTranscriptCLI(t *testing.T, ctx context.Context, cli, action string, request object, expectedError string) object {
	t.Helper()
	input, err := json.Marshal(request)
	if err != nil {
		t.Fatal(err)
	}
	args := append([]string{"transcript"}, strings.Fields(action)...)
	cmd := exec.CommandContext(ctx, cli, append(args, "--json", "--stdin")...)
	cmd.Stdin = bytes.NewReader(input)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	output, err := cmd.Output()
	var body object
	if decode := json.Unmarshal(output, &body); decode != nil {
		t.Fatalf("CLI %s: %v, decoding %q: %v; stderr: %s", action, err, output, decode, &stderr)
	}
	failure, _ := body["error"].(object)
	if (err != nil) != (expectedError != "") || (expectedError != "" && failure["code"] != expectedError) {
		t.Fatalf("CLI %s: got %v (%v), expected error %q", action, body, err, expectedError)
	}
	return body
}

func copyTranscriptFixture(t *testing.T, dir string, names ...string) {
	t.Helper()
	for _, name := range names {
		body, err := os.ReadFile(filepath.Join(*transcriptFixturePath, name))
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, name), body, 0600); err != nil {
			t.Fatal(err)
		}
	}
}

func checkTranscriptQueueParity(t *testing.T, ctx context.Context, contents, safeRoot, isolatedEndpoint string,
	call func(string, object, string) object) {
	t.Helper()
	if *transcriptFixturePath == "" {
		t.Skip("supply -transcript-fixture with the output of Tests/Integration/transcript_fixture.py")
	}
	ffmpeg, err := exec.LookPath("ffmpeg")
	if err != nil {
		t.Fatal("ffmpeg is needed to compare decoded queue output")
	}
	dir, err := os.MkdirTemp(safeRoot, "transcript-queue-")
	if err != nil {
		t.Fatal(err)
	}
	copyTranscriptFixture(t, dir, "wide.mov", "close.mov", "lav.wav")
	write := func(name, body string) string {
		t.Helper()
		path := filepath.Join(dir, name)
		if err := os.WriteFile(path, []byte(body), 0600); err != nil {
			t.Fatal(err)
		}
		return path
	}
	// Use the fixtures' distinct camera colors and fixed recorder. Zero offsets put
	// both camera clocks on the same 25 fps grid for an exact encode comparison.
	const projectJSON = `{"format":"mpcut","schema_version":3,"kind":"multicam","reference_angle_id":"wide",
	  "group_range":{"from":"0","to":"4"},"angles":[{"id":"wide","file":"wide.mov"},{"id":"close","file":"close.mov"}],
	  "audio_sources":[{"id":"lav","file":"lav.wav"}],"audio":{"mode":"fixed","source_id":"lav","audio_stream_index":0},
	  "switches":[{"group_time":"0","angle_id":"wide"},{"group_time":"2","angle_id":"close"}]}`
	pathCLI := write("queue-cli.cut", projectJSON)
	pathLive := write("queue-live.cut", projectJSON)
	words := write("queue-words.json", `{"source":"lav.wav","duration_seconds":18,"sample_zero":{"numerator":0,"denominator":1},
	  "metadata":{},"segments":[{"start":1,"end":3,"words":[
	    {"text":"Queuing","start":1,"end":1.9},{"text":"excerpts","start":2.1,"end":3}]}]}`)
	cli := filepath.Join(contents, "Helpers/mpcut")
	for _, path := range []string{pathCLI, pathLive} {
		callTranscriptCLI(t, ctx, cli, "attachment import", object{"project_path": path, "transcript": words,
			"source_id": "lav", "audio_stream_index": 0, "in_place": true}, "")
	}
	seed := readTranscriptProject(t, pathLive)
	if len(seed.Transcripts.Attachments) != 1 {
		t.Fatalf("expected one multicam transcript attachment: %+v", seed)
	}
	attachment := seed.Transcripts.Attachments[0]
	selection := object{"first_word_id": "s0-w0", "last_word_id": "s0-w1", "space": "current_cut"}
	edit := object{"action": "queue", "selections": []object{selection}, "boundary_policy": "exact", "name": "Camera quote"}
	filePlan := filepath.Join(dir, "queue-review.json")
	snapshot := filepath.Join(dir, "Camera quote.cut")
	callTranscriptCLI(t, ctx, cli, "edit plan", object{"project_path": pathCLI, "request": edit, "output": filePlan}, "")
	callTranscriptCLI(t, ctx, cli, "excerpt queue", object{"project_path": pathCLI, "plan_file": filePlan, "out_project": snapshot, "name": "Camera quote"}, "")
	checkExcerpt := func(path string) {
		t.Helper()
		body, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		var project object
		if err := json.Unmarshal(body, &project); err != nil {
			t.Fatal(err)
		}
		if !reflect.DeepEqual(project["assembly"], []any{object{"from": "1", "to": "3"}}) ||
			!reflect.DeepEqual(project["audio"], object{"mode": "fixed", "source_id": "lav", "audio_stream_index": float64(0)}) {
			t.Fatalf("snapshot did not retain the selected interval and fixed recorder: %v", project)
		}
		words := callTranscriptCLI(t, ctx, cli, "words read", object{"project_path": path, "space": "current_cut"}, "")
		items, ok := words["items"].([]any)
		if !ok || words["total"] != float64(2) || len(items) != 2 ||
			items[0].(object)["text"] != "Queuing" || items[1].(object)["text"] != "excerpts" {
			t.Fatalf("reopened excerpt cannot read its copied transcript store: %v", words)
		}
		copy := readTranscriptProject(t, path).Transcripts.Attachments
		if len(copy) != 1 || copy[0].Asset.File == attachment.Asset.File ||
			copy[0].Asset.SHA256 != attachment.Asset.SHA256 {
			t.Fatalf("expected a separate transcript asset with the same content identity: %v", copy)
		}
	}
	live := call("project_open", object{"project_path": pathLive, "operation_id": "open-transcript-queue"}, "")["project_handle"]
	state := func() object { return call("project_editor_state_read", object{"project_handle": live}, "") }
	eventually(t, "indexed transcript multicam sources", func() bool {
		status := state()
		if status["can_edit"] != true {
			return false
		}
		for _, source := range call("multicam_state_read", object{"project_handle": live, "section": "sources"}, "")["sources"].([]any) {
			if source.(object)["indexed"] != true {
				return false
			}
		}
		return true
	})
	stamp := func(operation string) object {
		return object{"project_handle": live, "operation_id": operation,
			"attachment_id": attachment.ID, "result_id": attachment.Asset.SHA256,
			"expected_revision": state()["revision"], "expected_transcript_revision": seed.Transcripts.Revision}
	}
	plan := stamp("plan-camera-quote")
	plan["edit"] = edit
	reviewed := call("transcript_editor_edit_plan", plan, "")
	queue := stamp("queue-camera-quote")
	queue["plan_id"] = reviewed["plan_id"]
	queue["name"] = "Camera quote"
	queued := call("transcript_editor_excerpt_queue", queue, "")
	if queued["queue_id"] == nil {
		t.Fatalf("missing queued excerpt identity: %v", queued)
	}

	// Change both original projects after queuing. The subsequent output must still
	// switch from wide to close halfway through the saved excerpt.
	originalCLI, err := os.ReadFile(pathCLI)
	if err != nil {
		t.Fatal(err)
	}
	var fileProject object
	if err := json.Unmarshal(originalCLI, &fileProject); err != nil {
		t.Fatal(err)
	}
	fileProject["switches"] = []object{{"group_time": "0", "angle_id": "wide"}}
	changedCLI, err := json.Marshal(fileProject)
	if err != nil {
		t.Fatal(err)
	}
	write(filepath.Base(pathCLI), string(changedCLI))
	call("multicam_camera_take", object{"project_handle": live, "expected_revision": state()["revision"],
		"operation_id": "replace-camera-after-queue", "angle_id": "wide", "group_time": "2"}, "")

	checkExcerpt(snapshot)
	waitForOutput := func(label string, handle, job any) object {
		t.Helper()
		var result object
		eventually(t, label, func() bool {
			result = call("export_editor_job_status_read", object{"project_handle": handle, "job_id": job}, "")
			switch result["state"] {
			case "running", "cancelling":
				return false
			case "succeeded":
				return true
			default:
				t.Fatalf("%s failed: %v", label, result)
				return false
			}
		})
		return result
	}
	liveSnapshot := filepath.Join(dir, "MCP Camera quote.cut")
	save := stamp("save-live-camera-quote")
	save["queue_id"] = queued["queue_id"]
	save["path"] = liveSnapshot
	saving := call("transcript_editor_excerpt_save", save, "")
	waitForOutput("save live excerpt project", live, saving["job_id"])
	checkExcerpt(liveSnapshot)
	reopened := call("project_open", object{"project_path": liveSnapshot, "operation_id": "reopen-live-camera-quote"}, "")["project_handle"]
	var reopenedState object
	eventually(t, "reopened live excerpt to be editable", func() bool {
		reopenedState = call("project_editor_state_read", object{"project_handle": reopened}, "")
		return reopenedState["can_edit"] == true
	})
	wordsAfterOpen := call("transcript_editor_words_read", object{"project_handle": reopened, "space": "current_cut"}, "")
	if wordsAfterOpen["total"] != float64(2) {
		t.Fatalf("reopened live excerpt lost the transcript: %v", wordsAfterOpen)
	}

	cliMovie := filepath.Join(dir, "cli.mov")
	cmd := exec.CommandContext(ctx, cli, "export", "project", "render", "--project", snapshot, "--output", cliMovie,
		"--mode", "encode", "--video", "prores", "--audio", "pcm", "--json")
	log, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("render CLI snapshot: %v\n%s", err, log)
	}
	liveMovie := filepath.Join(dir, "MCP Camera quote.mov")
	start := call("export_editor_project_render", object{"project_handle": reopened, "expected_revision": reopenedState["revision"],
		"operation_id": "render-camera-quote", "output": liveMovie,
		"mode": "encode", "codec": "prores", "audio": "pcm"}, "")
	result := waitForOutput("render reopened live transcript excerpt", reopened, start["job_id"])
	outputs, ok := result["outputs"].([]any)
	if !ok || !reflect.DeepEqual(outputs, []any{liveMovie}) {
		t.Fatalf("expected one output named for the excerpt: %v", result)
	}
	decode := func(path string, args ...string) []byte {
		t.Helper()
		flags := append([]string{"-v", "error", "-nostdin", "-i", path}, args...)
		cmd := exec.CommandContext(ctx, ffmpeg, flags...)
		output, err := cmd.Output()
		if err != nil {
			t.Fatalf("decode %s with %v: %v", path, args, err)
		}
		return output
	}
	audio := func(path string) []byte {
		return decode(path, "-map", "0:a:0", "-ac", "1", "-ar", "16000", "-f", "s16le", "-")
	}
	cliAudio, liveAudio := audio(cliMovie), audio(liveMovie)
	originalAudio := audio(filepath.Join(dir, "lav.wav"))
	const bytesPerSecond = 16000 * 2
	if len(originalAudio) < 3*bytesPerSecond {
		t.Fatal("the lav fixture is too short for the excerpt")
	}
	expectedAudio := originalAudio[bytesPerSecond : 3*bytesPerSecond]
	if !bytes.Equal(cliAudio, expectedAudio) || !bytes.Equal(liveAudio, expectedAudio) {
		t.Fatalf("renditions differ from the original two-second lav interval (CLI has %d bytes, live has %d)", len(cliAudio), len(liveAudio))
	}
	coverSample := func(path, timestamp string) []byte {
		return decode(path, "-ss", timestamp, "-map", "0:v:0", "-frames:v", "1",
			"-vf", "crop=16:8:8:0,format=rgb24", "-f", "rawvideo", "-")
	}
	for _, movie := range []string{cliMovie, liveMovie} {
		before, after := coverSample(movie, "0.96"), coverSample(movie, "1")
		if len(before) < 3 || len(after) < 3 || before[2] <= before[0] || after[0] <= after[2] {
			t.Fatalf("expected blue wide at frame 24 and red close at frame 25 in %s", movie)
		}
	}
	t.Log("verified named multicam queue exports preserve the camera switch and fixed soundtrack after editing the originals")

	walkthroughOutput := filepath.Join(dir, "agent-output")
	if err := os.Mkdir(walkthroughOutput, 0700); err != nil {
		t.Fatal(err)
	}
	walkthroughProject := write("Agent quote.cut", projectJSON)
	script := filepath.Join(contents, "Resources/Documentation/docs/mcp_walkthrough.py")
	timingPath := filepath.Join(dir, "agent-timings.json")
	walkthrough := exec.CommandContext(ctx, "python3", script, "--helper", filepath.Join(contents, "Helpers/mpcut-mcp"),
		"--transcript-project", walkthroughProject, "--quote", "Queuing excerpts", "--output-dir", walkthroughOutput,
		"--import-transcript", words, "--bind-source", "lav", "--bind-stream", "0", "--timeout", "120", "--timings", timingPath)
	walkthrough.Env = append(os.Environ(), isolatedEndpoint)
	log, err = walkthrough.CombinedOutput()
	if err != nil || !bytes.Contains(log, []byte("Verified quote export")) {
		t.Fatalf("agent-only transcript walkthrough: %v\n%s", err, log)
	}
	timingData, err := os.ReadFile(timingPath)
	if err != nil {
		t.Fatal(err)
	}
	var timings []struct {
		Operation     string  `json:"operation"`
		Duration      float64 `json:"duration_seconds"`
		ResponseBytes int     `json:"response_bytes"`
	}
	if err := json.Unmarshal(timingData, &timings); err != nil {
		t.Fatal(err)
	}
	operations := make(map[string]bool)
	for _, timing := range timings {
		if timing.Duration < 0 {
			t.Fatalf("negative duration for %s", timing.Operation)
		}
		operations[timing.Operation] = true
		if timing.Operation == "transcript_editor_words_search" && timing.ResponseBytes <= 0 {
			t.Fatal("walkthrough search timing did not include response size")
		}
	}
	for _, operation := range []string{"helper_spawn", "transcript_editor_words_search", "export_queue_render", "media_file_inspect", "walkthrough", "helper_shutdown"} {
		if !operations[operation] {
			t.Errorf("walkthrough timings missing %s", operation)
		}
	}
	t.Log("verified packaged MCP-only walkthrough from tool discovery to rendered quote inspection")
}
