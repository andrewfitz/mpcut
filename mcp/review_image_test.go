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
