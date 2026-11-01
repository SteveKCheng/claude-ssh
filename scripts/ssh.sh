#!/usr/bin/env bash
#vim: set tabstop=4 shiftwidth=4 expandtab:
# /ssh dispatcher (POSIX). Subcommands: open, call, put, get, close, status, help.
set -uo pipefail

sock_for() { printf '/tmp/cm-%s' "$1"; }
log_for()  { printf '/tmp/ssh-%s.log' "$1"; }

declare -A config
script_argv0="$0"

parse_config() {
  # Automatically resolve a config file located next to the script
  local config_file="$(dirname -- "$script_argv0")/config.ini"
  
  if [[ -f "$config_file" ]]; then
      while IFS= read -r line || [[ -n "$line" ]]; do
          # Strip leading whitespace to handle indented comments safely
          line="${line#"${line%%[![:space:]]*}"}"
  
          # Skip empty lines and lines starting with '#'
          if [[ -z "$line" || "$line" == \#* ]]; then
              continue
          fi
  
          # Ensure the line actually contains a key-value pair
          if [[ "$line" == *"="* ]]; then
              # Extract everything before the first '=' as the key
              key="${line%%=*}"
              # Extract everything after the first '=' as the value
              value="${line#*=}"
  
              # Trim trailing whitespace from the key
              key="${key%"${key##*[![:space:]]}"}"
  
              # Trim leading and trailing whitespace from the value
              value="${value#"${value%%[![:space:]]*}"}"
              value="${value%"${value##*[![:space:]]}"}"
  
              # Store in the associative array
              config["$key"]="$value"
          fi
      done < "$config_file"
  fi

  ssh_open_args=()

  local ssh_config="${config["ssh-config"]:-}"
  [ -n "$ssh_config" ] && ssh_open_args+=( -F "$ssh_config" )
}

require_master() {
  local h="$1" sock; sock=$(sock_for "$h")
  if [[ ! -S "$sock" ]]; then
    echo "No live SSH master for '$h'. Run: ssh.sh open $h" >&2
    exit 3
  fi
}

stamp() { date '+%Y-%m-%d %H:%M:%S.%3N' 2>/dev/null || date '+%Y-%m-%d %H:%M:%S'; }
short_stamp() { date '+%H:%M:%S.%3N' 2>/dev/null || date '+%H:%M:%S'; }
run_ssh() {
  ssh "${ssh_open_args[@]}" "$@" || exit $?
}

# ----- open ------------------------------------------------------------------
cmd_open() {
  local h="${1:?usage: ssh.sh open <host>}"

  parse_config
  local sock log; sock=$(sock_for "$h"); log=$(log_for "$h")

  # Reuse existing live master.
  if [[ -S "$sock" ]]; then
    echo "X"

    if run_ssh -S "$sock" -O check "$h" >/dev/null 2>&1; then
      local s; s=$(stamp)
      if [[ ! -f "$log" ]]; then
        printf '[%s] === ssh master found (already open) for %q ===\n\n' "$s" "$h" > "$log"
      else
        printf '[%s] === ssh master resumed for %q ===\n\n' "$s" "$h" >> "$log"
      fi
      cat <<EOF
Master already open for '$h' (reusing existing socket).
Socket: $sock
Log:    $log

Watch live from another terminal:
  tail -F "$log"
EOF
      return 0
    fi
    run_ssh -S "$sock" -O exit "$h" >/dev/null 2>&1 || true
    sleep 0.2
    rm -f "$sock"
  fi

  # Probe non-interactively.
  if run_ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "$h" exit 0 >/dev/null 2>&1; then
    run_ssh -M -S "$sock" -fN \
      -o ControlPersist=yes \
      -o ServerAliveInterval=30 \
      -o ServerAliveCountMax=3 \
      "$h"
    if ! run_ssh -S "$sock" -O check "$h" >/dev/null 2>&1; then
      echo "Master opened but -O check failed. Try: ssh.sh close $h and retry." >&2
      exit 3
    fi
    local s; s=$(stamp)
    printf '[%s] === ssh master opened for %q ===\n\n' "$s" "$h" > "$log"
    cat <<EOF
Master open for '$h'.
Socket: $sock
Log:    $log

Watch live from another terminal:
  tail -F "$log"
EOF
    return 0
  fi

  # Interactive auth required.
  cat <<EOF

===============================================================================
  ACTION NEEDED: '$h' wants you to log in interactively
===============================================================================

This server needs either a password OR a hardware-key touch.
I cannot enter those from inside this Claude session, so:

  1. Open a normal terminal window.
       Windows:  press Win+R, type  powershell  and press Enter.
       Mac/Linux: any Terminal app.

  2. Run this single line:

       claude-ssh auth $h

  3. Enter your password (or touch your hardware key) when prompted.

  4. KEEP THAT WINDOW OPEN.  ssh runs there in the foreground holding the
     authenticated connection. You can minimize it -- just do not close it.

  5. Come back here and say:  ready

  When you are done with the host, go back to that window and press Ctrl+C
  (or close it). The session ends there.

===============================================================================

Why a foreground window? On Windows, ssh's -f flag (daemonize) does not
survive console closure -- the master dies when the terminal closes. Keeping
ssh in the foreground in a visible window is the most reliable approach.

NOTE: Claude Code's !-prefix does NOT work for this step. It cannot give ssh
the real terminal it needs for password input. Use a normal terminal window.

If claude-ssh is not on your PATH yet, run the installer once:
   ~/.claude/skills/ssh/install.sh
   (or on Windows:  & "\$HOME\.claude\skills\ssh\install.ps1" )

Or, if you want to skip the persistent connection and just run one-off ssh
commands (slower, no live log), tell me:  use one-shot mode
EOF
  exit 4
}

# ----- auth ------------------------------------------------------------------
# Interactive master open. NO probe. Runs ssh -M -N <host> in the FOREGROUND
# so it stays attached to this terminal. The user keeps this window open
# (minimized) while Claude uses the master. Closing the window ends the session.
#
# Why no -f? On Windows, -f daemonizes but the forked child stays attached to
# the parent console. When the user closes their terminal, Windows sends
# CTRL_CLOSE_EVENT to the master and it dies. Foreground -N avoids that:
# the master is THIS process, and as long as this window stays open the
# master stays alive.
cmd_auth() {
  local h="${1:?usage: ssh.sh auth <host>}"

  parse_config
  local sock log; sock=$(sock_for "$h"); log=$(log_for "$h")

  if [[ -S "$sock" ]]; then
    if run_ssh -S "$sock" -O check "$h" >/dev/null 2>&1; then
      echo "Master already open for '$h'. Nothing to do."
      echo "(If the master appears stale, run: claude-ssh close $h  then retry.)"
      return 0
    fi
    rm -f "$sock"
  fi

  local s; s=$(stamp)
  printf '[%s] === ssh master opened (interactive auth, foreground) for %q ===\n\n' "$s" "$h" > "$log"

  cat <<EOF
Opening interactive SSH master to '$h'...

Enter your password OR touch your hardware key when prompted.

After login, THIS WINDOW HOLDS THE CONNECTION. Leave it open (minimize it).
Tell Claude: ready

When you are done with the SSH session, press Ctrl+C here or close the window.
The master will end at that point.

----- ssh starts now -----
EOF

  run_ssh -M -S "$sock" -N \
    -o ControlPersist=600 \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=3 \
    "$h"
}

# ----- call ------------------------------------------------------------------
cmd_call() {
  local h="${1:?usage: ssh.sh call <host> <command...>}"
  shift
  if [[ $# -eq 0 ]]; then echo "usage: ssh.sh call <host> <command...>" >&2; exit 1; fi
  local cmd="$*"

  parse_config
  require_master "$h"
  local sock log; sock=$(sock_for "$h"); log=$(log_for "$h")

  printf '[%s] >>> %s\n' "$(stamp)" "$cmd" >> "$log"

  local mux_pat='mux_client_request_session'
  set +e
  run_ssh -n -S "$sock" "$h" "$cmd" \
    > >(while IFS= read -r line; do printf '%s\n' "$line" >> "$log"; printf '%s\n' "$line"; done) \
    2> >(while IFS= read -r line; do [[ "$line" =~ $mux_pat ]] && continue; printf '[stderr] %s\n' "$line" >> "$log"; printf '%s\n' "$line" >&2; done)
  local code=$?
  set -e
  sleep 0.05
  printf '[%s] <<< exit=%d\n\n' "$(short_stamp)" "$code" >> "$log"
  exit "$code"
}

# ----- put -------------------------------------------------------------------
cmd_put() {
  local h="${1:?usage: ssh.sh put <host> <local> <remote>}"
  local local_path="${2:?missing local path}"
  local remote_path="${3:?missing remote path}"

  parse_config
  require_master "$h"
  [[ -e "$local_path" ]] || { echo "Local file not found: $local_path" >&2; exit 4; }
  local sock log; sock=$(sock_for "$h"); log=$(log_for "$h")
  local size; size=$(stat -c %s "$local_path" 2>/dev/null || stat -f %z "$local_path" 2>/dev/null || echo "?")
  printf '[%s] >>> put %s -> %s:%s (%s bytes)\n' "$(stamp)" "$local_path" "$h" "$remote_path" "$size" >> "$log"

  local mux_pat='mux_client_request_session'
  set +e
  scp -o "ControlPath=$sock" -p "$local_path" "$h:$remote_path" 2>&1 | while IFS= read -r line; do
    [[ "$line" =~ $mux_pat ]] && continue
    printf '%s\n' "$line" >> "$log"
    printf '%s\n' "$line"
  done
  local code=${PIPESTATUS[0]}
  set -e
  printf '[%s] <<< put exit=%d\n\n' "$(short_stamp)" "$code" >> "$log"
  exit "$code"
}

# ----- get -------------------------------------------------------------------
cmd_get() {
  local h="${1:?usage: ssh.sh get <host> <remote> <local>}"
  local remote_path="${2:?missing remote path}"
  local local_path="${3:?missing local path}"

  parse_config
  require_master "$h"
  local sock log; sock=$(sock_for "$h"); log=$(log_for "$h")
  printf '[%s] >>> get %s:%s -> %s\n' "$(stamp)" "$h" "$remote_path" "$local_path" >> "$log"

  local mux_pat='mux_client_request_session'
  set +e
  scp -o "ControlPath=$sock" -p "$h:$remote_path" "$local_path" 2>&1 | while IFS= read -r line; do
    [[ "$line" =~ $mux_pat ]] && continue
    printf '%s\n' "$line" >> "$log"
    printf '%s\n' "$line"
  done
  local code=${PIPESTATUS[0]}
  set -e
  if [[ $code -eq 0 && -e "$local_path" ]]; then
    local size; size=$(stat -c %s "$local_path" 2>/dev/null || stat -f %z "$local_path" 2>/dev/null || echo "?")
    printf '[%s] <<< get exit=0 (%s bytes)\n\n' "$(short_stamp)" "$size" >> "$log"
  else
    printf '[%s] <<< get exit=%d\n\n' "$(short_stamp)" "$code" >> "$log"
  fi
  exit "$code"
}

# ----- close -----------------------------------------------------------------
cmd_close() {
  local h="${1:?usage: ssh.sh close <host>}"
  local sock log; sock=$(sock_for "$h"); log=$(log_for "$h")
  if [[ -S "$sock" ]]; then
    run_ssh -S "$sock" -O exit "$h" >/dev/null 2>&1 || true
    sleep 0.2
  fi
  rm -f "$sock"
  if [[ -f "$log" ]]; then
    printf '[%s] === ssh master closed for %q ===\n\n' "$(stamp)" "$h" >> "$log"
  fi
  echo "Master closed for '$h'."
}

# ----- status ----------------------------------------------------------------
cmd_status() {
  shopt -s nullglob
  local socks=( /tmp/cm-* )
  if [[ ${#socks[@]} -eq 0 ]]; then
    echo "No active SSH masters."
    return
  fi
  printf '%-30s %-8s %s\n' 'HOST' 'STATUS' 'LOG'
  printf '%-30s %-8s %s\n' '----' '------' '---'
  for s in "${socks[@]}"; do
    local h="${s##*/cm-}"
    local log; log=$(log_for "$h")
    local status='DEAD'
    if run_ssh -S "$s" -O check "$h" >/dev/null 2>&1; then status='ALIVE'; fi
    printf '%-30s %-8s %s\n' "$h" "$status" "$log"
  done
}

cmd_local_forward()
{
  local h="${1:?usage: ssh.sh local-forward <host> <local-port> <remote-dest>}"
  local local_port="${2:?missing local port}"
  local remote_dest="${3:?missing remote destination}"

  parse_config
  require_master "$h"
  local sock log; sock=$(sock_for "$h"); log=$(log_for "$h")

  run_ssh -n -S "$sock" -O forward -L "${local_port}:${remote_dest}" -- "$h" 

  printf '[%s] >>> local-forward %s -> %s\n' "$(stamp)" "$h" "$local_port" "$remote_dest" >> "$log"  
}

cmd_remote_forward()
{
  local h="${1:?usage: ssh.sh remote-forward <host> <remote-port> <local-dest>}"
  local remote_port="${2:?missing remote port}"
  local local_dest="${3:?missing local destination}"

  parse_config
  require_master "$h"
  local sock log; sock=$(sock_for "$h"); log=$(log_for "$h")

  run_ssh -n -S "$sock" -O forward -R "${remote_port}:${local_dest}" -- "$h" 

  printf '[%s] >>> remote-forward %s -> %s\n' "$(stamp)" "$h" "$remote_port" "$local_dest" >> "$log"  
}

# ----- help ------------------------------------------------------------------
cmd_help() {
  cat <<'EOF'
/ssh - persistent SSH session with live log

Usage:
  claude-ssh open  <host>                   Open master (probes auth first)
  claude-ssh auth  <host>                   Open master interactively (password / passkey)
  claude-ssh call  <host> <command...>      Run a command via the master
  claude-ssh put   <host> <local> <remote>  Upload a file (scp via master)
  claude-ssh get   <host> <remote> <local>  Download a file (scp via master)
  claude-ssh local-forward <host> \         Accept on a local TCP port,
    <local-port> <remote-dest>               forwarding connections to the remote side
  claude-ssh remote-forward <host> \        Request the remote side to accept connections
    <remote-port> <local-dest>               on its TCP port, then forward them here
  claude-ssh close <host>                   Close the master
  claude-ssh status                         List active masters
  claude-ssh help                           Show this help

Aliases: exec, run, sh -> call

Per-host files live in /tmp:
  cm-<host>        control socket
  ssh-<host>.log   live log (tail with: tail -F <log>)
EOF
}

# ----- dispatch --------------------------------------------------------------
sub="${1:-help}"
shift || true
case "$sub" in
  open)            cmd_open  "$@" ;;
  auth)            cmd_auth  "$@" ;;
  call|exec|run|sh) cmd_call  "$@" ;;
  put)             cmd_put   "$@" ;;
  get)             cmd_get   "$@" ;;
  local-forward)   cmd_local_forward "$@" ;;
  remote-forward)  cmd_remote_forward "$@" ;;
  close)           cmd_close "$@" ;;
  status)          cmd_status      ;;
  help|-h|--help)  cmd_help        ;;
  *) echo "Unknown subcommand: '$sub'. Try: claude-ssh help" >&2; exit 1 ;;
esac
