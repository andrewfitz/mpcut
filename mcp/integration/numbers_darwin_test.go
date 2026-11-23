package integration

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"github.com/modelcontextprotocol/go-sdk/jsonrpc"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

func checkExactNumbers(t *testing.T, project any, call func(string, object) (*mcp.CallToolResult, error)) {
	t.Helper()
	fraction := json.Number("1.0000000000000001")
	checkInvalid := func(name, field string, args object) {
		t.Helper()
		result, err := call(name, args)
		if err != nil {
			var wire *jsonrpc.Error
			if !errors.As(err, &wire) || wire.Code != jsonrpc.CodeInvalidParams || !strings.Contains(wire.Message, field) {
				t.Fatalf("%s returned an unrelated error for fractional %s: %v", name, field, err)
			}
			return
		}
		if !result.IsError {
			t.Fatalf("%s accepted fractional %s: %v", name, field, result.StructuredContent)
		}
		if body, ok := result.StructuredContent.(object); ok && body["code"] == "invalid_arguments" {
			if message, ok := body["message"].(string); ok && strings.Contains(message, field) {
				return
			}
		}
		for _, content := range result.Content {
			if text, ok := content.(*mcp.TextContent); ok && strings.HasPrefix(text.Text, `validating "arguments":`) && strings.Contains(text.Text, field) {
				return
			}
		}
		t.Fatalf("%s did not identify fractional %s: %v %v", name, field, result.StructuredContent, result.Content)
	}
	checkInvalid("project_editor_state_read", "offset", object{"project_handle": project, "offset": fraction})
	checkInvalid("project_file_inspect", "project_data", object{"operation_id": fileOperationID(), "project_data": object{
		"format": "mpcut", "schema_version": fraction, "kind": "sequence", "clips": []object{},
	}})

	result, err := call("project_editor_state_read", object{"project_handle": project, "offset": json.Number("9007199254740993.0")})
	if err != nil || result.IsError || len(result.Content) != 1 {
		t.Fatalf("exact integer page request failed: %v %v", result, err)
	}
	text, ok := result.Content[0].(*mcp.TextContent)
	if !ok {
		t.Fatalf("expected JSON text for the exact integer receipt: %v", result.Content)
	}
	// The SDK decodes dynamically typed structured numbers into float64.
	// Read the same native JSON receipt from the text block into an exact type.
	var receipt struct {
		Offset json.Number
		Clips  []json.RawMessage
	}
	if err := json.Unmarshal([]byte(text.Text), &receipt); err != nil || receipt.Offset != "9007199254740993" || len(receipt.Clips) != 0 {
		t.Fatalf("page receipt rounded the integer or returned the wrong page: %s (%v)", text.Text, err)
	}
	t.Log("verified exact integer receipt beyond binary64 precision and rejected fractional page and inline schema versions")
}
