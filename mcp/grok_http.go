package main

import (
	"crypto/subtle"
	"errors"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

func serveGrok(helper, socket, keyFile string) error {
	// Use the open app's catalog and guides, including on an older installation.
	helper, err := filepath.EvalSymlinks(helper)
	if err != nil {
		return err
	}
	if filepath.Base(filepath.Dir(helper)) != "Helpers" {
		return errors.New("choose the helper in MPCut.app/Contents/Helpers")
	}
	key, err := readGrokBearerKey(keyFile)
	if err != nil {
		return err
	}
	server, err := editorServer(helper, socket)
	if err != nil {
		return err
	}
	transport := mcp.NewStreamableHTTPHandler(func(*http.Request) *mcp.Server { return server }, &mcp.StreamableHTTPOptions{
		Stateless: true, JSONResponse: true, MaxRequestBodyBytes: maxFrame,
		CrossOriginProtection: http.NewCrossOriginProtection(),
	})
	mux := http.NewServeMux()
	mux.HandleFunc("/mpcut/mcp", func(w http.ResponseWriter, r *http.Request) {
		scheme, token, _ := strings.Cut(r.Header.Get("Authorization"), " ")
		if !strings.EqualFold(scheme, "Bearer") || subtle.ConstantTimeCompare([]byte(token), []byte(key)) != 1 {
			w.Header().Set("WWW-Authenticate", `Bearer realm="MPCut"`)
			http.Error(w, "MPCut connector credential required", http.StatusUnauthorized)
			return
		}
		transport.ServeHTTP(w, r)
	})
	endpoint := &http.Server{Addr: "127.0.0.1:8472", Handler: mux, ReadHeaderTimeout: 10 * time.Second, ReadTimeout: 30 * time.Second, IdleTimeout: time.Minute}
	return endpoint.ListenAndServe()
}

func readGrokBearerKey(path string) (string, error) {
	const maxKeyFileSize = 4096
	// Opening without following links or waiting on a FIFO keeps validation
	// tied to the same file descriptor used to read the credential.
	file, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	if err != nil {
		return "", err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return "", err
	}
	if !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 {
		return "", errors.New("Grok bearer key must be a private regular file (chmod 600)")
	}
	raw, err := io.ReadAll(io.LimitReader(file, maxKeyFileSize+1))
	if err != nil {
		return "", err
	}
	key := strings.TrimSpace(string(raw))
	if len(raw) > maxKeyFileSize || len(key) < 32 || strings.ContainsAny(key, " \t\r\n") {
		return "", errors.New("expected a single bearer key of at least 32 characters in a file at most 4096 bytes")
	}
	return key, nil
}
