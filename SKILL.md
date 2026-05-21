---
name: ssh
description: Use when running multiple shell commands or file transfers over SSH to one remote host in a single session, when the user wants a persistent connection (no re-auth per command), and when the user wants to watch the SSH commands and output live in a separate terminal
---

# /ssh - Persistent SSH session with live log

## Overview

One SSH master connection per host, multiplexed channels for each command, structured per-host log file the user tails in real time. Built on OpenSSH's `ControlMaster`. SCP transfers reuse the same master.

The skill ships a single dispatcher per platform (`ssh.ps1` / `ssh.sh`) and an installer that drops a `claude-ssh` shim into the user's PATH. After install, you invoke everything as `claude-ssh <subcommand>` - no path required.

## When to use

- Multiple shell commands on one remote host within a session
- User wants real-time visibility (a tail window on the log)
- File uploads or downloads (the wrapper reuses the master - no second auth)
- Need clean per-command exit codes, separable stdout/stderr
- Multiple commands need to execute in parallel on the same connection

## When NOT to use

- A single one-off SSH command (just call `ssh <host> '<cmd>'` directly)
- Interactive remote programs (`vim`, `top`, REPLs) - they need a TTY; this skill uses one-shot exec channels
- Persistent CWD / env between commands - fresh shell per call (see "Fresh shell gotcha" below)

## CLI

After running the installer once, the dispatcher is on PATH as `claude-ssh`:

| Subcommand | Args | Purpose |
|---|---|---|
| `open`   | `<host>` | Open master (probes key/agent auth first) |
| `auth`   | `<host>` | Open master interactively (password / passkey). Designed for `!claude-ssh auth` |
| `call`   | `<host> <cmd...>` | Run one command via the master (aliases: `exec`, `run`, `sh`) |
| `put`    | `<host> <local> <remote>` | Upload via scp+master |
| `get`    | `<host> <remote> <local>` | Download via scp+master |
| `close`  | `<host>` | Close the master |
| `status` | - | List active masters with ALIVE/DEAD per host |
| `help`   | - | Show usage |

If `claude-ssh` isn't on PATH yet, run the installer once:
- Windows: `& "$HOME\.claude\skills\ssh\install.ps1"`
- POSIX:   `~/.claude/skills/ssh/install.sh`

If the installer hasn't run yet, fall back to the full path:
- Windows: `& "$HOME\.claude\skills\ssh\scripts\ssh.ps1" <subcommand> ...`
- POSIX:   `~/.claude/skills/ssh/scripts/ssh.sh <subcommand> ...`

## Critical: which ssh binary

**On Windows, do NOT use** `C:\Windows\System32\OpenSSH\ssh.exe`. Microsoft's port has broken `ControlMaster` ([Win32-OpenSSH#405](https://github.com/PowerShell/Win32-OpenSSH/issues/405), open since 2017). The dispatcher auto-detects in this order:
1. `$env:SSH_BIN` override
2. `%ProgramFiles%\Git\usr\bin\ssh.exe` (Git for Windows - recommended)
3. `%ProgramFiles(x86)%\Git\usr\bin\ssh.exe`
4. `%LOCALAPPDATA%\Programs\Git\usr\bin\ssh.exe`

On Linux/macOS, `ssh.sh` uses system `ssh`. On WSL, run inside WSL.

## Auth modes

`claude-ssh open` probes auth automatically with `BatchMode=yes` first.

| Mode | Probe | What happens |
|---|---|---|
| Key-based (RSA, ed25519, ed25519-sk) | ✅ passes | Master opens silently. Done. |
| `ssh-agent` / `gpg-agent` / Pageant | ✅ passes | Agent socket inherited. Silent open. |
| FIDO2 / passkey (sk-*, YubiKey, Touch ID, Windows Hello) | ❌ fails | Dispatcher prints `!claude-ssh auth <host>` instructions. |
| Password | ❌ fails | Same: `!claude-ssh auth <host>` instructions. |

### Handling exit code 4 (interactive auth needed)

When `claude-ssh open <host>` exits with code 4:

1. The dispatcher has ALREADY printed beginner-friendly steps. Relay them verbatim. Do not paraphrase.
2. The primary instruction tells the user to type `!claude-ssh auth <host>` here in Claude - Claude Code's `!` prefix runs that as a real shell command, ssh's password / hardware-key prompt appears inline.
3. Wait for the user to say "ready" / "I'm in" / "done".
4. When confirmed, run `claude-ssh open <host>` again. It detects the now-open master, reuses it, initializes the log, reports success.
5. If the user says "use one-shot mode", fall back to per-command `ssh <host> '<cmd>'` invocations.

## Workflow

1. **Open the master**
   ```
   claude-ssh open <host>
   ```

2. **Tell the user the tail command** verbatim (the dispatcher prints it):
   - PowerShell: `Get-Content -Wait -Tail 0 "$env:TEMP\ssh-<host>.log"`
   - POSIX: `tail -F /tmp/ssh-<host>.log`

3. **Run every command** through `claude-ssh call`. The dispatcher streams output line-by-line to both your stdout and the log file, prepends `[timestamp] >>> <cmd>`, appends `[timestamp] <<< exit=N`, filters the cosmetic MSYS2 mux warning.

4. **Transfer files** with `claude-ssh put` / `claude-ssh get`.

5. **Long-running commands:** invoke via `run_in_background`. The log keeps streaming.

6. **Parallel commands:** dispatch multiple `call` invocations in one message.

7. **Close the master** when done:
   ```
   claude-ssh close <host>
   ```
   `ControlPersist=600` auto-reaps after 10 min idle if you forget.

## Quick reference

```
claude-ssh open    <host>
claude-ssh auth    <host>                    # interactive; works under Claude Code's !
claude-ssh call    <host> '<remote cmd>'
claude-ssh put     <host> <local> <remote>
claude-ssh get     <host> <remote> <local>
claude-ssh close   <host>
claude-ssh status
```

## Fresh shell per command (the main gotcha)

Each `call` spawns a brand-new remote shell. `cd /tmp` in call A does NOT persist to call B. Workarounds:
```
claude-ssh call <host> 'cd /tmp && ls -la'

$remoteCwd = '/var/log'
claude-ssh call <host> "cd $remoteCwd && tail -n 20 syslog"
```

## Hard rules

| Rule | Why |
|---|---|
| Never modify `~/.ssh/config` to add `ControlMaster`, `ControlPath`, `ServerAliveInterval`, etc. | User's config is theirs. Pass options via `-o` flags in the dispatcher only. |
| Never call raw `ssh -S <sock> ...` or `scp ...` outside the dispatcher | The log loses visibility for that call. |
| Never use Windows-native `C:\Windows\System32\OpenSSH\ssh.exe` | Mux is broken. |
| Never suppress all stderr with `2>$null` | Hides real errors. Dispatcher filters only the specific cosmetic line. |
| Never pivot to a stdin-streaming driver if `ControlMaster` appears to fail | Almost always a wrong-binary problem. |

## Common mistakes

| Mistake | Symptom | Fix |
|---|---|---|
| Forgot to open before calling | `call` errors "No live SSH master for '<host>'" | Run `claude-ssh open <host>` first |
| Called `ssh`/`scp` directly | Log shows nothing for that call | Always go through `claude-ssh` |
| Picked native Windows ssh.exe | `getsockname failed: Not a socket` | Install Git for Windows |
| Chained `cd` expecting persistence | Next command's `pwd` is `$HOME` | Chain with `&&` or track CWD client-side |
| Added own `2>&1` in PowerShell call site | `NativeCommandError` records | Dispatcher handles stderr separately |
| Password auth without interactive UX | Master fails to open | Instruct user with `!claude-ssh auth <host>` |

## Defense in depth (opt-in)

For "log every SSH call even if the dispatcher is bypassed," add the `PostToolUse` hook in `hook-config.md`. Not required.

## Files

```
SKILL.md, GUIDE.md, README.md, INSTALL.md, LICENSE, hook-config.md, .gitignore
install.ps1   (Windows installer - adds claude-ssh to PATH)
install.sh    (POSIX installer)
scripts/
  ssh.ps1     (Windows dispatcher; all subcommands inline)
  ssh.sh      (POSIX dispatcher)
```
