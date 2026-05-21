# Defense-in-depth: PostToolUse hook (optional)

The skill's dispatcher (`ssh.ps1` / `ssh.sh`) already logs every command + output. This hook adds a second, independent log line for any `ssh -S` invocation — useful if you don't fully trust Claude to use the dispatcher every time.

## What it does

After every `Bash` or `PowerShell` tool call whose command text contains `ssh -S`, the hook appends one line to `$TMP/ssh-claude-toolcalls.log` recording: timestamp, the command Claude ran, and the tool's exit code. You tail that file alongside the per-host log for full coverage.

## Setup

Add to `~/.claude/settings.json` (merge into existing `hooks` if you have one):

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Bash|PowerShell",
        "hooks": [
          {
            "type": "command",
            "command": "powershell -NoProfile -Command \"$ev = $input | ConvertFrom-Json; $cmd = $ev.tool_input.command; if ($cmd -match 'ssh\\s+(-\\w+\\s+)*-S\\s+') { $line = '[' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') + '] tool=' + $ev.tool_name + ' exit=' + $ev.tool_response.exit_code + ' cmd=' + $cmd; Add-Content -Path ($env:TEMP + '\\ssh-claude-toolcalls.log') -Value $line }\""
          }
        ]
      }
    ]
  }
}
```

POSIX equivalent (replace the `command` value):

```bash
sh -c 'jq -r "select(.tool_input.command|test(\"ssh +(-[a-zA-Z]+ +)*-S +\")) | \"[\\(now|strftime(\"%Y-%m-%d %H:%M:%S\"))] tool=\\(.tool_name) exit=\\(.tool_response.exit_code) cmd=\\(.tool_input.command)\"" >> /tmp/ssh-claude-toolcalls.log'
```

## Watching

```
# Windows
Get-Content -Wait -Tail 0 $env:TEMP\ssh-claude-toolcalls.log

# POSIX
tail -F /tmp/ssh-claude-toolcalls.log
```

## Why this is "defense in depth"

The dispatcher log (`ssh-<host>.log`) only captures calls that went through the dispatcher. If Claude accidentally calls `ssh -S <sock> host 'cmd'` directly (skipping the dispatcher), that call is invisible to the dispatcher log — but the hook catches it because the hook fires on the *harness's* tool-call boundary, which Claude cannot bypass.

For most users, the dispatcher log alone is sufficient. Enable the hook only if you've seen Claude bypass the dispatcher or you want an audit-grade record.
