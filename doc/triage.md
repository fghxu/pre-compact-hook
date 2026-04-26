# Triage: `.transcripts/*` files never created after `/compact`

**Date:** 2026-04-26
**Reporter:** project owner ran `/compact` in both VS Code Copilot Chat and
Copilot CLI, and observed that no files were appended under `.transcripts/` or
`.github/session_context.md`.
**Question put to triage:** is this a bug in GitHub Copilot (PreCompact hooks
not fully rolled out yet) or in our code (e.g. wrong stdin parsing)?

---

## TL;DR

The hook script (`pre-compact-copilot.ps1`) is **not at fault** — it works
correctly when piped a real payload. The problem is the **hook configuration
file** (`.github/hooks/pre-compact-copilot.json`) uses a non-existent schema, so
both Copilot CLI and VS Code Copilot Chat silently skip it at load time. The
`/compact` command runs, but no hook is registered on the `PreCompact` event.

Three issues were found and fixed:
1. Hook JSON used a made-up `"powershell"` property instead of the required
   `"command"` / `"windows"` properties.
2. Hook JSON used `"cwd": "${workspaceFolder}"`; that variable is a VS Code
   **tasks/launch** token and is **not** expanded by the hooks runtime.
3. The script only looked for `workspaceRoot` in the payload, but the real
   Copilot payload sends `cwd`. Also `trigger` was never populated because
   the real payload sends `hookEventName`.

---

## Triage steps

### 1. Confirm the hook script itself works

Simulated the real Copilot payload from a PowerShell session:

```powershell
$payload = @{
  timestamp       = "2026-04-26T13:45:00.000Z"
  cwd             = "C:\git\claudecode\pre-compact-hook"
  sessionId       = "test-session-123"
  hookEventName   = "PreCompact"
  transcript_path = ""
} | ConvertTo-Json -Compress

$payload | pwsh -NoProfile -NonInteractive -File .\pre-compact-copilot.ps1
```

**Result:** exit 0, valid JSON written to stdout, and the expected files were
created:

```
.transcripts\transcripts.jsonl
.transcripts\transcripts.md
.github\session_context.md
```

**Conclusion:** the script is reachable and correct. If it were being invoked
by Copilot, the files would appear. Therefore the script is **not being
invoked at all**.

### 2. Look up the authoritative hook spec

I went to primary sources rather than guessing:

| Source | Finding |
|---|---|
| [`code.visualstudio.com/docs/copilot/customization/hooks`](https://code.visualstudio.com/docs/copilot/customization/hooks) | Official VS Code hook schema. The only recognized command properties are `type: "command"` + `command` (default) + optional OS overrides `windows` / `linux` / `osx`. Property `"powershell"` does not exist. |
| VS Code docs (same page) | *"VS Code uses the same hook format as Claude Code and Copilot CLI for compatibility."* So the same JSON works for both editors. |
| `github/copilot-cli` repo, `changelog.md` — version **1.0.5** | *"Add preCompact hook to run commands before context compaction starts"* — PreCompact in Copilot CLI is only a few weeks old. |
| `github/copilot-cli` issue **#1138** (closed 2026-04-07) | Feature request that added PreCompact — confirms PreCompact is the official event name with a capital P (matches VS Code spec). |
| `github/copilot-cli` issue **#2875** (closed 2026-04-21) | User-level `~/.copilot/hooks` was added very recently. |
| Auto-discovery paths (VS Code docs) | `.github/hooks/*.json` **(workspace)**, `.claude/settings.json`, `.claude/settings.local.json`, `~/.copilot/hooks`, `~/.claude/settings.json` |

### 3. Compare our config against the spec

Our file:

```jsonc
{
  "hooks": {
    "PreCompact": [
      {
        "type": "command",
        "powershell": "pwsh -NoProfile -NonInteractive -File \"${workspaceFolder}\\pre-compact-copilot.ps1\"",
        "cwd": "${workspaceFolder}",
        "timeout": 30
      }
    ]
  }
}
```

Problems, from most to least severe:

| # | Issue | What the spec says |
|---|---|---|
| 1 | Property is `"powershell"` — **there is no `command` field**. Hook fails schema validation, is silently skipped. | `type: "command"` and `command` (or OS-specific `windows`/`linux`/`osx`) are both required. |
| 2 | `"cwd": "${workspaceFolder}"` | `${workspaceFolder}` is a VS Code *tasks/launch* variable; the hooks runtime does **not** expand it. `cwd` must be a plain path, or be omitted (in which case the hook runs in the workspace root, which is what we want). |
| 3 | No `windows`/`linux`/`osx` overrides | Not blocking, but helpful for cross-platform use once the config is valid. |

### 4. Compare our script's payload parsing against the spec

The real payload shape (from the VS Code hooks page):

```json
{
  "timestamp": "2026-02-09T10:30:00.000Z",
  "cwd": "/path/to/workspace",
  "sessionId": "session-identifier",
  "hookEventName": "PreCompact",
  "transcript_path": "/path/to/transcript.json"
}
```

Our script only looked for `$payload.workspaceRoot` (our own test convention)
and `$payload.trigger` (also our own). Neither field exists in a real payload.
So even if the hook had registered, it would have fallen back to the fallback
path (`$PWD`) and to `trigger = "unknown"`. That's not broken per se, but it
was going to produce poor output once the config was fixed.

### 5. Why the original "tests passed" didn't catch any of this

The Pester suite feeds the script payloads built by the test helper
`New-TestPayload`, which uses *our* internal shape (`workspaceRoot`,
`trigger`). The tests verify the script's internal behaviour, but they
cannot catch:
- Wrong hook-config schema (the config file is never loaded by tests).
- The mismatch between our test payload shape and the real Copilot payload
  shape (no test actually exercised the spec's field names).

---

## Findings

1. **Hook was never registered.** The `.github/hooks/pre-compact-copilot.json`
   config file uses a `"powershell"` property that does not exist in the
   Copilot / VS Code hooks schema, and a `${workspaceFolder}` token that is
   never expanded by the hooks runtime. Both Copilot CLI and VS Code Copilot
   Chat silently skip hooks whose command fields are invalid, so no error
   surfaces to the user — the hook simply does nothing.

2. **Script payload parsing diverges from the real spec.** The real payload
   uses `cwd` and `hookEventName`; our script only recognized our own
   test-only fields `workspaceRoot` and `trigger`.

3. **Not a GitHub Copilot bug.** PreCompact is shipped in Copilot CLI 1.0.5+
   (late March 2026), and it's documented as Preview in VS Code. The feature
   works; we were just holding it wrong.

---

## Fixes

### Fix 1 — `.github/hooks/pre-compact-copilot.json`

Replaced the invalid schema with the official one. Added `windows`
override so the command parses identically on Windows regardless of which
shell is parsing the JSON string.

```json
{
  "hooks": {
    "PreCompact": [
      {
        "type": "command",
        "command": "pwsh -NoProfile -NonInteractive -File ./pre-compact-copilot.ps1",
        "windows": "pwsh -NoProfile -NonInteractive -File .\\pre-compact-copilot.ps1",
        "timeout": 30
      }
    ]
  }
}
```

Notes:
- No `cwd` — hooks run in the workspace root by default, which is what we want.
- Relative path `./pre-compact-copilot.ps1` is resolved from the workspace
  root, keeping the config portable across checkouts.

### Fix 2 — `pre-compact-copilot.ps1`

Two small, backward-compatible changes.

**Workspace root resolution now prefers the spec's `cwd`:**

```powershell
$workspaceRoot = $null
if ($payload.cwd -and (Test-Path $payload.cwd)) {
    $workspaceRoot = $payload.cwd
} elseif ($payload.workspaceRoot -and (Test-Path $payload.workspaceRoot)) {
    $workspaceRoot = $payload.workspaceRoot
} else {
    $workspaceRoot = $PWD.Path
}
```

**Trigger falls back to `hookEventName` when the test-only `trigger` field is
absent:**

```powershell
$trigger = if ($payload.trigger) {
    $payload.trigger
} elseif ($payload.hookEventName) {
    $payload.hookEventName
} else {
    "unknown"
}
```

The existing test payloads still use `workspaceRoot` / `trigger`, so all
existing tests continue to pass; real Copilot payloads now work natively.

### Fix 3 — `README.md`

Updated the installation, version requirements, and verification sections to
reflect the real spec. See README for details.

---

## How to verify the fix end-to-end

### In Copilot CLI

1. Check version: `copilot` → `/version`. Must be **≥ 1.0.5** (PreCompact was
   added in that release).
2. Start a session in this repo, do a couple of turns, then run `/compact`.
3. Check the files:
   ```powershell
   Get-ChildItem .transcripts
   Get-Content .github\session_context.md -Tail 40
   ```
   A new `## Compaction #N (PreCompact, ...)` block should appear in
   `transcripts.md` and `session_context.md`.
4. You can also inspect hook loading via `/env` in the CLI.

### In VS Code Copilot Chat

1. Agent hooks are **Preview** — ensure VS Code is recent (Insiders recommended
   until GA). If your org has disabled hooks, contact the admin.
2. Open the **Output** panel → channel **"GitHub Copilot Chat Hooks"**. When
   the hook loads you should see a line referencing
   `.github/hooks/pre-compact-copilot.json`.
3. Run `/compact` in Copilot Chat and inspect the same files as above.

### Quick smoke test from the shell

This simulates what Copilot does and does not depend on any IDE state:

```powershell
$payload = @{
  timestamp       = (Get-Date -Format o)
  cwd             = (Resolve-Path .).Path
  sessionId       = "smoke-test"
  hookEventName   = "PreCompact"
  transcript_path = ""
} | ConvertTo-Json -Compress

$payload | pwsh -NoProfile -NonInteractive -File .\pre-compact-copilot.ps1
```

Expected: exit 0, JSON on stdout, files appended in `.transcripts\` and
`.github\session_context.md`.

---

## Suggested follow-ups (not done in this pass)

- Add a Pester test that feeds the script a payload using the **real** spec
  fields (`cwd`, `hookEventName`) so this class of regression is caught in CI.
- Add a JSON-schema file for `pre-compact-copilot.json` and validate it in CI,
  so a future typo in the hook config is caught before shipping.
- When the user-level `~/.copilot/hooks` rollout stabilises (Copilot CLI issue
  #2875), document that install path in the README as an alternative to the
  workspace-level config.
