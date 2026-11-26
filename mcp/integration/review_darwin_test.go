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

// A request for several times returns its metadata under frames, then a label and an image per frame.
func checkReviewBatch(t *testing.T, reply *mcp.CallToolResult, space string, times []string) {
	t.Helper()
	if reply.IsError {
		t.Fatalf("review frames: %v", reply.StructuredContent)
	}
	metadata, _ := reply.StructuredContent.(map[string]any)
	frames, _ := metadata["frames"].([]any)
	if len(frames) != len(times) || len(reply.Content) != 1+2*len(times) {
		t.Fatalf("expected %d frames and their images, got %v with %d content blocks", len(times), metadata, len(reply.Content))
	}
	for i, time := range times {
		frame := frames[i].(map[string]any)
		label, isText := reply.Content[1+2*i].(*mcp.TextContent)
		picture, isImage := reply.Content[2+2*i].(*mcp.ImageContent)
		if !isText || !isImage || !strings.HasSuffix(label.Text, space+" "+time) {
			t.Fatalf("frame %d is not a label and its image: %v", i+1, reply.Content[1+2*i])
		}
		if _, hasJPEG := frame["jpeg"]; hasJPEG || frame["space"] != space || frame["time"] != time || frame["source_time"] != time {
			t.Fatalf("unexpected frame metadata: %v", frame)
		}
		image, err := jpeg.Decode(bytes.NewReader(picture.Data))
		if err != nil {
			t.Fatalf("review frame JPEG decode: %v", err)
		}
		if bounds := image.Bounds(); frame["width"] != float64(bounds.Dx()) || frame["height"] != float64(bounds.Dy()) {
			t.Fatalf("frame metadata and image dimensions disagree: %v %v", frame, bounds)
		}
	}
}
