# VS Code Copilot PreCompact Hook Implementation Plan

## Overview

This document describes the implementation plan for the VS Code Copilot PreCompact hook (`pre-compact-copilot.ps1`). The hook saves all available runtime context before compaction into append-only transcript files and a session restoration file.

## Goals

- Preserve full transcript history across multiple compactions without data loss.
- Maintain a human-readable compaction summary in `.transcripts/transcripts.md`.
- Maintain structured event logs in `.transcripts/transcripts.jsonl`.
- Provide a session restoration file at `.github/session_context.md`.
- Make log capture configurable to avoid overwhelming the Markdown summary.
- Never delete existing content in any transcript file.

---

## File Paths

| File | Purpose | Location |
|------|---------|----------|
| `pre-compact-copilot.ps1` | Hook script (PowerShell) | Project root |
| `.github/hooks/pre-compact-copilot.json` | Hook configuration | Project root |
| `.transcripts/transcripts.md` | Human-readable compaction history | Project root |
| `.transcripts/transcripts.jsonl` | Structured event logs (append-only JSONL) | Project root |
| `.github/session_context.md` | Session restoration summary for Copilot | `.github/` directory |

### Directory Structure

```
project-root/
  .github/
    hooks/
      pre-compact-copilot.json   # Hook configuration
    session_context.md           # Cumulative session context (appended on each PreCompact)
  .transcripts/
    transcripts.md               # Human-readable compaction log (append-only)
    transcripts.jsonl            # Structured event log (append-only JSONL)
  pre-compact-copilot.ps1        # Hook script at project root
```

---

## Transcript Storage Rules

### Append-Only Policy

- **`.transcripts/transcripts.md`**: Append new summary sections only. Never overwrite or delete existing content.
- **`.transcripts/transcripts.jsonl`**: Append new JSON lines only. Never truncate or delete existing lines.
- **`.github/session_context.md`**: Append the latest distilled context section only.

### Creating the `.transcripts/` Directory

The hook must create `.transcripts/` if it does not already exist:

```powershell
$transcriptDir = Join-Path $workspaceRoot ".transcripts"
if (-not (Test-Path $transcriptDir)) {
    New-Item -ItemType Directory -Path $transcriptDir -Force | Out-Null
}
```

---

## Hook Configuration

The Copilot hook is configured via a JSON file in `.github/hooks/`. Register the hook with the `PreCompact` event:

### `.github/hooks/pre-compact-copilot.json`

```json
{
  "hooks": [
    {
      "id": "pre-compact-copilot",
      "name": "PreCompact Context Saver",
      "trigger": "PreCompact",
      "command": "pwsh",
      "args": ["-File", "pre-compact-copilot.ps1"],
      "cwd": "${workspaceFolder}",
      "enabled": true,
      "timeout": 30000
    }
  ]
}
```

### Configuration Fields

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Unique hook identifier |
| `name` | string | Human-readable hook name |
| `trigger` | string | Event to trigger on; must be `"PreCompact"` |
| `command` | string | Shell or executable to run |
| `args` | array | Arguments passed to the command |
| `cwd` | string | Working directory; `${workspaceFolder}` resolves to project root |
| `enabled` | boolean | Whether the hook is active |
| `timeout` | integer | Maximum execution time in milliseconds |

---

## Hook Input Schema

VS Code Copilot sends a JSON payload to the hook via stdin or environment variables. Expected fields:

```json
{
  "workspaceRoot": "string (absolute path to project root)",
  "transcript": "string or array (raw transcript content)",
  "transcript_path": "string (path to transcript file, if available)",
  "logs": "string or array (debug log content, if available)",
  "trigger": "auto" | "manual",
  "contextSummary": {
    "tool_calls_count": "number (if pre-calculated)",
    "token_usage": "number (if pre-calculated)",
    "duration_ms": "number (if pre-calculated)"
  }
}
```

### Field Descriptions

| Field | Type | Description |
|-------|------|-------------|
| `workspaceRoot` | string | Absolute path to the project root |
| `transcript` | string/array | Raw transcript content (may be string or array) |
| `transcript_path` | string | Path to transcript file if Copilot exposes one |
| `logs` | string/array | Debug log content from Copilot |
| `trigger` | string | `"auto"` when Copilot triggers compaction; `"manual"` when user triggers |
| `contextSummary` | object | Pre-calculated summary metrics (tool calls, tokens, duration) |

### Input Fallback Logic

If `transcript` is not directly available, the hook should attempt to read from `transcript_path`. If neither is available, the hook should still write a diagnostic entry and return a safe response.

---

## Processing Steps

### Step 1: Parse Hook Input

```powershell
param(
    [Parameter(Mandatory=$false, ValueFromPipeline=$true)]
    [string]$InputData
)

# Try to read from stdin if no arguments passed
if ([string]::IsNullOrEmpty($InputData)) {
    $InputData = $input | Out-String
}

$payload = $InputData | ConvertFrom-Json
$workspaceRoot = $payload.workspaceRoot
$trigger = $payload.trigger
$contextSummary = $payload.contextSummary
```

### Step 2: Ensure `.transcripts/` Directory

```powershell
$transcriptDir = Join-Path $workspaceRoot ".transcripts"
if (-not (Test-Path $transcriptDir)) {
    New-Item -ItemType Directory -Path $transcriptDir -Force | Out-Null
}
```

### Step 3: Extract Transcript and Logs

```powershell
# Get transcript content
$transcriptContent = $null
if ($payload.transcript) {
    if ($payload.transcript -is "array") {
        $transcriptContent = $payload.transcript
    } else {
        $transcriptContent = $payload.transcript -split "`n"
    }
} elseif ($payload.transcript_path -and (Test-Path $payload.transcript_path)) {
    $transcriptContent = Get-Content $payload.transcript_path -Encoding UTF8
}

# Get debug logs
$logsContent = $null
if ($payload.logs) {
    if ($payload.logs -is "array") {
        $logsContent = $payload.logs
    } else {
        $logsContent = $payload.logs -split "`n"
    }
}
```

### Step 4: Parse Events

```powershell
$events = @()
if ($transcriptContent) {
    foreach ($line in $transcriptContent) {
        try {
            $event = $line | ConvertFrom-Json
            $events += $event
        } catch {
            # Skip malformed lines
        }
    }
}
```

### Step 5: Extract High-Signal Content

```powershell
function Get-Decisions($events) {
    $decisions = @()
    foreach ($e in $events) {
        if ($e.type -eq "assistant" -and $e.content -match "decided|chose|switched|using|going with") {
            $decisions += $e.content
        }
    }
    return $decisions
}

function Get-ToolCalls($events) {
    $toolCalls = @()
    foreach ($e in $events) {
        if ($e.type -eq "tool" -or $e.tool_call) {
            $toolCalls += $e
        }
    }
    return $toolCalls
}

function Get-OpenIssues($events) {
    $issues = @()
    foreach ($e in $events) {
        if ($e.type -eq "user" -and $e.content -match "still need|pending|not sure|TODO") {
            $issues += $e.content
        }
    }
    return $issues
}
```

### Step 6: Build Compaction Summary

```powershell
$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm"
$decisions = Get-Decisions $events
$toolCalls = Get-ToolCalls $events
$openIssues = Get-OpenIssues $events

$summary = @{
    compaction_number = 1
    trigger = $trigger
    timestamp = $timestamp
    tool_calls_count = $contextSummary.tool_calls_count
    token_usage = $contextSummary.token_usage
    duration_ms = $contextSummary.duration_ms
    decisions = $decisions
    tool_calls = $toolCalls
    open_issues = $openIssues
}
```

### Step 7: Append to `.transcripts/transcripts.md`

```powershell
$mdPath = Join-Path $transcriptDir "transcripts.md"
$mdSection = @"

## Compaction #$($summary.compaction_number) ($($trigger), $($timestamp))

- **Trigger**: $($trigger)
$(
    if ($summary.tool_calls_count) { "- **Tool Calls**: $($summary.tool_calls_count)" }
    if ($summary.token_usage) { "- **Token Usage**: $($summary.token_usage)" }
    if ($summary.duration_ms) { "- **Duration**: $($summary.duration_ms)ms" }
)
- **Decisions**:
$($decisions | ForEach-Object { "  - $_" })
- **Tool Calls**:
$($toolCalls | ForEach-Object { "  - $($_.name): $($_.input.command)" })
- **Open Issues**:
$($openIssues | ForEach-Object { "  - $_" })
"@

Add-Content -Path $mdPath -Value $mdSection -Encoding UTF8
```

### Step 8: Append to `.transcripts/transcripts.jsonl`

```powershell
$jsonlPath = Join-Path $transcriptDir "transcripts.jsonl"
$jsonlEvent = @{
    event_type = "compact_summary"
    source = "copilot"
    timestamp = $timestamp
    trigger = $trigger
    tool_calls_count = $summary.tool_calls_count
    token_usage = $summary.token_usage
    duration_ms = $summary.duration_ms
    decisions = $decisions
    tool_calls = $toolCalls
    open_issues = $openIssues
} | ConvertTo-Json -Compress

Add-Content -Path $jsonlPath -Value $jsonlEvent -Encoding UTF8
```

### Step 9: Append to `.github/session_context.md`

```powershell
$sessionCtxPath = Join-Path $workspaceRoot ".github/session_context.md"
$sessionCtxSection = @"

## Compaction #$($summary.compaction_number) ($($trigger), $($timestamp))

### Decisions
$($decisions | ForEach-Object { "- $_" })

### Tool Calls
$($toolCalls | ForEach-Object { "- $($_.name): $($_.input.command)" })

### Open Issues
$($openIssues | ForEach-Object { "- $_" })
"@

Add-Content -Path $sessionCtxPath -Value $sessionCtxSection -Encoding UTF8
```

### Step 10: Return Hook Output

```powershell
$latestSection = Get-Content $sessionCtxPath -Tail 20 -Encoding UTF8 -Raw
$output = @{
    systemMessage = "Context from previous compactions has been saved. Review `.github/session_context.md` for history. Latest summary:`n$latestSection"
    additionalContext = @{
        type = "file"
        path = ".github/session_context.md"
        content = $latestSection
    }
} | ConvertTo-Json -Compress

Write-Output $output
```

---

## Output Contract

The hook should return valid JSON to stdout with the following fields:

```json
{
  "systemMessage": "string (human-readable message to inject into Copilot's context)",
  "additionalContext": {
    "type": "file",
    "path": "string (path to session context file)",
    "content": "string (latest session context content)"
  }
}
```

### Notes on Copilot Hook Output

- If Copilot's hook API does not support direct context injection via `systemMessage`, the hook should still write the summary files and return a minimal acknowledgement.
- The primary value is in the append-only transcript files that Copilot can read on next session start.

---

## Configuration Options

The hook behavior can be controlled via a configuration file at `.github/hooks/pre-compact-copilot.config.json`:

```json
{
  "capture_live_logs": true,
  "capture_debug_export": true,
  "write_md_summary": true,
  "write_jsonl_events": true,
  "max_md_sections": 10,
  "include_tool_call_details": true
}
```

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `capture_live_logs` | boolean | `true` | Parse live logs and append to `.transcripts/transcripts.md` |
| `capture_debug_export` | boolean | `true` | Save OTLP JSON debug export to `.transcripts/transcripts.jsonl` |
| `write_md_summary` | boolean | `true` | Append human-readable summary to `.transcripts/transcripts.md` |
| `write_jsonl_events` | boolean | `true` | Append structured events to `.transcripts/transcripts.jsonl` |
| `max_md_sections` | integer | `10` | Optional cap on recent sections in `.transcripts/transcripts.md` |
| `include_tool_call_details` | boolean | `true` | Include tool call details in the summary |

---

## Error Handling

### Missing Workspace Root

```powershell
if ([string]::IsNullOrEmpty($workspaceRoot) -or -not (Test-Path $workspaceRoot)) {
    $errorEvent = @{
        event_type = "error"
        timestamp = (Get-Date -Format "o")
        error = "workspace_root_missing"
        message = "Workspace root not provided or not found"
    } | ConvertTo-Json -Compress

    $jsonlPath = Join-Path $transcriptDir "transcripts.jsonl"
    Add-Content -Path $jsonlPath -Value $errorEvent -Encoding UTF8

    Write-Output '{"systemMessage": "Workspace root not found. Context saving skipped.", "additionalContext": null}'
    exit 0
}
```

### Malformed Payload

```powershell
try {
    $payload = $InputData | ConvertFrom-Json
} catch {
    $errorEvent = @{
        event_type = "error"
        timestamp = (Get-Date -Format "o")
        error = "payload_parse_failed"
        message = "Failed to parse hook input JSON"
    } | ConvertTo-Json -Compress

    $jsonlPath = Join-Path $transcriptDir "transcripts.jsonl"
    Add-Content -Path $jsonlPath -Value $errorEvent -Encoding UTF8

    Write-Output '{"systemMessage": "Failed to parse hook input. Context saving skipped.", "additionalContext": null}'
    exit 0
}
```

### Directory Creation Failure

```powershell
try {
    New-Item -ItemType Directory -Path $transcriptDir -Force | Out-Null
} catch {
    Write-Output '{"systemMessage": "Failed to create transcript directory. Check permissions.", "additionalContext": null}'
    exit 1
}
```

### Log Parsing Failures

If `capture_live_logs` is enabled but log parsing fails, skip the log write but still complete the summary:

```powershell
try {
    if ($captureLiveLogs -and $logsContent) {
        $parsedLogs = Parse-Logs $logsContent
        # Append parsed logs to transcripts.md
    }
} catch {
    # Log parsing failed; skip log write but continue
}
```

---

## Multiple Compactions

The hook must handle multiple compactions in a single session. Each invocation should:

1. Read the full transcript (which includes prior compaction summaries if available)
2. Extract only the content since the last compaction
3. Append a new section to all three files

The compaction number can be derived by counting existing `## Compaction #` headings in `.transcripts/transcripts.md`:

```powershell
if (Test-Path $mdPath) {
    $existingHeadings = Select-String -Path $mdPath -Pattern "^## Compaction #" | Measure-Object
    $compactionNumber = $existingHeadings.Count + 1
} else {
    $compactionNumber = 1
}
```

---

## Testing Plan

### Scope

- Validate Copilot PreCompact hook execution in VS Code.
- Ensure append-only `.transcripts` behavior across multiple invocations.
- Confirm `.github/session_context.md` is updated reliably.
- Verify log capture configuration toggles correctly.

### Test Cases

#### TC-1: Hook Input Parsing

| ID | Description | Expected Result |
|----|-------------|----------------|
| TC-1.1 | Valid payload with transcript and logs | Hook parses all fields correctly |
| TC-1.2 | Payload missing transcript data | Hook writes error event, returns safe JSON |
| TC-1.3 | Payload without precomputed summary | Hook derives summary from transcript content |
| TC-1.4 | Invalid JSON or schema changes | Hook writes error event, does not crash |
| TC-1.5 | Empty payload | Hook writes minimal diagnostic entry |

#### TC-2: Transcript and Log Processing

| ID | Description | Expected Result |
|----|-------------|----------------|
| TC-2.1 | Raw transcript only | Hook extracts decisions, tool calls, issues |
| TC-2.2 | Raw transcript plus debug export | Hook captures both sources |
| TC-2.3 | Large transcript and log payloads | Hook completes within 5 seconds |
| TC-2.4 | Live logs with verbose output (enabled) | Verbose content appended to `.transcripts/transcripts.md` |
| TC-2.5 | Live logs with verbose output (disabled) | No verbose content appended |

#### TC-3: File Output Behavior

| ID | Description | Expected Result |
|----|-------------|----------------|
| TC-3.1 | `.transcripts/transcripts.md` after first compaction | File created with section heading and content |
| TC-3.2 | `.transcripts/transcripts.md` after second compaction | New section appended, old content preserved |
| TC-3.3 | `.transcripts/transcripts.jsonl` appends structured JSON | New JSON line appended, no lines removed |
| TC-3.4 | `.github/session_context.md` appends distilled context | New section appended, old content preserved |
| TC-3.5 | Existing `.transcripts` content remains after error | No existing lines are deleted or overwritten |

#### TC-4: Configuration Toggles

| ID | Description | Expected Result |
|----|-------------|----------------|
| TC-4.1 | `capture_live_logs` enabled | Live logs appended to `.transcripts/transcripts.md` |
| TC-4.2 | `capture_live_logs` disabled | Live logs skipped, summary still written |
| TC-4.3 | `capture_debug_export` enabled | OTLP export appended to `.transcripts/transcripts.jsonl` |
| TC-4.4 | `capture_debug_export` disabled | Debug export skipped, summary still written |
| TC-4.5 | `write_md_summary` disabled | No Markdown summary written, JSONL still appended |

#### TC-5: Output Contract

| ID | Description | Expected Result |
|----|-------------|----------------|
| TC-5.1 | Hook returns valid JSON | Output is valid JSON with `systemMessage` field |
| TC-5.2 | `systemMessage` contains expected text | Message references session context file |
| TC-5.3 | `additionalContext` includes latest context snippet | File path and content are included |
| TC-5.4 | Direct context injection unavailable | Files still written, safe JSON returned |

#### TC-6: Error Handling

| ID | Description | Expected Result |
|----|-------------|----------------|
| TC-6.1 | Workspace resolution failure | Graceful error, no crash |
| TC-6.2 | Missing `.transcripts/` directory | Directory created automatically |
| TC-6.3 | Log parsing failure | Diagnostic entry written, no crash |
| TC-6.4 | Permission denied on transcript directory | Hook writes error event, returns safe JSON |

### Success Criteria

- Copilot PreCompact hook writes append-only transcripts correctly.
- `.github/session_context.md` is reliable for recovery.
- The hook can operate with or without debug export.
- Config options prevent excessive Markdown log noise.
- Hook execution completes within 5 seconds for typical payloads.
- Invalid input does not crash the hook; errors are logged and a safe JSON response is returned.

### Test Data

#### Sample Copilot Payload (Small)

```json
{
  "workspaceRoot": "C:\\path\\to\\project",
  "transcript": [
    {"type": "user", "content": "Create a new Kubernetes deployment"},
    {"type": "assistant", "content": "I'll create a Kubernetes deployment for you.", "tool_calls": [{"name": "Write", "input": {"path": "k8s/deployment.yaml"}}]},
    {"type": "tool", "name": "Write", "input": {"path": "k8s/deployment.yaml"}, "output": "File written successfully"}
  ],
  "logs": "2026-04-25T10:00:00Z [INFO] Processing request...",
  "trigger": "auto",
  "contextSummary": {
    "tool_calls_count": 3,
    "token_usage": 4200,
    "duration_ms": 1250
  }
}
```

#### Sample Copilot Payload (Large)

Generate 1000+ transcript entries using a script that alternates user/assistant/tool messages with realistic content patterns.

#### Edge Case Payloads

- Empty transcript array
- Transcript with only whitespace strings
- Payload with 50% malformed JSON lines
- Payload with extremely long single message (>100KB)
- Missing `contextSummary` object

### Test Automation

Use Pester for PowerShell unit and integration tests:

```powershell
Describe "pre-compact-copilot.ps1" {
    It "Parses valid hook payload" {
        $payload = @{
            workspaceRoot = "C:\path\to\project"
            transcript = @(
                @{type="user";content="Create a deployment"}
            )
            trigger = "manual"
            contextSummary = @{tool_calls_count=1}
        } | ConvertTo-Json -Compress

        $result = $payload | pwsh -File pre-compact-copilot.ps1
        $result | Should -Not -BeNullOrEmpty
    }

    It "Handles missing transcript gracefully" {
        $payload = @{
            workspaceRoot = "C:\path\to\project"
            trigger = "auto"
        } | ConvertTo-Json -Compress

        $result = $payload | pwsh -File pre-compact-copilot.ps1
        $result | Should -Match "systemMessage"
    }
}
```

---

## Installation

### Hook Registration

Place the hook configuration file at `.github/hooks/pre-compact-copilot.json` and ensure the hook script `pre-compact-copilot.ps1` is at the project root.

VS Code Copilot will automatically discover and register hooks from the `.github/hooks/` directory.

### Manual Registration (if needed)

If the hook is not auto-discovered, add it to your VS Code settings (`settings.json`):

```json
{
  "github.copilot.hooks": [
    {
      "id": "pre-compact-copilot",
      "name": "PreCompact Context Saver",
      "trigger": "PreCompact",
      "command": "pwsh",
      "args": ["-File", "pre-compact-copilot.ps1"],
      "cwd": "${workspaceFolder}",
      "enabled": true,
      "timeout": 30000
    }
  ]
}
```

### Verification

After registration, trigger a manual compaction in Copilot and verify:

1. `.transcripts/transcripts.md` exists and contains a new section.
2. `.transcripts/transcripts.jsonl` exists and contains new JSON lines.
3. `.github/session_context.md` exists and contains the latest context.
4. No existing content was deleted or overwritten.

---

## Debugging

### Enable Debug Logging

Add a `--debug` flag or set `DEBUG=1` in the environment:

```powershell
if ($env:DEBUG -eq "1") {
    Write-Host "[DEBUG] Workspace root: $workspaceRoot"
    Write-Host "[DEBUG] Trigger: $trigger"
    Write-Host "[DEBUG] Events count: $($events.Count)"
}
```

### Check Hook Output

Run the hook manually with a test payload:

```powershell
$testPayload = @{
    workspaceRoot = "C:\path\to\project"
    transcript = @(
        @{type="user";content="Test"}
    )
    trigger = "manual"
    contextSummary = @{tool_calls_count=0}
} | ConvertTo-Json -Compress

$testPayload | pwsh -File pre-compact-copilot.ps1
```

### Common Issues

| Issue | Cause | Fix |
|-------|-------|-----|
| Hook not firing | Hook not registered in `.github/hooks/` | Verify configuration file exists and is valid JSON |
| Empty output files | `workspaceRoot` not provided | Check that payload includes `workspaceRoot` |
| JSON parse error | Malformed payload JSON | Hook should skip invalid lines; check logs |
| Permission denied | Cannot write to `.transcripts/` | Run VS Code with appropriate permissions |
| Config options ignored | Config file not found | Ensure `.github/hooks/pre-compact-copilot.config.json` exists |

---

## Appendix: Copilot-Specific Considerations

### Precomputed Summary Metrics

If `contextSummary` is available in the payload, use it directly:

```powershell
if ($payload.contextSummary) {
    $toolCallsCount = $payload.contextSummary.tool_calls_count
    $tokenUsage = $payload.contextSummary.token_usage
    $durationMs = $payload.contextSummary.duration_ms
}
```

If not available, derive from transcript:

```powershell
$toolCallsCount = ($events | Where-Object { $_.type -eq "tool" }).Count
$tokenUsage = $events.Count * 150  # Rough estimate
$durationMs = $null
```

### OTLP Debug Export

If Copilot provides an OTLP JSON debug export in the payload:

```powershell
if ($payload.debugExport) {
    $debugEvent = @{
        event_type = "debug_export"
        source = "copilot"
        timestamp = (Get-Date -Format "o")
        data = $payload.debugExport
    } | ConvertTo-Json -Compress

    $jsonlPath = Join-Path $transcriptDir "transcripts.jsonl"
    Add-Content -Path $jsonlPath -Value $debugEvent -Encoding UTF8
}
```

### Live Log Parsing

If `capture_live_logs` is enabled and `logs` content is available:

```powershell
function Parse-Logs($logsContent) {
    $parsed = @()
    foreach ($line in $logsContent) {
        if ($line -match "\[(\w+)\]\s+(.*)") {
            $parsed += @{
                level = $Matches[1]
                message = $Matches[2]
                raw = $line
            }
        }
    }
    return $parsed
}
```

Append parsed logs to `.transcripts/transcripts.md` only if `capture_live_logs` is true and the volume is manageable.
