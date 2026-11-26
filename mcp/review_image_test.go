package main

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"image"
	"image/jpeg"
	"testing"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

func TestReviewFrameRejectsMissingOrCorruptPayload(t *testing.T) {
	for _, raw := range []string{`{}`, `{"jpeg":"broken"}`, `{"jpeg":"YXR0YWNobWVudA=="}`, `{"jpeg":"/9j/2Q=="}`} {
		if _, err := reviewFrameResult(json.RawMessage(raw)); err == nil {
			t.Errorf("accepted an invalid review result: %s", raw)
		}
	}
}

func TestReviewFrameValidatesImageAndMetadata(t *testing.T) {
	var encoded bytes.Buffer
	if err := jpeg.Encode(&encoded, image.NewGray(image.Rect(0, 0, 8, 4)), nil); err != nil {
		t.Fatal(err)
	}
	makeFrame := func(jpeg []byte, width int) json.RawMessage {
		t.Helper()
		raw, err := json.Marshal(map[string]any{"jpeg": jpeg, "width": width, "height": 4})
		if err != nil {
			t.Fatal(err)
		}
		return raw
	}
	valid := encoded.Bytes()
	result, err := reviewFrameResult(makeFrame(valid, 8))
	if err != nil {
		t.Fatal(err)
	}
	if string(result.StructuredContent.(json.RawMessage)) != `{"height":4,"width":8}` || len(result.Content) != 2 {
		t.Fatalf("unexpected review result: %+v", result)
	}
	if block, ok := result.Content[1].(*mcp.ImageContent); !ok || block.MIMEType != "image/jpeg" || !bytes.Equal(block.Data, valid) {
		t.Fatal("missing original JPEG content")
	}
	if _, err := reviewFrameResult(makeFrame(valid, 7)); err == nil {
		t.Fatal("accepted image dimensions that disagree with the metadata")
	}
	// Retain the JPEG headers and end marker while removing the scan data.
	startOfScan := bytes.Index(valid, []byte{0xff, 0xda})
	if startOfScan < 0 {
		t.Fatal("test JPEG has no scan marker")
	}
	endOfScanHeader := startOfScan + 2 + int(binary.BigEndian.Uint16(valid[startOfScan+2:]))
	truncated := append(bytes.Clone(valid[:endOfScanHeader]), 0xff, 0xd9)
	if _, err := jpeg.DecodeConfig(bytes.NewReader(truncated)); err != nil {
		t.Fatalf("test JPEG should have readable headers: %v", err)
	}
	if _, err := reviewFrameResult(makeFrame(truncated, 8)); err == nil {
		t.Fatal("accepted JPEG with missing scan data")
	}
}

func TestReviewFrameBatchLabelsEachImage(t *testing.T) {
	encode := func(width int) []byte {
		t.Helper()
		var encoded bytes.Buffer
		if err := jpeg.Encode(&encoded, image.NewGray(image.Rect(0, 0, width, 4)), nil); err != nil {
			t.Fatal(err)
		}
		return encoded.Bytes()
	}
	// The second picture is wider than the default review edge, as a request with max_edge allows.
	first, second := encode(8), encode(1280)
	raw, err := json.Marshal(map[string]any{"view": "source", "frames": []map[string]any{
		{"jpeg": first, "width": 8, "height": 4, "space": "source", "time": "0"},
		{"jpeg": second, "width": 1280, "height": 4, "space": "source", "time": "1141"},
	}})
	if err != nil {
		t.Fatal(err)
	}
	result, err := reviewFrameResult(raw)
	if err != nil {
		t.Fatal(err)
	}
	want := `{"frames":[{"height":4,"space":"source","time":"0","width":8},{"height":4,"space":"source","time":"1141","width":1280}],"view":"source"}`
	if got := string(result.StructuredContent.(json.RawMessage)); got != want {
		t.Fatalf("unexpected batch metadata: %s", got)
	}
	if len(result.Content) != 5 {
		t.Fatalf("expected metadata and a label and an image per frame, got %d blocks", len(result.Content))
	}
	for i, picture := range [][]byte{first, second} {
		label, isText := result.Content[1+2*i].(*mcp.TextContent)
		block, isImage := result.Content[2+2*i].(*mcp.ImageContent)
		if !isText || !isImage || !bytes.Equal(block.Data, picture) {
			t.Fatalf("frame %d is not a label followed by its image", i+1)
		}
		if want := []string{"frame 1: source 0", "frame 2: source 1141"}[i]; label.Text != want {
			t.Fatalf("label %q, want %q", label.Text, want)
		}
	}
	// A saved-file job names the clock and gives the requested time exactly.
	saved, err := json.Marshal(map[string]any{"frames": []map[string]any{
		{"jpeg": first, "width": 8, "height": 4, "clock": "source", "requested_time": map[string]int{"numerator": 1001, "denominator": 30000}},
		{"jpeg": first, "width": 8, "height": 4, "clock": "sequence", "requested_time": map[string]int{"numerator": 3, "denominator": 1}},
	}})
	if err != nil {
		t.Fatal(err)
	}
	fromFile, err := reviewFrameResult(saved)
	if err != nil {
		t.Fatal(err)
	}
	for i, want := range []string{"frame 1: source 1001/30000", "frame 2: sequence 3"} {
		if label := fromFile.Content[1+2*i].(*mcp.TextContent).Text; label != want {
			t.Fatalf("saved-file label %q, want %q", label, want)
		}
	}
	for _, invalid := range []string{`{"frames":[]}`, `{"frames":[{"jpeg":"broken","width":8,"height":4}]}`} {
		if _, err := reviewFrameResult(json.RawMessage(invalid)); err == nil {
			t.Errorf("accepted an invalid batch: %s", invalid)
		}
	}
	oversized, _ := json.Marshal(map[string]any{"jpeg": encode(4000), "width": 4000, "height": 4})
	if _, err := reviewFrameResult(oversized); err == nil {
		t.Fatal("accepted a picture wider than the largest review edge")
	}
}
