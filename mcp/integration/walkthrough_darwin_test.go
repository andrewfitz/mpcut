package integration

import (
	"context"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func checkPackagedWalkthrough(t *testing.T, ctx context.Context, contents, project, media string, requireSocketOwner func(*testing.T)) {
	t.Helper()
	python, err := exec.LookPath("python3")
	if err != nil {
		t.Skip("Python 3 unavailable for the bundled walkthrough")
	}
	script := filepath.Join(contents, "Resources/Documentation/docs/mcp_walkthrough.py")
	helper := filepath.Join(contents, "Helpers/mpcut-mcp")
	for _, step := range []struct {
		args []string
		want []string
	}{
		{[]string{"--discovery"}, []string{"mpcut://docs/agent-guide", "mpcut://docs/tool-reference"}},
		{[]string{"--project", project}, []string{"Timeline ", project, "History ", "Presentation ", "Analysis ", "Export queue "}},
		{[]string{"--file", media}, []string{`"state": "succeeded"`, `"codec": "prores"`, filepath.Base(media)}},
	} {
		requireSocketOwner(t)
		cmd := exec.CommandContext(ctx, python, append([]string{script, "--helper", helper}, step.args...)...)
		output, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("bundled walkthrough %s: %v\n%s", step.args[0], err, output)
		}
		for _, want := range step.want {
			if !strings.Contains(string(output), want) {
				t.Fatalf("bundled walkthrough %s did not report %q:\n%s", step.args[0], want, output)
			}
		}
	}
	t.Log("verified packaged Python walkthrough discovery, live editor reads and real file inspection")
}
