// mpcut-mcp is the stdio endpoint for the running MPCut editor.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// Release packaging sets this to MPCutRelease.version.
var version = "dev"

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run() error {
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	exe, err = filepath.EvalSymlinks(exe)
	if err != nil {
		return err
	}
	directory := fmt.Sprintf("mpcut-%d", os.Getuid())
	if name := os.Getenv("MPCUT_TEST_SOCKET_DIRECTORY"); name != "" {
		if !regexp.MustCompile(`^mpcut-test-[a-zA-Z0-9]{1,64}$`).MatchString(name) {
			return errors.New("invalid MPCut test socket directory")
		}
		directory = name
	}
	return serveEditor(exe, filepath.Join("/tmp", directory, "control.sock"))
}

func serveEditor(exe, path string) error {
	dir := filepath.Join(filepath.Dir(exe), "..", "Resources", "MCPTools")
	if filepath.Base(filepath.Dir(exe)) != "Helpers" {
		// go run from the module or checkout root uses the same descriptors as the bundle.
		dir = filepath.Join("Sources", "MPCutApp", "MCPResources")
		if _, err := os.Stat(dir); errors.Is(err, os.ErrNotExist) {
			dir = filepath.Join("..", dir)
		}
	}
	tools, err := readCatalog(dir)
	if err != nil {
		return err
	}
	server := mcp.NewServer(&mcp.Implementation{Name: "mpcut", Version: version}, &mcp.ServerOptions{
		Instructions: "Use list_projects and get_editor_state for live edits. Target the returned project and revision. Preserve the operation ID when retrying an edit. File tools operate on saved files. Enable local control in MPCut Settings. Read mpcut://docs/agent-guide for workflows and recovery.",
	})
	registerDocumentation(server, exe)
	for _, tool := range tools {
		mcp.AddTool(server, tool, func(ctx context.Context, req *mcp.CallToolRequest, _ map[string]json.RawMessage) (*mcp.CallToolResult, any, error) {
			// The SDK validates input. Forward the original JSON to preserve exact numeric values.
			result, err := callEditor(ctx, path, req.Params.Name, req.Params.Arguments)
			return result, nil, err
		})
	}
	return server.Run(context.Background(), &mcp.StdioTransport{MaxLineLength: maxFrame})
}

func readCatalog(dir string) ([]*mcp.Tool, error) {
	files, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	var tools []*mcp.Tool
	seen := map[string]struct{}{}
	for _, entry := range files {
		if entry.IsDir() || filepath.Ext(entry.Name()) != ".json" {
			continue
		}
		file := filepath.Join(dir, entry.Name())
		data, err := os.ReadFile(file)
		if err != nil {
			return nil, err
		}
		var group []*mcp.Tool
		if err := json.Unmarshal(data, &group); err != nil {
			return nil, fmt.Errorf("%s: %w", file, err)
		}
		for _, t := range group {
			if t == nil || t.Name == "" {
				return nil, fmt.Errorf("%s: missing tool name", file)
			}
			schema, ok := t.InputSchema.(map[string]any)
			if !ok || schema["type"] != "object" {
				return nil, fmt.Errorf("%s: tool %s requires an object input schema", file, t.Name)
			}
			if _, ok := seen[t.Name]; ok {
				return nil, fmt.Errorf("%s: duplicate tool %s", file, t.Name)
			}
			seen[t.Name] = struct{}{}
			tools = append(tools, t)
		}
	}
	if len(tools) == 0 {
		return nil, fmt.Errorf("no MPCut tool descriptors found in %s", dir)
	}
	return tools, nil
}
