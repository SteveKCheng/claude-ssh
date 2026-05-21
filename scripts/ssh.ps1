#requires -Version 5.1
# /ssh dispatcher. Subcommands: open, call, put, get, close, status, help.
# PS5.1 wraps native-exe stderr as NativeCommandError; do NOT use $ErrorActionPreference='Stop'.

param(
  [Parameter(Position=0)][string]$Subcommand = 'help',
  [Parameter(ValueFromRemainingArguments=$true)][string[]]$Rest = @()
)

# ----- shared helpers --------------------------------------------------------

function Resolve-SshBinary {
  if ($env:SSH_BIN -and (Test-Path $env:SSH_BIN)) { return $env:SSH_BIN }
  $candidates = @(
    "$env:ProgramFiles\Git\usr\bin\ssh.exe",
    "${env:ProgramFiles(x86)}\Git\usr\bin\ssh.exe",
    "$env:LOCALAPPDATA\Programs\Git\usr\bin\ssh.exe"
  )
  foreach ($p in $candidates) {
    if ($p -and (Test-Path $p)) { return $p }
  }
  return $null
}

function Get-ScpBinary([string]$ssh) {
  $scp = $ssh -replace 'ssh\.exe$', 'scp.exe'
  if (Test-Path $scp) { return $scp }
  return $null
}

function Get-Paths([string]$h) {
  @{
    Sock = Join-Path $env:TEMP "cm-$h"
    Log  = Join-Path $env:TEMP "ssh-$h.log"
  }
}

function Require-Ssh {
  $ssh = Resolve-SshBinary
  if (-not $ssh) {
    Write-Error ('No usable ssh binary found. Install Git for Windows (https://git-scm.com/download/win), ' +
                 'or set $env:SSH_BIN. Native Windows ssh.exe has broken ControlMaster ' +
                 '(https://github.com/PowerShell/Win32-OpenSSH/issues/405) and is intentionally not used.')
    exit 2
  }
  return $ssh
}

function Require-Master([string]$h) {
  $p = Get-Paths $h
  if (-not (Test-Path $p.Sock)) {
    Write-Error ("No live SSH master for '{0}'. Run: ssh.ps1 open {0}" -f $h)
    exit 3
  }
}

function Log-Append([string]$log, [string]$line) {
  for ($i=0; $i -lt 50; $i++) {
    try { [System.IO.File]::AppendAllText($log, $line); return } catch [System.IO.IOException] { Start-Sleep -Milliseconds 5 }
  }
}

# ----- subcommand: open ------------------------------------------------------

function Cmd-Open([string]$h) {
  if (-not $h) { Write-Error 'usage: ssh.ps1 open <host>'; exit 1 }
  $ssh = Require-Ssh
  $p   = Get-Paths $h
  $sock = $p.Sock; $log = $p.Log

  # Reuse existing live master.
  if (Test-Path $sock) {
    & $ssh -S $sock -O check $h *> $null
    if ($LASTEXITCODE -eq 0) {
      $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
      if (-not (Test-Path $log)) {
        [System.IO.File]::WriteAllText($log, ("[{0}] === ssh master found (already open) for '{1}' ===`r`n`r`n" -f $stamp, $h))
      } else {
        [System.IO.File]::AppendAllText($log, ("[{0}] === ssh master resumed for '{1}' ===`r`n`r`n" -f $stamp, $h))
      }
      Write-Output ("Master already open for '{0}' (reusing existing socket)." -f $h)
      Write-Output ("ssh binary: {0}" -f $ssh)
      Write-Output ("Socket:     {0}" -f $sock)
      Write-Output ("Log:        {0}" -f $log)
      Write-Output ''
      Write-Output 'Watch live from another PowerShell window:'
      Write-Output ('  Get-Content -Wait -Tail 0 "{0}"' -f $log)
      exit 0
    }
    # Stale socket - clean up
    & $ssh -S $sock -O exit $h *> $null
    Start-Sleep -Milliseconds 200
    Remove-Item $sock -ErrorAction SilentlyContinue
  }

  # Probe non-interactively to see if key/agent auth works.
  & $ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new $h 'true' *> $null
  if ($LASTEXITCODE -eq 0) {
    & $ssh -M -S $sock -fN `
      -o ControlPersist=600 `
      -o ServerAliveInterval=30 `
      -o ServerAliveCountMax=3 `
      $h
    if ($LASTEXITCODE -ne 0) {
      Write-Error ("Master open failed (exit {0}) after a successful probe. This is unusual - try again." -f $LASTEXITCODE)
      exit $LASTEXITCODE
    }
    & $ssh -S $sock -O check $h *> $null
    if ($LASTEXITCODE -ne 0) {
      Write-Error ("Master opened but -O check failed. Try: ssh.ps1 close {0} and retry." -f $h)
      exit 3
    }
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
    [System.IO.File]::WriteAllText($log, ("[{0}] === ssh master opened for '{1}' ===`r`n`r`n" -f $stamp, $h))
    Write-Output ("Master open for '{0}'." -f $h)
    Write-Output ("ssh binary: {0}" -f $ssh)
    Write-Output ("Socket:     {0}" -f $sock)
    Write-Output ("Log:        {0}" -f $log)
    Write-Output ''
    Write-Output 'Watch live from another PowerShell window:'
    Write-Output ('  Get-Content -Wait -Tail 0 "{0}"' -f $log)
    exit 0
  }

  # Interactive auth required (password / passkey / FIDO2 touch).
  $bar = '==============================================================================='
  Write-Output ''
  Write-Output $bar
  Write-Output ('  ACTION NEEDED: {0} wants you to log in interactively' -f $h)
  Write-Output $bar
  Write-Output ''
  Write-Output 'This server needs either a password OR a hardware-key touch.'
  Write-Output 'I cannot enter those from inside this Claude session, so:'
  Write-Output ''
  Write-Output '  1. Open a normal terminal window.'
  Write-Output '       Windows:  press Win+R, type  powershell  and press Enter.'
  Write-Output '       Mac/Linux: any Terminal app.'
  Write-Output ''
  Write-Output '  2. Run this single line:'
  Write-Output ''
  Write-Output ('       claude-ssh auth {0}' -f $h)
  Write-Output ''
  Write-Output '  3. Enter your password (or touch your hardware key) when prompted.'
  Write-Output ''
  Write-Output '  4. KEEP THAT WINDOW OPEN.  ssh runs there in the foreground holding the'
  Write-Output '     authenticated connection. You can minimize it -- just do not close it.'
  Write-Output ''
  Write-Output '  5. Come back here and say:  ready'
  Write-Output ''
  Write-Output '  When you are done with the host, go back to that window and press Ctrl+C'
  Write-Output '  (or close it). The session ends there.'
  Write-Output ''
  Write-Output $bar
  Write-Output ''
  Write-Output 'Why a foreground window? On Windows, ssh''s -f flag (daemonize) does not'
  Write-Output 'survive console closure -- the master dies when the terminal closes. Keeping'
  Write-Output 'ssh in the foreground in a visible window is the most reliable approach.'
  Write-Output ''
  Write-Output 'NOTE: Claude Code''s !-prefix does NOT work for this step. It cannot give ssh'
  Write-Output 'the real terminal it needs for password input. Use a normal terminal window.'
  Write-Output ''
  Write-Output 'If claude-ssh is not on your PATH yet, run the installer once:'
  Write-Output '   & "$HOME\.claude\skills\ssh\install.ps1"'
  Write-Output ''
  Write-Output 'Or, if you want to skip the persistent connection and just run one-off ssh'
  Write-Output 'commands (slower, no live log), tell me:  use one-shot mode'
  exit 4
}

# ----- subcommand: auth ------------------------------------------------------
# Interactive master open. NO probe. Runs ssh -M -fN <host>, which prompts for
# password / hardware-key touch on the caller's TTY, forks to background after
# auth. Designed to be invoked via Claude Code's `!claude-ssh auth <host>`.

function Cmd-Auth([string]$h) {
  if (-not $h) { Write-Error 'usage: ssh.ps1 auth <host>'; exit 1 }
  $ssh = Require-Ssh
  $p   = Get-Paths $h
  $sock = $p.Sock; $log = $p.Log

  # If a live master already exists, do nothing.
  if (Test-Path $sock) {
    & $ssh -S $sock -O check $h *> $null
    if ($LASTEXITCODE -eq 0) {
      Write-Output ("Master already open for '{0}'. Nothing to do." -f $h)
      Write-Output ('(If the master appears stale, run: claude-ssh close {0}  then retry.)' -f $h)
      return
    }
    Remove-Item $sock -ErrorAction SilentlyContinue
  }

  $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
  [System.IO.File]::WriteAllText($log, ("[{0}] === ssh master opened (interactive auth, foreground) for '{1}' ===`r`n`r`n" -f $stamp, $h))

  Write-Output ("Opening interactive SSH master to '{0}'..." -f $h)
  Write-Output ''
  Write-Output 'Enter your password OR touch your hardware key when prompted.'
  Write-Output ''
  Write-Output 'After login, THIS WINDOW HOLDS THE CONNECTION. Leave it open (minimize it).'
  Write-Output 'Tell Claude: ready'
  Write-Output ''
  Write-Output 'When you are done with the SSH session, press Ctrl+C here or close the window.'
  Write-Output 'The master will end at that point.'
  Write-Output ''
  Write-Output '----- ssh starts now -----'
  Write-Output ''

  # NO -f. ssh stays in foreground attached to this terminal.
  # On Windows, -f forks a child that dies when the parent console closes.
  # Keeping ssh in foreground means the master IS this process, and it stays
  # alive as long as the user keeps this window open.
  & $ssh -M -S $sock -N `
    -o ControlPersist=600 `
    -o ServerAliveInterval=30 `
    -o ServerAliveCountMax=3 `
    $h
  exit $LASTEXITCODE
}

# ----- subcommand: call ------------------------------------------------------

function Cmd-Call([string]$h, [string[]]$CmdParts) {
  if (-not $h -or -not $CmdParts -or $CmdParts.Count -eq 0) {
    Write-Error 'usage: ssh.ps1 call <host> <remote command...>'
    exit 1
  }
  $ssh  = Require-Ssh
  Require-Master $h
  $p    = Get-Paths $h
  $sock = $p.Sock; $log = $p.Log
  $cmd  = $CmdParts -join ' '

  $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
  Log-Append $log ("[{0}] >>> {1}`r`n" -f $stamp, $cmd)

  function Quote-Arg([string]$s) {
    if ($s -match '[\s"]') { '"' + ($s -replace '\\(?=\\*")', '\\' -replace '"', '\"') + '"' } else { $s }
  }
  $argList = @('-n', '-S', (Quote-Arg $sock), (Quote-Arg $h), (Quote-Arg $cmd)) -join ' '

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName               = $ssh
  $psi.Arguments              = $argList
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  $psi.UseShellExecute        = $false
  $psi.CreateNoWindow         = $true

  $proc = New-Object System.Diagnostics.Process
  $proc.StartInfo = $psi
  [void]$proc.Start()

  $muxPat    = 'mux_client_request_session'
  $outReader = $proc.StandardOutput
  $errReader = $proc.StandardError

  $rsOut = [runspacefactory]::CreateRunspace(); $rsOut.Open()
  $psOut = [powershell]::Create(); $psOut.Runspace = $rsOut
  [void]$psOut.AddScript({
    param($reader, $logPath)
    function Append-Locked([string]$p, [string]$s) {
      for ($i=0; $i -lt 50; $i++) {
        try { [System.IO.File]::AppendAllText($p, $s); return } catch [System.IO.IOException] { Start-Sleep -Milliseconds 5 }
      }
    }
    while (-not $reader.EndOfStream) {
      $line = $reader.ReadLine()
      if ($null -eq $line) { break }
      Append-Locked $logPath "$line`r`n"
      [Console]::Out.WriteLine($line)
    }
  }).AddArgument($outReader).AddArgument($log)

  $rsErr = [runspacefactory]::CreateRunspace(); $rsErr.Open()
  $psErr = [powershell]::Create(); $psErr.Runspace = $rsErr
  [void]$psErr.AddScript({
    param($reader, $logPath, $muxPat)
    function Append-Locked([string]$p, [string]$s) {
      for ($i=0; $i -lt 50; $i++) {
        try { [System.IO.File]::AppendAllText($p, $s); return } catch [System.IO.IOException] { Start-Sleep -Milliseconds 5 }
      }
    }
    while (-not $reader.EndOfStream) {
      $line = $reader.ReadLine()
      if ($null -eq $line) { break }
      if ($line -match $muxPat) { continue }
      Append-Locked $logPath "[stderr] $line`r`n"
      [Console]::Error.WriteLine($line)
    }
  }).AddArgument($errReader).AddArgument($log).AddArgument($muxPat)

  $hOut = $psOut.BeginInvoke()
  $hErr = $psErr.BeginInvoke()

  $proc.WaitForExit()

  [void]$psOut.EndInvoke($hOut)
  [void]$psErr.EndInvoke($hErr)
  $psOut.Dispose(); $psErr.Dispose()
  $rsOut.Close();   $rsErr.Close()

  $code = $proc.ExitCode
  if ($null -eq $code) { $code = -1 }
  Log-Append $log ("[{0}] <<< exit={1}`r`n`r`n" -f (Get-Date -Format 'HH:mm:ss.fff'), $code)
  exit $code
}

# ----- subcommands: put / get ------------------------------------------------

function Cmd-Put([string]$h, [string]$local, [string]$remote) {
  if (-not $h -or -not $local -or -not $remote) {
    Write-Error 'usage: ssh.ps1 put <host> <local-path> <remote-path>'
    exit 1
  }
  $ssh = Require-Ssh
  $scp = Get-ScpBinary $ssh
  if (-not $scp) { Write-Error "scp not found alongside ssh ($ssh)"; exit 2 }
  Require-Master $h
  if (-not (Test-Path $local)) { Write-Error "Local file not found: $local"; exit 4 }
  $p    = Get-Paths $h
  $sock = $p.Sock; $log = $p.Log

  $size  = (Get-Item $local).Length
  $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
  Log-Append $log ("[{0}] >>> put {1} -> {2}:{3} ({4} bytes)`r`n" -f $stamp, $local, $h, $remote, $size)

  & $scp -o "ControlPath=$sock" -p $local ("{0}:{1}" -f $h, $remote) 2>&1 | ForEach-Object {
    $line = if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { "$_" }
    if ($line -notmatch 'mux_client_request_session') {
      Log-Append $log "$line`r`n"
      Write-Output $line
    }
  }
  $code = $LASTEXITCODE
  Log-Append $log ("[{0}] <<< put exit={1}`r`n`r`n" -f (Get-Date -Format 'HH:mm:ss.fff'), $code)
  exit $code
}

function Cmd-Get([string]$h, [string]$remote, [string]$local) {
  if (-not $h -or -not $remote -or -not $local) {
    Write-Error 'usage: ssh.ps1 get <host> <remote-path> <local-path>'
    exit 1
  }
  $ssh = Require-Ssh
  $scp = Get-ScpBinary $ssh
  if (-not $scp) { Write-Error "scp not found alongside ssh ($ssh)"; exit 2 }
  Require-Master $h
  $p    = Get-Paths $h
  $sock = $p.Sock; $log = $p.Log

  $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
  Log-Append $log ("[{0}] >>> get {1}:{2} -> {3}`r`n" -f $stamp, $h, $remote, $local)

  & $scp -o "ControlPath=$sock" -p ("{0}:{1}" -f $h, $remote) $local 2>&1 | ForEach-Object {
    $line = if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { "$_" }
    if ($line -notmatch 'mux_client_request_session') {
      Log-Append $log "$line`r`n"
      Write-Output $line
    }
  }
  $code = $LASTEXITCODE
  if ($code -eq 0 -and (Test-Path $local)) {
    $size = (Get-Item $local).Length
    Log-Append $log ("[{0}] <<< get exit=0 ({1} bytes)`r`n`r`n" -f (Get-Date -Format 'HH:mm:ss.fff'), $size)
  } else {
    Log-Append $log ("[{0}] <<< get exit={1}`r`n`r`n" -f (Get-Date -Format 'HH:mm:ss.fff'), $code)
  }
  exit $code
}

# ----- subcommand: close -----------------------------------------------------

function Cmd-Close([string]$h) {
  if (-not $h) { Write-Error 'usage: ssh.ps1 close <host>'; exit 1 }
  $ssh = Resolve-SshBinary
  $p   = Get-Paths $h
  $sock = $p.Sock; $log = $p.Log

  if ($ssh -and (Test-Path $sock)) {
    & $ssh -S $sock -O exit $h *> $null
    Start-Sleep -Milliseconds 200
  }
  Remove-Item $sock -ErrorAction SilentlyContinue

  if (Test-Path $log) {
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
    Log-Append $log ("[{0}] === ssh master closed for '{1}' ===`r`n`r`n" -f $stamp, $h)
  }
  Write-Output ("Master closed for '{0}'." -f $h)
}

# ----- subcommand: status ----------------------------------------------------

function Cmd-Status {
  $ssh = Resolve-SshBinary
  $socks = Get-ChildItem $env:TEMP -Filter 'cm-*' -File -ErrorAction SilentlyContinue
  if (-not $socks -or $socks.Count -eq 0) {
    Write-Output 'No active SSH masters.'
    return
  }
  Write-Output ('{0,-30} {1,-8} {2}' -f 'HOST', 'STATUS', 'LOG')
  Write-Output ('{0,-30} {1,-8} {2}' -f '----', '------', '---')
  foreach ($s in $socks) {
    $h = $s.Name -replace '^cm-', ''
    $log = Join-Path $env:TEMP "ssh-$h.log"
    $status = 'DEAD'
    if ($ssh) {
      & $ssh -S $s.FullName -O check $h *> $null
      if ($LASTEXITCODE -eq 0) { $status = 'ALIVE' }
    }
    Write-Output ('{0,-30} {1,-8} {2}' -f $h, $status, $log)
  }
}

# ----- subcommand: help ------------------------------------------------------

function Cmd-Help {
  Write-Output '/ssh - persistent SSH session with live log'
  Write-Output ''
  Write-Output 'Usage:'
  Write-Output '  claude-ssh open  <host>                    Open master (probes auth first)'
  Write-Output '  claude-ssh auth  <host>                    Open master interactively (for password / passkey)'
  Write-Output '  claude-ssh call  <host> <command...>       Run a command via the master'
  Write-Output '  claude-ssh put   <host> <local> <remote>   Upload a file (scp via master)'
  Write-Output '  claude-ssh get   <host> <remote> <local>   Download a file (scp via master)'
  Write-Output '  claude-ssh close <host>                    Close the master'
  Write-Output '  claude-ssh status                          List active masters'
  Write-Output '  claude-ssh help                            Show this help'
  Write-Output ''
  Write-Output 'Aliases: exec, run, sh -> call'
  Write-Output ''
  Write-Output 'Per-host files live in $env:TEMP:'
  Write-Output '  cm-<host>        control socket'
  Write-Output '  ssh-<host>.log   live log (tail with: Get-Content -Wait -Tail 0 <log>)'
}

# ----- dispatch --------------------------------------------------------------

switch -Regex ($Subcommand.ToLower()) {
  '^open$'            { Cmd-Open  $Rest[0] }
  '^auth$'            { Cmd-Auth  $Rest[0] }
  '^(call|exec|run|sh)$' { Cmd-Call  $Rest[0] ($Rest | Select-Object -Skip 1) }
  '^put$'             { Cmd-Put   $Rest[0] $Rest[1] $Rest[2] }
  '^get$'             { Cmd-Get   $Rest[0] $Rest[1] $Rest[2] }
  '^close$'           { Cmd-Close $Rest[0] }
  '^status$'          { Cmd-Status }
  '^(help|-h|--help)$' { Cmd-Help }
  default {
    Write-Error ("Unknown subcommand: '{0}'. Try: claude-ssh help" -f $Subcommand)
    exit 1
  }
}
