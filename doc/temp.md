1. What gets saved in the .md files?

  The PreCompact hook fires before Claude's context window is compacted (truncated). At that point, the hook can read the full transcript file (transcript_path from stdin) — a .jsonl file containing every message, tool call, and
  result in the session.

  The hook would parse that transcript and extract the high-signal content that compaction is about to delete. The .md file would contain:

  Decisions & Actions

  - What decisions Claude made ("decided to use Terraform instead of Pulumi", "chose to add a Redis cache")
  - What files were modified and why ("rewrote infra/modules/vpc/main.tf to add NAT gateway")
  - Commands that had meaningful results (not ls output, but terraform plan showing changes, test results, error messages)
  - Questions the user answered ("user confirmed: deploy to staging, not prod")

  Open Issues & TODOs

  - Unresolved questions ("still need to figure out why pod restarts on node-3")
  - Pending tasks ("next: update the Route53 record after the load balancer is created")

  Key Discoveries
00
  - Bugs found and their root causes ("the timeout was caused by security group blocking port 443")
  - Infrastructure state ("current kubectl context is staging-eu-west, workspace: blue")

  Session Metadata

  - Compaction number, timestamp, token counts (before/after)
  - Trigger type: auto (Claude hit context limit) vs manual (user ran /compact)

  The hook does NOT save every line of conversation — that would defeat the purpose of compaction. It saves a distilled summary of what matters, formatted so Claude can quickly re-read it after compaction.

  ---
  2. Multiple compactions — one file or many?

  Good question. With multiple compactions (which is common in long sessions), a single cumulative file is better. Here's the structure:

  .claude/session_context.md

  # Session Context - Compaction Log

  ## Compaction #1 (auto, 2026-04-25 01:30)
  - Tokens: 142,000 → 45,000
  - Decisions: Switched from ECS to EKS for the new service
  - Modified files: infra/modules/eks/main.tf, k8s/service.yaml
  - Key discovery: The IAM role `eks-node-role` was missing the `AmazonEKS_CNI_Policy`
  - Open issue: Need to update the node group sizing before deploy
  - Commands: terraform plan showed 3 additions, 1 change

  ## Compaction #2 (auto, 2026-04-25 02:15)
  - Tokens: 138,000 → 42,000
  - Decisions: Increased node group min from 2 to 3, max from 5 to 10
  - Modified files: infra/modules/eks/node-group.tf
  - Resolved: IAM policy added, terraform plan now clean
  - Open issue: ArgoCD still not picking up the new Helm chart values
  - Commands: terraform apply completed successfully

  ## Compaction #3 (...)
  ...

  This way:
  - The hook appends a new section at each compaction
  - Claude can read the whole file to get the full history
  - The file doesn't grow unbounded — each section is already a compressed summary

  Alternatively, you could keep only the N most recent sections (e.g., last 3) to prevent the file from becoming too large.

  ---
  3. How are the saved .md files used?

  Two mechanisms work together:

  A. Hook injects it back to Claude automatically

  The PreCompact hook can return a systemMessage in its JSON output. After compaction completes, the hook (or a PostCompact hook) can output:

  {
    "systemMessage": "Here is a summary of what was compacted. Read .claude/session_context.md to restore important context."
  }

  Even better: the hook script reads the file and embeds the latest compaction section directly into the systemMessage, so Claude gets it in context without needing another tool call.

  B. SessionStart reloads it

  A SessionStart hook checks if .claude/session_context.md exists and reads it into the session:

  {
    "systemMessage": "Previous session context restored from .claude/session_context.md:\n<contents>"
  }

  This means if you close Claude and reopen it (crash, terminal close, next day), the context from multiple past compactions is still available. Claude knows what it was working on, what decisions were made, and what's still
  open.

  C. Claude reads it during the conversation

  In very long sessions, you can tell Claude: /read .claude/session_context.md to remind it of earlier decisions. Since the file is a human-readable markdown summary, you can also review it yourself to audit what Claude has been
  doing.

  ---
  Summary: The Full Lifecycle

  1. Session starts → SessionStart hook loads any existing context file
  2. Claude works normally → conversation accumulates
  3. Context limit reached → PreCompact hook fires
  4. Hook parses transcript → extracts decisions, findings, open items → writes to session_context.md
  5. Compaction happens → old messages summarized
  6. PostCompact / Stop hook → injects the saved context back to Claude
  7. Claude continues working with restored knowledge
  8. Steps 3-7 repeat on each compaction → new section appended
  9. Next day → SessionStart reads the full file, Claude knows where it left off