# Install

## Requirements

| Platform | Need |
|---|---|
| Windows 10/11 | PowerShell 5.1+ (built in) **AND** [Git for Windows](https://git-scm.com/download/win) |
| macOS | Bash or Zsh, system `ssh` |
| Linux | Bash, `openssh-client` package |
| WSL | Run installer & skill inside WSL (separate keychain from Windows host) |

Why Git for Windows on Windows? Microsoft's bundled `C:\Windows\System32\OpenSSH\ssh.exe` has a broken `ControlMaster` ([#405](https://github.com/PowerShell/Win32-OpenSSH/issues/405)). Git for Windows ships a working OpenSSH. The dispatcher auto-detects it.

---

## 1. Clone the skill

```bash
# Linux / macOS
git clone https://github.com/Infamous0192/claude-ssh ~/.claude/skills/ssh
```
```powershell
# Windows
git clone https://github.com/Infamous0192/claude-ssh $env:USERPROFILE\.claude\skills\ssh
```

> The destination path matters — Claude Code discovers skills inside `~/.claude/skills/`. The folder must be named `ssh` so the skill registers as `/ssh`.

The skill is now discoverable by Claude as `/ssh`.

---

## 2. Run the installer (one-time)

This drops a `claude-ssh` shim into `~/.local/bin/` and makes sure it's on your PATH. After this, `claude-ssh open <host>` etc. work from any shell.

```powershell
# Windows (PowerShell)
& "$HOME\.claude\skills\ssh\install.ps1"
```
```bash
# Linux / macOS
~/.claude/skills/ssh/install.sh
```

Output looks like:
```
Wrote shim: C:\Users\<user>\.local\bin\claude-ssh.cmd
[OK] C:\Users\<user>\.local\bin is already on your user PATH.

=== Install complete ===
Test it:    claude-ssh help
Open host:  claude-ssh open <your-ssh-alias>
```

If the installer says it added the bin dir to PATH, **restart your terminal** (or follow the printed line to refresh in-session) before using `claude-ssh`.

---

## 3. Allowlist (recommended)

Without this, Claude asks for permission every time. Add to `~/.claude/settings.json` under `permissions.allow`:

### Windows
```json
{
  "permissions": {
    "allow": [
      "PowerShell(claude-ssh*)",
      "PowerShell(& C:\\Users\\<YOUR-USER>\\.claude\\skills\\ssh\\scripts\\ssh.ps1*)"
    ]
  }
}
```

Replace `<YOUR-USER>` with your Windows username. The first line matches when Claude calls `claude-ssh` directly; the second matches when Claude calls the script by full path (e.g., right after install before PATH refresh).

### Linux / macOS
```json
{
  "permissions": {
    "allow": [
      "Bash(claude-ssh*)",
      "Bash(~/.claude/skills/ssh/scripts/ssh.sh*)"
    ]
  }
}
```

One allowlist set covers all subcommands.

---

## 4. (Optional) Defense-in-depth audit hook

For a second independent log of every SSH call Claude makes — fires even if the dispatcher is bypassed — add the `PostToolUse` hook from [`hook-config.md`](./hook-config.md) to `settings.json`.

Not required for normal use.

---

## 5. Verify

In Claude Code:
> /ssh

> open an ssh session to `<some-host-alias-from-your-ssh-config>` and run `uname -a`

Claude should pick the right ssh binary, open a master, print a `Get-Content -Wait` / `tail -F` command, run `uname -a`, show output. Log appears at `$env:TEMP\ssh-<host>.log` (Windows) or `/tmp/ssh-<host>.log` (POSIX).

From any terminal:
```
claude-ssh status
```

---

## Updating

```bash
cd ~/.claude/skills/ssh
git pull
```

No re-install needed unless the install script changes. The shim points at the dispatcher path, which is stable.

---

## Uninstall

```powershell
# Windows
Remove-Item -Recurse -Force $env:USERPROFILE\.claude\skills\ssh
Remove-Item $env:USERPROFILE\.local\bin\claude-ssh.cmd
```
```bash
# POSIX
rm -rf ~/.claude/skills/ssh
rm -f ~/.local/bin/claude-ssh
```

Remove the allowlist entries from `settings.json`. Done.
