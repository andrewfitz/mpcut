package integration

import (
	"bytes"
	"image"
	"image/color"
	"image/jpeg"
	"image/png"
	"maps"
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

func checkStillAuthoring(t *testing.T, toolCaller func(*testing.T) func(string, object, string) object,
	rawCall func(*testing.T, string, object) *mcp.CallToolResult,
	runGUIProbe func(*testing.T, string, string) bool, dir string) {
	t.Helper()
	card := filepath.Join(dir, "Red card.png")
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
	for _, fixture := range []struct {
		name, program, replacement, contents string
	}{
		{"sequence", "sequence", "sequence", `"clips":[{"id":"clip","file":"media.mov","from":"0","to":"1001/2500"}]`},
		{"multicam", "assembly", "group", `"referenceAngle":"wide","range":{"from":"0","to":"1001/2500"},"angles":[{"id":"wide","file":"media.mov"}],"audio":{"mode":"none"},"switches":[{"at":"0","angle":"wide"}]`},
	} {
		t.Run(fixture.name, func(t *testing.T) {
			call := toolCaller(t)
			path := filepath.Join(dir, "still-"+fixture.name+".cut")
			doc := `{"format":"mpcut","schemaVersion":1,"kind":"` + fixture.name + `",` + fixture.contents + `}`
			if err := os.WriteFile(path, []byte(doc), 0600); err != nil {
				t.Fatal(err)
			}
			opID := func(name string) string { return "still-" + fixture.name + "-" + name }
			open := func(action string) any {
				return call("open_project", object{"path": path, "operationID": opID(action)}, "")["project"]
			}
			project := open("open")
			state := func() object { return call("get_editor_state", object{"project": project}, "") }
			eventually(t, "indexed "+fixture.name+" source", func() bool {
				if fixture.name == "sequence" {
					current := state()
					return current["busy"] == false && current["total"] == float64(1)
				}
				sources := call("get_multicam", object{"project": project, "section": "sources"}, "")["sources"].([]any)
				return len(sources) == 1 && sources[0].(map[string]any)["indexed"] == true && state()["canEdit"] == true
			})
			mutate := func(name, ID string, fields object) object {
				args := object{"project": project, "expectedRevision": state()["revision"], "operationID": opID(ID)}
				maps.Copy(args, fields)
				return call(name, args, "")
			}
			list := func() []any {
				return call("list_stills", object{"project": project}, "")["items"].([]any)
			}
			replacement := mutate("add_still", "replace", object{"operation": "replace", "path": card, "space": fixture.replacement,
				"from": "1001/30000", "to": "1001/7500"})
			insert := mutate("add_still", "insert", object{"operation": "insert", "path": card, "space": fixture.program,
				"at": "0", "duration": "1001/15000", "cadence": "1001/30000"})
			original := list()
			if len(original) != 2 || original[0].(map[string]any)["placement"] != insert["placement"] ||
				original[1].(map[string]any)["placement"] != replacement["placement"] {
				t.Fatalf("unexpected still placements: %v", original)
			}
			mutate("update_still", "adjust", object{"placement": insert["placement"], "duration": "1001/10000",
				"fit": "fill", "background": "#008000"})
			adjusted := list()
			row := adjusted[0].(map[string]any)
			framing := row["framing"].(map[string]any)
			if row["authoredFrom"] != "0" || row["authoredTo"] != "1001/10000" || framing["background"] != "#008000" || framing["mode"] != "fill" {
				t.Fatalf("adjusted still did not reflect authored duration and framing: %v", row)
			}
			mutate("undo", "undo-adjust", nil)
			if got := list(); !reflect.DeepEqual(got, original) {
				t.Fatalf("undo did not restore still list: %v", got)
			}
			mutate("redo", "redo-adjust", nil)
			if got := list(); !reflect.DeepEqual(got, adjusted) {
				t.Fatalf("redo did not restore adjusted still list: %v", got)
			}
			if monitor := call("set_video_monitor", object{"project": project, "visible": true}, ""); monitor["monitorVisible"] != true {
				t.Fatalf("native video monitor did not open: %v", monitor)
			}
			if monitor := call("set_video_monitor", object{"project": project, "visible": false}, ""); monitor["monitorVisible"] != false {
				t.Fatalf("native video monitor did not close: %v", monitor)
			}
			job := mutate("render_project", "copy-preflight", object{"scope": "timeline", "mode": "copy", "dryRun": true,
				"output": filepath.Join(dir, "still-"+fixture.name+".mov")})["job"]
			var mode string
			eventually(t, "still copy refusal and fallback", func() bool {
				status := call("live_job_status", object{"project": project, "job": job}, "")
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
			call("focus_project", object{"project": project}, "")
			if runGUIProbe(t, "still_badge.swift", map[string]string{"smart": "Lossless", "encode": "Re-encode"}[mode]) {
				t.Log("verified native tier badge agrees with the MCP export fallback")
				for _, step := range []struct {
					menu string
					want []any
				}{{"Undo Update Still", original}, {"Redo Update Still", adjusted}} {
					if !runGUIProbe(t, "press_menu.swift", step.menu) {
						t.Fatal("AX permission became unavailable during native menu checks")
					}
					eventually(t, step.menu, func() bool { return reflect.DeepEqual(list(), step.want) })
				}
			}
			mutate("save_project", "save", nil)
			mutate("close_project", "close", nil)
			prev := project
			project = open("reopen")
			if project == prev || state()["dirty"] != false || !reflect.DeepEqual(list(), adjusted) {
				t.Fatalf("reopened still placement or window did not match saved document: %v", list())
			}
			mutate("undo", "undo-reopened", nil)
			if got := list(); !reflect.DeepEqual(got, original) {
				t.Fatalf("undo after reopen did not restore persisted history: %v", got)
			}
			mutate("redo", "redo-reopened", nil)
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
				result := rawCall(t, "review_frame", object{"project": project, "space": frame.space, "time": frame.time})
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
			row = list()[0].(map[string]any)
			splitArgs := object{"project": project, "expectedRevision": state()["revision"], "operationID": opID("split"),
				"occurrence": row["occurrence"], "space": fixture.program, "time": "1001/30000"}
			left := row["placement"]
			invalid := maps.Clone(splitArgs)
			invalid["operationID"] = opID("split-invalid-clock")
			invalid["space"] = map[string]string{"sequence": "source", "multicam": "group"}[fixture.name]
			call("split_at", invalid, "invalid_target")
			split := call("split_at", splitArgs, "")
			if split["leftPlacement"] != left || split["rightPlacement"] == left || len(list()) != 3 {
				t.Fatalf("split did not produce independent insert targets: %v, list: %v", split, list())
			}
			if replay := call("split_at", splitArgs, ""); !reflect.DeepEqual(replay, split) || len(list()) != 3 {
				t.Fatalf("split retry did not replay: %v", replay)
			}
			stale := maps.Clone(splitArgs)
			stale["operationID"] = opID("split-stale")
			call("split_at", stale, "stale_revision")
			position := call("seek", object{"project": project, "space": fixture.program, "time": "1001/30000",
				"occurrence": split["right"], "expectedRevision": split["revision"]}, "")
			if fixture.name == "multicam" && (position["placement"] != split["rightPlacement"] || position["groupTime"] != nil) {
				t.Fatalf("seek mapped a still to a camera: %v", position)
			}
			mutate("undo", "undo-split", nil)
			if got := list(); !reflect.DeepEqual(got, adjusted) {
				t.Fatalf("undo did not rejoin split still: %v", got)
			}
			newPath := filepath.Join(dir, "Relinked "+fixture.name+".png")
			if err := os.WriteFile(newPath, pngData.Bytes(), 0600); err != nil {
				t.Fatal(err)
			}
			mutate("relink_still", "relink", object{"asset": insert["asset"], "path": newPath})
			got := list()[0].(map[string]any)
			gotPath, _ := got["path"].(string)
			gotFile, gotErr := os.Stat(gotPath)
			relinkedFile, relinkErr := os.Stat(newPath)
			if gotErr != nil || relinkErr != nil || !os.SameFile(gotFile, relinkedFile) || got["asset"] != insert["asset"] {
				t.Fatalf("relink changed asset ID or kept the old path: %v", got)
			}
			mutate("remove_still", "remove", object{"placement": insert["placement"]})
			if got := list(); len(got) != 1 || got[0].(map[string]any)["placement"] != replacement["placement"] {
				t.Fatalf("removed the wrong still: %v", got)
			}
			mutate("close_project", "close-fixture", object{"changes": "discard"})
			t.Log("verified still insert, replacement, framing, duration, undo/redo, fallback, save/reopen and JPEG pixels")
		})
	}
}
