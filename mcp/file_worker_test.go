package main

import (
	"bufio"
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestFileWorkerRejectsInvalidGreetingBeforeEOF(t *testing.T) {
	dir := t.TempDir()
	// Keep stdout open until the parent rejects the greeting and closes stdin.
	worker := filepath.Join(dir, "MPCutDesktop")
	if err := os.WriteFile(worker, []byte("#!/bin/sh\nprintf broken >&3\nexec cat >/dev/null\n"), 0700); err != nil {
		t.Fatal(err)
	}
	err := serveFiles(filepath.Join(dir, "mpcut-mcp"))
	if err == nil || !strings.Contains(err.Error(), "unexpected file worker greeting") {
		t.Fatalf("serveFiles returned %v", err)
	}
}

func TestFileWorkerExitsWhenWorkerDies(t *testing.T) {
	const fixture = "MPCUT_TEST_FILE_WORKER_HELPER"
	if path := os.Getenv(fixture); path != "" {
		if err := serveFiles(path); err == nil || !strings.Contains(err.Error(), "file worker exited: exit status 42") {
			fmt.Fprintf(os.Stderr, "serveFiles returned %v\n", err)
			os.Exit(1)
		}
		return
	}
	dir := t.TempDir()
	worker := filepath.Join(dir, "MPCutDesktop")
	// Hold the worker open until the MCP helper has handled a request.
	trigger := filepath.Join(dir, "exit")
	script := "#!/bin/sh\nprintf 'ready\\n' >&3\nwhile ! test -e \"$MPCUT_TEST_FILE_WORKER_EXIT\"; do sleep .05; done\nexit 42\n"
	if err := os.WriteFile(worker, []byte(script), 0700); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestFileWorkerExitsWhenWorkerDies$")
	cmd.Env = append(os.Environ(), fixture+"="+filepath.Join(dir, "mpcut-mcp"), "MPCUT_TEST_FILE_WORKER_EXIT="+trigger)
	stdin, err := cmd.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	defer stdin.Close()
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() {
		if cmd.ProcessState == nil {
			// Release the detached fixture even if the test failed before initialization.
			os.WriteFile(trigger, nil, 0600)
			cmd.Wait()
		}
	}()
	if _, err := stdin.Write([]byte("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"clientInfo\":{\"name\":\"test\",\"version\":\"1\"}}}\n")); err != nil {
		t.Fatal(err)
	}
	reply, err := bufio.NewReader(stdout).ReadString('\n')
	if err != nil || !strings.Contains(reply, "\"id\":1") {
		t.Fatalf("missing initialize response: %q, %v", reply, err)
	}
	if err := os.WriteFile(trigger, nil, 0600); err != nil {
		t.Fatal(err)
	}
	if err := cmd.Wait(); err != nil {
		t.Fatal(err)
	}
}
