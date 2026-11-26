// mpcut-mcp is the stdio endpoint for the running MPCut editor.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"maps"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// Release packaging sets this to MPCutRelease.version.
var version = "dev"

// The whole catalog is several hundred tools. A host that loads every schema into its
// model's context can advertise part of it: --toolsets names catalog groups, and
// --live-only leaves out the saved-file tools, as --files-only leaves out the live ones.
type toolSelection struct {
	groups   []string
	liveOnly bool
}

var selection toolSelection

const discoveryGroup = "projects"

func (s toolSelection) includes(name, group string, filesOnly bool) bool {
	if s.liveOnly && fileTool(name) {
		return false
	}
	// A chosen group always comes with what its tools depend on: window discovery for the live
	// ones, and the job receipts that every saved-file tool returns.
	return len(s.groups) == 0 || slices.Contains(s.groups, group) ||
		(group == discoveryGroup && !filesOnly) || strings.HasPrefix(name, "file_job_")
}

// parseSelection removes the tool selection options and returns the remaining arguments.
func parseSelection(args []string) (toolSelection, []string, error) {
	var chosen toolSelection
	var rest []string
	for i := 0; i < len(args); i++ {
		switch {
		case args[i] == "--live-only":
			chosen.liveOnly = true
		case args[i] == "--toolsets" && i+1 < len(args):
			i++
			for _, group := range strings.Split(args[i], ",") {
				if group = strings.TrimSpace(group); group != "" {
					chosen.groups = append(chosen.groups, group)
				}
			}
			if len(chosen.groups) == 0 {
				return chosen, nil, errors.New("--toolsets needs at least one group name")
			}
		default:
			rest = append(rest, args[i])
		}
	}
	if chosen.liveOnly && slices.Contains(rest, "--files-only") {
		return chosen, nil, errors.New("--live-only and --files-only leave no tools")
	}
	return chosen, rest, nil
}

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run(args []string) error {
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	exe, err = filepath.EvalSymlinks(exe)
	if err != nil {
		return err
	}
	if selection, args, err = parseSelection(args); err != nil {
		return err
	}
	if len(args) == 1 && args[0] == "--files-only" {
		return serveFiles(exe)
	}
	directory := fmt.Sprintf("mpcut-%d", os.Getuid())
	if name := os.Getenv("MPCUT_TEST_SOCKET_DIRECTORY"); name != "" {
		if !regexp.MustCompile(`^mpcut-test-[a-zA-Z0-9]{1,64}$`).MatchString(name) {
			return errors.New("invalid MPCut test socket directory")
		}
		directory = name
	}
	socket := filepath.Join("/tmp", directory, "control.sock")
	if len(args) > 0 && args[0] == "--grok-http" {
		if len(args) != 3 {
			return errors.New("usage: --grok-http APP_HELPER_PATH BEARER_KEY_FILE")
		}
		return serveGrok(args[1], socket, args[2])
	}
	if len(args) != 0 {
		return errors.New("usage: mpcut-mcp [--toolsets GROUP,...] [--live-only] [--files-only | --grok-http APP_HELPER_PATH BEARER_KEY_FILE]")
	}
	return serveEditor(exe, socket)
}

func serveEditor(exe, path string) error {
	server, err := editorServer(exe, path)
	if err != nil {
		return err
	}
	return server.Run(context.Background(), &mcp.StdioTransport{MaxLineLength: maxFrame})
}

func editorServer(exe, path string) (*mcp.Server, error) {
	return configuredServer(exe, path, false)
}

func configuredServer(exe, path string, filesOnly bool) (*mcp.Server, error) {
	dir := filepath.Join(filepath.Dir(exe), "..", "Resources", "MCPTools")
	if filepath.Base(filepath.Dir(exe)) != "Helpers" {
		// go run from the module or checkout root uses the same descriptors as the bundle.
		dir = filepath.Join("Sources", "MPCutApp", "MCPResources")
		if _, err := os.Stat(dir); errors.Is(err, os.ErrNotExist) {
			dir = filepath.Join("..", dir)
		}
	}
	tools, groups, err := readCatalogGroups(dir)
	if err != nil {
		return nil, err
	}
	for _, group := range selection.groups {
		known := false
		for _, name := range groups {
			known = known || name == group
		}
		if !known {
			names := slices.Compact(slices.Sorted(maps.Values(groups)))
			return nil, fmt.Errorf("unknown tool group %q; choose from %s", group, strings.Join(names, ", "))
		}
	}
	instructions := "Use project_windows_list and project_editor_state_read for live edits. Target the returned project and revision. Preserve the operation ID when retrying an edit. File tools operate on saved files. Enable local control in MPCut Settings. Read mpcut://docs/agent-guide for workflows and recovery."
	if filesOnly {
		instructions = "Read mpcut://docs/headless for saved-project workflows. Retain the operation ID to recover the job across files-only sessions with file_job_status_read."
	}
	server := mcp.NewServer(&mcp.Implementation{Name: "mpcut", Version: version}, &mcp.ServerOptions{
		Instructions: instructions,
	})
	registerDocumentation(server, exe)
	for _, tool := range tools {
		if filesOnly && !fileTool(tool.Name) || !selection.includes(tool.Name, groups[tool.Name], filesOnly) {
			continue
		}
		if err := registerEditorTool(server, tool, path); err != nil {
			return nil, err
		}
	}
	return server, nil
}

func registerEditorTool(server *mcp.Server, tool *mcp.Tool, path string) (err error) {
	// AddTool reports invalid descriptors by panicking during registration.
	defer func() {
		if failure := recover(); failure != nil {
			err = fmt.Errorf("register MPCut tool %q: %v", tool.Name, failure)
		}
	}()
	mcp.AddTool(server, tool, func(ctx context.Context, req *mcp.CallToolRequest, _ map[string]json.RawMessage) (*mcp.CallToolResult, any, error) {
		// The SDK validates input. Forward the original JSON to preserve exact numeric values.
		result, err := callEditor(ctx, path, req.Params.Name, req.Params.Arguments)
		return result, nil, err
	})
	return nil
}

func readCatalog(dir string) ([]*mcp.Tool, error) {
	tools, _, err := readCatalogGroups(dir)
	return tools, err
}

// readCatalogGroups also names each tool's group: its descriptor file without the extension.
func readCatalogGroups(dir string) ([]*mcp.Tool, map[string]string, error) {
	files, err := os.ReadDir(dir)
	if err != nil {
		return nil, nil, err
	}
	var tools []*mcp.Tool
	groups := map[string]string{}
	seen := map[string]struct{}{}
	for _, entry := range files {
		if entry.IsDir() || filepath.Ext(entry.Name()) != ".json" {
			continue
		}
		file := filepath.Join(dir, entry.Name())
		data, err := os.ReadFile(file)
		if err != nil {
			return nil, nil, err
		}
		var group []*mcp.Tool
		// Rational timestamp bounds must survive tools/list as exact integers.
		decoder := json.NewDecoder(bytes.NewReader(data))
		decoder.UseNumber()
		if err := decoder.Decode(&group); err != nil {
			return nil, nil, fmt.Errorf("%s: %w", file, err)
		}
		if err := decoder.Decode(new(json.RawMessage)); err != io.EOF {
			return nil, nil, fmt.Errorf("%s: unexpected data after tool descriptors", file)
		}
		for _, t := range group {
			if t == nil || t.Name == "" {
				return nil, nil, fmt.Errorf("%s: missing tool name", file)
			}
			schema, ok := t.InputSchema.(map[string]any)
			if !ok || schema["type"] != "object" {
				return nil, nil, fmt.Errorf("%s: tool %s requires an object input schema", file, t.Name)
			}
			if _, ok := seen[t.Name]; ok {
				return nil, nil, fmt.Errorf("%s: duplicate tool %s", file, t.Name)
			}
			seen[t.Name] = struct{}{}
			groups[t.Name] = strings.TrimSuffix(entry.Name(), ".json")
			tools = append(tools, t)
		}
	}
	if len(tools) == 0 {
		return nil, nil, fmt.Errorf("no MPCut tool descriptors found in %s", dir)
	}
	return tools, groups, nil
}
