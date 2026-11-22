package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"
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
			input := json.RawMessage(`{"expectedRevision":9007199254740993}`)
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
			res, err := callEditor(ctx, path, "get_editor_state", input)
			if err != nil {
				t.Fatal(err)
			}
			r := <-received
			if r.Version != 1 || r.Tool != "get_editor_state" || string(r.Arguments) != string(input) {
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

func TestBridgeReturnsCancellationBeforeConnecting(t *testing.T) {
	ctx, cancel := context.WithCancel(t.Context())
	cancel()
	res, err := callEditor(ctx, socketPath(t), "list_projects", nil)
	if res != nil || !errors.Is(err, context.Canceled) {
		t.Fatalf("got result %v, error %v", res, err)
	}
}
