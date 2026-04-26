# Claude Code PreCompact Hook Implementation Plan

## Overview

This document describes the implementation plan for the Claude Code PreCompact hook (`pre-compact-cc.ps1`). The hook saves all available runtime context before compaction into append-only transcript files and a session restoration file.

## Goals

- Preserve full transcript history across multiple compactions without data loss.
- Maintain a human-readable compaction summary in `.transcripts/transcripts.md`.
- Maintain structured event logs in `.transcripts/transcripts.jsonl`.
- Provide a session restoration file at `.claude/session_context.md`.
- Make log capture configurable to avoid overwhelming the Markdown summary.
- Never delete existing content in any transcript file.

---

## File Paths

| File | Purpose | Location |
|------|---------|----------|
| `pre-compact-cc.ps1` | Hook script (PowerShell) | Project root or `.claude/hooks/` |
| `.transcripts/transcripts.md` | Human-readable compaction history | Project root |
| `.transcripts/transcripts.jsonl` | Structured event logs (append-only JSONL) | Project root |
| `.claude/session_context.md` | Session restoration summary for Claude | `.claude/` directory |

### Directory Structure

```
project-root/
  .claude/
    session_context.md   # Cumulative session context (appended on each PreCompact)
    hooks/
      pre-compact-cc.ps1  # Optional: hook script in standard location
  .transcripts/
    transcripts.md      # Human-readable compaction log (append-only)
    transcripts.jsonl   # Structured event log (append-only JSONL)
  pre-compact-cc.ps1    # Or hook script at project root
```

---

## Transcript Storage Rules

### Append-Only Policy

- **`.transcripts/transcripts.md`**: Append new summary sections only. Never overwrite or delete existing content.
- **`.transcripts/transcripts.jsonl`**: Append new JSON lines only. Never truncate or delete existing lines.
- **`.claude/session_context.md`**: Append the latest distilled context section only.

### Creating the `.transcripts/` Directory

The hook must create `.transcripts/` if it does not already exist:

```powershell
$transcriptDir = Join-Path $cwd ".transcripts"
if (-not (Test-Path $transcriptDir)) {
    New-Item -ItemType Directory -Path $transcriptDir -Force | Out-Null
}
```

---

## Hook Input Schema

Claude Code sends a JSON payload to the hook via stdin. Expected fields:

```json
{
  "session_id": "string (UUID)",
  "transcript_path": "string (absolute path to .jsonl transcript file)",
  "cwd": "string (absolute path to project root)",
  "hook_event_name": "PreCompact",
  "trigger": "auto" | "manual",
  "custom_instructions": "string (optional)"
}
```

### Field Descriptions

| Field | Type | Description |
|-------|------|-------------|
| `session_id` | string | Unique session identifier |
| `transcript_path` | string | Absolute path to the transcript `.jsonl` file |
| `cwd` | string | Absolute path to the project root |
| `hook_event_name` | string | Always `"PreCompact"` for this hook |
| `trigger` | string | `"auto"` when Claude triggers compaction; `"manual"` when user runs `/compact` |
| `custom_instructions` | string | Optional instructions from the user |

---

## Transcript File Format

### `transcript_path` (Input)

The `transcript_path` points to a `.jsonl` file where each line is a JSON object representing a message, tool call, or result. This file may already contain prior compaction summaries because `/compact` can be run multiple times in a session.

**Important**: Never delete or truncate this file. The hook reads from it but does not modify it.

### Example Transcript Line

```json
{"type":"user","content":"Deploy the new service to staging"}
{"type":"assistant","content":"I'll deploy the service to staging now.","tool_calls":[{"name":"bash","input":{"command":"kubectl apply -f service.yaml"}}]}
{"type":"tool","name":"bash","input":{"command":"kubectl apply -f service.yaml"},"output":"deployment.apps/service created"}
```

### Prior Compaction Summary Lines

After a compaction, the transcript may contain lines like:

```json
{"type":"compact_summary","trigger":"auto","tokens_before":142000,"tokens_after":45000,"summary":"Decisions: Switched from ECS to EKS..."}
```

The hook should recognize and parse these lines to avoid re-extracting content that has already been summarized.

---

## Processing Steps

### Step 1: Parse Hook Input

Read stdin and deserialize the JSON payload:

```powershell
$input = $input | ConvertFrom-Json
$cwd = $input.cwd
$transcriptPath = $input.transcript_path
$trigger = $input.trigger
$sessionId = $input.session_id
```

### Step 2: Ensure `.transcripts/` Directory

```powershell
$transcriptDir = Join-Path $cwd ".transcripts"
if (-not (Test-Path $transcriptDir)) {
    New-Item -ItemType Directory -Path $transcriptDir -Force | Out-Null
}
```

### Step 3: Read and Parse Transcript

Read the full transcript file (append-only, do not modify):

```powershell
$transcriptLines = Get-Content $transcriptPath -Encoding UTF8
$events = foreach ($line in $transcriptLines) {
    try { $line | ConvertFrom-Json } catch { $null }
}
$events = $events | Where-Object { $null -ne $_ }
```

### Step 4: Extract High-Signal Content

Parse the transcript and extract:

- **Decisions**: Statements where Claude made a choice ("decided to use X instead of Y")
- **Actions**: Files modified, commands run, infrastructure changes
- **Tool Results**: Meaningful command output (not routine `ls` output)
- **Open Issues**: Unresolved questions, pending tasks, TODOs
- **Key Discoveries**: Bug root causes, configuration findings
- **User Answers**: Important context provided by the user

```powershell
function Get-Decisions($events) {
    # Look for assistant messages containing decision language
    $decisions = @()
    foreach ($e in $events) {
        if ($e.type -eq "assistant" -and $e.content -match "decided|chose|switched|using|going with") {
            $decisions += $e.content
        }
    }
    return $decisions
}

function Get-ModifiedFiles($events) {
    # Look for tool calls that modify files (Write/Edit/Apply)
    $files = @()
    foreach ($e in $events) {
        if ($e.type -eq "tool" -and $e.name -match "Write|Edit|Apply|Bash" -and $e.input.command) {
            $files += $e.input.command
        }
    }
    return $files
}

function Get-OpenIssues($events) {
    # Look for unresolved questions or explicit TODOs
    $issues = @()
    foreach ($e in $events) {
        if ($e.type -eq "user" -and $e.content -match "still need|pending|not sure|TODO") {
            $issues += $e.content
        }
    }
    return $issues
}
```

### Step 5: Build Compaction Summary

Construct a structured summary for this compaction:

```powershell
$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm"
$summary = @{
    compaction_number = 1
    trigger = $trigger
    timestamp = $timestamp
    session_id = $sessionId
    decisions = $decisions
    modified_files = $modifiedFiles
    open_issues = $openIssues
    key_discoveries = $discoveries
} | ConvertTo-Json -Compress
```

### Step 6: Append to `.transcripts/transcripts.md`

Append a new Markdown section to the human-readable log:

```powershell
$mdPath = Join-Path $transcriptDir "transcripts.md"
$mdSection = @"

## Compaction #$($summary.compaction_number) ($($trigger), $($timestamp))

- **Trigger**: $($trigger)
- **Session ID**: $($sessionId)
- **Decisions**:
$($decisions | ForEach-Object { "  - $_" })
- **Modified Files**:
$($modifiedFiles | ForEach-Object { "  - $_" })
- **Open Issues**:
$($openIssues | ForEach-Object { "  - $_" })
- **Key Discoveries**:
$($discoveries | ForEach-Object { "  - $_" })
"@

Add-Content -Path $mdPath -Value $mdSection -Encoding UTF8
```

### Step 7: Append to `.transcripts/transcripts.jsonl`

Append structured event lines to the JSONL log:

```powershell
$jsonlPath = Join-Path $transcriptDir "transcripts.jsonl"
$jsonlEvent = @{
    event_type = "compact_summary"
    timestamp = $timestamp
    session_id = $sessionId
    trigger = $trigger
    decisions = $decisions
    modified_files = $modifiedFiles
    open_issues = $openIssues
    key_discoveries = $discoveries
} | ConvertTo-Json -Compress

Add-Content -Path $jsonlPath -Value $jsonlEvent -Encoding UTF8
```

### Step 8: Append to `.claude/session_context.md`

Append the latest distilled context to the session restoration file:

```powershell
$sessionCtxPath = Join-Path $cwd ".claude/session_context.md"
$sessionCtxSection = @"

## Compaction #$($summary.compaction_number) ($($trigger), $($timestamp))

### Decisions
$($decisions | ForEach-Object { "- $_" })

### Modified Files
$($modifiedFiles | ForEach-Object { "- $_" })

### Open Issues
$($openIssues | ForEach-Object { "- $_" })

### Key Discoveries
$($discoveries | ForEach-Object { "- $_" })
"@

Add-Content -Path $sessionCtxPath -Value $sessionCtxSection -Encoding UTF8
```

### Step 9: Return Hook Output

Write JSON to stdout for Claude Code to consume:

```powershell
$latestSection = Get-Content $sessionCtxPath -Tail 20 -Encoding UTF8 -Raw
$output = @{
    systemMessage = "Context from previous compactions has been saved. Review `.claude/session_context.md` for history. Latest summary:`n$latestSection"
    additionalContext = @{
        type = "file"
        path = ".claude/session_context.md"
        content = $latestSection
    }
} | ConvertTo-Json -Compress

Write-Output $output
```

---

## Output Contract

The hook must return valid JSON to stdout with the following fields:

```json
{
  "systemMessage": "string (human-readable message to inject into Claude's context)",
  "additionalContext": {
    "type": "file",
    "path": "string (path to session context file)",
    "content": "string (latest session context content)"
  }
}
```

### Optional Fields

| Field | Type | Description |
|-------|------|-------------|
| `continue` | boolean | Whether to continue with compaction after the hook |
| `blocking` | boolean | Whether to block compaction until the hook completes |

---

## Configuration Options

The hook behavior can be controlled via a configuration file at `.claude/hooks/pre-compact-cc.config.json`:

```json
{
  "capture_tool_calls": true,
  "write_md_summary": true,
  "write_jsonl_events": true,
  "max_md_sections": 10,
  "include_routine_commands": false
}
```

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `capture_tool_calls` | boolean | `true` | Include tool call details in the summary |
| `write_md_summary` | boolean | `true` | Append human-readable summary to `.transcripts/transcripts.md` |
| `write_jsonl_events` | boolean | `true` | Append structured events to `.transcripts/transcripts.jsonl` |
| `max_md_sections` | integer | `10` | Optional cap on recent sections in `.transcripts/transcripts.md` |
| `include_routine_commands` | boolean | `false` | If false, skip routine commands like `ls`, `pwd`, `cat` |

---

## Error Handling

### Missing Transcript File

If `transcript_path` does not exist or cannot be read:

```powershell
if (-not (Test-Path $transcriptPath)) {
    $errorEvent = @{
        event_type = "error"
        timestamp = (Get-Date -Format "o")
        error = "transcript_file_missing"
        message = "Transcript file not found at $($transcriptPath)"
    } | ConvertTo-Json -Compress

    $jsonlPath = Join-Path $transcriptDir "transcripts.jsonl"
    Add-Content -Path $jsonlPath -Value $errorEvent -Encoding UTF8

    Write-Output '{"systemMessage": "Transcript file not found. Context saving skipped.", "additionalContext": null}'
    exit 0
}
```

### Invalid JSON in Transcript

If a line in the transcript file is not valid JSON, skip it and continue:

```powershell
foreach ($line in $transcriptLines) {
    try {
        $event = $line | ConvertFrom-Json
        $events += $event
    } catch {
        # Skip malformed lines without failing
    }
}
```

### Directory Creation Failure

If `.transcripts/` cannot be created:

```powershell
try {
    New-Item -ItemType Directory -Path $transcriptDir -Force | Out-Null
} catch {
    Write-Output '{"systemMessage": "Failed to create transcript directory. Check permissions.", "additionalContext": null}'
    exit 1
}
```

### Output JSON Failure

If the hook cannot construct valid output JSON:

```powershell
try {
    $output = @{ systemMessage = $msg; additionalContext = $ctx } | ConvertTo-Json -Compress
    Write-Output $output
} catch {
    # Fallback: plain text output
    Write-Output '{"systemMessage": "Context saved but output generation failed.", "additionalContext": null}'
}
```

---

## Multiple Compactions

The hook must handle multiple compactions in a single session. Each invocation should:

1. Read the full transcript (which includes prior compaction summaries)
2. Extract only the content since the last compaction
3. Append a new section to all three files

The compaction number can be derived by counting existing `## Compaction #` headings in `.transcripts/transcripts.md`:

```powershell
$existingHeadings = Select-String -Path $mdPath -Pattern "^## Compaction #" | Measure-Object
$compactionNumber = $existingHeadings.Count + 1
```

---

## Testing Plan

### Scope

- Validate native PreCompact hook execution in Claude Code.
- Ensure append-only `.transcripts` behavior across multiple invocations.
- Confirm `.claude/session_context.md` is updated reliably.
- Exercise error paths for missing or malformed transcript files.

### Test Cases

#### TC-1: Hook Input Parsing

| ID | Description | Expected Result |
|----|-------------|----------------|
| TC-1.1 | Valid JSON payload from stdin | Hook parses all fields correctly |
| TC-1.2 | Missing `transcript_path` field | Hook writes error event, returns safe JSON |
| TC-1.3 | Invalid JSON in stdin | Hook writes error event, does not crash |
| TC-1.4 | Missing `cwd` field | Hook writes error event, returns safe JSON |

#### TC-2: Transcript Processing

| ID | Description | Expected Result |
|----|-------------|----------------|
| TC-2.1 | Normal transcript file with prior summary history | Hook extracts decisions, actions, issues correctly |
| TC-2.2 | Empty transcript file | Hook writes a minimal summary section |
| TC-2.3 | Large transcript file (1000+ entries) | Hook completes within 5 seconds, extracts high-signal content |
| TC-2.4 | Transcript with special characters (Unicode, quotes) | Hook handles encoding correctly |
| TC-2.5 | Transcript with malformed JSON lines | Hook skips invalid lines, processes valid ones |

#### TC-3: File Output Behavior

| ID | Description | Expected Result |
|----|-------------|----------------|
| TC-3.1 | `.transcripts/transcripts.md` after first compaction | File created with section heading and content |
| TC-3.2 | `.transcripts/transcripts.md` after second compaction | New section appended, old content preserved |
| TC-3.3 | `.transcripts/transcripts.jsonl` appends structured JSON | New JSON line appended, no lines removed |
| TC-3.4 | `.claude/session_context.md` appends latest context | New section appended, old content preserved |
| TC-3.5 | Existing `.transcripts` content remains after error | No existing lines are deleted or overwritten |

#### TC-4: Output Contract

| ID | Description | Expected Result |
|----|-------------|----------------|
| TC-4.1 | Hook returns valid JSON | Output is valid JSON with `systemMessage` field |
| TC-4.2 | `systemMessage` contains expected text | Message references session context file |
| TC-4.3 | `additionalContext` includes latest context snippet | File path and content are included |

#### TC-5: Error Handling

| ID | Description | Expected Result |
|----|-------------|----------------|
| TC-5.1 | Missing `.transcripts/` directory | Directory is created automatically |
| TC-5.2 | Permission denied on transcript directory | Hook writes error event, returns safe JSON |
| TC-5.3 | Invalid event parsing | Diagnostic JSON line written, no crash |
| TC-5.4 | Output JSON construction failure | Fallback JSON returned, no crash |

#### TC-6: Multiple Compactions

| ID | Description | Expected Result |
|----|-------------|----------------|
| TC-6.1 | Three compactions in one session | Three sections appended to each file |
| TC-6.2 | Compaction numbering increments correctly | Section headings show #1, #2, #3 |
| TC-6.3 | Prior compaction content preserved | Old sections readable after new compaction |

### Success Criteria

- All compactions append new sections without deleting old content.
- The hook can run multiple times in a single session.
- `.claude/session_context.md` remains cumulative and readable.
- A broken transcript payload does not corrupt prior history.
- Hook execution completes within 5 seconds for typical transcripts.
- Invalid input does not crash the hook; errors are logged and a safe JSON response is returned.

### Test Data

#### Sample Transcript (Small)

```jsonl
{"type":"user","content":"Create a new Kubernetes deployment"}
{"type":"assistant","content":"I'll create a Kubernetes deployment for you.","tool_calls":[{"name":"Write","input":{"path":"k8s/deployment.yaml","content":"apiVersion: apps/v1\nkind: Deployment\n..."}}]}
{"type":"tool","name":"Write","input":{"path":"k8s/deployment.yaml"},"output":"File written successfully"}
{"type":"assistant","content":"Deployment file created. Applying to cluster now.","tool_calls":[{"name":"Bash","input":{"command":"kubectl apply -f k8s/deployment.yaml"}}]}
{"type":"tool","name":"Bash","input":{"command":"kubectl apply -f k8s/deployment.yaml"},"output":"deployment.apps/myapp created"}
{"type":"user","content":"Great, now scale it to 3 replicas"}
{"type":"assistant","content":"Scaling to 3 replicas.","tool_calls":[{"name":"Bash","input":{"command":"kubectl scale deployment myapp --replicas=3"}}]}
{"type":"tool","name":"Bash","input":{"command":"kubectl scale deployment myapp --replicas=3"},"output":"deployment.apps/myapp scaled"}
```

#### Sample Transcript (Large)

Generate 1000+ lines using a script that alternates user/assistant/tool messages with realistic content patterns.

#### Edge Case Transcripts

- Empty file (0 lines)
- File with only whitespace
- File with 50% malformed JSON lines
- File with extremely long single message (>100KB)

### Test Automation

Use Pester for PowerShell unit and integration tests:

```powershell
Describe "pre-compact-cc.ps1" {
    It "Parses valid hook input" {
        $inputJson = '{"session_id":"test","transcript_path":".transcripts/test.jsonl","cwd":".","hook_event_name":"PreCompact","trigger":"manual"}'
        $result = $inputJson | pwsh -File pre-compact-cc.ps1
        $result | Should -Not -BeNullOrEmpty
    }
}
```

---

## Installation

### Hook Registration

Add the hook to your Claude Code settings (e.g., `~/.claude/settings.json` or project-level `.claude/settings.json`):

```json
{
  "hooks": {
    "PreCompact": {
      "command": "pwsh",
      "args": ["-File", "pre-compact-cc.ps1"],
      "cwd": "${workspaceFolder}"
    }
  }
}
```

### Alternative: Shell Configuration

```json
{
  "hooks": {
    "PreCompact": {
      "shell": "powershell",
      "command": "pre-compact-cc.ps1",
      "cwd": "${workspaceFolder}"
    }
  }
}
```

### Verification

After registration, trigger a manual compaction with `/compact` and verify:

1. `.transcripts/transcripts.md` exists and contains a new section.
2. `.transcripts/transcripts.jsonl` exists and contains new JSON lines.
3. `.claude/session_context.md` exists and contains the latest context.
4. No existing content was deleted or overwritten.

---

## Debugging

### Enable Debug Logging

Add a `--debug` flag or set `DEBUG=1` in the environment:

```powershell
if ($env:DEBUG -eq "1") {
    Write-Host "[DEBUG] Transcript path: $transcriptPath"
    Write-Host "[DEBUG] Events count: $($events.Count)"
}
```

### Check Hook Output

Run the hook manually with a test payload:

```powershell
$testInput = @{
    session_id = "test-session"
    transcript_path = "C:\path\to\project\.transcripts\transcript.jsonl"
    cwd = "C:\path\to\project"
    hook_event_name = "PreCompact"
    trigger = "manual"
} | ConvertTo-Json -Compress

$testInput | pwsh -File pre-compact-cc.ps1
```

### Common Issues

| Issue | Cause | Fix |
|-------|-------|-----|
| Hook not firing | Hook not registered in settings | Verify settings.json configuration |
| Empty output files | Transcript path incorrect | Check that `transcript_path` from stdin is valid |
| JSON parse error | Malformed JSON in transcript | Hook should skip invalid lines; check logs |
| Permission denied | Cannot write to `.transcripts/` | Run editor with appropriate permissions |
