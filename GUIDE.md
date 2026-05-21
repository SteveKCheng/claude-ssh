# `/ssh` - User Guide

Run multiple commands on a remote host through one persistent SSH connection, while you watch every command and its output live in another terminal. With file transfer.

After installation, you have a `claude-ssh` command on PATH. Claude uses it; so can you.

---

## TL;DR

```
You (in Claude):   /ssh   (or "open an ssh session to <host>")
You (other PS):    Get-Content -Wait -Tail 0 $env:TEMP\ssh-<host>.log
Now ask Claude anything - every remote command + output appears live in your tail window.
When done:         "close the ssh session"  (or wait 10 min for auto-reap)
```

Replace `<host>` with your SSH alias (`prod-db`, `staging`, `homelab`, etc.).

---

## What it does

Opens **one** SSH connection per host, runs all commands through it. You get:

1. **No re-auth per command.** First handshake ~600 ms; every command after reuses the connection.
2. **Live log file** at `$TMP/ssh-<host>.log`. Tail it, watch in real time.
3. **Clean per-command exit codes**, separate stdout/stderr.
4. **File transfer (`put`/`get`) reuses the same master** - no second auth.
5. **Parallel commands** on one TCP connection.
6. **`claude-ssh` command** on your PATH - call from any shell.

Under the hood, one dispatcher script per platform with subcommands:

```
claude-ssh open  <host>
claude-ssh auth  <host>     # interactive (for password/passkey)
claude-ssh call  <host> <cmd>
claude-ssh put   <host> <local> <remote>
claude-ssh get   <host> <remote> <local>
claude-ssh close <host>
claude-ssh status
claude-ssh help
```

You don't usually invoke these directly - Claude does. But `claude-ssh status` is handy to see what's open.

---

## Setup

One-time:

```powershell
# Windows
& "$HOME\.claude\skills\ssh\install.ps1"

# Linux / macOS
~/.claude/skills/ssh/install.sh
```

The installer drops a `claude-ssh` shim into `~/.local/bin/` and adds it to your PATH if needed. Restart your terminal after install (or follow the printed instructions to refresh PATH in the current session).

After that, see `INSTALL.md` for the optional allowlist that stops Claude from asking permission on every call.

---

## How to use

### 1. Trigger the skill

Any of these:
- `/ssh` (then describe what you want)
- "open an ssh session to prod-db"
- "ssh into homelab and check disk space"
- "upload this file to the server"
- "pull the latest log from the server"

### 2. Open a second terminal to watch

Claude prints the exact tail command:
```powershell
# Windows
Get-Content -Wait -Tail 0 "$env:TEMP\ssh-<host>.log"
```
```bash
# Linux / macOS
tail -F /tmp/ssh-<host>.log
```

Lines stream in as Claude runs each command.

### 3. Ask Claude to do things

Just talk normally:
- "show me disk usage on `/` and `/var`"
- "tail the last 50 lines of `/var/log/syslog`"
- "upload `./deploy.sh` to `/tmp/deploy.sh`"
- "pull `/var/log/nginx/access.log` from the server"
- "run `apt update && apt upgrade -y` in the background"

### 4. Close when done

- Say "close the ssh session"
- Or leave it - `ControlPersist=600` auto-reaps after 10 minutes idle

---

## Authentication

The dispatcher probes your auth automatically the first time. **You don't have to know which auth your server uses** - the skill figures it out.

### Key-based / agent auth (most common)

You don't have to do anything. Master opens silently, you get the tail command, ready to go.

### Password or hardware-key touch (FIDO2 / YubiKey / Touch ID / Windows Hello)

Claude prints clear step-by-step instructions:

```
===============================================================================
  ACTION NEEDED: 'myserver' wants you to log in interactively
===============================================================================

This server needs either a password OR a hardware-key touch.
I cannot enter those from inside this Claude session, so:

  1. Open a normal terminal window.
       Windows:  press Win+R, type  powershell  and press Enter.
       Mac/Linux: any Terminal app.

  2. Run this single line:

       claude-ssh auth myserver

  3. Enter your password (or touch your hardware key) when prompted.

  4. KEEP THAT WINDOW OPEN. ssh runs there in the foreground holding the
     authenticated connection. Minimize it -- just do not close it.

  5. Come back here and say:  ready

  When you are done with the host, go back to that window and press Ctrl+C
  (or close it). The session ends there.
===============================================================================
```

**Your action:**
1. Open a regular terminal.
2. Run `claude-ssh auth <host>` and enter password / touch your key.
3. Minimize that window — leave it running in the background.
4. Come back to Claude, say "ready".

**One window per host, kept open while you're working.** When you close it, the SSH session ends — explicit and visible.

> **Why a foreground window?** Tried daemonizing (`ssh -fN`). On Windows the forked master inherits the parent's console, and when the user closes the terminal Windows kills it via `CTRL_CLOSE_EVENT`. Stale socket, broken master. Keeping ssh in the foreground in a visible window makes the lifecycle obvious and reliable.

> **Why not just `!claude-ssh auth myhost` in Claude?** Claude Code's `!` prefix runs commands but does **not** allocate a real terminal for ssh's password prompt. ssh sees garbled input and rejects auth. `Permission denied`. A normal terminal window is the path that actually works.

### "Can't I just give Claude my password?"

No. Passwords get logged, cached, leaked. The skill is designed so your password is handled by ssh directly, in your own shell session. Claude never sees it.

### "What if `!` doesn't work?"

The fallback is built in: open a regular terminal yourself and run the same command without the `!`:
```
claude-ssh auth <host>
```
Authenticate there, come back, say "ready". Same result.

### "I don't want to bother with this"

Tell Claude **"use one-shot mode"**. Claude falls back to running `ssh <host> '<cmd>'` per command. Each prompts separately. Annoying but works.

---

## Reading the log

```
[2026-05-20 14:11:33.892] >>> uname -a
Linux example-host 6.8.0-111-generic ... GNU/Linux
[14:11:34.577] <<< exit=0

[2026-05-20 14:11:44.711] >>> ls /nope-does-not-exist
[stderr] ls: cannot access '/nope-does-not-exist': No such file or directory
[14:11:45.309] <<< exit=2

[2026-05-20 14:12:10.221] >>> put ./deploy.sh -> example-host:/tmp/deploy.sh (847 bytes)
deploy.sh                                100%  847    23.8KB/s   00:00
[14:12:10.984] <<< put exit=0
```

- `>>> <cmd>` - command sent
- plain lines - stdout
- `[stderr] <line>` - stderr (kept separate so warnings/errors stand out)
- `<<< exit=N` - exit code
- `>>> put …` / `>>> get …` - file transfers

Long commands stream line-by-line as they emit.

---

## File transfer

| You say... | Claude runs |
|---|---|
| "upload `./local-file` to `/remote/path`" | `claude-ssh put <host> ./local-file /remote/path` |
| "download `/remote/file` to `./local/`" | `claude-ssh get <host> /remote/file ./local/file` |

Both stream scp progress into the log. Exit codes captured.

---

## See what's connected

From any terminal:
```
claude-ssh status
```

```
HOST                           STATUS   LOG
----                           ------   ---
prod-db                        ALIVE    C:\Users\...\Temp\ssh-prod-db.log
staging                        DEAD     C:\Users\...\Temp\ssh-staging.log
```

---

## What it can't do

- **Interactive programs** (`vim`, `top`, `mysql>`, `python` REPL). One-shot exec channels, no TTY. For interactive work, SSH in directly from another terminal (the master doesn't conflict).
- **Persistent shell state.** Fresh remote shell per call. `cd /tmp` then `pwd` returns `$HOME`. Chain commands with `&&`, or tell Claude "stay in `/var/log` for the next few commands".

---

## Multiple hosts

Each alias gets its own connection and log:
```
$TMP/ssh-prod-db.log
$TMP/ssh-staging.log
$TMP/ssh-homelab.log
```
Open separate tail windows per host. Closing one doesn't affect others.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `claude-ssh: command not found` | Installer didn't run, or PATH not refreshed | Run the installer; restart terminal |
| `getsockname failed: Not a socket` | Native Windows ssh.exe used | Install Git for Windows |
| `No live SSH master for '<host>'` | Tried to call without opening | Open the session first |
| Master open hangs / fails | Password auth without a TTY | Type `!claude-ssh auth <host>` in Claude; or run it yourself in a terminal |
| Log appears stuck | No commands ran, or remote command is waiting for input | Ask Claude what it's doing |
| Master won't reopen | Orphan `ssh.exe` | `Get-Process ssh \| Stop-Process -Force` (PS) or `pkill ssh` (POSIX), retry |
| Cosmetic `mux_client_request_session` warning | Known MSYS2 quirk on Windows | Filtered from log; ignore |
| Permission prompts on every call | Skill not allowlisted | See `INSTALL.md` |

---

## Files

```
~/.claude/skills/ssh/
  SKILL.md, GUIDE.md, README.md, INSTALL.md, LICENSE, hook-config.md, .gitignore
  install.ps1    (Windows installer)
  install.sh     (POSIX installer)
  scripts/
    ssh.ps1      (Windows dispatcher)
    ssh.sh       (POSIX dispatcher)
```

Logs and sockets go to `$env:TEMP\` (Windows) or `/tmp` (POSIX):
- Control socket: `cm-<host>`
- Log: `ssh-<host>.log`
