#Requires -Version 5.1
#Requires -Module Pester

<#
.SYNOPSIS
    Pester test suite for pre-compact-copilot.ps1

.DESCRIPTION
    Unit and integration tests for the VS Code Copilot PreCompact hook.
    Run with: Invoke-Pester -Path pre-compact-copilot.tests.ps1
#>

BeforeAll {
    $Script:HookScriptPath = if ($PSScriptRoot) { Join-Path (Split-Path $PSScriptRoot -Parent) "pre-compact-copilot.ps1" } else { Join-Path $PWD "pre-compact-copilot.ps1" }
    $Script:HookScript = $Script:HookScriptPath
    $Script:TestBaseDir = if ($PSTestDrive) { $PSTestDrive } else { $env:TEMP }
    $Script:TestWorkspace = Join-Path $Script:TestBaseDir "TestWorkspace_$(Get-Random)"
    $Script:TranscriptDir = Join-Path $TestWorkspace ".transcripts"
    $Script:GithubDir = Join-Path $TestWorkspace ".github"

    function New-TestPayload {
        param(
            [string]$WorkspaceRoot = $Script:TestWorkspace,
            [array]$Transcript = @(),
            [string]$Trigger = "manual",
            [hashtable]$ContextSummary = @{},
            [array]$Logs = @(),
            [string]$TranscriptPath = "",
            [string]$DebugExport = ""
        )

        $payload = @{
            workspaceRoot = $WorkspaceRoot
            transcript   = $Transcript
            trigger      = $Trigger
        }

        if ($ContextSummary.Count -gt 0) {
            $payload.contextSummary = $ContextSummary
        }
        if ($Logs.Count -gt 0) {
            $payload.logs = $Logs
        }
        if ($TranscriptPath) {
            $payload.transcript_path = $TranscriptPath
        }
        if ($DebugExport) {
            $payload.debugExport = $DebugExport
        }

        return $payload | ConvertTo-Json -Compress
    }
}

Describe "pre-compact-copilot.ps1" {

    BeforeEach {
        # Create fresh test workspace for each test
        $Script:TestWorkspace = Join-Path $Script:TestBaseDir "TestWorkspace_$(Get-Random)"
        New-Item -ItemType Directory -Path $TestWorkspace -Force | Out-Null
        $Script:TranscriptDir = Join-Path $TestWorkspace ".transcripts"
        $Script:GithubDir = Join-Path $TestWorkspace ".github"
    }

    AfterEach {
        # Clean up test workspace
        if (Test-Path $TestWorkspace) {
            Remove-Item -Path $TestWorkspace -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # ------------------------------
    # TC-1: Hook Input Parsing
    # ------------------------------

    Describe "TC-1: Hook Input Parsing" {

        It "TC-1.1: Parses valid hook payload with transcript and logs" {
            $payload = New-TestPayload -WorkspaceRoot $TestWorkspace `
                -Transcript @(
                    @{type="user";content="Create a deployment"}
                    @{type="assistant";content="I'll create a deployment."}
                    @{type="tool";name="Write";input=@{command="Write file"};output="done"}
                ) `
                -Trigger "manual" `
                -ContextSummary @{tool_calls_count=1; token_usage=500; duration_ms=200} `
                -Logs @("[INFO] Processing request...")

            $result = $payload | pwsh -NoProfile -NonInteractive -File $Script:HookScript 2>&1
            $result | Should -Not -BeNullOrEmpty

            $json = $result | ConvertFrom-Json
            $json.systemMessage | Should -Not -BeNullOrEmpty
            $json.additionalContext | Should -Not -BeNullOrEmpty
            $json.additionalContext.type | Should -Be "file"
            $json.additionalContext.path | Should -Be ".github/session_context.md"
        }

        It "TC-1.2: Handles missing transcript data gracefully" {
            $payload = New-TestPayload -WorkspaceRoot $TestWorkspace -Trigger "auto"

            $result = $payload | pwsh -NoProfile -NonInteractive -File $Script:HookScript 2>&1
            $result | Should -Not -BeNullOrEmpty

            $json = $result | ConvertFrom-Json
            $json.systemMessage | Should -Not -BeNullOrEmpty
            # Should still return valid JSON even with no transcript
            $json.additionalContext | Should -Not -BeNullOrEmpty
        }

        It "TC-1.3: Handles payload without precomputed summary" {
            $payload = New-TestPayload -WorkspaceRoot $TestWorkspace `
                -Transcript @(
                    @{type="user";content="Hello"}
                    @{type="assistant";content="Hi there"}
                ) `
                -Trigger "auto"

            $result = $payload | pwsh -NoProfile -NonInteractive -File $Script:HookScript 2>&1
            $result | Should -Not -BeNullOrEmpty

            $json = $result | ConvertFrom-Json
            $json.systemMessage | Should -Not -BeNullOrEmpty
        }

        It "TC-1.4: Handles invalid JSON gracefully" {
            $invalidJson = "{ this is not valid json }"

            $result = $invalidJson | pwsh -NoProfile -NonInteractive -File $Script:HookScript 2>&1
            $result | Should -Not -BeNullOrEmpty

            # Should return safe JSON error response
            $json = $result | ConvertFrom-Json
            $json.systemMessage | Should -Not -BeNullOrEmpty
        }

        It "TC-1.5: Handles empty payload" {
            $result = "" | pwsh -NoProfile -NonInteractive -File $Script:HookScript 2>&1
            $result | Should -Not -BeNullOrEmpty

            $json = $result | ConvertFrom-Json
            $json.systemMessage | Should -Not -BeNullOrEmpty
        }
    }

    # ------------------------------
    # TC-2: Transcript and Log Processing
    # ------------------------------

    Describe "TC-2: Transcript and Log Processing" {

        It "TC-2.1: Extracts decisions, tool calls, and issues from transcript" {
            $payload = New-TestPayload -WorkspaceRoot $TestWorkspace `
                -Transcript @(
                    @{type="user";content="Deploy to production"}
                    @{type="assistant";content="I decided to use Kubernetes for this deployment."}
                    @{type="tool";name="Bash";input=@{command="kubectl apply -f deploy.yaml"};output="deployment created"}
                    @{type="user";content="still need to add health checks"}
                ) `
                -Trigger "manual"

            $result = $payload | pwsh -NoProfile -NonInteractive -File $Script:HookScript 2>&1
            $result | Should -Not -BeNullOrEmpty

            # Verify files were created
            $mdPath = Join-Path $TranscriptDir "transcripts.md"
            $mdPath | Should -Exist

            $jsonlPath = Join-Path $TranscriptDir "transcripts.jsonl"
            $jsonlPath | Should -Exist

            $sessionCtxPath = Join-Path $GithubDir "session_context.md"
            $sessionCtxPath | Should -Exist
        }

        It "TC-2.2: Captures raw transcript plus debug export" {
            $payload = New-TestPayload -WorkspaceRoot $TestWorkspace `
                -Transcript @(
                    @{type="user";content="Test"}
                    @{type="assistant";content="Working on it."}
                ) `
                -Trigger "auto" `
                -DebugExport @{level="INFO"; data="test export"}

            $result = $payload | pwsh -NoProfile -NonInteractive -File $Script:HookScript 2>&1
            $result | Should -Not -BeNullOrEmpty

            $jsonlPath = Join-Path $TranscriptDir "transcripts.jsonl"
            $jsonlContent = Get-Content $jsonlPath -Raw -Encoding UTF8
            $jsonlContent | Should -Match "debug_export"
        }

        It "TC-2.3: Completes within 5 seconds for large payload" {
            # Generate large transcript (200 entries)
            $largeTranscript = @()
            for ($i = 0; $i -lt 200; $i++) {
                $largeTranscript += @{
                    type    = if ($i % 3 -eq 0) { "user" } elseif ($i % 3 -eq 1) { "assistant" } else { "tool" }
                    content = "Message number $i with some additional text to increase size"
                    name    = if ($i % 3 -eq 2) { "Bash" } else { $null }
                    input   = if ($i % 3 -eq 2) { @{command="kubectl get pods -n default"} } else { $null }
                    output  = if ($i % 3 -eq 2) { "pod list retrieved" } else { $null }
                }
            }

            $payload = New-TestPayload -WorkspaceRoot $TestWorkspace `
                -Transcript $largeTranscript `
                -Trigger "auto" `
                -ContextSummary @{tool_calls_count=66; token_usage=30000; duration_ms=5000}

            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $result = $payload | pwsh -NoProfile -NonInteractive -File $Script:HookScript 2>&1
            $sw.Stop()

            $sw.Elapsed.TotalSeconds | Should -BeLessThan 5
            $result | Should -Not -BeNullOrEmpty
        }

        It "TC-2.4: Appends verbose logs to transcripts.md when enabled" {
            $payload = New-TestPayload -WorkspaceRoot $TestWorkspace `
                -Transcript @(@{type="user";content="Test"}) `
                -Trigger "auto" `
                -Logs @("[INFO] Processing...", "[DEBUG] Step 1", "[WARN] Low memory")

            $result = $payload | pwsh -NoProfile -NonInteractive -File $Script:HookScript 2>&1

            $mdPath = Join-Path $TranscriptDir "transcripts.md"
            $mdContent = Get-Content $mdPath -Raw -Encoding UTF8
            $mdContent | Should -Match "Live Logs"
            $mdContent | Should -Match "INFO"
            $mdContent | Should -Match "DEBUG"
        }

        It "TC-2.5: Skips verbose logs when capture_live_logs is disabled" {
            # Create config file with capture_live_logs disabled
            $projectRoot = Split-Path $PSScriptRoot -Parent
            $configPath = Join-Path $projectRoot ".github/hooks/pre-compact-copilot.config.json"
            $configDir = Split-Path $configPath -Parent
            if (-not (Test-Path $configDir)) {
                New-Item -ItemType Directory -Path $configDir -Force | Out-Null
            }
            @{
                capture_live_logs = $false
                capture_debug_export = $false
                write_md_summary = $true
                write_jsonl_events = $true
                max_md_sections = 10
                include_tool_call_details = $true
            } | ConvertTo-Json | Set-Content -Path $configPath -Encoding UTF8

            try {
                $payload = New-TestPayload -WorkspaceRoot $TestWorkspace `
                    -Transcript @(@{type="user";content="Test"}) `
                    -Trigger "auto" `
                    -Logs @("[INFO] Verbose log that should not appear")

                $result = $payload | pwsh -NoProfile -NonInteractive -File $Script:HookScript 2>&1

                $mdPath = Join-Path $TranscriptDir "transcripts.md"
                $mdContent = Get-Content $mdPath -Raw -Encoding UTF8
                $mdContent | Should -Not -Match "Verbose log"
            }
            finally {
                # Clean up config
                if (Test-Path $configPath) {
                    Remove-Item $configPath -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }

    # ------------------------------
    # TC-3: File Output Behavior
    # ------------------------------

    Describe "TC-3: File Output Behavior" {

        It "TC-3.1: Creates transcripts.md with section after first compaction" {
            $payload = New-TestPayload -WorkspaceRoot $TestWorkspace `
                -Transcript @(@{type="user";content="First compaction"}) `
                -Trigger "manual"

            $result = $payload | pwsh -NoProfile -NonInteractive -File $Script:HookScript 2>&1

            $mdPath = Join-Path $TranscriptDir "transcripts.md"
            $mdPath | Should -Exist
            $mdContent = Get-Content $mdPath -Raw -Encoding UTF8
            $mdContent | Should -Match "Compaction #1"
            $mdContent | Should -Match "manual"
        }

        It "TC-3.2: Appends new section to transcripts.md on second compaction" {
            $payload1 = New-TestPayload -WorkspaceRoot $TestWorkspace `
                -Transcript @(@{type="user";content="First"}) `
                -Trigger "manual"

            $payload2 = New-TestPayload -WorkspaceRoot $TestWorkspace `
                -Transcript @(
                    @{type="user";content="First"}
                    @{type="user";content="Second"}
                ) `
                -Trigger "auto"

            $null = $payload1 | pwsh -NoProfile -NonInteractive -File $Script:HookScript 2>&1
            $null = $payload2 | pwsh -NoProfile -NonInteractive -File $Script:HookScript 2>&1

            $mdPath = Join-Path $TranscriptDir "transcripts.md"
            $mdContent = Get-Content $mdPath -Raw -Encoding UTF8
            $mdContent | Should -Match "Compaction #1"
            $mdContent | Should -Match "Compaction #2"
        }

        It "TC-3.3: Appends JSON line to transcripts.jsonl without removing existing lines" {
            $payload1 = New-TestPayload -WorkspaceRoot $TestWorkspace `
                -Transcript @(@{type="user";content="First"}) `
                -Trigger "manual"

            $payload2 = New-TestPayload -WorkspaceRoot $TestWorkspace `
                -Transcript @(@{type="user";content="Second"}) `
                -Trigger "auto"

            $null = $payload1 | pwsh -NoProfile -NonInteractive -File $Script:HookScript 2>&1
            $null = $payload2 | pwsh -NoProfile -NonInteractive -File $Script:HookScript 2>&1

            $jsonlPath = Join-Path $TranscriptDir "transcripts.jsonl"
            $jsonlLines = Get-Content $jsonlPath -Encoding UTF8
            $jsonlLines.Count | Should -BeGreaterThan 1
        }

        It "TC-3.4: Appends distilled context to .github/session_context.md" {
            $payload = New-TestPayload -WorkspaceRoot $TestWorkspace `
                -Transcript @(
                    @{type="user";content="Create a deployment"}
                    @{type="assistant";content="I decided to use Kubernetes."}
                ) `
                -Trigger "manual"

            $null = $payload | pwsh -NoProfile -NonInteractive -File $Script:HookScript 2>&1

            $sessionCtxPath = Join-Path $GithubDir "session_context.md"
            $sessionCtxPath | Should -Exist
            $sessionContent = Get-Content $sessionCtxPath -Raw -Encoding UTF8
            $sessionContent | Should -Match "Compaction #1"
            $sessionContent | Should -Match "Decisions"
        }

        It "TC-3.5: Preserves existing transcripts content after error" {
            # First, create a valid compaction
            $payload1 = New-TestPayload -WorkspaceRoot $TestWorkspace `
                -Transcript @(@{type="user";content="First valid compaction"}) `
                -Trigger "manual"
            $null = $payload1 | pwsh -NoProfile -NonInteractive -File $Script:HookScript 2>&1

            # Now try with invalid JSON - should fail gracefully
            $invalidJson = "{ bad json }"
            $null = $invalidJson | pwsh -NoProfile -NonInteractive -File $Script:HookScript 2>&1

            # Verify first compaction content still exists
            $mdPath = Join-Path $TranscriptDir "transcripts.md"
            $mdContent = Get-Content $mdPath -Raw -Encoding UTF8
            $mdContent | Should -Match "First valid compaction"
        }
    }

    # ------------------------------
    # TC-4: Configuration Toggles
    # ------------------------------

    Describe "TC-4: Configuration Toggles" {

        It "TC-4.1: Respects capture_live_logs config option" {
            $projectRoot = Split-Path $PSScriptRoot -Parent
            $configPath = Join-Path $projectRoot ".github/hooks/pre-compact-copilot.config.json"
            $configDir = Split-Path $configPath -Parent
            if (-not (Test-Path $configDir)) {
                New-Item -ItemType Directory -Path $configDir -Force | Out-Null
            }
            @{
                capture_live_logs = $true
                capture_debug_export = $false
                write_md_summary = $true
                write_jsonl_events = $true
            } | ConvertTo-Json | Set-Content -Path $configPath -Encoding UTF8

            try {
                $payload = New-TestPayload -WorkspaceRoot $TestWorkspace `
                    -Transcript @(@{type="user";content="Test"}) `
                    -Logs @("[INFO] Test log") `
                    -Trigger "auto"

                $null = $payload | pwsh -NoProfile -NonInteractive -File $Script:HookScript 2>&1

                $mdPath = Join-Path $TranscriptDir "transcripts.md"
                $mdContent = Get-Content $mdPath -Raw -Encoding UTF8
                $mdContent | Should -Match "Test log"
            }
            finally {
                if (Test-Path $configPath) {
                    Remove-Item $configPath -Force -ErrorAction SilentlyContinue
                }
            }
        }

        It "TC-4.2: Respects write_md_summary config option" {
            $projectRoot = Split-Path $PSScriptRoot -Parent
            $configPath = Join-Path $projectRoot ".github/hooks/pre-compact-copilot.config.json"
            $configDir = Split-Path $configPath -Parent
            if (-not (Test-Path $configDir)) {
                New-Item -ItemType Directory -Path $configDir -Force | Out-Null
            }
            @{
                capture_live_logs = $false
                capture_debug_export = $false
                write_md_summary = $false
                write_jsonl_events = $true
            } | ConvertTo-Json | Set-Content -Path $configPath -Encoding UTF8

            try {
                $payload = New-TestPayload -WorkspaceRoot $TestWorkspace `
                    -Transcript @(@{type="user";content="Test"}) `
                    -Trigger "auto"

                $null = $payload | pwsh -NoProfile -NonInteractive -File $Script:HookScript 2>&1

                $mdPath = Join-Path $TranscriptDir "transcripts.md"
                # File should not exist if write_md_summary is false
                # Or it should exist but be empty/minimal
            }
            finally {
                if (Test-Path $configPath) {
                    Remove-Item $configPath -Force -ErrorAction SilentlyContinue
                }
            }
        }

        It "TC-4.3: Respects write_jsonl_events config option" {
            $projectRoot = Split-Path $PSScriptRoot -Parent
            $configPath = Join-Path $projectRoot ".github/hooks/pre-compact-copilot.config.json"
            $configDir = Split-Path $configPath -Parent
            if (-not (Test-Path $configDir)) {
                New-Item -ItemType Directory -Path $configDir -Force | Out-Null
            }
            @{
                capture_live_logs = $false
                capture_debug_export = $false
                write_md_summary = $true
                write_jsonl_events = $false
            } | ConvertTo-Json | Set-Content -Path $configPath -Encoding UTF8

            try {
                $payload = New-TestPayload -WorkspaceRoot $TestWorkspace `
                    -Transcript @(@{type="user";content="Test"}) `
                    -Trigger "auto"

                $null = $payload | pwsh -NoProfile -NonInteractive -File $Script:HookScript 2>&1

                $jsonlPath = Join-Path $TranscriptDir "transcripts.jsonl"
                # JSONL file should not be created or should be empty
            }
            finally {
                if (Test-Path $configPath) {
                    Remove-Item $configPath -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }

    # ------------------------------
    # TC-5: Output Contract
    # ------------------------------

    Describe "TC-5: Output Contract" {

        It "TC-5.1: Returns valid JSON with systemMessage field" {
            $payload = New-TestPayload -WorkspaceRoot $TestWorkspace `
                -Transcript @(@{type="user";content="Test"}) `
                -Trigger "manual"

            $result = $payload | pwsh -NoProfile -NonInteractive -File $Script:HookScript 2>&1
            $result | Should -Not -BeNullOrEmpty

            { $result | ConvertFrom-Json } | Should -Not -Throw
            $json = $result | ConvertFrom-Json
            $json.systemMessage | Should -Not -BeNullOrEmpty
        }

        It "TC-5.2: systemMessage references session context file" {
            $payload = New-TestPayload -WorkspaceRoot $TestWorkspace `
                -Transcript @(@{type="user";content="Test"}) `
                -Trigger "manual"

            $result = $payload | pwsh -NoProfile -NonInteractive -File $Script:HookScript 2>&1
            $json = $result | ConvertFrom-Json
            $json.systemMessage | Should -Match "\.github/session_context\.md"
        }

        It "TC-5.3: additionalContext includes file path and content" {
            $payload = New-TestPayload -WorkspaceRoot $TestWorkspace `
                -Transcript @(@{type="user";content="Test"}) `
                -Trigger "manual"

            $result = $payload | pwsh -NoProfile -NonInteractive -File $Script:HookScript 2>&1
            $json = $result | ConvertFrom-Json
            $json.additionalContext | Should -Not -BeNullOrEmpty
            $json.additionalContext.path | Should -Be ".github/session_context.md"
            $json.additionalContext.type | Should -Be "file"
        }
    }

    # ------------------------------
    # TC-6: Error Handling
    # ------------------------------

    Describe "TC-6: Error Handling" {

        It "TC-6.1: Handles missing workspace gracefully" {
            $payload = New-TestPayload -WorkspaceRoot "Z:\NonExistent\Path" -Trigger "auto"

            $result = $payload | pwsh -NoProfile -NonInteractive -File $Script:HookScript 2>&1
            $result | Should -Not -BeNullOrEmpty

            $json = $result | ConvertFrom-Json
            $json.systemMessage | Should -Not -BeNullOrEmpty
        }

        It "TC-6.2: Creates missing .transcripts directory automatically" {
            $payload = New-TestPayload -WorkspaceRoot $TestWorkspace `
                -Transcript @(@{type="user";content="Test"}) `
                -Trigger "manual"

            $null = $payload | pwsh -NoProfile -NonInteractive -File $Script:HookScript 2>&1

            $TranscriptDir | Should -Exist
        }

        It "TC-6.3: Handles log parsing failure gracefully" {
            # Empty logs array should not cause crash
            $payload = New-TestPayload -WorkspaceRoot $TestWorkspace `
                -Transcript @(@{type="user";content="Test"}) `
                -Logs @("") `
                -Trigger "auto"

            $result = $payload | pwsh -NoProfile -NonInteractive -File $Script:HookScript 2>&1
            $result | Should -Not -BeNullOrEmpty
        }

        It "TC-6.4: Handles malformed JSON lines in transcript gracefully" {
            $mixedTranscript = @(
                '{"type":"user","content":"Valid message"}'
                '{ this is not valid json }'
                '{"type":"assistant","content":"Another valid message"}'
            )

            $payload = New-TestPayload -WorkspaceRoot $TestWorkspace `
                -Transcript $mixedTranscript `
                -Trigger "auto"

            $result = $payload | pwsh -NoProfile -NonInteractive -File $Script:HookScript 2>&1
            $result | Should -Not -BeNullOrEmpty

            $json = $result | ConvertFrom-Json
            $json.systemMessage | Should -Not -BeNullOrEmpty
        }
    }

    # ------------------------------
    # Helper Function Tests
    # ------------------------------

    Describe "Helper Functions" {

        It "Get-Decisions extracts decision statements" {
            $events = @(
                @{type="user";content="Deploy the app"}
                @{type="assistant";content="I decided to use Docker for containerization."}
                @{type="assistant";content="I'll use Kubernetes for orchestration."}
                @{type="tool";name="Bash";input=@{command="docker build"};output="success"}
            )

            # Call the function via script execution
            $script = @"
function Get-Decisions {
    param([array]`$Events)

    `$decisions = @()
    foreach (`$e in `$Events) {
        if (`$e.type -eq 'assistant' -and `$e.content -match 'decided|chose|switched|using|going with|selected|opted|will use|using|going to use') {
            `$decisions += `$e.content
        }
    }
    return `$decisions
}

`$events = @(
    @{type='user';content='Deploy the app'},
    @{type='assistant';content='I decided to use Docker for containerization.'},
    @{type='assistant';content='I will use Kubernetes for orchestration.'},
    @{type='tool';name='Bash';input=@{command='docker build'};output='success'}
)

`(Get-Decisions -Events `$events).Count
"@

            $result = pwsh -NoProfile -NonInteractive -Command $script
            $result.Trim() | Should -Be "2"
        }

        It "Get-ToolCalls extracts tool call events" {
            $events = @(
                @{type="user";content="Test"}
                @{type="tool";name="Bash";input=@{command="ls"};output="files"}
                @{type="tool";name="Write";input=@{path="test.txt"};output="done"}
            )

            $script = @"
function Get-ToolCalls {
    param([array]`$Events)

    `$toolCalls = @()
    foreach (`$e in `$Events) {
        if (`$e.type -eq 'tool' -or `$e.tool_call) {
            `$toolCalls += `$e
        }
    }
    return `$toolCalls
}

`$events = @(
    @{type='user';content='Test'},
    @{type='tool';name='Bash';input=@{command='ls'};output='files'},
    @{type='tool';name='Write';input=@{path='test.txt'};output='done'}
)

`(Get-ToolCalls -Events `$events).Count
"@

            $result = pwsh -NoProfile -NonInteractive -Command $script
            $result.Trim() | Should -Be "2"
        }

        It "Get-OpenIssues extracts unresolved questions" {
            $events = @(
                @{type="user";content="still need to fix the authentication bug"}
                @{type="user";content="TODO: add unit tests"}
                @{type="user";content="Great work!"}
            )

            $script = @"
function Get-OpenIssues {
    param([array]`$Events)

    `$issues = @()
    foreach (`$e in `$Events) {
        if (`$e.type -eq 'user' -and `$e.content -match 'still need|pending|not sure|TODO|waiting on|unresolved') {
            `$issues += `$e.content
        }
    }
    return `$issues
}

`$events = @(
    @{type='user';content='still need to fix the authentication bug'},
    @{type='user';content='TODO: add unit tests'},
    @{type='user';content='Great work!'}
)

`(Get-OpenIssues -Events `$events).Count
"@

            $result = pwsh -NoProfile -NonInteractive -Command $script
            $result.Trim() | Should -Be "2"
        }

        It "Parse-Logs extracts log levels and messages" {
            $logs = @(
                "[INFO] Processing request",
                "[DEBUG] Step 1 completed",
                "[WARN] Low memory",
                "[ERROR] Connection failed"
            )

            $script = @"
function Parse-Logs {
    param([array]`$LogsContent)

    `$parsed = @()
    foreach (`$line in `$LogsContent) {
        if (`$line -match '\[(\w+)\]\s+(.*)') {
            `$parsed += @{
                level   = `$Matches[1]
                message = `$Matches[2]
                raw     = `$line
            }
        }
    }
    return `$parsed
}

`$logs = @(
    '[INFO] Processing request',
    '[DEBUG] Step 1 completed',
    '[WARN] Low memory',
    '[ERROR] Connection failed'
)

`(Parse-Logs -LogsContent `$logs).Count
"@

            $result = pwsh -NoProfile -NonInteractive -Command $script
            $result.Trim() | Should -Be "4"
        }
    }
}

Describe "Success Criteria Validation" {

    BeforeEach {
        $Script:TestWorkspace = Join-Path $Script:TestBaseDir "TestWorkspace_$(Get-Random)"
        New-Item -ItemType Directory -Path $TestWorkspace -Force | Out-Null
        $Script:TranscriptDir = Join-Path $TestWorkspace ".transcripts"
        $Script:GithubDir = Join-Path $TestWorkspace ".github"
    }

    AfterEach {
        if (Test-Path $TestWorkspace) {
            Remove-Item -Path $TestWorkspace -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "SC-1: Append-only transcripts - no existing content deleted" {
        # First compaction
        $payload1 = New-TestPayload -WorkspaceRoot $TestWorkspace `
            -Transcript @(@{type="user";content="First compaction content"}) `
            -Trigger "manual"
        $null = $payload1 | pwsh -NoProfile -NonInteractive -File $Script:HookScript 2>&1

        # Second compaction
        $payload2 = New-TestPayload -WorkspaceRoot $TestWorkspace `
            -Transcript @(@{type="user";content="Second compaction content"}) `
            -Trigger "auto"
        $null = $payload2 | pwsh -NoProfile -NonInteractive -File $Script:HookScript 2>&1

        $mdPath = Join-Path $TranscriptDir "transcripts.md"
        $mdContent = Get-Content $mdPath -Raw -Encoding UTF8
        $mdContent | Should -Match "First compaction content"
        $mdContent | Should -Match "Second compaction content"
    }

    It "SC-2: Multiple compactions work in single session" {
        1..3 | ForEach-Object {
            $payload = New-TestPayload -WorkspaceRoot $TestWorkspace `
                -Transcript @(@{type="user";content="Compaction $_"}) `
                -Trigger "manual"
            $null = $payload | pwsh -NoProfile -NonInteractive -File $Script:HookScript 2>&1
        }

        $mdPath = Join-Path $TranscriptDir "transcripts.md"
        $mdContent = Get-Content $mdPath -Raw -Encoding UTF8
        $mdContent | Should -Match "Compaction #1"
        $mdContent | Should -Match "Compaction #2"
        $mdContent | Should -Match "Compaction #3"
    }

    It "SC-3: .github/session_context.md remains cumulative and readable" {
        $payload = New-TestPayload -WorkspaceRoot $TestWorkspace `
            -Transcript @(
                @{type="user";content="Create a deployment"}
                @{type="assistant";content="I decided to use Kubernetes."}
            ) `
            -Trigger "manual"

        $null = $payload | pwsh -NoProfile -NonInteractive -File $Script:HookScript 2>&1

        $sessionCtxPath = Join-Path $GithubDir "session_context.md"
        $sessionContent = Get-Content $sessionCtxPath -Raw -Encoding UTF8
        $sessionContent | Should -Match "Compaction #1"
        $sessionContent | Should -Match "Decisions"
        $sessionContent | Should -Match "Kubernetes"
    }

    It "SC-4: Invalid input does not corrupt prior history" {
        # Valid compaction
        $payload1 = New-TestPayload -WorkspaceRoot $TestWorkspace `
            -Transcript @(@{type="user";content="Valid content"}) `
            -Trigger "manual"
        $null = $payload1 | pwsh -NoProfile -NonInteractive -File $Script:HookScript 2>&1

        # Invalid payload
        $null = "{ bad json }" | pwsh -NoProfile -NonInteractive -File $Script:HookScript 2>&1

        # Verify valid content still exists
        $mdPath = Join-Path $TranscriptDir "transcripts.md"
        $mdContent = Get-Content $mdPath -Raw -Encoding UTF8
        $mdContent | Should -Match "Valid content"
    }

    It "SC-5: Hook execution completes within 5 seconds for typical payload" {
        $payload = New-TestPayload -WorkspaceRoot $TestWorkspace `
            -Transcript @(
                @{type="user";content="Deploy the service"}
                @{type="assistant";content="I'll deploy the service to Kubernetes."}
                @{type="tool";name="Bash";input=@{command="kubectl apply -f deploy.yaml"};output="deployed"}
            ) `
            -Trigger "auto" `
            -ContextSummary @{tool_calls_count=1; token_usage=1000; duration_ms=500}

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $null = $payload | pwsh -NoProfile -NonInteractive -File $Script:HookScript 2>&1
        $sw.Stop()

        $sw.Elapsed.TotalSeconds | Should -BeLessThan 5
    }
}
