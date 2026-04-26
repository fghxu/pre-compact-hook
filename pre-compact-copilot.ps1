#Requires -Version 5.1
<#
.SSYNOPSIS
    VS Code Copilot PreCompact Hook - Context Saver

.DESCRIPTION
    Saves all available runtime context before Copilot compaction into append-only
    transcript files and a session restoration file.

    - Appends to .transcripts/transcripts.md (human-readable summary)
    - Appends to .transcripts/transcripts.jsonl (structured event log)
    - Appends to .github/session_context.md (session restoration file)
    - Never deletes existing content in any transcript file

.PARAMETER InputData
    JSON payload from Copilot hook via stdin. If not provided, reads from pipeline.

.EXAMPLE
    $payload | pwsh -File pre-compact-copilot.ps1

.EXAMPLE
    pwsh -File pre-compact-copilot.ps1 -InputData $jsonString
#>

param(
    [Parameter(Mandatory=$false, ValueFromPipeline=$true)]
    [string]$InputData
)

# ------------------------------
# Configuration
# ------------------------------
# Load config if it exists, otherwise use defaults
$Config = @{
    capture_live_logs          = $true
    capture_debug_export      = $true
    write_md_summary          = $true
    write_jsonl_events        = $true
    max_md_sections           = 10
    include_tool_call_details = $true
}

$ConfigPath = Join-Path $PSScriptRoot ".github/hooks/pre-compact-copilot.config.json"
if (Test-Path $ConfigPath) {
    try {
        $loadedConfig = Get-Content $ConfigPath -Raw | ConvertFrom-Json
        foreach ($key in $loadedConfig.PSObject.Properties.Name) {
            $Config[$key] = $loadedConfig.$key
        }
    } catch {
        # Use defaults if config is malformed
    }
}

# ------------------------------
# Helper Functions
# ------------------------------

function Get-Decisions {
    param([array]$Events)

    $decisions = @()
    foreach ($e in $Events) {
        if ($e.type -eq "assistant" -and $e.content -match "decided|chose|switched|using|going with|selected|opted|will use|using|going to use") {
            $decisions += $e.content
        }
    }
    return $decisions
}

function Get-ToolCalls {
    param([array]$Events)

    $toolCalls = @()
    foreach ($e in $Events) {
        if ($e.type -eq "tool" -or $e.tool_call) {
            $toolCalls += $e
        }
    }
    return $toolCalls
}

function Get-OpenIssues {
    param([array]$Events)

    $issues = @()
    foreach ($e in $Events) {
        if ($e.type -eq "user" -and $e.content -match "still need|pending|not sure|TODO|waiting on|unresolved") {
            $issues += $e.content
        }
    }
    return $issues
}

function Get-KeyDiscoveries {
    param([array]$Events)

    $discoveries = @()
    foreach ($e in $Events) {
        if ($e.type -eq "tool" -and $e.output) {
            # Capture error messages and significant findings
            if ($e.output -match "error|failed|exception|timeout|denied|not found|cannot") {
                $discoveries += $e.output
            }
        }
    }
    return $discoveries
}

function Get-ModifiedFiles {
    param([array]$Events)

    $files = @()
    foreach ($e in $Events) {
        if ($e.type -eq "tool" -and $e.input -and $e.input.command) {
            # Extract file paths from common commands
            if ($e.input.command -match "(?:^|\s)([a-zA-Z]:[\\/]?[\w\-.\\/]+|/[\\/\w\-.\\/]+)") {
                $files += $Matches[1].Trim()
            }
        }
    }
    return $files | Select-Object -Unique
}

function Get-UserMessages {
    param([array]$Events)

    $messages = @()
    foreach ($e in $Events) {
        if ($e.type -eq "user" -and $e.content) {
            $messages += $e.content
        }
    }
    return $messages
}

function Parse-Logs {
    param([array]$LogsContent)

    $parsed = @()
    foreach ($line in $LogsContent) {
        if ($line -match "\[(\w+)\]\s+(.*)") {
            $parsed += @{
                level   = $Matches[1]
                message = $Matches[2]
                raw     = $line
            }
        }
    }
    return $parsed
}

function Get-NextCompactionNumber {
    param([string]$MdPath)

    if (-not (Test-Path $MdPath)) {
        return 1
    }
    $existingHeadings = Select-String -Path $MdPath -Pattern "^## Compaction #" | Measure-Object
    return $existingHeadings.Count + 1
}

function Write-DiagnosticEvent {
    param(
        [string]$JsonlPath,
        [string]$EventType,
        [string]$ErrorCode,
        [string]$Message
    )

    $event = @{
        event_type = $EventType
        timestamp  = (Get-Date -Format "o")
        error      = $ErrorCode
        message    = $Message
    } | ConvertTo-Json -Compress

    Add-Content -Path $JsonlPath -Value $event -Encoding UTF8
}

# ------------------------------
# Main Execution
# ------------------------------

# Read stdin if no InputData provided
if ([string]::IsNullOrEmpty($InputData)) {
    $InputData = $input | Out-String
}

# Parse payload
$payload = $null
try {
    if ([string]::IsNullOrEmpty($InputData)) {
        throw "No input data"
    }
    $payload = $InputData | ConvertFrom-Json
} catch {
    # Fallback: try reading from stdin again
    $InputData = $input | Out-String
    if (-not [string]::IsNullOrEmpty($InputData)) {
        try {
            $payload = $InputData | ConvertFrom-Json
        } catch {
            # Malformed payload - write diagnostic and exit gracefully
            $transcriptDir = Join-Path $env:TEMP ".transcripts_debug"
            if (-not (Test-Path $transcriptDir)) {
                New-Item -ItemType Directory -Path $transcriptDir -Force | Out-Null
            }
            $jsonlPath = Join-Path $transcriptDir "transcripts.jsonl"
            Write-DiagnosticEvent -JsonlPath $jsonlPath -EventType "error" -ErrorCode "payload_parse_failed" -Message "Failed to parse hook input JSON: $_"
            Write-Output '{"systemMessage": "Failed to parse hook input. Context saving skipped.", "additionalContext": null}'
            exit 0
        }
    } else {
        $transcriptDir = Join-Path $env:TEMP ".transcripts_debug"
        if (-not (Test-Path $transcriptDir)) {
            New-Item -ItemType Directory -Path $transcriptDir -Force | Out-Null
        }
        $jsonlPath = Join-Path $transcriptDir "transcripts.jsonl"
        Write-DiagnosticEvent -JsonlPath $jsonlPath -EventType "error" -ErrorCode "no_input_data" -Message "No input data provided to hook"
        Write-Output '{"systemMessage": "No input data. Context saving skipped.", "additionalContext": null}'
        exit 0
    }
}

# Extract workspace root
# Copilot CLI / VS Code Copilot sends `cwd` in the real payload (per VS Code
# hooks spec: https://code.visualstudio.com/docs/copilot/customization/hooks ).
# We keep `workspaceRoot` as a backward-compatible alias so older test payloads
# and manual invocations still work.
$workspaceRoot = $null
if ($payload.cwd -and (Test-Path $payload.cwd)) {
    $workspaceRoot = $payload.cwd
} elseif ($payload.workspaceRoot -and (Test-Path $payload.workspaceRoot)) {
    $workspaceRoot = $payload.workspaceRoot
} else {
    # Fallback: use current directory
    $workspaceRoot = $PWD.Path
}

# Ensure .transcripts/ directory exists
$transcriptDir = Join-Path $workspaceRoot ".transcripts"
try {
    if (-not (Test-Path $transcriptDir)) {
        New-Item -ItemType Directory -Path $transcriptDir -Force | Out-Null
    }
} catch {
    Write-Output '{"systemMessage": "Failed to create transcript directory. Check permissions.", "additionalContext": null}'
    exit 1
}

# Ensure .github/ directory exists
$githubDir = Join-Path $workspaceRoot ".github"
if (-not (Test-Path $githubDir)) {
    New-Item -ItemType Directory -Path $githubDir -Force | Out-Null
}

# Extract trigger type.
# `trigger` is our own test convention ("auto"/"manual"); Copilot's real payload
# uses `hookEventName` (e.g. "PreCompact") per the VS Code hooks spec. Honour
# either, defaulting to "unknown".
$trigger = if ($payload.trigger) {
    $payload.trigger
} elseif ($payload.hookEventName) {
    $payload.hookEventName
} else {
    "unknown"
}

# Extract context summary metrics
$toolCallsCount = $null
$tokenUsage = $null
$durationMs = $null
if ($payload.contextSummary) {
    $toolCallsCount = $payload.contextSummary.tool_calls_count
    $tokenUsage = $payload.contextSummary.token_usage
    $durationMs = $payload.contextSummary.duration_ms
}

# ------------------------------
# Extract Transcript and Logs
# ------------------------------

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

$logsContent = $null
if ($payload.logs) {
    if ($payload.logs -is "array") {
        $logsContent = $payload.logs
    } else {
        $logsContent = $payload.logs -split "`n"
    }
}

# ------------------------------
# Parse Events
# ------------------------------

$events = @()
if ($transcriptContent) {
    if ($transcriptContent -is "array") {
        # Direct array of hashtable objects (already parsed)
        foreach ($item in $transcriptContent) {
            if ($item -is "hashtable" -or $item.PSObject.Properties["type"]) {
                $events += $item
            }
        }
    } else {
        # String array (JSON lines)
        foreach ($line in $transcriptContent) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try {
                $event = $line | ConvertFrom-Json
                $events += $event
            } catch {
                # Skip malformed lines
            }
        }
    }
}

# Derive metrics if not precomputed
if (-not $toolCallsCount) {
    $toolCallsCount = ($events | Where-Object { $_.type -eq "tool" }).Count
}
if (-not $tokenUsage) {
    $tokenUsage = $events.Count * 150
}

# ------------------------------
# Extract High-Signal Content
# ------------------------------

$decisions = Get-Decisions -Events $events
$toolCalls = Get-ToolCalls -Events $events
$openIssues = Get-OpenIssues -Events $events
$discoveries = Get-KeyDiscoveries -Events $events
$modifiedFiles = Get-ModifiedFiles -Events $events
$userMessages = Get-UserMessages -Events $events

# ------------------------------
# Build Summary
# ------------------------------

$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm"
$compactionNumber = Get-NextCompactionNumber -MdPath (Join-Path $transcriptDir "transcripts.md")

$summary = @{
    compaction_number = $compactionNumber
    trigger           = $trigger
    timestamp         = $timestamp
    tool_calls_count  = $toolCallsCount
    token_usage       = $tokenUsage
    duration_ms       = $durationMs
    decisions         = $decisions
    tool_calls        = $toolCalls
    open_issues       = $openIssues
    discoveries       = $discoveries
    modified_files    = $modifiedFiles
    user_messages     = $userMessages
}

# ------------------------------
# Write to .transcripts/transcripts.md
# ------------------------------

if ($Config.write_md_summary) {
    $mdPath = Join-Path $transcriptDir "transcripts.md"

    $mdSection = "`n## Compaction #$($summary.compaction_number) ($($trigger), $($timestamp))`n`n"
    $mdSection += "- **Trigger**: $($trigger)`n"
    if ($summary.tool_calls_count) { $mdSection += "- **Tool Calls**: $($summary.tool_calls_count)`n" }
    if ($summary.token_usage) { $mdSection += "- **Token Usage**: $($summary.token_usage)`n" }
    if ($summary.duration_ms) { $mdSection += "- **Duration**: $($summary.duration_ms)ms`n" }

    if ($summary.decisions.Count -gt 0) {
        $mdSection += "- **Decisions**:`n"
        foreach ($d in $summary.decisions) {
            $mdSection += "  - $($d)`n"
        }
    }

    if ($summary.modified_files.Count -gt 0) {
        $mdSection += "- **Modified Files**:`n"
        foreach ($f in $summary.modified_files) {
            $mdSection += "  - $($f)`n"
        }
    }

    if ($summary.tool_calls.Count -gt 0 -and $Config.include_tool_call_details) {
        $mdSection += "- **Tool Calls**:`n"
        foreach ($tc in $summary.tool_calls) {
            $cmd = if ($tc.input -and $tc.input.command) { $tc.input.command } else { "N/A" }
            $name = if ($tc.name) { $tc.name } elseif ($tc.tool_call -and $tc.tool_call.name) { $tc.tool_call.name } else { "unknown" }
            $mdSection += "  - $($name): $($cmd)`n"
        }
    }

    if ($summary.open_issues.Count -gt 0) {
        $mdSection += "- **Open Issues**:`n"
        foreach ($i in $summary.open_issues) {
            $mdSection += "  - $($i)`n"
        }
    }

    if ($summary.user_messages.Count -gt 0) {
        $mdSection += "- **User Messages**:`n"
        foreach ($msg in $summary.user_messages) {
            $mdSection += "  - $($msg)`n"
        }
    }

    if ($summary.discoveries.Count -gt 0) {
        $mdSection += "- **Key Discoveries**:`n"
        foreach ($disc in $summary.discoveries) {
            $mdSection += "  - $($disc)`n"
        }
    }

    Add-Content -Path $mdPath -Value $mdSection -Encoding UTF8
}

# ------------------------------
# Write to .transcripts/transcripts.jsonl
# ------------------------------

if ($Config.write_jsonl_events) {
    $jsonlPath = Join-Path $transcriptDir "transcripts.jsonl"

    $jsonlEvent = @{
        event_type        = "compact_summary"
        source            = "copilot"
        compaction_number = $summary.compaction_number
        timestamp         = $timestamp
        trigger           = $summary.trigger
        tool_calls_count  = $summary.tool_calls_count
        token_usage       = $summary.token_usage
        duration_ms      = $summary.duration_ms
        decisions         = $summary.decisions
        modified_files    = $summary.modified_files
        open_issues       = $summary.open_issues
        discoveries       = $summary.discoveries
    } | ConvertTo-Json -Compress

    Add-Content -Path $jsonlPath -Value $jsonlEvent -Encoding UTF8
}

# ------------------------------
# Write to .github/session_context.md
# ------------------------------

$sessionCtxPath = Join-Path $githubDir "session_context.md"

$sessionCtxSection = "`n## Compaction #$($summary.compaction_number) ($($trigger), $($timestamp))`n`n"
$sessionCtxSection += "### Decisions`n"
if ($summary.decisions.Count -gt 0) {
    foreach ($d in $summary.decisions) {
        $sessionCtxSection += "- $($d)`n"
    }
} else {
    $sessionCtxSection += "- (none recorded)`n"
}

$sessionCtxSection += "`n### Modified Files`n"
if ($summary.modified_files.Count -gt 0) {
    foreach ($f in $summary.modified_files) {
        $sessionCtxSection += "- $($f)`n"
    }
} else {
    $sessionCtxSection += "- (none recorded)`n"
}

$sessionCtxSection += "`n### Tool Calls`n"
if ($summary.tool_calls.Count -gt 0) {
    foreach ($tc in $summary.tool_calls) {
        $cmd = if ($tc.input -and $tc.input.command) { $tc.input.command } else { "N/A" }
        $name = if ($tc.name) { $tc.name } elseif ($tc.tool_call -and $tc.tool_call.name) { $tc.tool_call.name } else { "unknown" }
        $sessionCtxSection += "- $($name): $($cmd)`n"
    }
} else {
    $sessionCtxSection += "- (none recorded)`n"
}

$sessionCtxSection += "`n### Open Issues`n"
if ($summary.open_issues.Count -gt 0) {
    foreach ($i in $summary.open_issues) {
        $sessionCtxSection += "- $($i)`n"
    }
} else {
    $sessionCtxSection += "- (none recorded)`n"
}

$sessionCtxSection += "`n### Key Discoveries`n"
if ($summary.discoveries.Count -gt 0) {
    foreach ($disc in $summary.discoveries) {
        $sessionCtxSection += "- $($disc)`n"
    }
} else {
    $sessionCtxSection += "- (none recorded)`n"
}

Add-Content -Path $sessionCtxPath -Value $sessionCtxSection -Encoding UTF8

# ------------------------------
# Write Debug Export to JSONL (if enabled and available)
# ------------------------------

if ($Config.capture_debug_export -and $payload.debugExport) {
    $jsonlPath = Join-Path $transcriptDir "transcripts.jsonl"
    $debugEvent = @{
        event_type = "debug_export"
        source     = "copilot"
        timestamp  = (Get-Date -Format "o")
        data       = $payload.debugExport
    } | ConvertTo-Json -Compress

    Add-Content -Path $jsonlPath -Value $debugEvent -Encoding UTF8
}

# ------------------------------
# Write Live Logs to transcripts.md (if enabled and available)
# ------------------------------

if ($Config.capture_live_logs -and $logsContent) {
    $mdPath = Join-Path $transcriptDir "transcripts.md"
    $parsedLogs = Parse-Logs -LogsContent $logsContent

    if ($parsedLogs.Count -gt 0) {
        $logSection = "`n### Live Logs (Captured)`n"
        foreach ($log in $parsedLogs) {
            $logSection += "- [$($log.level)] $($log.message)`n"
        }
        Add-Content -Path $mdPath -Value $logSection -Encoding UTF8
    }
}

# ------------------------------
# Return Hook Output
# ------------------------------

$latestSection = ""
try {
    if (Test-Path $sessionCtxPath) {
        $latestSection = Get-Content $sessionCtxPath -Tail 30 -Encoding UTF8 -Raw
    }
} catch {
    $latestSection = ""
}

$output = @{
    systemMessage      = "Context from previous compactions has been saved. Review `.github/session_context.md` for history. Latest summary:`n$latestSection"
    additionalContext  = @{
        type    = "file"
        path    = ".github/session_context.md"
        content = $latestSection
    }
} | ConvertTo-Json -Compress

Write-Output $output
exit 0
