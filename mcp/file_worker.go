package main

import (
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

func fileTool(name string) bool {
	return strings.Contains(name, "_file_") || strings.HasPrefix(name, "file_job_") || name == "cli_help_read" || name == "cli_version_read"
}

// The alternate stdio entry point owns a private worker and never connects to the editor.
func serveFiles(exe string) error {
	dir, err := os.MkdirTemp("/tmp", "mpcut-files-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(dir)
	worker := filepath.Join(filepath.Dir(exe), "..", "MacOS", "MPCut")
	if filepath.Base(filepath.Dir(exe)) != "Helpers" {
		worker = filepath.Join(filepath.Dir(exe), "MPCutDesktop")
	}
	cmd := exec.Command(worker, "--file-worker", dir)
	// Keep the worker out of the helper's process group so termination of the
	// client and helper still lets the worker drain its jobs on pipe EOF.
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Stdout = os.Stderr
	cmd.Stderr = os.Stderr
	ready, output, err := os.Pipe()
	if err != nil {
		return err
	}
	defer ready.Close()
	// The worker writes one greeting on fd 3, independently of its diagnostics.
	cmd.ExtraFiles = []*os.File{output}
	lifetime, err := cmd.StdinPipe()
	if err != nil {
		output.Close()
		return err
	}
	err = cmd.Start()
	output.Close()
	if err != nil {
		return err
	}
	ctx, cancel := context.WithCancelCause(context.Background())
	defer cancel(nil)
	exited := make(chan struct{})
	go func() {
		err := cmd.Wait()
		if err == nil {
			cancel(fmt.Errorf("file worker exited unexpectedly"))
		} else {
			cancel(fmt.Errorf("file worker exited: %w", err))
		}
		close(exited)
	}()
	defer func() {
		lifetime.Close()
		// Give the worker time to cancel its file jobs before reclaiming a stuck process.
		timer := time.NewTimer(30 * time.Second)
		defer timer.Stop()
		select {
		case <-exited:
		case <-timer.C:
			cmd.Process.Kill()
			<-exited
		}
	}()
	if err := ready.SetReadDeadline(time.Now().Add(30 * time.Second)); err != nil {
		return err
	}
	const greeting = "ready\n"
	var message [len(greeting)]byte
	if _, err := io.ReadFull(ready, message[:]); err != nil {
		return fmt.Errorf("file worker did not start: %w", err)
	}
	if string(message[:]) != greeting {
		return fmt.Errorf("unexpected file worker greeting: %q", message[:])
	}
	ready.Close()
	server, err := configuredServer(exe, filepath.Join(dir, "control.sock"), true)
	if err != nil {
		return err
	}
	err = server.Run(ctx, &mcp.IOTransport{Reader: os.Stdin, Writer: os.Stdout, MaxLineLength: maxFrame})
	if err == context.Canceled {
		return context.Cause(ctx)
	}
	return err
}
