package main

import (
	"context"
	"os"
	"path/filepath"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// Reference material ships with the helper, so clients can read it when the editor is closed.
func registerDocumentation(server *mcp.Server, executable string) {
	dir := filepath.Join(filepath.Dir(executable), "..", "Resources", "Documentation", "docs")
	if filepath.Base(filepath.Dir(executable)) != "Helpers" {
		dir = "docs"
		if _, err := os.Stat(dir); os.IsNotExist(err) {
			dir = filepath.Join("..", "docs")
		}
	}
	for _, doc := range []struct{ name, slug, file string }{
		{"MPCut agent guide", "agent-guide", "MCP-AGENT-GUIDE.md"},
		{"Headless editing", "headless", "HEADLESS.md"},
		{"MPCut tool reference", "tool-reference", "MCP-REFERENCE.md"},
	} {
		uri := "mpcut://docs/" + doc.slug
		path := filepath.Join(dir, doc.file)
		server.AddResource(&mcp.Resource{Name: doc.name, URI: uri, MIMEType: "text/markdown"},
			func(context.Context, *mcp.ReadResourceRequest) (*mcp.ReadResourceResult, error) {
				data, err := os.ReadFile(path)
				if os.IsNotExist(err) {
					return nil, mcp.ResourceNotFoundError(uri)
				}
				if err != nil {
					return nil, err
				}
				return &mcp.ReadResourceResult{Contents: []*mcp.ResourceContents{
					{URI: uri, MIMEType: "text/markdown", Text: string(data)},
				}}, nil
			})
	}
}
