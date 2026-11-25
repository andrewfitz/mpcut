package integration

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"strconv"
	"testing"
	"time"
)

// Each test has a unique socket directory and uses the same name for its Backstage session.
func launchBackstage(t *testing.T, ctx context.Context, session, bundle string, environment []string, args ...string) (int, func()) {
	t.Helper()
	command := func(ctx context.Context, args ...string) *exec.Cmd {
		cmd := exec.CommandContext(ctx, "backstage", args...)
		cmd.Env = append(os.Environ(), "BACKSTAGE_SESSION="+session)
		return cmd
	}
	launch := []string{"launch", bundle, "--env", "MPCUT_MUTED=1"}
	for _, variable := range environment {
		launch = append(launch, "--env", variable)
	}
	output, err := command(ctx, append(append(launch, "--"), args...)...).CombinedOutput()
	var result struct {
		PID int `json:"pid"`
	}
	if err != nil || json.Unmarshal(output, &result) != nil || result.PID <= 0 {
		t.Fatalf("Backstage launch failed: %v %s", err, output)
	}
	stopped := false
	quit := func() {
		t.Helper()
		if stopped {
			return
		}
		stopped = true
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		if output, err := command(ctx, "quit", "--pid", strconv.Itoa(result.PID), "--force").CombinedOutput(); err != nil {
			t.Errorf("Backstage quit failed: %v %s", err, output)
		}
	}
	t.Cleanup(quit)
	return result.PID, quit
}
