package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"image/jpeg"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

const (
	// A review JPEG is at most 1 MiB, and the request chooses its longest edge up to this many pixels.
	maxReviewBytes = 1 << 20
	maxReviewEdge  = 3840
	// One reply holds at most this many pictures.
	maxReviewFrames = 12
)

// A review image travels once over MCP, in an image content block. Structured
// results contain only the indexed frame metadata and project identity.
// A request for several times returns them under "frames"; each image block
// follows a one-line text label naming its frame.
func reviewFrameResult(raw json.RawMessage) (*mcp.CallToolResult, error) {
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(raw, &fields); err != nil {
		return nil, err
	}
	batch, isBatch := fields["frames"]
	if !isBatch {
		image, err := reviewImage(fields)
		if err != nil {
			return nil, err
		}
		metadata, err := json.Marshal(fields)
		if err != nil {
			return nil, err
		}
		result := toolResult(metadata, false)
		result.Content = append(result.Content, &mcp.ImageContent{MIMEType: "image/jpeg", Data: image})
		return result, nil
	}
	var frames []map[string]json.RawMessage
	if err := json.Unmarshal(batch, &frames); err != nil || len(frames) < 1 || len(frames) > maxReviewFrames {
		return nil, errors.New("invalid MPCut review frame list")
	}
	var pictures []mcp.Content
	for i, frame := range frames {
		image, err := reviewImage(frame)
		if err != nil {
			return nil, err
		}
		var space, time string
		_ = json.Unmarshal(frame["space"], &space)
		_ = json.Unmarshal(frame["time"], &time)
		pictures = append(pictures, &mcp.TextContent{Text: fmt.Sprintf("frame %d: %s %s", i+1, space, time)},
			&mcp.ImageContent{MIMEType: "image/jpeg", Data: image})
	}
	stripped, err := json.Marshal(frames)
	if err != nil {
		return nil, err
	}
	fields["frames"] = stripped
	metadata, err := json.Marshal(fields)
	if err != nil {
		return nil, err
	}
	result := toolResult(metadata, false)
	result.Content = append(result.Content, pictures...)
	return result, nil
}

// reviewImage validates one frame's JPEG against its metadata and removes it from the fields.
func reviewImage(fields map[string]json.RawMessage) ([]byte, error) {
	var encoded string
	if err := json.Unmarshal(fields["jpeg"], &encoded); err != nil || len(encoded) > base64.StdEncoding.EncodedLen(maxReviewBytes) {
		return nil, errors.New("invalid MPCut review JPEG")
	}
	image, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil || len(image) < 4 || len(image) > maxReviewBytes ||
		image[len(image)-2] != 0xff || image[len(image)-1] != 0xd9 {
		return nil, errors.New("invalid MPCut review JPEG")
	}
	config, err := jpeg.DecodeConfig(bytes.NewReader(image))
	if err != nil {
		return nil, err
	}
	if config.Width < 1 || config.Height < 1 || config.Width > maxReviewEdge || config.Height > maxReviewEdge {
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
	return image, nil
}
