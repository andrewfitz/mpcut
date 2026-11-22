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
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

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
	if res := exchange(2, "tools/call", map[string]any{"name": "get_editor_state", "arguments": map[string]any{}}); res["isError"] != true {
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
			for _, name := range []string{"list_projects", "get_editor_state", "review_frame"} {
				if tools[name] == nil {
					t.Errorf("%s missing", name)
				}
			}

			resources, err := session.ListResources(ctx, nil)
			if err != nil {
				t.Fatal(err)
			}
			if len(resources.Resources) != 2 {
				t.Fatalf("got %d documentation resources", len(resources.Resources))
			}
			for uri, file := range map[string]string{
				"mpcut://docs/agent-guide":    "MCP-AGENT-GUIDE.md",
				"mpcut://docs/tool-reference": "MCP-REFERENCE.md",
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

			res, err := session.CallTool(ctx, &mcp.CallToolParams{Name: "list_projects"})
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
				_, err := session.CallTool(callCtx, &mcp.CallToolParams{Name: "list_projects"})
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

	res, err := session.CallTool(ctx, &mcp.CallToolParams{Name: "list_projects"})
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

func TestCatalogDirectoryContainingBrackets(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "MPCut [Test].app")
	if err := os.Mkdir(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	data := []byte(`[{"name":"list_projects","inputSchema":{"type":"object"}}]`)
	if err := os.WriteFile(filepath.Join(dir, "projects.json"), data, 0o600); err != nil {
		t.Fatal(err)
	}
	tools, err := readCatalog(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(tools) != 1 || tools[0].Name != "list_projects" {
		t.Fatalf("unexpected catalog %+v", tools)
	}
}
