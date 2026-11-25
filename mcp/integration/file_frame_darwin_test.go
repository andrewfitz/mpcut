package integration

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

func TestFileReviewFrames(t *testing.T) {
	if *bundlePath == "" {
		t.Skip("supply -bundle to exercise the files-only MPCut worker")
	}
	dir := t.TempDir()
	_, testFile, _, _ := runtime.Caller(0)
	data, err := os.ReadFile(filepath.Join(filepath.Dir(testFile), "../../Tests/MPCutAppTests/Fixtures/ProRes-2997.mov"))
	if err != nil {
		t.Fatal(err)
	}
	write := func(name string, data []byte) string {
		t.Helper()
		path := filepath.Join(dir, name)
		if err := os.WriteFile(path, data, 0600); err != nil {
			t.Fatal(err)
		}
		return path
	}
	media := write("media.mov", data)
	write("close.mov", data)
	sequence := write("sequence.cut", []byte(`{"format":"mpcut","schema_version":9,"kind":"sequence",
		"clips":[{"id":"clip","file":"media.mov","from":"0","to":"1001/2500"}]}`))
	largeID := write("large-id.cut", []byte(`{"format":"mpcut","schema_version":9,"kind":"sequence",
		"clips":[{"id":"clip`+strings.Repeat(`\u0001`, 512)+`","file":"media.mov","from":"0","to":"1001/2500"}]}`))
	multicam := write("multicam.cut", []byte(`{"format":"mpcut","schema_version":9,"kind":"multicam",
		"reference_angle_id":"wide","group_range":{"from":"0","to":"1001/2500"},
		"angles":[{"id":"wide","file":"media.mov"},{"id":"close","file":"close.mov"}],
		"audio":{"mode":"none"},"switches":[{"group_time":"0","angle_id":"wide"}],
		"assembly":[{"kind":"group","from":"1001/10000","to":"1001/5000","angle_id":"close"}]}`))

	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	helper := exec.Command(filepath.Join(*bundlePath, "Contents", "Helpers", "mpcut-mcp"), "--files-only")
	helper.Env = append(os.Environ(), "CFFIXED_USER_HOME="+dir, "MPCUT_MUTED=1",
		"MPCUT_FILE_RECEIPT_DIRECTORY="+filepath.Join(dir, "receipts"))
	helper.Stderr = os.Stderr
	client := mcp.NewClient(&mcp.Implementation{Name: "mpcut-file-review-integration", Version: "1"}, nil)
	session, err := client.Connect(ctx, &mcp.CommandTransport{Command: helper}, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	call := func(t *testing.T, tool string, args object) *mcp.CallToolResult {
		t.Helper()
		reply, err := session.CallTool(ctx, &mcp.CallToolParams{Name: tool, Arguments: args})
		if err != nil {
			t.Fatalf("%s transport: %v", tool, err)
		}
		return reply
	}

	rejected := call(t, "review_file_frame_read", object{
		"operation_id": fileOperationID(), "at": "0", "file": media, "project_path": sequence,
	})
	if !rejected.IsError {
		t.Fatal("accepted both a source file and a saved project")
	}

	for _, tc := range []struct {
		name string
		args object
		want object
	}{
		{"source", object{"file": media, "at": "0"}, object{"clock": "source"}},
		{"sequence", object{"project_path": sequence, "at": "0"}, object{"clock": "sequence", "source_id": "clip"}},
		{"sequence with oversized ID", object{"project_path": largeID, "at": "0"}, object{"clock": "sequence", "source_id": nil}},
		{"group", object{"project_path": multicam, "clock": "group", "at": "1001/10000"}, object{"clock": "group", "source_id": "wide"}},
		{"assembly", object{"project_path": multicam, "clock": "assembly", "at": "0"}, object{"clock": "assembly", "source_id": "close"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			tc.args["operation_id"] = fileOperationID()
			reply := call(t, "review_file_frame_read", tc.args)
			if reply.IsError {
				t.Fatalf("frame job submission: %+v", reply.StructuredContent)
			}
			jobID, ok := reply.StructuredContent.(object)["job_id"].(string)
			if !ok {
				t.Fatalf("missing job ID: %+v", reply.StructuredContent)
			}
			eventually(t, "review frame job", func() bool {
				status := call(t, "file_job_status_read", object{"job_id": jobID})
				body, ok := status.StructuredContent.(object)
				if !ok || status.IsError {
					t.Fatalf("invalid frame job status: %+v", status.StructuredContent)
				}
				switch body["state"] {
				case "running", "cancelling":
					return false
				case "succeeded":
					if body["result"] != nil || body["output_text"] != nil {
						t.Fatal("generic job status exposed inline review image data")
					}
					return true
				default:
					t.Fatalf("frame job failed: %+v", body)
					return false
				}
			})
			tc.want["job_id"] = jobID
			checkReviewFrame(t, call(t, "review_file_frame_result_read", object{"job_id": jobID}), tc.want)
			if page := call(t, "file_job_result_read", object{"job_id": jobID}); !page.IsError {
				t.Fatal("generic result paging exposed review image data")
			}
		})
	}
}
