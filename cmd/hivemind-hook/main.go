package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

const fallbackJSON = "{}"

type outputMode int

const (
	outputPassthrough outputMode = iota
	outputJSONFallback
)

type hookInvocation struct {
	scriptPath string
	scriptArgs []string
	outputMode outputMode
}

func main() {
	os.Exit(run(os.Args[1:]))
}

func run(args []string) int {
	exePath, err := os.Executable()
	if err != nil {
		writeFallbackJSON("", fmt.Sprintf("resolve executable: %v", err))
		return 0
	}

	exePath, err = filepath.EvalSymlinks(exePath)
	if err != nil {
		writeFallbackJSON(hubDirFromExecutable(exePath), fmt.Sprintf("resolve executable symlink: %v", err))
		return 0
	}

	hubDir := hubDirFromExecutable(exePath)
	invocation, err := hookScriptForAction(hubDir, args)
	if err != nil {
		writeFallbackJSON(hubDir, err.Error())
		return 0
	}

	bashPath, err := resolveBash()
	if err != nil {
		writeFallbackJSON(hubDir, err.Error())
		return 0
	}

	stdout, err := runHookScript(bashPath, invocation.scriptPath, invocation.scriptArgs)
	if err != nil {
		message := fmt.Sprintf("run %s via %s: %v", invocation.scriptPath, bashPath, err)
		if invocation.outputMode == outputJSONFallback {
			writeFallbackJSON(hubDir, message)
		} else {
			appendHubLog(hubDir, message)
		}
		return 0
	}

	if invocation.outputMode == outputJSONFallback {
		writeJSONOrFallback(hubDir, stdout, "")
		return 0
	}

	_, _ = os.Stdout.Write(stdout)
	return 0
}

func hubDirFromExecutable(exePath string) string {
	return filepath.Clean(filepath.Join(filepath.Dir(exePath), ".."))
}

func hookScriptForAction(hubDir string, args []string) (hookInvocation, error) {
	if len(args) == 0 {
		return hookInvocation{}, fmt.Errorf("missing action")
	}

	if legacyCodexAction(args[0]) {
		return codexInvocation(hubDir, args[0], args[1:])
	}

	if len(args) < 2 {
		return hookInvocation{}, fmt.Errorf("missing action for adapter %q", args[0])
	}

	return adapterInvocation(hubDir, args[0], args[1], args[2:])
}

func legacyCodexAction(action string) bool {
	switch action {
	case "session-start", "stop":
		return true
	default:
		return false
	}
}

func codexInvocation(hubDir, action string, scriptArgs []string) (hookInvocation, error) {
	repoRoot := filepath.Join(hubDir, "hive-mind")
	switch action {
	case "session-start":
		return hookInvocation{
			scriptPath: filepath.Join(repoRoot, "core", "hub", "codex-hook-session-start.sh"),
			scriptArgs: scriptArgs,
			outputMode: outputJSONFallback,
		}, nil
	case "stop":
		return hookInvocation{
			scriptPath: filepath.Join(repoRoot, "core", "hub", "codex-hook-stop.sh"),
			scriptArgs: scriptArgs,
			outputMode: outputJSONFallback,
		}, nil
	default:
		return hookInvocation{}, fmt.Errorf("unknown codex action %q", action)
	}
}

func adapterInvocation(hubDir, adapter, action string, scriptArgs []string) (hookInvocation, error) {
	switch strings.ToLower(adapter) {
	case "codex":
		return codexInvocation(hubDir, action, scriptArgs)
	case "claude", "claude-code":
		return claudeInvocation(hubDir, action, scriptArgs)
	default:
		return hookInvocation{}, fmt.Errorf("unknown adapter %q", adapter)
	}
}

func claudeInvocation(hubDir, action string, scriptArgs []string) (hookInvocation, error) {
	repoRoot := filepath.Join(hubDir, "hive-mind")

	switch action {
	case "session-start":
		return hookInvocation{
			scriptPath: filepath.Join(repoRoot, "core", "hub", "claude-hook-session-start.sh"),
			scriptArgs: scriptArgs,
			outputMode: outputPassthrough,
		}, nil
	case "stop":
		return hookInvocation{
			scriptPath: filepath.Join(repoRoot, "core", "hub", "claude-hook-stop.sh"),
			scriptArgs: scriptArgs,
			outputMode: outputPassthrough,
		}, nil
	case "post-edit", "post-tool-use":
		return hookInvocation{
			scriptPath: filepath.Join(repoRoot, "core", "hub", "claude-hook-post-tool-use.sh"),
			scriptArgs: scriptArgs,
			outputMode: outputPassthrough,
		}, nil
	default:
		return hookInvocation{}, fmt.Errorf("unknown claude action %q", action)
	}
}

func runHookScript(bashPath, scriptPath string, scriptArgs []string) ([]byte, error) {
	args := append([]string{scriptPath}, scriptArgs...)
	cmd := exec.Command(bashPath, args...)
	cmd.Env = os.Environ()
	cmd.Stdin = os.Stdin
	cmd.Stderr = os.Stderr

	var stdout bytes.Buffer
	cmd.Stdout = &stdout

	err := cmd.Run()
	return stdout.Bytes(), err
}

func writeFallbackJSON(hubDir, reason string) {
	writeJSONOrFallback(hubDir, nil, reason)
}

func writeJSONOrFallback(hubDir string, payload []byte, reason string) {
	payload = bytes.TrimSpace(payload)
	if len(payload) > 0 && json.Valid(payload) {
		_, _ = os.Stdout.Write(payload)
		return
	}

	if reason != "" {
		appendHubLog(hubDir, reason)
	} else if len(payload) > 0 {
		appendHubLog(hubDir, fmt.Sprintf("hook script emitted invalid JSON: %q", string(payload)))
	}

	_, _ = os.Stdout.WriteString(fallbackJSON)
}

func appendHubLog(hubDir, message string) {
	if hubDir == "" || message == "" {
		return
	}

	logPath := filepath.Join(hubDir, ".sync-error.log")
	f, err := os.OpenFile(logPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return
	}
	defer f.Close()

	timestamp := time.Now().Format(time.RFC3339)
	_, _ = fmt.Fprintf(f, "[%s] hivemind-hook: %s\n", timestamp, message)
}

func resolveBash() (string, error) {
	if runtime.GOOS != "windows" {
		return exec.LookPath("bash")
	}

	for _, candidate := range windowsBashCandidates() {
		if isUsableWindowsBash(candidate) {
			return candidate, nil
		}
	}

	return "", fmt.Errorf("could not resolve Git Bash; install Git for Windows or set HIVEMIND_GIT_BASH")
}

func windowsBashCandidates() []string {
	var candidates []string

	appendCandidate := func(path string) {
		if path != "" {
			candidates = append(candidates, filepath.Clean(path))
		}
	}

	appendInstallRoot := func(root string) {
		if root == "" {
			return
		}
		appendCandidate(filepath.Join(root, "bin", "bash.exe"))
		appendCandidate(filepath.Join(root, "usr", "bin", "bash.exe"))
	}

	appendCandidate(os.Getenv("HIVEMIND_GIT_BASH"))
	appendCandidate(os.Getenv("BASH"))

	if gitExe, err := exec.LookPath("git"); err == nil {
		gitExe = filepath.Clean(gitExe)
		appendCandidate(filepath.Join(filepath.Dir(gitExe), "bash.exe"))
		appendInstallRoot(filepath.Join(filepath.Dir(gitExe), ".."))
		appendInstallRoot(filepath.Join(filepath.Dir(gitExe), "..", ".."))
		appendInstallRoot(filepath.Join(filepath.Dir(gitExe), "..", "..", ".."))
	}

	for _, root := range []string{
		filepath.Join(os.Getenv("ProgramFiles"), "Git"),
		filepath.Join(os.Getenv("ProgramW6432"), "Git"),
		filepath.Join(os.Getenv("ProgramFiles(x86)"), "Git"),
		filepath.Join(os.Getenv("LocalAppData"), "Programs", "Git"),
	} {
		appendInstallRoot(root)
	}

	if bashExe, err := exec.LookPath("bash.exe"); err == nil {
		appendCandidate(bashExe)
	}
	if bashExe, err := exec.LookPath("bash"); err == nil {
		appendCandidate(bashExe)
	}

	seen := make(map[string]struct{}, len(candidates))
	unique := make([]string, 0, len(candidates))
	for _, candidate := range candidates {
		key := strings.ToLower(candidate)
		if _, ok := seen[key]; ok {
			continue
		}
		seen[key] = struct{}{}
		unique = append(unique, candidate)
	}

	return unique
}

func isUsableWindowsBash(path string) bool {
	if path == "" {
		return false
	}

	clean := filepath.Clean(path)
	lower := strings.ToLower(clean)
	if strings.HasSuffix(lower, filepath.Clean(`\windows\system32\bash.exe`)) {
		return false
	}
	if strings.Contains(lower, `\system32\bash.exe`) {
		return false
	}

	info, err := os.Stat(clean)
	if err != nil || info.IsDir() {
		return false
	}

	return strings.EqualFold(filepath.Ext(clean), ".exe")
}
