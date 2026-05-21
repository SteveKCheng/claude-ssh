#!/usr/bin/env bash
# Installer for the /ssh skill on Linux / macOS / WSL.
# Symlinks ~/.local/bin/claude-ssh -> dispatcher so you can call
# `claude-ssh open <host>` from any shell.
# Idempotent: safe to run multiple times.

set -euo pipefail

skill_dir="$HOME/.claude/skills/ssh"
dispatch="$skill_dir/scripts/ssh.sh"
bin_dir="$HOME/.local/bin"
link_path="$bin_dir/claude-ssh"

if [[ ! -f "$dispatch" ]]; then
  echo "Skill dispatcher not found at $dispatch" >&2
  echo "Did the skill get cloned to the right place?" >&2
  exit 2
fi

chmod +x "$dispatch"

mkdir -p "$bin_dir"

# Replace any existing symlink/file.
if [[ -L "$link_path" || -e "$link_path" ]]; then
  rm -f "$link_path"
fi
ln -s "$dispatch" "$link_path"
echo "Linked: $link_path -> $dispatch"

# Check PATH.
case ":$PATH:" in
  *":$bin_dir:"*)
    echo ""
    echo "[OK] $bin_dir is on your PATH."
    ;;
  *)
    echo ""
    echo "[!] $bin_dir is NOT on your PATH yet."
    echo "    Add this line to your shell rc (~/.bashrc, ~/.zshrc, ~/.profile):"
    echo ""
    echo '        export PATH="$HOME/.local/bin:$PATH"'
    echo ""
    echo "    Then restart your shell, or run that line now in the current shell."
    ;;
esac

echo ""
echo "=== Install complete ==="
echo ""
echo "Test it:    claude-ssh help"
echo "Open host:  claude-ssh open <your-ssh-alias>"
echo ""
echo "Suggested allowlist for ~/.claude/settings.json:"
echo ""
echo "   \"Bash($HOME/.claude/skills/ssh/scripts/ssh.sh*)\""
echo "   \"Bash($link_path*)\""
echo ""
