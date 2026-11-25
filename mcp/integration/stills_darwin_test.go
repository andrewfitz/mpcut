package integration

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"image"
	"image/color"
	"image/jpeg"
	"image/png"
	"maps"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"slices"
	"testing"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

func writeStillTestCard(t *testing.T, card string) []byte {
	t.Helper()
	picture := image.NewRGBA(image.Rect(0, 0, 64, 36))
	for y := 0; y < 36; y++ {
		for x := 0; x < 64; x++ {
			picture.SetRGBA(x, y, color.RGBA{R: 255, A: 255})
		}
	}
	var pngData bytes.Buffer
	if err := png.Encode(&pngData, picture); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(card, pngData.Bytes(), 0600); err != nil {
		t.Fatal(err)
	}
	return pngData.Bytes()
}

func checkHeldSoundtrack(t *testing.T, call func(string, object, string) object, dir string) {
	t.Helper()
	const samples = 48001
	header := []byte("RIFF")
	header = binary.LittleEndian.AppendUint32(header, 36+samples*2)
	header = append(header, "WAVEfmt "...)
	for _, word := range []uint32{16, 1<<16 | 1, 48000, 96000, 16<<16 | 2} {
		header = binary.LittleEndian.AppendUint32(header, word)
	}
	header = append(header, "data"...)
	header = binary.LittleEndian.AppendUint32(header, samples*2)
	recording := filepath.Join(dir, "held soundtrack.wav")
	if err := os.WriteFile(recording, append(header, make([]byte, samples*2)...), 0600); err != nil {
		t.Fatal(err)
	}
	cover := filepath.Join(dir, "held cover.png")
	writeStillTestCard(t, cover)
	project := filepath.Join(dir, "held cover.cut")
	filePlan := func(tool string, args object) object {
		t.Helper()
		args["operation_id"] = fileOperationID()
		job := call(tool, args, "")["job_id"]
		var result object
		eventually(t, tool, func() bool {
			status := call("file_job_status_read", object{"job_id": job}, "")
			if status["state"] == "running" {
				return false
			}
			if status["state"] != "succeeded" {
				t.Fatalf("%s failed: %v", tool, status)
			}
			result = status["result"].(object)
			return true
		})
		return result
	}
	filePlan("still_file_project_create", object{"out_project": project, "image": cover,
		"width": 64, "height": 36, "rate": "30", "duration": "2"})
	filePlan("still_file_soundtrack_attach", object{"project_path": project, "soundtrack": recording,
		"fit_soundtrack": true, "in_place": true})
	output := filepath.Join(dir, "held cover.m4v")
	fileResult := filePlan("export_file_project_render", object{"project_path": project,
		"output": output, "container": "m4v", "mode": "smart", "video": "h264", "audio": "alac", "still_timing": "held", "dry_run": true})
	const count = "generated_video_sample_count"
	wantDuration := object{"numerator": float64(samples), "denominator": float64(48000)}
	if fileResult[count] != float64(1) || !reflect.DeepEqual(fileResult["written_picture_duration"], wantDuration) {
		t.Fatalf("unexpected file plan: %v", fileResult)
	}

	handle := call("project_open", object{"project_path": project, "operation_id": "held-soundtrack-open"}, "")["project_handle"]
	state := func() object { return call("project_editor_state_read", object{"project_handle": handle}, "") }
	eventually(t, "held project ready", func() bool { return state()["busy"] == false && state()["can_edit"] == true })
	edit := func(tool, operation string, fields object) object {
		args := object{"project_handle": handle, "expected_revision": state()["revision"], "operation_id": operation}
		maps.Copy(args, fields)
		return call(tool, args, "")
	}
	edit("still_editor_soundtrack_detach", "held-soundtrack-detach", nil)
	attach := edit("still_editor_soundtrack_attach", "held-soundtrack-attach", object{"soundtrack": recording, "fit_soundtrack": true})
	if attach["changed"] != true || attach["soundtrack"] == nil {
		t.Fatalf("live attach did not report the soundtrack edit: %v", attach)
	}
	job := edit("export_editor_project_plan", "held-soundtrack-plan", object{
		"output": output, "container": "m4v", "mode": "smart", "codec": "h264", "audio": "alac", "still_timing": "held",
	})["job_id"]
	eventually(t, "held live plan", func() bool {
		status := call("export_editor_job_status_read", object{"project_handle": handle, "job_id": job}, "")
		if status["state"] == "running" {
			return false
		}
		if status["state"] != "succeeded" {
			t.Fatalf("held live plan failed: %v", status)
		}
		result := status["result"].(object)
		plan, _ := result["plan"].(object)
		for _, field := range []string{"container", count, "video_codec", "written_picture_duration"} {
			if !reflect.DeepEqual(plan[field], fileResult[field]) {
				t.Fatalf("held plans disagree on %s: %v vs %v", field, plan, fileResult)
			}
		}
		return true
	})
	edit("project_close", "held-soundtrack-close", object{"changes": "discard"})
}

func checkStillAuthoring(t *testing.T, toolCaller func(*testing.T) func(string, object, string) object,
	rawCall func(*testing.T, string, object) *mcp.CallToolResult,
	runGUIProbe func(*testing.T, string, string) bool, dir string) {
	t.Helper()
	card := filepath.Join(dir, "Red card.png")
	pngData := writeStillTestCard(t, card)
	for _, fixture := range []struct {
		name, program, replacement, contents string
	}{
		{"sequence", "sequence", "sequence", `"clips":[{"id":"clip","file":"media.mov","from":"0","to":"1001/2500"}]`},
		{"multicam", "assembly", "group", `"reference_angle_id":"wide","group_range":{"from":"0","to":"1001/2500"},"angles":[{"id":"wide","file":"media.mov"}],"audio":{"mode":"none"},"switches":[{"group_time":"0","angle_id":"wide"}]`},
	} {
		t.Run(fixture.name, func(t *testing.T) {
			call := toolCaller(t)
			path := filepath.Join(dir, "still-"+fixture.name+".cut")
			doc := `{"format":"mpcut","schema_version":9,"kind":"` + fixture.name + `",` + fixture.contents + `}`
			if err := os.WriteFile(path, []byte(doc), 0600); err != nil {
				t.Fatal(err)
			}
			opID := func(name string) string { return "still-" + fixture.name + "-" + name }
			open := func(action string) any {
				return call("project_open", object{"project_path": path, "operation_id": opID(action)}, "")["project_handle"]
			}
			project := open("open")
			state := func() object { return call("project_editor_state_read", object{"project_handle": project}, "") }
			eventually(t, "indexed "+fixture.name+" source", func() bool {
				if fixture.name == "sequence" {
					current := state()
					return current["busy"] == false && current["total"] == float64(1)
				}
				sources := call("multicam_state_read", object{"project_handle": project, "section": "sources"}, "")["sources"].([]any)
				return len(sources) == 1 && sources[0].(map[string]any)["indexed"] == true && state()["can_edit"] == true
			})
			mutate := func(name, ID string, fields object) object {
				args := object{"project_handle": project, "expected_revision": state()["revision"], "operation_id": opID(ID)}
				maps.Copy(args, fields)
				return call(name, args, "")
			}
			list := func() []any {
				return call("still_editor_placements_list", object{"project_handle": project}, "")["items"].([]any)
			}
			replacement := mutate("still_editor_picture_replace", "replace", object{"path": card, "space": fixture.replacement,
				"from": "1001/30000", "to": "1001/7500"})
			insertArgs := object{"project_handle": project, "expected_revision": state()["revision"], "operation_id": opID("insert"),
				"path": card, "space": fixture.program, "at": "0",
				"duration": "1001/15000", "cadence": "1001/30000"}
			insert := call("still_editor_placement_insert", insertArgs, "")
			if replay := call("still_editor_placement_insert", insertArgs, ""); !reflect.DeepEqual(replay, insert) {
				t.Fatalf("still import did not replay: %v", replay)
			}
			conflict := maps.Clone(insertArgs)
			conflict["duration"] = "1001/10000"
			call("still_editor_placement_insert", conflict, "operation_conflict")
			staleInsert := maps.Clone(insertArgs)
			staleInsert["operation_id"] = opID("stale-insert")
			call("still_editor_placement_insert", staleInsert, "stale_revision")
			call("still_editor_placements_list", object{"project_handle": project, "expected_revision": insertArgs["expected_revision"]}, "stale_revision")
			original := list()
			if len(original) != 2 || original[0].(map[string]any)["placement"] != insert["placement"] ||
				original[1].(map[string]any)["placement"] != replacement["placement"] {
				t.Fatalf("unexpected still placements: %v", original)
			}
			snapshot := state()
			for _, tool := range []any{"still_editor_placements_list", "still_editor_placement_insert", "still_editor_placement_update", "still_editor_placement_remove", "still_editor_asset_relink", "timeline_clips_space"} {
				if !slices.Contains(snapshot["available_operations"].([]any), tool) {
					t.Fatalf("available operations are missing %s: %v", tool, snapshot["available_operations"])
				}
			}
			spacingArgs := object{"project_handle": project, "expected_revision": snapshot["revision"], "operation_id": opID("space"), "duration": "1001/15000"}
			spaced := call("timeline_clips_space", spacingArgs, "")
			if spaced["action"] != "Space Clips" || spaced["changed"] != true || spaced["history_retained"] != true {
				t.Fatalf("timeline_clips_space did not retain its native edit: %v", spaced)
			}
			if retry := call("timeline_clips_space", spacingArgs, ""); !reflect.DeepEqual(retry, spaced) {
				t.Fatalf("timeline_clips_space did not replay: %v", retry)
			}
			rows := list()
			if len(rows) != 3 {
				t.Fatalf("timeline_clips_space did not add one gap: %v", rows)
			}
			gap := rows[1].(map[string]any)
			if gap["kind"] != "gap" || gap["duration"] != "1001/15000" || gap["framing"].(map[string]any)["background"] != "#000000" {
				t.Fatalf("unexpected spacing gap: %v", gap)
			}
			mutate("history_undo", "undo-space", nil)
			if got := list(); !reflect.DeepEqual(got, original) {
				t.Fatalf("undo did not restore placements before spacing: %v", got)
			}
			snapshot = state()
			page := call("still_editor_placements_list", object{"project_handle": project, "expected_revision": snapshot["revision"],
				"offset": 1, "limit": 1}, "")
			if page["total"] != float64(2) || !reflect.DeepEqual(page["items"], original[1:]) {
				t.Fatalf("second page does not contain the replacement: %v", page)
			}
			if fixture.name == "multicam" {
				view := call("multicam_state_read", object{"project_handle": project, "section": "stills", "offset": 1, "limit": 1}, "")
				if view["total"] != page["total"] || !reflect.DeepEqual(view["items"], page["items"]) {
					t.Fatalf("multicam still view disagrees with still_editor_placements_list: %v", view)
				}
			}
			mutate("still_editor_placement_update", "adjust", object{"placement": insert["placement"], "duration": "1001/10000",
				"fit": "fill", "background": "#008000"})
			adjusted := list()
			row := adjusted[0].(map[string]any)
			framing := row["framing"].(map[string]any)
			if row["authored_from"] != "0" || row["authored_to"] != "1001/10000" || framing["background"] != "#008000" || framing["mode"] != "fill" {
				t.Fatalf("adjusted still did not reflect authored duration and framing: %v", row)
			}
			mutate("history_undo", "undo-adjust", nil)
			if got := list(); !reflect.DeepEqual(got, original) {
				t.Fatalf("undo did not restore still list: %v", got)
			}
			mutate("history_redo", "redo-adjust", nil)
			if got := list(); !reflect.DeepEqual(got, adjusted) {
				t.Fatalf("redo did not restore adjusted still list: %v", got)
			}
			if monitor := call("playback_monitor_visibility_set", object{"project_handle": project, "visible": true}, ""); monitor["monitor_visible"] != true {
				t.Fatalf("native video monitor did not open: %v", monitor)
			}
			if monitor := call("playback_monitor_visibility_set", object{"project_handle": project, "visible": false}, ""); monitor["monitor_visible"] != false {
				t.Fatalf("native video monitor did not close: %v", monitor)
			}
			job := mutate("export_editor_project_plan", "copy-preflight", object{"scope": "timeline", "mode": "copy",
				"output": filepath.Join(dir, "still-"+fixture.name+".mov")})["job_id"]
			var mode string
			eventually(t, "still copy refusal and fallback", func() bool {
				status := call("export_editor_job_status_read", object{"project_handle": project, "job_id": job}, "")
				switch status["state"] {
				case "running":
					return false
				case "succeeded":
					result, _ := status["result"].(map[string]any)
					fallback, _ := result["fallback"].(map[string]any)
					if result["eligible"] != false || (fallback["mode"] != "smart" && fallback["mode"] != "encode") {
						t.Fatalf("copy did not report a usable picture fallback: %v", status)
					}
					mode = fallback["mode"].(string)
					return true
				default:
					t.Fatalf("copy preflight failed: %v", status)
					return false
				}
			})
			call("project_window_focus", object{"project_handle": project}, "")
			if !t.Run("NativeTierBadgeAndHistory", func(t *testing.T) {
				if !runGUIProbe(t, "still_badge.swift", map[string]string{"smart": "Lossless", "encode": "Re-encode"}[mode]) {
					t.Skip("accessibility permission unavailable for native still tier badge and history")
				}
				t.Log("verified native tier badge agrees with the MCP export fallback")
				call := toolCaller(t)
				for _, step := range []struct {
					menu string
					want []any
				}{{"Undo Update Still", original}, {"Redo Update Still", adjusted}} {
					if !runGUIProbe(t, "press_menu.swift", step.menu) {
						t.Fatal("AX permission became unavailable during native menu checks")
					}
					eventually(t, step.menu, func() bool {
						items := call("still_editor_placements_list", object{"project_handle": project}, "")["items"]
						return reflect.DeepEqual(items, step.want)
					})
				}
			}) {
				t.FailNow()
			}
			mutate("project_save", "save", nil)
			mutate("project_close", "close", nil)
			prev := project
			project = open("reopen")
			if project == prev || state()["dirty"] != false || !reflect.DeepEqual(list(), adjusted) {
				t.Fatalf("reopened still placement or window did not match saved document: %v", list())
			}
			mutate("history_undo", "undo-reopened", nil)
			if got := list(); !reflect.DeepEqual(got, original) {
				t.Fatalf("undo after reopen did not restore persisted history: %v", got)
			}
			mutate("history_redo", "redo-reopened", nil)
			if got := list(); !reflect.DeepEqual(got, adjusted) {
				t.Fatalf("redo after reopen did not restore adjusted still list: %v", got)
			}
			type reviewTarget struct {
				space, time string
				placement   object
			}
			targets := []reviewTarget{
				{fixture.program, "0", insert},
				{fixture.program, "1001/7500", replacement},
			}
			if fixture.name == "multicam" {
				targets = append(targets, reviewTarget{"group", "1001/15000", replacement})
			}
			for _, frame := range targets {
				result := rawCall(t, "review_editor_frame_read", object{"project_handle": project, "space": frame.space, "time": frame.time})
				checkReviewFrame(t, result, object{"space": frame.space, "picture": "still", "placement": frame.placement["placement"]})
				for _, block := range result.Content {
					if content, ok := block.(*mcp.ImageContent); ok {
						decoded, err := jpeg.Decode(bytes.NewReader(content.Data))
						if err != nil {
							t.Fatal(err)
						}
						bounds := decoded.Bounds()
						r, g, b, _ := decoded.At(bounds.Dx()/2, bounds.Dy()/2).RGBA()
						if r < 50000 || g > 10000 || b > 10000 {
							t.Fatalf("review JPEG center was (%d, %d, %d), expected red still", r, g, b)
						}
					}
				}
			}
			reviewDir := filepath.Join(dir, "still-review-"+fixture.name)
			export := mutate("review_editor_frames_export", "export-review", object{"output": reviewDir,
				"selection": "times", "space": fixture.program, "times": []string{"0", "1001/7500"}, "preset": "review"})
			eventually(t, "scoped still review output", func() bool {
				status := call("export_editor_job_status_read", object{"project_handle": project, "job_id": export["job_id"]}, "")
				if status["state"] == "running" {
					return false
				}
				if status["state"] != "succeeded" || !reflect.DeepEqual(status["outputs"], []any{reviewDir}) {
					t.Fatalf("scoped review did not publish its directory: %v", status)
				}
				return true
			})
			manifestData, err := os.ReadFile(filepath.Join(reviewDir, "manifest.json"))
			if err != nil {
				t.Fatal(err)
			}
			var manifest struct {
				Frames []struct{ File, Space, Placement string }
			}
			if err := json.Unmarshal(manifestData, &manifest); err != nil || len(manifest.Frames) != 2 {
				t.Fatalf("invalid scoped review manifest: %s (%v)", manifestData, err)
			}
			for i, frame := range manifest.Frames {
				if frame.Space != fixture.program || frame.Placement != targets[i].placement["placement"] {
					t.Fatalf("review manifest addressed a different placement: %v", frame)
				}
				if _, err := os.Stat(filepath.Join(reviewDir, frame.File)); err != nil {
					t.Fatal(err)
				}
			}
			if fixture.name == "sequence" {
				mutate("timeline_selection_set", "select-insert", object{"action": "select_range", "from": "0", "to": "1001/10000"})
			} else {
				call("multicam_selection_set", object{"project_handle": project, "expected_revision": state()["revision"],
					"action": "assembly_range", "from": "0", "to": "1001/10000"}, "")
			}
			selected := mutate("export_editor_project_plan", "selected-preflight", object{"scope": "selection", "mode": "encode", "tracks": "video",
				"output": filepath.Join(dir, "still-selection-"+fixture.name+".mov")})
			eventually(t, "render preflight limited to the selected still", func() bool {
				status := call("export_editor_job_status_read", object{"project_handle": project, "job_id": selected["job_id"]}, "")
				if status["state"] == "running" {
					return false
				}
				result, _ := status["result"].(object)
				plan, _ := result["plan"].(object)
				picture, _ := plan["picture"].([]any)
				if status["state"] != "succeeded" || result["eligible"] != true || len(picture) != 1 {
					t.Fatalf("selected still did not resolve alone: %v", status)
				}
				action := picture[0].(object)
				if action["action"] != "generate_still" || action["placement_id"] != insert["placement"] {
					t.Fatalf("preflight included unselected picture: %v", picture)
				}
				return true
			})
			row = list()[0].(map[string]any)
			splitArgs := object{"project_handle": project, "expected_revision": state()["revision"], "operation_id": opID("split"),
				"occurrence": row["occurrence"], "space": fixture.program, "time": "1001/30000"}
			left := row["placement"]
			invalid := maps.Clone(splitArgs)
			invalid["operation_id"] = opID("split-invalid-clock")
			invalid["space"] = map[string]string{"sequence": "source", "multicam": "group"}[fixture.name]
			call("timeline_item_split", invalid, "invalid_target")
			split := call("timeline_item_split", splitArgs, "")
			if split["left_placement"] != left || split["right_placement"] == left || len(list()) != 3 {
				t.Fatalf("split did not produce independent insert targets: %v, list: %v", split, list())
			}
			if replay := call("timeline_item_split", splitArgs, ""); !reflect.DeepEqual(replay, split) || len(list()) != 3 {
				t.Fatalf("split retry did not replay: %v", replay)
			}
			stale := maps.Clone(splitArgs)
			stale["operation_id"] = opID("split-stale")
			call("timeline_item_split", stale, "stale_revision")
			position := call("timeline_playhead_seek", object{"project_handle": project, "space": fixture.program, "time": "1001/30000",
				"occurrence": split["right"], "expected_revision": split["revision"]}, "")
			if fixture.name == "multicam" && (position["placement"] != split["right_placement"] || position["group_time"] != nil) {
				t.Fatalf("seek mapped a still to a camera: %v", position)
			}
			mutate("history_undo", "undo-split", nil)
			if got := list(); !reflect.DeepEqual(got, adjusted) {
				t.Fatalf("undo did not rejoin split still: %v", got)
			}
			newPath := filepath.Join(dir, "Relinked "+fixture.name+".png")
			if err := os.WriteFile(newPath, pngData, 0600); err != nil {
				t.Fatal(err)
			}
			mutate("still_editor_asset_relink", "relink", object{"asset": insert["asset"], "path": newPath})
			got := list()[0].(map[string]any)
			gotPath, _ := got["path"].(string)
			gotFile, gotErr := os.Stat(gotPath)
			relinkedFile, relinkErr := os.Stat(newPath)
			if gotErr != nil || relinkErr != nil || !os.SameFile(gotFile, relinkedFile) || got["asset"] != insert["asset"] {
				t.Fatalf("relink changed asset ID or kept the old path: %v", got)
			}
			if fixture.name == "multicam" {
				extra := mutate("still_editor_placement_insert", "infer-card-cadence", object{"path": newPath,
					"space": "assembly", "at": "0", "duration": "1001/30000"})
				first := list()[0].(object)
				if first["placement"] != extra["placement"] || first["cadence"] != "1001/30000" {
					t.Fatalf("inserting at an existing card did not inherit its cadence: %v", first)
				}
				mutate("history_undo", "undo-infer-card-cadence", nil)
			}
			mutate("still_editor_placement_remove", "remove", object{"placement": insert["placement"]})
			if got := list(); len(got) != 1 || got[0].(map[string]any)["placement"] != replacement["placement"] {
				t.Fatalf("removed the wrong still: %v", got)
			}
			mutate("project_close", "close-fixture", object{"changes": "discard"})
			t.Log("verified still insert, replacement, framing, duration, undo/redo, fallback, save/reopen and JPEG pixels")
		})
	}
}

func checkClipSpacing(t *testing.T, call func(string, object, string) object, dir string) {
	t.Helper()
	path := filepath.Join(dir, "Source spacing.cut")
	source := filepath.Join(dir, "media.mov")
	first := object{"id": "first", "file": filepath.Base(source), "from": "0", "to": "1001/7500"}
	second := object{"id": "second", "file": source, "from": "1001/5000", "to": "1001/2500"}
	clips := []object{first, second}
	document := object{"format": "mpcut", "schema_version": 9, "kind": "sequence", "clips": clips}
	saved, err := json.Marshal(document)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, saved, 0600); err != nil {
		t.Fatal(err)
	}

	project := call("project_open", object{"project_path": path, "operation_id": "source-spacing-open"}, "")["project_handle"]
	var current object
	eventually(t, "indexed source spacing project", func() bool {
		current = call("project_editor_state_read", object{"project_handle": project}, "")
		return slices.Contains(current["available_operations"].([]any), "timeline_clips_space")
	})
	spacingArgs := object{"project_handle": project, "expected_revision": current["revision"],
		"operation_id": "source-spacing-edit", "source_timing": true, "background": "#123456"}
	receipt := call("timeline_clips_space", spacingArgs, "")
	if receipt["project_handle"] != project || receipt["action"] != "Space Clips" || receipt["changed"] != true ||
		receipt["history_retained"] != true || receipt["revision"] == current["revision"] {
		t.Fatalf("unexpected spacing receipt: %v", receipt)
	}
	conflict := maps.Clone(spacingArgs)
	conflict["background"] = "#FFFFFF"
	call("timeline_clips_space", conflict, "operation_conflict")
	conflict["operation_id"] = "source-spacing-stale"
	call("timeline_clips_space", conflict, "stale_revision")
	noOp := maps.Clone(spacingArgs)
	noOp["expected_revision"] = receipt["revision"]
	noOp["operation_id"] = "source-spacing-no-op"
	if repeated := call("timeline_clips_space", noOp, ""); repeated["changed"] != false ||
		repeated["history_retained"] != false || repeated["revision"] != receipt["revision"] {
		t.Fatalf("reapplying the same spacing changed the project: %v", repeated)
	}
	list := call("still_editor_placements_list", object{"project_handle": project, "expected_revision": receipt["revision"]}, "")
	rows := list["items"].([]any)
	if len(rows) != 1 {
		t.Fatalf("source spacing did not add one gap: %v", list)
	}
	gap := rows[0].(object)
	if gap["kind"] != "gap" || gap["offline"] != false || gap["duration"] != "1001/15000" || gap["cadence"] != "1001/30000" ||
		gap["framing"].(object)["background"] != "#123456" {
		t.Fatalf("incorrect source-timed gap: %v", gap)
	}
	undone := call("history_undo", object{"project_handle": project, "expected_revision": receipt["revision"],
		"operation_id": "source-spacing-undo"}, "")
	if list := call("still_editor_placements_list", object{"project_handle": project, "expected_revision": undone["revision"]}, ""); list["total"] != float64(0) {
		t.Fatalf("undo retained the source-timed gap: %v", list)
	}
	if retry := call("timeline_clips_space", spacingArgs, ""); !reflect.DeepEqual(retry, receipt) {
		t.Fatalf("spacing retry after undo did not replay the original receipt: %v", retry)
	}
	call("project_close", object{"project_handle": project, "expected_revision": undone["revision"],
		"operation_id": "source-spacing-close", "changes": "discard"}, "")

	output := filepath.Join(dir, "Source spacing.mov")
	rawClips := []object{{"file": source, "from": first["from"], "to": first["to"]},
		{"file": source, "from": second["from"], "to": second["to"]}}
	for _, fixture := range []struct {
		name string
		args object
	}{
		{"saved", object{"project_path": path, "output": output}},
		{"inline", object{"project_data": document, "working_directory": dir, "output": output}},
		{"raw", object{"edit": object{"output": output, "clips": rawClips}}},
	} {
		args := fixture.args
		maps.Copy(args, object{"operation_id": fileOperationID(), "space_clips": "source", "dry_run": true, "mode": "encode"})
		tool := "export_file_project_render"
		if fixture.name == "raw" {
			tool = "export_file_clips_join"
		}
		job := call(tool, args, "")["job_id"]
		if retry := call(tool, args, ""); retry["job_id"] != job {
			t.Fatalf("%s export retry returned a different job: %v", fixture.name, retry)
		}
		conflict := maps.Clone(args)
		conflict["space_clips"] = "0"
		call(tool, conflict, "operation_id_conflict")
		eventually(t, "spaced "+fixture.name+" dry run", func() bool {
			status := call("file_job_status_read", object{"job_id": job}, "")
			switch status["state"] {
			case "running":
				return false
			case "succeeded":
				result := status["result"].(object)
				duration := object{"numerator": float64(1001), "denominator": float64(15000)}
				if !reflect.DeepEqual(result["generated_still_duration"], duration) {
					t.Fatalf("%s export did not plan the expected gap: %v", fixture.name, result)
				}
				return true
			default:
				t.Fatalf("%s export did not succeed: %v", fixture.name, status)
				return false
			}
		})
	}
	if content, err := os.ReadFile(path); err != nil || !bytes.Equal(content, saved) {
		t.Fatalf("file export modified the source project: %v", err)
	}
	if _, err := os.Stat(output); !os.IsNotExist(err) {
		t.Fatalf("file export dry run wrote a render: %v", err)
	}
}

func checkClearVariableRateSpacing(t *testing.T, call func(string, object, string) object) {
	t.Helper()
	_, testFile, _, _ := runtime.Caller(0)
	source := filepath.Join(filepath.Dir(testFile), "../../Tests/MPCutAppTests/Fixtures/VFR-PTS.mp4")
	path := filepath.Join(t.TempDir(), "Variable rate spacing.cut")
	document := object{"format": "mpcut", "schema_version": 9, "kind": "sequence", "clips": []object{
		{"id": "first", "file": source, "from": "0", "to": "1/5"},
		{"id": "second", "file": source, "from": "2/5", "to": "3/5"},
	}}
	saved, err := json.Marshal(document)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, saved, 0600); err != nil {
		t.Fatal(err)
	}
	project := call("project_open", object{"project_path": path, "operation_id": "vfr-spacing-open"}, "")["project_handle"]
	var current object
	eventually(t, "indexed variable rate spacing project", func() bool {
		current = call("project_editor_state_read", object{"project_handle": project}, "")
		return slices.Contains(current["available_operations"].([]any), "timeline_clips_space")
	})
	call("timeline_clips_space", object{"project_handle": project, "expected_revision": current["revision"],
		"operation_id": "vfr-spacing-missing-cadence", "duration": "1/10"}, "invalid_arguments")
	added := call("timeline_clips_space", object{"project_handle": project, "expected_revision": current["revision"],
		"operation_id": "vfr-spacing-add", "duration": "1/10", "cadence": "1/10"}, "")
	cleared := call("timeline_clips_space", object{"project_handle": project, "expected_revision": added["revision"],
		"operation_id": "vfr-spacing-clear", "duration": "0"}, "")
	if cleared["changed"] != true || cleared["history_retained"] != true {
		t.Fatalf("gap removal did not commit: %v", cleared)
	}
	if list := call("still_editor_placements_list", object{"project_handle": project, "expected_revision": cleared["revision"]}, ""); list["total"] != float64(0) {
		t.Fatalf("gap removal retained a gap: %v", list)
	}
	call("project_close", object{"project_handle": project, "expected_revision": cleared["revision"],
		"operation_id": "vfr-spacing-close", "changes": "discard"}, "")
}
