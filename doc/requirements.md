we will implement the precompact hook for the AI assisted development.
note,  the precompact hook is not a claude code only feature.  copilot also supports it.
do a online search for the different hook implement API between claude code and github copilot

basically, before the /compact event starts,  we will invoke the hook to save all the context that maintained by the editor (claude code or copilot),  

do the online research  to see what are the best practice for precompact hook event.  what is best to be saved.
if any system/editor (cc or copilot) maintained context can be saved?  or any running chat, commands history...

due to the api difference, we will implement both versions of hook, one hook for Claude Code named: pre-compact-cc.ps1, and the other is for VSCode copilot - pre-compact-copilot.ps1. 

discuss with me the options. write down all the research findings, archetect decisions we chose, and code plans into the file: plan.md,   so the other coding agent can use the file and begin to code.

and how do we test the hook,  write down the test plan to: test-plan.md

we will start for copilot version first.






 Implementation Approach;  I don't think the internal implemenaton for Claude code and copilot are same,  like the maintained context to be directly write to the file.  etc.   you need do more research one that.
so yes,  Create separate PowerShell scripts for each platform (as originally planned)

Context File Location
Claude Code uses .claude/session_context.md. 
For VS Code Copilot: use .github/session_context.md to match the hook file location

Platform Detection
How should the script detect which platform it's running on?   either script will be registered by the Claude code or the copilot's setting file, right?  so, the scripts do not need to know which platform it is running on.   they will be invoked by the hook of the editor's setting/config file.

Transcript Access
I am thinking we need two file types,  one is named "trascript.md"  and one "transcripts.jsonl" 
the "trascript.md" holds human readable contexts.  and the "transcripts.jsonl" is for Claude Code or Copilot to use, in case it exited unexpectly,  they can read this "transcripts.jsonl"  to get all the previous context.   also, for the "transcripts.jsonl" Transcript format can be same or different, either way,  as long as Claude Code and VS Code Copilot can natively write and read information from it
by the way. always check if a subdirectory named ".transcripts" directly under the project folder, create it if not. 
Path formats  - relative

 Hook Configuration
we definitly need Separate hook configuration files for each platform?  create the instructions about how to config/install them in the final  README.md

6. Testing Strategy
Since both platforms support hooks, Start with one platform and add the other later

7. Error Handling
Are there platform-specific error conditions we need to handle differently?   yes


do more research what run tim context that CC and Copilot maintains.   if exist,  it may alredy be summerized, with good quality and we probably can directly save them


====
Claude Code Transcript Format: Does the transcript.jsonl file already contain summarized/structured decision data, 
Yes,  consider the file already has previous summerized context, in a long chat, the /compact (summerize) can be already run multiple times. so each time this file will be added with more information.  so,  never delete anything in this file, append only.  


VS Code Agent Logs Export: Since VS Code Agent Debug Logs can be exported as OTLP JSON:

Should we capture this export in PreCompact and save it? Yes, you can. 
and, if the live logs contains important information, we will also parse the live logs during hook execution and save to the transcript.md, for human readable format.  make it a configurable option, we will test this,  to see how many of this logs, if too many, we can turn it off the write to the transcript.md file.
Yes, the PreCompact hook access the debug logs and the raw transcript,  again, depend on how much debug log it will write, make it a configurable option to turn off the log to the transcript.jsonl file.



Cross-Platform Transcript Format:

both platforms' transcripts in compatible JSON formats is fine. 
Should transcripts.jsonl unified
the "transcript_path" is the ".transcripts\" subdirectory under the project path. it has two files 
transcripts.md  <-- human readable context, could be pre-exist from previous compact.
transcripts.jsonl <-- the debug info, tool call logs. in big quantity
note the two files can have overlap information,  the main idea for the .md file is for human read. the jsonl file is for CC or Copilot to read.

For Claude Code and For VS Code Copilot, the "transcript_path" is the ".transcripts\" subdirectory under the project path.

Pre-summarized Context:
Does VS Code's summary view (tool calls count, token usage, duration) come pre-calculated?   not sure,  you need find out what command can get these info, 
Can the PreCompact hook directly access this summary data to avoid re-parsing?  if there is a way, then yes, again do your research to see if it is available. 