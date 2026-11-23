#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
IFS= read -r helper < helper-path.txt

umask 077
key_dir="${MPCUT_GROK_KEY_DIR:-$HOME/Library/Application Support/MPCut/Grok Connector}"
mkdir -p "$key_dir"
key_file="$key_dir/bearer-token.txt"
if [[ ! -e "$key_file" ]]; then
    pending=$(mktemp "$key_dir/.token.XXXXXX")
    trap 'rm -f "$pending"' EXIT
    /usr/bin/openssl rand -hex 32 > "$pending"
    # A second launch may have finished creating the key first.
    ln -h "$pending" "$key_file" || [[ -f "$key_file" ]]
    rm -f "$pending"
    trap - EXIT
fi

echo "MPCut connector key file: $key_file"
echo "Local MCP address: http://127.0.0.1:8472/mpcut/mcp"
echo "Keep this window open while editing. Press Control-C to stop."
exec ./mpcut-grok-connector --grok-http "$helper" "$key_file"
