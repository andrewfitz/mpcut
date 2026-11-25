package integration

import (
	"bytes"
	"encoding/json"
	"errors"
	"reflect"
	"strings"
	"testing"
)

// plainProject returns the plain JSON document of a project file's bytes, with its refs table
// written out again. Bytes that are already a plain document come back as they are.
func plainProject(data []byte) ([]byte, error) {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	var root map[string]any
	if err := decoder.Decode(&root); err != nil {
		return nil, err
	}
	if refs, keyed := root["refs"].(map[string]any); keyed {
		delete(root, "refs")
		document, err := expandRefs(root, refs, 0)
		if err != nil {
			return nil, err
		}
		// `base` marks the edit a history was saved for. Like `refs`, it belongs to the saved layout.
		if expanded, ok := document.(map[string]any); ok {
			if history, ok := expanded["history"].(map[string]any); ok {
				delete(history, "base")
			}
		}
		return json.Marshal(document)
	}
	return data, nil
}

// expandRefs resolves a saved project's `refs` table, which lists what the project repeats
// once under keys taken from the content: "~KEY" is a text entry, {"~": "KEY"} an object or
// list entry, and "~~x" the text "~x". The snapshot and embedded assets carry literal JSON.
func expandRefs(node any, refs map[string]any, depth int) (any, error) {
	damaged := errors.New("the project's refs table is damaged")
	if depth > 64 {
		return nil, damaged
	}
	switch typed := node.(type) {
	case string:
		if !strings.HasPrefix(typed, "~") {
			return typed, nil
		}
		if strings.HasPrefix(typed, "~~") {
			return typed[1:], nil
		}
		literal, ok := refs[typed[1:]].(string)
		if !ok {
			return nil, damaged
		}
		return literal, nil
	case []any:
		result := make([]any, len(typed))
		for index, value := range typed {
			expanded, err := expandRefs(value, refs, depth+1)
			if err != nil {
				return nil, err
			}
			result[index] = expanded
		}
		return result, nil
	case map[string]any:
		if key, ok := typed["~"].(string); ok && len(typed) == 1 {
			entry, found := refs[key]
			if _, text := entry.(string); !found || text {
				return nil, damaged
			}
			return expandRefs(entry, refs, depth+1)
		}
		result := make(map[string]any, len(typed))
		for key, value := range typed {
			if key == "media_snapshot" || (depth == 0 && key == "embedded_assets") {
				result[key] = value
				continue
			}
			expanded, err := expandRefs(value, refs, depth+1)
			if err != nil {
				return nil, err
			}
			result[key] = expanded
		}
		return result, nil
	}
	return node, nil
}

// One project as its plain document.
const plainProjectSample = `{"clips":[{"file":"media/a long recording name.mov","from":"0","id":"0F8FAD5B-D9CB-469F-A165-708677289500","to":"2"},{"file":"media/a long recording name.mov","from":"1","id":"0F8FAD5B-D9CB-469F-A165-708677289501","to":"3"}],"format":"mpcut","history":{"undo":[{"action":"Trim Clip","clips":[{"file":"media/a long recording name.mov","from":"0","id":"0F8FAD5B-D9CB-469F-A165-708677289500","to":"1"},{"file":"media/a long recording name.mov","from":"1","id":"0F8FAD5B-D9CB-469F-A165-708677289501","to":"3"}]},{"action":"Trim Clip","clips":[{"file":"media/a long recording name.mov","from":"0","id":"0F8FAD5B-D9CB-469F-A165-708677289500","to":"5"},{"file":"media/a long recording name.mov","from":"1","id":"0F8FAD5B-D9CB-469F-A165-708677289501","to":"3"}]}]},"kind":"sequence","note":"~/Movies","schema_version":9,"transcripts":{"attachments":[{"bindings":[{"audio_stream_index":0,"file":"media/a long recording name.mov","offset":{"denominator":1,"numerator":0},"sequence_clock_origin":{"denominator":3000,"numerator":-1},"track_id":"t-1"},{"audio_stream_index":0,"file":"media/a long recording name.mov","offset":{"denominator":1,"numerator":0},"sequence_clock_origin":{"denominator":3000,"numerator":-1},"track_id":"t-2"}],"id":"A","import_origin":{"denominator":2,"numerator":1}}],"revision":2}}`

// The same project as MPCut saves it now, with what it repeats in a `refs` table keyed by content.
const keyedProjectSample = `{"clips":[{"file":"~p","from":"0","id":"0F8FAD5B-D9CB-469F-A165-708677289500","to":"2"},{"file":"~p","from":"1","id":"0F8FAD5B-D9CB-469F-A165-708677289501","to":"3"}],"format":"mpcut","history":{"undo":[{"action":"Trim Clip","clips":[{"file":"~p","from":"0","id":"0F8FAD5B-D9CB-469F-A165-708677289500","to":"1"},{"~":"c1"}]},{"action":"Trim Clip","clips":[{"file":"~p","from":"0","id":"0F8FAD5B-D9CB-469F-A165-708677289500","to":"5"},{"~":"c1"}]}]},"kind":"sequence","note":"~~/Movies","refs":{"c1":{"file":"~p","from":"1","id":"0F8FAD5B-D9CB-469F-A165-708677289501","to":"3"},"p":"media/a long recording name.mov","unused":"left by a merge","~":""},"schema_version":9,"transcripts":{"attachments":[{"bindings":[{"audio_stream_index":0,"file":"~p","offset":{"denominator":1,"numerator":0},"sequence_clock_origin":{"denominator":3000,"numerator":-1},"track_id":"t-1"},{"audio_stream_index":0,"file":"~p","offset":{"denominator":1,"numerator":0},"sequence_clock_origin":{"denominator":3000,"numerator":-1},"track_id":"t-2"}],"id":"A","import_origin":{"denominator":2,"numerator":1}}],"revision":2}}`

func TestPlainProjectExpandsTheRefsTable(t *testing.T) {
	var want any
	if err := json.Unmarshal([]byte(plainProjectSample), &want); err != nil {
		t.Fatal(err)
	}
	for name, input := range map[string][]byte{
		"plain": []byte(plainProjectSample), "keyed": []byte(keyedProjectSample),
	} {
		plain, err := plainProject(input)
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		var got any
		if err := json.Unmarshal(plain, &got); err != nil || !reflect.DeepEqual(got, want) {
			t.Fatalf("%s: read %s (decode error %v)", name, plain, err)
		}
	}
	if _, err := plainProject([]byte(`{"clips":[{"file":"~gone"}],"refs":{"~":""},"schema_version":9}`)); err == nil {
		t.Fatal("a reference with no entry was read")
	}
	input := []byte(`{"embedded_assets":{"transcripts":{"someAsset":{"provenance":{"metadata":{"~":"literal"}},"words":[{"t":"~hello"}]}}},"refs":{},"schema_version":9}`)
	literal, err := plainProject(input)
	if err != nil || !bytes.Contains(literal, []byte(`{"~":"literal"}`)) || !bytes.Contains(literal, []byte(`"~hello"`)) {
		t.Fatalf("embedded data changed during reference expansion: %s (%v)", literal, err)
	}
}
