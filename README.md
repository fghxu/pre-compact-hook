# VS Code Copilot PreCompact Hook

Saves all available runtime context before Copilot compaction into append-only transcript files and a session restoration file.

## Overview

This project implements a PreCompact hook for VS Code Copilot that preserves full transcript history across multiple compactions without data loss.

## Features

- **Append-only transcript storage** - Never deletes existing content
- **Human-readable summaries** in `.transcripts/transcripts.md`
- **Structured event logs** in `.transcripts/transcripts.jsonl`
- **Session restoration file** at `.github/session_context.md`
- **Configurable log capture** to avoid overwhelming the Markdown summary

## File Structure

```
project-root/
  pre-compact-copilot.ps1     # Main hook script
  README.md                   # This file
  .github/
    hooks/
      pre-compact-copilot.json          # Hook configuration
      pre-compact-copilot.config.json   # Optional runtime config
  .transcripts/
    transcripts.md           # Human-readable compaction history
    transcripts.jsonl        # Structured event logs (JSONL)
  testing/
    pre-compact-copilot.tests.ps1  # Pester test suite
  doc/
    plan-Copilot.md          # Implementation plan
    requirements.md          # Requirements research
    plan.md                  # Architecture decisions
```

## Installation

1. Copy `pre-compact-copilot.ps1` to your project root
2. Copy `.github/hooks/pre-compact-copilot.json` to your project's `.github/hooks/` directory
3. Create the `.github/hooks/` directory if it doesn't exist

## Configuration

The hook reads settings from `.github/hooks/pre-compact-copilot.config.json` (optional):

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

### Configuration Options

| Option | Description | Default |
|--------|-------------|---------|
| `capture_live_logs` | Include live logs in transcripts.md | true |
| `capture_debug_export` | Capture debug export data | true |
| `write_md_summary` | Write markdown summary | true |
| `write_jsonl_events` | Write JSONL event log | true |
| `max_md_sections` | Maximum sections before cleanup | 10 |
| `include_tool_call_details` | Include tool call details | true |

## Usage

The hook is triggered automatically by VS Code Copilot's PreCompact event. It can also be invoked manually:

```powershell
$payload | pwsh -File pre-compact-copilot.ps1
```

### Input Payload Schema

```json
{
  "workspaceRoot": "string (absolute path to project root)",
  "transcript": "array (raw transcript content)",
  "transcript_path": "string (path to transcript file, if available)",
  "logs": "array (debug log content, if available)",
  "trigger": "auto | manual",
  "contextSummary": {
    "tool_calls_count": "number",
    "token_usage": "number",
    "duration_ms": "number"
  }
}
```

### Output Schema

```json
{
  "systemMessage": "string",
  "additionalContext": {
    "type": "file",
    "path": ".github/session_context.md",
    "content": "string"
  }
}
```

## Testing

Run the Pester test suite:

```powershell
Invoke-Pester -Path testing/pre-compact-copilot.tests.ps1
```

All 34 tests should pass, covering:
- Hook input parsing
- Transcript and log processing
- File output behavior
- Configuration toggles
- Output contract validation
- Error handling

## Transcript Storage Rules

- **`.transcripts/transcripts.md`**: Appends new summary sections only. Never overwrites or deletes.
- **`.transcripts/transcripts.jsonl`**: Appends new JSON lines only. Never truncates.
- **`.github/session_context.md`**: Appends the latest distilled context section.

## Goals

- Preserve full transcript history across multiple compactions without data loss
- Maintain a human-readable compaction summary in `.transcripts/transcripts.md`
- Maintain structured event logs in `.transcripts/transcripts.jsonl`
- Provide a session restoration file at `.github/session_context.md`
- Make log capture configurable to avoid overwhelming the Markdown summary
- Never delete existing content in any transcript file
