package main

import (
	"bytes"
	"encoding/base64"
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
	const maxBytes = 1 << 20
	var encoded string
	if err := json.Unmarshal(fields["jpeg"], &encoded); err != nil || len(encoded) > base64.StdEncoding.EncodedLen(maxBytes) {
		return nil, errors.New("invalid MPCut review JPEG")
	}
	image, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil || len(image) < 4 || len(image) > maxBytes ||
		image[len(image)-2] != 0xff || image[len(image)-1] != 0xd9 {
		return nil, errors.New("invalid MPCut review JPEG")
	}
	config, err := jpeg.DecodeConfig(bytes.NewReader(image))
	if err != nil {
		return nil, err
	}
	// Both review renderers scale the image to at most 640 pixels on either axis.
	const maxDimension = 640
	if config.Width < 1 || config.Height < 1 || config.Width > maxDimension || config.Height > maxDimension {
		return nil, errors.New("review JPEG dimensions exceed the review limit")
	}
	var width, height int
	if json.Unmarshal(fields["width"], &width) != nil || json.Unmarshal(fields["height"], &height) != nil ||
		width != config.Width || height != config.Height {
		return nil, errors.New("review JPEG dimensions do not match frame metadata")
	}
	if _, err := jpeg.Decode(bytes.NewReader(image)); err != nil {
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
