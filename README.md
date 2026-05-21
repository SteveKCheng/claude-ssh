# `/ssh` — Give Claude a real SSH terminal. And watch it work.

> A [Claude Code skill](https://docs.claude.com/en/docs/claude-code/skills) that lets your AI run commands on a remote server through **one persistent SSH connection**, and lets **you** watch every keystroke land in real time from another window.

After install you get a global `claude-ssh` command. Claude uses it; so can you.

```bash
claude-ssh open  myserver
claude-ssh call  myserver 'uptime'
claude-ssh put   myserver ./deploy.sh /tmp/deploy.sh
claude-ssh get   myserver /var/log/app.log ./logs/app.log
claude-ssh close myserver
claude-ssh status        # who's connected
```

---

## The problem

You: "Claude, ssh into my server and check disk space."

Claude: *opens SSH connection* → *runs `df -h`* → *closes connection* → "Disk is 80% full."

You: "Now check memory."

Claude: *opens **another** SSH connection* → ...

**Three things are wrong with this picture:**

1. ⏱️ **Re-auth every single command.** Three handshakes for three commands. Coffee gets cold.
2. 🙈 **You can't see what's happening.** Claude says it ran `df -h` — did it? What was the actual output? You're flying blind.
3. 💀 **Output is summarized.** Claude paraphrases. Sometimes you wanted the raw `Failed to start postgresql.service` line.

---

## The fix

`/ssh` opens **one** SSH master connection per host, multiplexes every subsequent command through it, and **mirrors every command + output to a log file you can tail in a normal terminal window**.

```
┌─── Your Claude session ─────────┐    ┌─── Your other PowerShell window ────────┐
│                                 │    │                                          │
│ You: "check if docker runs and  │    │ PS> Get-Content -Wait $env:TEMP\ssh-     │
│       restart it if not"        │    │      myserver.log                        │
│                                 │    │                                          │
│ Claude: [running...]            │    │ [14:23:01] >>> systemctl is-active docker│
│                                 │    │ inactive                                 │
│                                 │    │ [14:23:01] <<< exit=3                    │
│                                 │    │ [14:23:02] >>> sudo systemctl start ...  │
│                                 │    │ [14:23:04] <<< exit=0                    │
│                                 │    │ [14:23:04] >>> systemctl is-active docker│
│                                 │    │ active                                   │
│                                 │    │ [14:23:04] <<< exit=0                    │
│                                 │    │                                          │
└─────────────────────────────────┘    └──────────────────────────────────────────┘
```

You see what Claude saw. Live. While it's still typing.

---

## What you get

- 🚀 **One handshake.** First command ~600 ms. Every command after reuses the connection (~50 ms on Linux, ~700 ms on Windows due to MSYS2 socket emulation — but auth is still skipped).
- 👀 **Live log file.** Tail it from any terminal. Every command echoed, every line of output captured, stderr tagged, exit codes recorded.
- 📦 **File transfer.** Upload (`put`) and download (`get`) reuse the same master.
- ⚡ **Parallel commands.** Many concurrent channels on one TCP connection.
- 🔐 **Every auth mode.** Keys, `ssh-agent`/Pageant, FIDO2 / passkeys (YubiKey, Touch ID, Windows Hello), and even passwords. The hard ones use an inline `!claude-ssh auth myhost` flow — see below.
- 🛠️ **Git-style CLI on PATH.** `claude-ssh open`, `claude-ssh call`, … one global command per platform.
- 🪟 **Windows, macOS, Linux.** `ssh.ps1` + `ssh.sh`, same behavior.
- 🧯 **No `~/.ssh/config` mutation.** Your config stays untouched.
- 🛡️ **Optional defense-in-depth hook** for paranoid audit logging.

---

## The passkey / password trick

The painful part of "AI runs SSH for me" is what happens when the server wants a password or a hardware-key touch — Claude can't type a password and can't tap your YubiKey. Old solutions: "open a new terminal, paste this big command, come back when done." Annoying.

This skill exploits Claude Code's `!` prefix. When auth is needed, Claude tells you:

> Type this here in Claude (start with `!`):
> `!claude-ssh auth myserver`

You type it. Claude Code passes the line to your real shell. ssh prompts for your password (or blinks your hardware key). You type / touch — **right there in the same chat**. ssh forks to background. The master is open. You tell Claude "ready". Done.

No new windows. No copy-paste of giant commands. The same chat handles both Claude's commands and your interactive auth.

---

## Installation

### 1. Clone the skill
```bash
# Linux / macOS
git clone https://github.com/<your-fork>/ssh-skill ~/.claude/skills/ssh

# Windows (PowerShell)
git clone https://github.com/<your-fork>/ssh-skill $env:USERPROFILE\.claude\skills\ssh
```

### 2. Run the installer once
```powershell
# Windows
& "$HOME\.claude\skills\ssh\install.ps1"
```
```bash
# Linux / macOS
~/.claude/skills/ssh/install.sh
```

That drops a `claude-ssh` shim into `~/.local/bin/` and makes sure it's on PATH.

### 3. Allowlist (optional but recommended)

Add to `~/.claude/settings.json` so Claude doesn't prompt on every call. See [`INSTALL.md`](./INSTALL.md).

### 4. Test
```bash
claude-ssh help
claude-ssh open <your-ssh-alias>
```

---

## Usage in Claude

```
/ssh    (then describe what you want)

"open an ssh session to prod-db"
"upload ./deploy.sh to the server"
"tail the nginx logs while I push a change"
```

Claude loads the skill, opens the master, prints the exact `tail` command you should run in another window, then starts working.

Full user guide: [`GUIDE.md`](./GUIDE.md). Auth flow details: same file under "Authentication".

---

## The boring details (why this works)

OpenSSH has a feature called [`ControlMaster`](https://man.openbsd.org/ssh_config.5#ControlMaster) that's been around for ~20 years. One process holds an authenticated SSH connection; subsequent `ssh`/`scp` invocations reuse it instead of re-handshaking. Auth happens once; everything after is essentially free.

The skill is one ~400-line PowerShell dispatcher and a ~200-line Bash one that:
1. Pick the right `ssh` binary (Git for Windows on Windows — Microsoft's port has [a broken `ControlMaster` since 2017](https://github.com/PowerShell/Win32-OpenSSH/issues/405)).
2. Probe key/agent auth non-interactively. If it works, open the master silently. If not, print copy-pasteable `!claude-ssh auth <host>` instructions.
3. Open the master with sensible defaults (`ControlPersist=600`, `ServerAliveInterval=30`).
4. Run each command / scp transfer in its own multiplexed channel.
5. Tee output to both stdout and a persistent per-host log file using `FileShare.Read` so your `tail -F` doesn't get locked out.
6. Filter the one cosmetic MSYS2 warning that would otherwise spam the log on Windows.

No daemon, no socket protocol, no agent. Just OpenSSH being used the way it was meant to be used, with a thin wrapper that adds observability.

---

## License

MIT. See [`LICENSE`](./LICENSE). Fork it, ship it, sell it.

---

## Contributing

PRs welcome. Especially:
- More auth-mode coverage (`gpg-agent`, Kerberos, Smart Card)
- Better Windows-native ssh.exe handling once Microsoft fixes [#405](https://github.com/PowerShell/Win32-OpenSSH/issues/405) (don't hold your breath)
- Codex / Cursor / Continue ports
