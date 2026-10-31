#!/bin/sh
# Installer for the /ssh skill on Linux.
# Symlinks ~/.local/bin/claude-ssh -> dispatcher so you can call
# `claude-ssh open <host>` from any shell.
# Idempotent: safe to run multiple times.

set -eu

script_path="$(readlink -f -- "$0")";
script_dir="$(dirname -- "$script_path")"

skills_dir="$HOME/.claude/skills"
exe_dir="$HOME/.local/bin"


skills_rel_dir="$(realpath --relative-base="$HOME" --relative-to="$skills_dir" -- "$script_dir")"
exe_rel_dir="$(realpath --relative-base="$HOME" --relative-to="$exe_dir" -- "$script_dir")"

if [ -e "$skills_dir/ssh" ] ; then
    ! [ -L "$skills_dir/ssh" -a -d "$skills_dir/ssh" ] && echo >&2 "$0: $skills_dir/ssh already exists, but is not a symbolic link to a directory; not replacing" && exit 2
    rm "$skills_dir/ssh"
fi

if [ -e "$exe_dir/claude-ssh" ] ; then
    ! [ -L "$exe_dir/claude-ssh" -a -f "$exe_dir/claude-ssh" ] && echo >&2 "$0: $exe_dir/claude-ssh already exists, but is not a symbolic link to a regular file; not replacing" && exit 2
    rm "$exe_dir/claude-ssh"
fi

ln -s -- "$skills_rel_dir" "$skills_dir/ssh"
ln -s -- "$exe_rel_dir/scripts/ssh.sh" "$exe_dir/claude-ssh"

cat << EOF
=== Established the following symbolic links ===

  $skills_dir/ssh -> $script_dir
  $exe_dir/claude-ssh -> $script_dir/scripts/ssh.sh

=== Install complete ===

Test it:    claude-ssh help
Open host:  claude-ssh open <your-ssh-alias>

Suggested allowlist for ~/.claude/settings.json:

  "Bash($exe_dir/claude-ssh)"

EOF

