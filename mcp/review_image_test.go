package main

import (
	"encoding/json"
	"testing"
)

func TestReviewFrameRejectsMissingOrCorruptPayload(t *testing.T) {
	for _, raw := range []string{`{}`, `{"jpeg":"broken"}`, `{"jpeg":"YXR0YWNobWVudA=="}`, `{"jpeg":"/9j/2Q=="}`} {
		if _, err := reviewFrameResult(json.RawMessage(raw)); err == nil {
			t.Errorf("accepted an invalid review result: %s", raw)
		}
	}
}
