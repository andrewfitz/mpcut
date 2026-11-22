package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net"
	"os"
	"path/filepath"
	"syscall"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

const maxFrame = 4 << 20

type editorError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

type request struct {
	Version   int             `json:"version"`
	Tool      string          `json:"tool"`
	Arguments json.RawMessage `json:"arguments"`
}

func toolResult(body json.RawMessage, failed bool) *mcp.CallToolResult {
	return &mcp.CallToolResult{IsError: failed, StructuredContent: body,
		Content: []mcp.Content{&mcp.TextContent{Text: string(body)}},
	}
}

func failure(code, message string) *mcp.CallToolResult {
	body, _ := json.Marshal(editorError{code, message})
	return toolResult(body, true)
}

func callEditor(ctx context.Context, path, tool string, args json.RawMessage) (*mcp.CallToolResult, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if len(args) == 0 {
		args = json.RawMessage("{}")
	}
	frame, err := json.Marshal(request{1, tool, args})
	if err != nil {
		return nil, err
	}
	if len(frame)+1 > maxFrame {
		return failure("request_too_large", "Reduce the request to less than 4 MiB."), nil
	}
	unavailable := func() *mcp.CallToolResult {
		return failure("app_unavailable", "Open MPCut and enable local MCP control in Settings → General → Automation.")
	}
	dir, err := os.Lstat(filepath.Dir(path))
	if err != nil {
		return unavailable(), nil
	}
	if !dir.IsDir() || dir.Mode().Perm()&0077 != 0 || !ownedByCurrentUser(dir) {
		return failure("unsafe_endpoint", "MPCut's socket directory must be private and owned by the current user."), nil
	}
	socket, err := os.Lstat(path)
	if err != nil {
		return unavailable(), nil
	}
	if socket.Mode()&os.ModeSocket == 0 || !ownedByCurrentUser(socket) {
		return failure("unsafe_endpoint", "MPCut's control endpoint must be a socket owned by the current user."), nil
	}
	conn, err := (&net.Dialer{Timeout: 3 * time.Second}).DialContext(ctx, "unix", path)
	if err != nil {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		return unavailable(), nil
	}
	defer conn.Close()
	stop := context.AfterFunc(ctx, func() { conn.Close() })
	defer stop()
	// Long-running jobs return IDs; allow native foreground validation to complete.
	if err := conn.SetDeadline(time.Now().Add(5 * time.Minute)); err != nil {
		return nil, err
	}
	var response struct {
		Result json.RawMessage `json:"result"`
		Error  json.RawMessage `json:"error"`
	}
	// A lost response after writing may represent an already committed edit.
	unknown := func() (*mcp.CallToolResult, error) {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		return failure("outcome_unknown", "MPCut did not return a complete, valid response. Inspect current state or retry with the identical operation ID and arguments."), nil
	}
	if _, err := conn.Write(append(frame, '\n')); err != nil {
		return unknown()
	}
	reader := bufio.NewReader(io.LimitReader(conn, maxFrame))
	reply, err := reader.ReadBytes('\n')
	if err != nil {
		return unknown()
	}
	if err := json.Unmarshal(reply, &response); err != nil {
		return unknown()
	}
	hasObject := func(raw json.RawMessage) bool { return bytes.HasPrefix(bytes.TrimSpace(raw), []byte("{")) }
	var result *mcp.CallToolResult
	switch {
	case hasObject(response.Error) && response.Result == nil:
		var reported editorError
		if err := json.Unmarshal(response.Error, &reported); err != nil || reported.Code == "" || reported.Message == "" {
			return unknown()
		}
		result = toolResult(response.Error, true)
	case hasObject(response.Result) && response.Error == nil && tool == "review_frame":
		result, err = reviewFrameResult(response.Result)
		if err != nil {
			return failure("invalid_result", "MPCut did not return a valid review JPEG. Request the frame again."), nil
		}
	case hasObject(response.Result) && response.Error == nil:
		result = toolResult(response.Result, false)
	default:
		return unknown()
	}

	// The JSON result and its text fallback can each expand by six bytes per
	// byte when escaped. Measure large results, reserving room for the RPC envelope.
	const resultLimit = mcp.DefaultMaxLineLength - (4 << 10)
	if len(reply)*12 >= resultLimit {
		encoded, err := json.Marshal(result)
		if err != nil {
			return unknown()
		}
		if len(encoded) >= resultLimit {
			return failure("response_too_large", "MPCut returned too much data for one MCP response. Request a smaller page when available. If you requested an edit, inspect its current state before retrying."), nil
		}
	}
	return result, nil
}

func ownedByCurrentUser(info os.FileInfo) bool {
	stat, ok := info.Sys().(*syscall.Stat_t)
	return ok && stat.Uid == uint32(os.Getuid())
}
