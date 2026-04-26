# PreCompact Hook Implementation Plan

## Overview

Implement separate PreCompact hook support for Claude Code and VS Code Copilot. Each platform must write append-only transcripts into `.transcripts/transcripts.md` and `.transcripts/transcripts.jsonl`, and preserve platform-specific session context in `.claude/session_context.md` or `.github/session_context.md`.

## Goals

- Save all available runtime transcript context before compaction.
- Preserve append-only history in `.transcripts/` and never delete existing content.
- Maintain human-readable summaries in `.transcripts/transcripts.md`.
- Maintain structured event logs / debug export in `.transcripts/transcripts.jsonl`.
- Provide platform-specific hook scripts and configuration files.
- Make log capture configurable to avoid overwhelming Markdown summary output.

## Shared Storage Rules

- Every write to `.transcripts/transcripts.md` must append new summary sections only.
- Every write to `.transcripts/transcripts.jsonl` must append JSON lines only.
- Do not truncate or delete existing `.transcripts` content.
- Ensure `.transcripts/` exists before writing.
- Use relative workspace paths where possible.

## Claude Code Plan

### Architecture

- Hook file: `pre-compact-cc.ps1`
- Companion session context file: `.claude/session_context.md`
- Transcript storage: `.transcripts/transcripts.md`, `.transcripts/transcripts.jsonl`
- Hook type: PreCompact command hook using PowerShell.

### Expected Input

- JSON payload from stdin containing:
  - `session_id`
  - `transcript_path`
  - `cwd`
  - `hook_event_name`
  - `trigger`
  - `custom_instructions`
- `transcript_path` points to a JSONL transcript file already containing prior compaction summaries and raw events.

### Expected Output

- JSON written to stdout with fields:
  - `systemMessage`
  - `additionalContext`
  - `continue` or other hook-specific flags if required
- Optional injection text should reference `.claude/session_context.md` and the latest compaction summary.

### Processing Steps

1. Ensure `.transcripts/` exists under the workspace root.
2. Load the transcript file from `transcript_path`.
3. Parse JSONL events without deleting prior summarized content.
4. Extract high-signal content:
   - Decisions and rationale
   - Actions the assistant took
   - Commands and tool call results
   - Open issues / TODOs
   - Relevant file changes
   - Any precomputed summary metadata if available
5. Append a new section to `.transcripts/transcripts.md`.
6. Append one or more structured JSON event lines to `.transcripts/transcripts.jsonl`.
7. Append a compact summary section to `.claude/session_context.md` for future restoration.
8. Return hook output that can be used by Claude to retain context after compaction.

### File Formats

- `.transcripts/transcripts.md`
  - Human-readable compaction history
  - Each compaction gets its own heading and timestamp
  - Optional metadata: trigger type, token counts, summary length

- `.transcripts/transcripts.jsonl`
  - Append-only structured events
  - One JSON object per line
  - Include event type, timestamp, source, and extracted metadata

- `.claude/session_context.md`
  - Cumulative session context summary for Claude
  - Appends the latest distilled context at every PreCompact

### Error Handling

- If the transcript file is missing or invalid, write a diagnostic event to `.transcripts/transcripts.jsonl` and return a safe error message via stdout JSON.
- If `.transcripts/` cannot be created, fail gracefully and log the reason.
- If output JSON cannot be constructed, emit a fallback system message.
- Preserve any existing `.transcripts` content even if parsing fails.

### Configuration Options

- `capture_debug_logs`: boolean - whether to write debug events into `.transcripts/transcripts.jsonl`.
- `write_md_summary`: boolean - whether to append human-readable summary to `.transcripts/transcripts.md`.
- `max_md_sections`: integer - optional cap on recent sections if file becomes too large.
- `append_only`: always enforced; never purge old history.

## Copilot Plan

### Architecture

- Hook file: `pre-compact-copilot.ps1`
- Hook configuration: `.github/hooks/pre-compact-copilot.json`
- Companion session context file: `.github/session_context.md`
- Transcript storage: `.transcripts/transcripts.md`, `.transcripts/transcripts.jsonl`
- Hook type: VS Code Copilot agent hook using PreCompact event support.

### Expected Input

- Payload exposed by Copilot PreCompact hook, including:
  - `workspaceRoot`
  - `transcript` or `transcript_path`
  - `logs` or debug stream references
  - `trigger` (auto/manual)
  - `contextSummary` if precomputed
- The payload may include OTLP JSON export or raw transcript data.

### Expected Output

- JSON written to stdout or returned via hook API with fields:
  - `systemMessage`
  - `additionalContext`
  - optional `continue`
- If hook output cannot directly inject text, write summary files and return a minimal acknowledgement.

### Processing Steps

1. Ensure `.transcripts/` exists under the workspace root.
2. Read the available Copilot hook payload.
3. Extract the raw transcript and any precomputed summary data.
4. Parse debug logs if configured.
5. Append a new section to `.transcripts/transcripts.md`.
6. Append structured lines to `.transcripts/transcripts.jsonl`.
7. Append the distilled context to `.github/session_context.md`.
8. Return a hook response that tells Copilot to preserve that context.

### Special Copilot Considerations

- If the PreCompact payload includes pre-summarized usage metrics, use them.
- If not, derive summary metadata from transcript/log contents.
- Make markdown log capture configurable to avoid logging too much noise.
- Keep debug exports optional in `.transcripts/transcripts.jsonl`.

### File Formats

- `.transcripts/transcripts.md`
  - Human-readable summary of Copilot session state and compaction history.
  - Append-only, with each hook invocation producing a new section.

- `.transcripts/transcripts.jsonl`
  - Structured line-delimited JSON events.
  - Include Copilot-specific fields like debug level, OTLP export tags, tool call metadata.

- `.github/session_context.md`
  - Cumulative restoration file for Copilot.
  - Appends the distilled context after each PreCompact.

### Error Handling

- If Copilot hook payload is malformed, preserve `.transcripts` history and write a diagnostic line.
- If workspace path resolution fails, return a hook error to the extension without deleting existing files.
- If log capture is disabled, skip heavy log writes but still append summary metadata.

### Configuration Options

- `capture_live_logs`: boolean - if true, parse live logs and append them to `.transcripts/transcripts.md`.
- `capture_debug_export`: boolean - if true, save OTLP JSON debug export to `.transcripts/transcripts.jsonl`.
- `write_human_readable_summary`: boolean - if true, generate Markdown summaries for every compaction.
- `max_history_sections`: optional integer cap for `.transcripts/transcripts.md`.
- `append_only`: always enforced.

## Test Plan - Claude Code

### Scope

- Validate native PreCompact hook execution.
- Ensure append-only `.transcripts` behavior.
- Confirm `.claude/session_context.md` is updated reliably.
- Exercise error paths for missing or malformed transcript files.

### Test Cases

1. Hook input parsing
   - Valid JSON payload from stdin
   - Missing `transcript_path`
   - Invalid JSON

2. Transcript processing
   - Normal transcript file with prior summary history
   - Empty transcript file
   - Large transcript file with 1000+ entries
   - Transcript file containing special characters

3. File output behavior
   - `.transcripts/transcripts.md` appends a new summary section
   - `.transcripts/transcripts.jsonl` appends structured JSON lines
   - `.claude/session_context.md` appends latest distilled summary
   - Existing `.transcripts` content remains unchanged

4. Output contract
   - Hook returns valid JSON
   - `systemMessage` contains expected text
   - `additionalContext` includes the latest context snippet

5. Error handling
   - Missing `.transcripts/` directory is created
   - Permission denied on directory returns graceful error
   - Invalid event parsing writes diagnostic JSON line instead of deleting history

### Success Criteria

- All compactions append new sections without deleting old content.
- The hook can run multiple times in a single session.
- `.claude/session_context.md` remains cumulative and readable.
- A broken transcript payload does not corrupt prior history.

## Test Plan - Copilot

### Scope

- Validate Copilot PreCompact hook execution in VS Code.
- Ensure append-only `.transcripts` behavior.
- Confirm `.github/session_context.md` is updated reliably.
- Verify log capture configuration toggles correctly.

### Test Cases

1. Hook input parsing
   - Valid Copilot payload with transcript and logs
   - Missing transcript data
   - Payload without precomputed summary data
   - Invalid JSON or schema changes

2. Transcript and log processing
   - Raw transcript only
   - Raw transcript plus debug export
   - Large transcript and log payloads
   - Live logs with verbose output when enabled

3. File output behavior
   - `.transcripts/transcripts.md` appends a new summary section
   - `.transcripts/transcripts.jsonl` appends structured Copilot events
   - `.github/session_context.md` appends distilled context
   - Existing `.transcripts` content remains unchanged

4. Configuration toggles
   - `capture_live_logs` enabled/disabled
   - `capture_debug_export` enabled/disabled
   - `write_human_readable_summary` enabled/disabled

5. Output contract
   - Hook returns valid response or acknowledgement
   - If direct context injection is unavailable, file writes still occur

6. Error handling
   - Workspace resolution failures are handled gracefully
   - Missing `.transcripts/` directory is created
   - Log parsing failures do not delete history

### Success Criteria

- Copilot PreCompact hook writes append-only transcripts correctly.
- `.github/session_context.md` is reliable for recovery.
- The hook can operate with or without debug export.
- Config options prevent excessive Markdown log noise.
