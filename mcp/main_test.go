package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

func TestInvalidLaunchMode(t *testing.T) {
	for _, args := range [][]string{{"--files-only", "extra"}, {"--file-only"}, {"--grok-http"}} {
		if err := run(args); err == nil || !strings.Contains(err.Error(), "usage:") {
			t.Fatalf("run(%q) returned %v", args, err)
		}
	}
}

func TestHelperSubprocess(t *testing.T) {
	if os.Getenv("MPCUT_HELPER_TEST_PROCESS") != "1" {
		return
	}
	if err := serveEditor(os.Args[0], os.Getenv("MPCUT_HELPER_TEST_SOCKET")); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	os.Exit(0)
}

func process(t *testing.T, ctx context.Context, path string) *exec.Cmd {
	t.Helper()
	cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestHelperSubprocess$")
	cmd.Env = append(os.Environ(), "MPCUT_HELPER_TEST_PROCESS=1", "MPCUT_HELPER_TEST_SOCKET="+path)
	return cmd
}

// Use raw transport frames here to detect accidental fallback to legacy initialization.
func TestJulyCallsWithoutInitialize(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	cmd := process(t, ctx, socketPath(t))
	in, err := cmd.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	out, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() {
		in.Close()
		if err := cmd.Wait(); err != nil {
			t.Error(err)
		}
	}()
	reader := bufio.NewReader(out)
	exchange := func(id int, method string, params map[string]any) map[string]any {
		t.Helper()
		params["_meta"] = map[string]any{
			"io.modelcontextprotocol/protocolVersion":    "2026-07-28",
			"io.modelcontextprotocol/clientInfo":         map[string]string{"name": "MPCut tests", "version": "1"},
			"io.modelcontextprotocol/clientCapabilities": map[string]any{},
		}
		if err := json.NewEncoder(in).Encode(map[string]any{"jsonrpc": "2.0", "id": id, "method": method, "params": params}); err != nil {
			t.Fatal(err)
		}
		reply, err := reader.ReadBytes('\n')
		if err != nil {
			t.Fatal(err)
		}
		var r struct {
			ID     int
			Result map[string]any
		}
		if err := json.Unmarshal(reply, &r); err != nil || r.ID != id || r.Result["resultType"] != "complete" {
			t.Fatalf("invalid July reply %s", reply)
		}
		return r.Result
	}
	if res := exchange(1, "tools/list", map[string]any{}); len(res["tools"].([]any)) < 2 {
		t.Fatal("missing tools")
	}
	if res := exchange(2, "tools/call", map[string]any{"name": "project_editor_state_read", "arguments": map[string]any{}}); res["isError"] != true {
		t.Fatal("missing arguments accepted")
	}
	res := exchange(3, "server/discover", map[string]any{})
	if !slices.Contains(res["supportedVersions"].([]any), any("2026-07-28")) {
		t.Fatal("missing July version")
	}
}

func TestSDKHostStdio(t *testing.T) {
	for _, version := range []string{"2026-07-28", "2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"} {
		t.Run(version, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(t.Context(), 15*time.Second)
			defer cancel()
			session := connectSDKHost(t, ctx, socketPath(t), version)
			defer session.Close()

			tools := map[string]*mcp.Tool{}
			for tool, err := range session.Tools(ctx, nil) {
				if err != nil {
					t.Fatal(err)
				}
				tools[tool.Name] = tool
			}
			for _, name := range []string{"project_windows_list", "project_editor_state_read", "review_editor_frame_read", "still_editor_placements_list", "timeline_gap_insert", "still_editor_picture_replace", "still_editor_placement_insert", "still_editor_placement_update", "still_editor_placement_remove", "still_editor_asset_relink", "timeline_clips_space"} {
				if tools[name] == nil {
					t.Errorf("%s missing", name)
				}
			}
			for _, operation := range []string{"list", "locate", "relink", "replace"} {
				name := "project_editor_media_" + operation
				if tools[name] == nil || fileTool(name) {
					t.Errorf("%s is missing or incorrectly routed to the file worker", name)
				}
				name = "project_file_media_" + operation
				if tools[name] == nil || !fileTool(name) {
					t.Errorf("%s is missing or incorrectly routed to a live editor", name)
				}
			}

			resources, err := session.ListResources(ctx, nil)
			if err != nil {
				t.Fatal(err)
			}
			if len(resources.Resources) != 3 {
				t.Fatalf("got %d documentation resources", len(resources.Resources))
			}
			for uri, file := range map[string]string{
				"mpcut://docs/agent-guide":    "MCP-AGENT-GUIDE.md",
				"mpcut://docs/tool-reference": "MCP-REFERENCE.md",
				"mpcut://docs/headless":       "HEADLESS.md",
			} {
				want, err := os.ReadFile(filepath.Join("..", "docs", file))
				if err != nil {
					t.Fatal(err)
				}
				resource, err := session.ReadResource(ctx, &mcp.ReadResourceParams{URI: uri})
				if err != nil {
					t.Fatal(err)
				}
				if len(resource.Contents) != 1 || resource.Contents[0].URI != uri ||
					resource.Contents[0].MIMEType != "text/markdown" || resource.Contents[0].Text != string(want) {
					t.Errorf("incorrect markdown for %s", uri)
				}
			}

			res, err := session.CallTool(ctx, &mcp.CallToolParams{Name: "project_windows_list"})
			if err != nil {
				t.Fatal(err)
			}
			if !res.IsError || len(res.Content) != 1 {
				t.Fatalf("expected app unavailable tool result: %+v", res)
			}
			text, ok := res.Content[0].(*mcp.TextContent)
			var failure editorError
			if !ok || json.Unmarshal([]byte(text.Text), &failure) != nil || failure.Code != "app_unavailable" {
				t.Fatalf("invalid app unavailable result: %+v", res)
			}
		})
	}
}

func TestStillSchemaRejectsMixedPlacementFields(t *testing.T) {
	ctx, cancel := context.WithTimeout(t.Context(), 15*time.Second)
	defer cancel()
	session := connectSDKHost(t, ctx, socketPath(t), "2026-07-28")
	defer session.Close()
	arguments := map[string]any{
		"project_handle": "timeline", "expected_revision": 0, "operation_id": "still-schema",
		"path": "/tmp/card.png", "space": "assembly", "at": "0", "duration": "1",
	}
	call := func() string {
		t.Helper()
		result, err := session.CallTool(ctx, &mcp.CallToolParams{Name: "still_editor_placement_insert", Arguments: arguments})
		if err != nil || !result.IsError || len(result.Content) != 1 {
			t.Fatalf("expected one validation or bridge error: %+v (%v)", result, err)
		}
		content, ok := result.Content[0].(*mcp.TextContent)
		if !ok {
			t.Fatalf("expected a text error, got %T", result.Content[0])
		}
		return content.Text
	}
	if valid := call(); !strings.Contains(valid, `"code":"app_unavailable"`) {
		t.Fatalf("valid insert did not reach the bridge: %s", valid)
	}
	arguments["from"] = "0"
	if mixed := call(); !strings.HasPrefix(mixed, `validating "arguments":`) {
		t.Fatalf("mixed insert was not rejected by the helper schema: %s", mixed)
	}
}

func TestMulticamAudioSchemaReachesDesktop(t *testing.T) {
	ctx, cancel := context.WithTimeout(t.Context(), 15*time.Second)
	defer cancel()
	session := connectSDKHost(t, ctx, socketPath(t), "2026-07-28")
	defer session.Close()
	lane := map[string]any{
		"id": "camera-a", "label": "Camera A", "color_slot": 2,
		"target": map[string]any{"kind": "camera", "angle_id": "a"},
	}
	selection := map[string]any{"source_id": "a", "audio_stream_index": 1}
	for _, tc := range []struct {
		tool   string
		fields map[string]any
		badKey string
		badVal any
	}{
		{"multicam_program_audio_set", map[string]any{"mode": "mix", "lanes": []any{lane}}, "source_id", "a"},
		{"multicam_program_audio_set", map[string]any{
			"mode": "replace", "replacement": "/tmp/donor.wav", "reference_source_id": "a",
			"relative_offset": "1/48000", "replacement_audio_stream_index": 0,
		}, "mode", "fixed"},
		{"multicam_track_audio_edit", map[string]any{
			"action": "set", "id": "donor", "original": selection,
			"path": "/tmp/donor.wav", "replacement_source_id": "donor-source", "replacement_stream_index": 0,
			"relative_offset": "1/48000", "uncovered": "keep_original",
		}, "replacement", selection},
		{"multicam_track_audio_sync_suggest", map[string]any{
			"program": true, "original": map[string]any{"source_id": "a"},
			"path": "/tmp/donor.wav", "replacement_stream_index": 0,
		}, "program", false},
		{"export_editor_project_plan", map[string]any{
			"output": "/tmp/downmix.mov", "mode": "copy", "audio": "pcm", "audio_output": "downmix_stereo",
		}, "audio_output", "surround"},
	} {
		t.Run(tc.tool, func(t *testing.T) {
			tc.fields["project_handle"] = "timeline"
			tc.fields["expected_revision"] = 0
			tc.fields["operation_id"] = "multicam-audio-schema"
			check := func(want string) {
				t.Helper()
				reply, err := session.CallTool(ctx, &mcp.CallToolParams{Name: tc.tool, Arguments: tc.fields})
				if err != nil || !reply.IsError || len(reply.Content) != 1 {
					t.Fatalf("expected one validation or bridge error: %+v (%v)", reply, err)
				}
				content, ok := reply.Content[0].(*mcp.TextContent)
				if !ok || !strings.Contains(content.Text, want) {
					t.Fatalf("expected %q in error, got %+v", want, reply.Content[0])
				}
			}
			check(`"code":"app_unavailable"`)
			tc.fields[tc.badKey] = tc.badVal
			check(`validating "arguments":`)
		})
	}
}

func connectSDKHost(t *testing.T, ctx context.Context, path, version string) *mcp.ClientSession {
	t.Helper()
	client := mcp.NewClient(&mcp.Implementation{Name: "MPCut test host", Version: "1"}, nil)
	session, err := client.Connect(ctx, &mcp.CommandTransport{Command: process(t, ctx, path)},
		&mcp.ClientSessionOptions{ProtocolVersion: version})
	if err != nil {
		t.Fatal(err)
	}
	if got := session.InitializeResult().ProtocolVersion; got != version {
		session.Close()
		t.Fatalf("negotiated protocol %q, want %q", got, version)
	}
	return session
}

func TestSDKCancellationClosesEditorSocket(t *testing.T) {
	for _, version := range []string{"2026-07-28", "2025-06-18"} {
		t.Run(version, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(t.Context(), 15*time.Second)
			defer cancel()
			path := socketPath(t)
			listener := listenForEditor(t, path)
			session := connectSDKHost(t, ctx, path, version)
			defer session.Close()

			callCtx, cancelCall := context.WithCancel(ctx)
			defer cancelCall()
			done := make(chan error, 1)
			go func() {
				_, err := session.CallTool(callCtx, &mcp.CallToolParams{Name: "project_windows_list"})
				done <- err
			}()
			conn, err := listener.AcceptUnix()
			if err != nil {
				t.Fatal(err)
			}
			defer conn.Close()
			if err := conn.SetReadDeadline(time.Now().Add(10 * time.Second)); err != nil {
				t.Fatal(err)
			}
			reader := bufio.NewReader(conn)
			if _, err := reader.ReadBytes('\n'); err != nil {
				t.Fatal(err)
			}
			cancelCall()
			if _, err := reader.ReadByte(); !errors.Is(err, io.EOF) {
				t.Fatalf("editor did not observe disconnection: %v", err)
			}
			if err := <-done; !errors.Is(err, context.Canceled) {
				t.Fatalf("tool call returned %v", err)
			}
			if _, err := session.ListTools(ctx, nil); err != nil {
				t.Fatalf("cancelling one call closed the session: %v", err)
			}
		})
	}
}

func TestEscapedToolResultFitsSDKFrame(t *testing.T) {
	ctx, cancel := context.WithTimeout(t.Context(), 45*time.Second)
	defer cancel()
	path := socketPath(t)
	listener := listenForEditor(t, path)
	session := connectSDKHost(t, ctx, path, "2026-07-28")
	defer session.Close()

	go func() {
		conn, err := listener.AcceptUnix()
		if err != nil {
			return
		}
		defer conn.Close()
		if _, err := bufio.NewReader(conn).ReadBytes('\n'); err != nil {
			return
		}
		reply := `{"result":{"detail":"` + strings.Repeat("<", 2<<20) + `"}}` + "\n"
		io.WriteString(conn, reply)
	}()

	res, err := session.CallTool(ctx, &mcp.CallToolParams{Name: "project_windows_list"})
	if err != nil {
		t.Fatal(err)
	}
	body, ok := res.StructuredContent.(map[string]any)
	if !ok || !res.IsError || body["code"] != "response_too_large" {
		t.Fatal("expected a structured response_too_large result")
	}
	if _, err := session.ListTools(ctx, nil); err != nil {
		t.Fatalf("oversized result closed the session: %v", err)
	}
}

// Schema keywords belong to JSON Schema. Field names inside properties belong to MPCut.
func TestConfiguredServerReportsInvalidToolSchema(t *testing.T) {
	contents := t.TempDir()
	dir := filepath.Join(contents, "Resources", "MCPTools")
	if err := os.MkdirAll(dir, 0700); err != nil {
		t.Fatal(err)
	}
	descriptor := `[{"name":"invalid_tool","inputSchema":{"type":"object","properties":{"label":{"type":42}}}}]`
	if err := os.WriteFile(filepath.Join(dir, "invalid.json"), []byte(descriptor), 0600); err != nil {
		t.Fatal(err)
	}
	server, err := configuredServer(filepath.Join(contents, "Helpers", "mpcut-mcp"), "", false)
	if server != nil || err == nil || !strings.Contains(err.Error(), "invalid_tool") {
		t.Fatalf("got server %v, error %v", server, err)
	}
}

func TestCatalogPropertyNames(t *testing.T) {
	tools, err := readCatalog(filepath.Join("..", "Sources", "MPCutApp", "MCPResources"))
	if err != nil {
		t.Fatal(err)
	}
	field := regexp.MustCompile(`^[a-z][a-z0-9]*(_[a-z0-9]+)*$`)
	var check func(string, any)
	check = func(path string, node any) {
		switch value := node.(type) {
		case map[string]any:
			for key, child := range value {
				if key == "properties" {
					for name := range child.(map[string]any) {
						if !field.MatchString(name) {
							t.Errorf("%s contains noncanonical field %q", path, name)
						}
					}
				}
				check(path+"."+key, child)
			}
		case []any:
			for _, child := range value {
				check(path, child)
			}
		}
	}
	for _, tool := range tools {
		check(tool.Name, tool.InputSchema)
	}
}

func TestCatalogDirectoryContainingBrackets(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "MPCut [Test].app")
	if err := os.Mkdir(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	data := []byte(`[{"name":"project_windows_list","inputSchema":{"type":"object"}}]`)
	if err := os.WriteFile(filepath.Join(dir, "projects.json"), data, 0o600); err != nil {
		t.Fatal(err)
	}
	tools, err := readCatalog(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(tools) != 1 || tools[0].Name != "project_windows_list" {
		t.Fatalf("unexpected catalog %+v", tools)
	}
}

func TestCatalogPreservesSignedTimestampBounds(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "transcript.json")
	schema := `{"type":"object","properties":{"value":{"type":"integer","minimum":-9223372036854775808,"maximum":9223372036854775807}}}`
	if err := os.WriteFile(path, []byte(`[{"name":"transcript_editor_words_read","inputSchema":`+schema+`}]`), 0o600); err != nil {
		t.Fatal(err)
	}
	tools, err := readCatalog(dir)
	if err != nil {
		t.Fatal(err)
	}
	encoded, err := json.Marshal(tools[0].InputSchema)
	if err != nil {
		t.Fatal(err)
	}
	for _, bound := range []string{"-9223372036854775808", "9223372036854775807"} {
		if !strings.Contains(string(encoded), bound) {
			t.Fatalf("timestamp bound %s changed in %s", bound, encoded)
		}
	}
}
