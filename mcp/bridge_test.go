package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

func socketPath(t *testing.T) string {
	t.Helper()
	// Darwin's sockaddr_un has at most 103 usable bytes.
	dir, err := os.MkdirTemp("/tmp", "mpcut-bridge-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	return filepath.Join(dir, "control.sock")
}

func listenForEditor(t *testing.T, path string) *net.UnixListener {
	t.Helper()
	listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: path, Net: "unix"})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { listener.Close() })
	if err := listener.SetDeadline(time.Now().Add(10 * time.Second)); err != nil {
		t.Fatal(err)
	}
	return listener
}

func TestBridgeRoundTrip(t *testing.T) {
	for _, tc := range []struct {
		name     string
		reply    string
		expected string
		failed   bool
	}{
		{"state", `{"result":{"revision":2}}`, `{"revision":2}`, false},
		{"stale", `{"error":{"code":"stale_revision","message":"Read state again.","revision":3}}`, `{"code":"stale_revision","message":"Read state again.","revision":3}`, true},
		{"lost", "", "", true},
		{"malformed JSON", `{"result":`, "", true},
		{"missing payload", `{}`, "", true},
		{"ambiguous payload", `{"result":{"revision":3},"error":{"code":"stale_revision","message":"Read state again."}}`, "", true},
		{"invalid error", `{"error":{"message":"Read state again."}}`, "", true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			path := socketPath(t)
			listener := listenForEditor(t, path)
			input := json.RawMessage(`{"expected_revision":9007199254740993}`)
			received := make(chan request, 1)
			go func() {
				conn, err := listener.Accept()
				if err != nil {
					return
				}
				defer conn.Close()
				frame, _ := bufio.NewReader(conn).ReadBytes('\n')
				var r request
				_ = json.Unmarshal(frame, &r)
				received <- r
				if tc.reply != "" {
					_, _ = conn.Write([]byte(tc.reply + "\n"))
				}
			}()
			ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
			defer cancel()
			res, err := callEditor(ctx, path, "project_editor_state_read", input)
			if err != nil {
				t.Fatal(err)
			}
			r := <-received
			if r.Version != 2 || r.Tool != "project_editor_state_read" || string(r.Arguments) != string(input) {
				t.Fatalf("unexpected forwarded request %+v", r)
			}
			body := res.StructuredContent.(json.RawMessage)
			if res.IsError != tc.failed {
				t.Fatalf("unexpected isError %v", res.IsError)
			}
			if tc.expected != "" && string(body) != tc.expected {
				t.Fatalf("unexpected response %s", body)
			}
			if tc.expected == "" {
				var e editorError
				if err := json.Unmarshal(body, &e); err != nil || e.Code != "outcome_unknown" {
					t.Fatalf("uncertain response: %s", body)
				}
			}
		})
	}
}

func TestBridgeFrameSizeUsesSocketEncoding(t *testing.T) {
	for _, tc := range []struct {
		size int
		code string
	}{
		{1 << 20, "app_unavailable"},
		{maxFrame, "request_too_large"},
	} {
		args := json.RawMessage(`{"text":"` + strings.Repeat("&", tc.size) + `"}`)
		result, err := callEditor(t.Context(), socketPath(t), "example", args)
		if err != nil {
			t.Fatal(err)
		}
		var reported editorError
		if err := json.Unmarshal(result.StructuredContent.(json.RawMessage), &reported); err != nil || reported.Code != tc.code {
			t.Fatalf("payload of %d bytes returned %+v (%v)", tc.size, reported, err)
		}
	}
}

func TestBridgeReturnsCancellationBeforeConnecting(t *testing.T) {
	ctx, cancel := context.WithCancel(t.Context())
	cancel()
	res, err := callEditor(ctx, socketPath(t), "project_windows_list", nil)
	if res != nil || !errors.Is(err, context.Canceled) {
		t.Fatalf("got result %v, error %v", res, err)
	}
}

func TestBridgeLargeReplyLimit(t *testing.T) {
	for _, tc := range []struct {
		name        string
		plain, html int
		tooLarge    bool
	}{
		{"plain reply fits", 2 << 20, 0, false},
		{"mixed reply fits", 1 << 20, 1 << 20, false},
		{"mixed reply exceeds limit", 1 << 20, 5 << 18, true},
		{"HTML escapes alone exceed limit", 0, 2 << 20, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			path := socketPath(t)
			listener := listenForEditor(t, path)
			body := `{"text":"` + strings.Repeat("a", tc.plain) + strings.Repeat("&", tc.html) + `"}`
			reply := []byte(`{"result":` + body + "}\n")
			go func() {
				conn, err := listener.Accept()
				if err != nil {
					return
				}
				defer conn.Close()
				if _, err := bufio.NewReader(conn).ReadBytes('\n'); err == nil {
					_, _ = conn.Write(reply)
				}
			}()
			ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
			defer cancel()
			result, err := callEditor(ctx, path, "project_editor_state_read", nil)
			if err != nil {
				t.Fatal(err)
			}
			raw := result.StructuredContent.(json.RawMessage)
			if result.IsError != tc.tooLarge {
				t.Fatalf("got IsError=%t, want %t", result.IsError, tc.tooLarge)
			}
			if tc.tooLarge {
				var reported editorError
				if err := json.Unmarshal(raw, &reported); err != nil || reported.Code != "response_too_large" {
					t.Fatalf("got %+v (%v), want response_too_large", reported, err)
				}
			} else if string(raw) != body || result.Content[0].(*mcp.TextContent).Text != body {
				t.Fatal("reply changed in transit")
			}
		})
	}
}
