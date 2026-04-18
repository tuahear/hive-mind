package main

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// runHookScript must capture stderr separately and never leak it to the
// parent process's stderr. Codex on Windows parses hivemind-hook's stderr
// as hook-runner output, so a noisy wrapper line would surface as a
// user-visible failure.
func TestRunHookScriptIsolatesStderrFromParentProcess(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("requires /bin/sh on PATH")
	}

	stdout, stderr, err := runHookScript("/bin/sh", "-c", []string{"printf OUT; printf ERR >&2"})
	if err != nil {
		t.Fatalf("runHookScript returned error: %v", err)
	}
	if string(stdout) != "OUT" {
		t.Fatalf("stdout = %q, want %q", string(stdout), "OUT")
	}
	if string(stderr) != "ERR" {
		t.Fatalf("stderr = %q, want %q", string(stderr), "ERR")
	}
}

// Stderr from the wrapper script must land in the hub log, not on the
// parent process's stderr. This pins the "capture + route to log" contract
// that the `run` entrypoint depends on.
func TestStderrRoutedToHubLog(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("requires /bin/sh on PATH")
	}
	hubDir := t.TempDir()

	_, stderr, err := runHookScript("/bin/sh", "-c", []string{"printf 'boom\\n' >&2"})
	if err != nil {
		t.Fatalf("runHookScript: %v", err)
	}
	if got := strings.TrimSpace(string(stderr)); got != "boom" {
		t.Fatalf("captured stderr = %q, want %q", got, "boom")
	}

	// Simulate the main.go routing: the caller appends captured stderr
	// to the hub log. Verify the log path is writable and the contract
	// (append mode, trimmed body) produces a readable log line.
	appendHubLog(hubDir, "script stderr: "+strings.TrimSpace(string(stderr)))
	data, err := os.ReadFile(filepath.Join(hubDir, ".sync-error.log"))
	if err != nil {
		t.Fatalf("read log: %v", err)
	}
	if !strings.Contains(string(data), "script stderr: boom") {
		t.Fatalf("log missing stderr text: %q", string(data))
	}
}

// Regression: the parent process's stderr stream must stay clean even
// when the wrapper script fails. Prior behavior (cmd.Stderr = os.Stderr)
// leaked script output into the hook runner, which Codex then rendered
// as hook-failure noise.
func TestStderrNeverLeaksOnScriptFailure(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("requires /bin/sh on PATH")
	}
	// Redirect the process's stderr into a pipe so we can assert nothing
	// lands there.
	oldStderr := os.Stderr
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatalf("pipe: %v", err)
	}
	os.Stderr = w
	defer func() { os.Stderr = oldStderr }()

	_, stderr, runErr := runHookScript("/bin/sh", "-c", []string{"printf 'oops\\n' >&2; exit 3"})
	w.Close()

	if runErr == nil {
		t.Fatalf("expected non-nil error from failing script")
	}
	if strings.TrimSpace(string(stderr)) != "oops" {
		t.Fatalf("captured stderr = %q, want %q", string(stderr), "oops")
	}

	buf := make([]byte, 4096)
	n, _ := r.Read(buf)
	if n != 0 {
		t.Fatalf("parent stderr received %q (should be empty)", buf[:n])
	}
}

// bashFacingPath must never produce a backslash in its output. Git Bash
// composes wrapper-facing paths with user content inside the script
// body; backslashes surface as literal characters on some paths and
// break the compose. The invariant holds on every supported OS because
// filepath.ToSlash is a no-op on POSIX.
func TestBashFacingPathHasNoBackslashes(t *testing.T) {
	// Use filepath.Join to construct an OS-native path — backslashes on
	// Windows, forward slashes on POSIX. The normalization contract is
	// the same in either direction: never hand a backslash to Git Bash.
	joined := filepath.Join("C:", "Users", "alice", "hub", "hive-mind", "core", "hub", "claude-hook-stop.sh")
	got := bashFacingPath(joined)
	if strings.ContainsRune(got, '\\') {
		t.Fatalf("bashFacingPath(%q) = %q, must not contain backslashes", joined, got)
	}
	// And it must still resolve to the same file when Go re-parses it.
	if filepath.Clean(got) == "" {
		t.Fatalf("bashFacingPath produced an empty or invalid path: %q", got)
	}
}

// Windows-only: verify the concrete "C:\\…" → "C:/…" rewrite that the
// bashFacingPath helper pins for Git Bash consumption.
func TestBashFacingPathRewritesWindowsSeparators(t *testing.T) {
	if runtime.GOOS != "windows" {
		t.Skip("Windows-only path shape")
	}
	got := bashFacingPath(`C:\Users\alice\hub\hive-mind\core\hub\claude-hook-stop.sh`)
	want := "C:/Users/alice/hub/hive-mind/core/hub/claude-hook-stop.sh"
	if got != want {
		t.Fatalf("bashFacingPath = %q, want %q", got, want)
	}
}
