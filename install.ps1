#requires -Version 5.1
# Installer for the /ssh skill on Windows.
# Puts a 'claude-ssh.cmd' shim into ~/.local/bin so you can call
# `claude-ssh open <host>` from any shell.
# Idempotent: safe to run multiple times.

$ErrorActionPreference = 'Stop'

$skillDir     = Join-Path $env:USERPROFILE '.claude\skills\ssh'
$scriptPathPs = Join-Path $skillDir 'scripts\ssh.ps1'
$scriptPathSh = Join-Path $skillDir 'scripts\ssh.sh'
$binDir       = Join-Path $env:USERPROFILE '.local\bin'
$shimCmdPath  = Join-Path $binDir 'claude-ssh.cmd'
$shimShPath   = Join-Path $binDir 'claude-ssh'

if (-not (Test-Path $scriptPathPs)) {
  Write-Error "Skill dispatcher not found at $scriptPathPs. Did the skill get cloned to the right place?"
  exit 2
}

if (-not (Test-Path $binDir)) {
  New-Item -ItemType Directory -Path $binDir -Force | Out-Null
  Write-Output "Created $binDir"
}

# .cmd shim for cmd.exe / PowerShell users -> ssh.ps1
$cmdShim = @"
@echo off
rem claude-ssh shim - forwards to %USERPROFILE%\.claude\skills\ssh\scripts\ssh.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%USERPROFILE%\.claude\skills\ssh\scripts\ssh.ps1" %*
"@
Set-Content -Path $shimCmdPath -Value $cmdShim -Encoding ASCII
Write-Output "Wrote shim: $shimCmdPath"

# Bash shim (no extension) for Git Bash / WSL users -> ssh.sh
# Claude Code's ! prefix routes commands through Bash on Windows; .cmd is invisible to bash.
$shShim = "#!/usr/bin/env bash`n" +
          "# claude-ssh - bash shim. On Git Bash for Windows, /tmp maps to" + "`n" +
          "# %USERPROFILE%\AppData\Local\Temp, the same place ssh.ps1 uses, so both" + "`n" +
          "# dispatchers share sockets and logs." + "`n" +
          'exec "$HOME/.claude/skills/ssh/scripts/ssh.sh" "$@"' + "`n"
# Write with LF endings (UTF-8 no BOM) so bash reads it cleanly.
[System.IO.File]::WriteAllText($shimShPath, $shShim.Replace("`r`n", "`n"), [System.Text.UTF8Encoding]::new($false))
Write-Output "Wrote shim: $shimShPath"

# Add ~/.local/bin to user PATH if not already there.
$userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
if (-not $userPath) { $userPath = '' }
$paths = $userPath -split ';' | Where-Object { $_ -ne '' }
$alreadyOnPath = $false
foreach ($p in $paths) {
  if ([IO.Path]::GetFullPath($p.TrimEnd('\')) -ieq [IO.Path]::GetFullPath($binDir.TrimEnd('\'))) {
    $alreadyOnPath = $true; break
  }
}

if ($alreadyOnPath) {
  Write-Output ""
  Write-Output "[OK] $binDir is already on your user PATH."
} else {
  $newPath = if ($userPath) { "$userPath;$binDir" } else { $binDir }
  [Environment]::SetEnvironmentVariable('PATH', $newPath, 'User')
  Write-Output ""
  Write-Output "[+] Added $binDir to your user PATH."
  Write-Output "    Restart your PowerShell / terminal so the change takes effect,"
  Write-Output "    or run this in the current session to use claude-ssh right now:"
  Write-Output ""
  Write-Output "        `$env:PATH = `"`$env:PATH;$binDir`""
}

Write-Output ""
Write-Output "=== Install complete ==="
Write-Output ""
Write-Output "Test it:"
Write-Output "  claude-ssh help                       (works in PowerShell, cmd, and Git Bash)"
Write-Output "  claude-ssh open <your-ssh-alias>"
Write-Output ""
Write-Output "Suggested allowlist for ~/.claude/settings.json:"
Write-Output ""
Write-Output '   "PowerShell(claude-ssh*)",'
Write-Output '   "Bash(claude-ssh*)",'
Write-Output '   "PowerShell(& C:\\Users\\<user>\\.claude\\skills\\ssh\\scripts\\ssh.ps1*)"'
Write-Output ""
