# PreCompact Hook Implementation Plan

## Research Findings

### Claude Code Hook System
- **Dedicated Events**: PreCompact and PostCompact hook events with JSON I/O
- **PreCompact Capabilities**: Can block compaction, inject context, receive trigger type (manual/auto) and custom instructions
- **PostCompact Capabilities**: Runs after compaction, receives compact_summary, can perform follow-up tasks
- **Input Schema**: JSON with session_id, transcript_path, cwd, hook_event_name, trigger, custom_instructions
- **Output Schema**: JSON with decision/blocking, additionalContext, systemMessage, continue flags
- **PowerShell Support**: Hooks can be written in PowerShell with shell: "powershell" configuration

### GitHub Copilot Hook System
- **No Direct PreCompact Hooks**: Unlike Claude Code, Copilot doesn't have built-in precompact hook events
- **VS Code Extension APIs**: Chat Participant API and Language Model API for building extensions
- **Chat Participants**: Extensions can create @-mentioned participants that handle user requests
- **Language Models**: Direct access to Copilot models for custom processing
- **No Compaction Events**: No equivalent to Claude Code's PreCompact/PostCompact events

### Best Practices for Context Preservation
Based on Claude Code documentation and general AI context management:

**What to Save:**
- Decisions made by the AI assistant
- Files modified and reasons why
- Commands with meaningful results (not routine ls/cat)
- User answers to questions
- Unresolved issues and TODOs
- Key discoveries and bug root causes
- Infrastructure state and configuration
- Session metadata (compaction count, timestamps, token counts)

**What NOT to Save:**
- Routine conversation chatter
- Every line of transcript (defeats compaction purpose)
- Redundant information
- Temporary debugging output

**Format:**
- Markdown files for human readability
- Structured sections for each compaction
- Cumulative file with multiple compaction entries
- Session metadata and timestamps

## Architectural Decisions

### Claude Code Implementation (pre-compact-cc.ps1)
- **Hook Type**: Command hook with PowerShell
- **Event**: PreCompact
- **Functionality**:
  - Parse transcript JSONL file from stdin
  - Extract high-signal content (decisions, actions, issues)
  - Write to .claude/session_context.md (append new section)
  - Return JSON with systemMessage to inject context
  - Support multiple compactions in single file

### GitHub Copilot Implementation (pre-compact-copilot.ps1)
- **Approach**: VS Code extension using Chat Participant API
- **No Direct Hook**: Since Copilot lacks precompact events, implement as:
  - Chat participant that monitors for compaction triggers
  - Custom slash command for manual context saving
  - Background process monitoring context window
- **Fallback Strategy**: Since no precompact hook exists, implement as:
  - Extension that provides /save-context command
  - Automatic context saving on model switching or session events
  - Integration with VS Code's chat history API

### Context File Structure
`
.claude/session_context.md
# Session Context - Compaction Log

## Compaction #1 (auto, 2026-04-25 01:30)
- Tokens: 142,000 → 45,000
- Decisions: [list]
- Modified files: [list]
- Key discoveries: [list]
- Open issues: [list]
- Commands: [summary]

## Compaction #2 (auto, 2026-04-25 02:15)
...
`

### Implementation Priority
1. **Start with Copilot version** as requested
2. Claude Code version second (easier due to existing hook infrastructure)

## Code Plans

### pre-compact-copilot.ps1 (VS Code Extension)
`powershell
# VS Code extension structure needed:
# - package.json with chat participant registration
# - extension.ts with chat handler
# - PowerShell script for context processing

# Extension manifest (package.json):
{
  "contributes": {
    "chatParticipants": [{
      "id": "context-saver",
      "name": "context-saver",
      "fullName": "Context Saver",
      "description": "Save context before compaction",
      "commands": [{
        "name": "save",
        "description": "Save current context to file"
      }]
    }]
  }
}

# Chat handler logic:
# - Monitor for context window approaching limit
# - Provide /save command for manual saving
# - Extract decisions, actions, issues from chat history
# - Write to session_context.md
`

### pre-compact-cc.ps1 (Claude Code Hook)
`powershell
# Read JSON input from stdin
 =  | ConvertFrom-Json

# Parse transcript file
 = .transcript_path
 = Get-Content  | ConvertFrom-Json

# Extract high-signal content
 = Extract-Decisions 
 = Extract-Actions 
 = Extract-OpenIssues 

# Write to context file
 = Join-Path .cwd ".claude/session_context.md"
Add-ContextSection    

# Return JSON output
@{
    systemMessage = "Context saved to session_context.md"
    additionalContext = Get-LatestContextSection 
} | ConvertTo-Json
`

### Shared Utilities
- Transcript parsing functions
- Context extraction logic
- Markdown formatting helpers
- File management (append vs overwrite)

## API Differences Summary
| Feature | Claude Code | GitHub Copilot |
|---------|-------------|----------------|
| PreCompact Event | ✓ Native | ✗ None |
| Hook Types | Command, HTTP, MCP, Prompt, Agent | Extension-based |
| PowerShell Support | ✓ Direct | ✓ Via extension |
| JSON I/O | ✓ Stdin/stdout | ✓ Via extension APIs |
| Blocking Capability | ✓ Can block compaction | ✗ No compaction event |
| Context Injection | ✓ systemMessage/additionalContext | ✓ Via chat responses |

## Next Steps
1. Implement Copilot version as VS Code extension
2. Test extension functionality
3. Implement Claude Code version
4. Integration testing
5. Documentation and deployment
