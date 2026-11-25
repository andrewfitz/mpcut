package integration

import (
	"bytes"
	"image/jpeg"
	"strings"
	"testing"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

func checkReviewFrame(t *testing.T, reply *mcp.CallToolResult, want object) {
	t.Helper()
	if reply.IsError {
		t.Fatalf("review frame: %v", reply.StructuredContent)
	}
	metadata, ok := reply.StructuredContent.(map[string]any)
	if _, hasJPEG := metadata["jpeg"]; !ok || hasJPEG {
		t.Fatal("review frame returned invalid metadata")
	}
	for key, value := range want {
		if metadata[key] != value {
			t.Fatalf("review frame %s = %v, want %v", key, metadata[key], value)
		}
	}
	images := 0
	for _, block := range reply.Content {
		switch c := block.(type) {
		case *mcp.ImageContent:
			images++
			if c.MIMEType != "image/jpeg" {
				t.Fatalf("unexpected frame MIME type %q", c.MIMEType)
			}
			if len(c.Data) > 1<<20 {
				t.Fatalf("review image exceeds 1 MiB: %d bytes", len(c.Data))
			}
			image, err := jpeg.Decode(bytes.NewReader(c.Data))
			if err != nil {
				t.Fatalf("review frame JPEG decode: %v", err)
			}
			bounds := image.Bounds()
			if bounds.Dx() > 640 || bounds.Dy() > 640 {
				t.Fatalf("review image exceeds 640 pixels on an axis: %v", bounds)
			}
			if metadata["width"] != float64(bounds.Dx()) || metadata["height"] != float64(bounds.Dy()) {
				t.Fatalf("frame metadata (%v x %v) and image dimensions (%d x %d) disagree", metadata["width"], metadata["height"], bounds.Dx(), bounds.Dy())
			}
		case *mcp.TextContent:
			if strings.Contains(c.Text, `"jpeg":`) {
				t.Fatal("frame base64 was duplicated in text content")
			}
		}
	}
	if images != 1 {
		t.Fatalf("expected one inline JPEG, received %d", images)
	}
}
