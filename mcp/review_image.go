package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"image/jpeg"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// A review image travels once over MCP, in an image content block. Structured
// results contain only the indexed frame metadata and project identity.
func reviewFrameResult(raw json.RawMessage) (*mcp.CallToolResult, error) {
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(raw, &fields); err != nil {
		return nil, err
	}
	var image []byte
	if err := json.Unmarshal(fields["jpeg"], &image); err != nil || len(image) < 4 || len(image) > 1<<20 ||
		image[len(image)-2] != 0xff || image[len(image)-1] != 0xd9 {
		return nil, errors.New("invalid MPCut review JPEG")
	}
	if _, err := jpeg.DecodeConfig(bytes.NewReader(image)); err != nil {
		return nil, err
	}
	delete(fields, "jpeg")
	metadata, err := json.Marshal(fields)
	if err != nil {
		return nil, err
	}
	result := toolResult(metadata, false)
	result.Content = append(result.Content, &mcp.ImageContent{MIMEType: "image/jpeg", Data: image})
	return result, nil
}
