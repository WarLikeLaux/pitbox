#!/usr/bin/env bash
# Refresh locally installed pitbox components from a published main commit.
set -Eeuo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

for command_name in git node codex claude diff install cmp; do
    command -v "$command_name" >/dev/null || { echo "Missing command: $command_name" >&2; exit 1; }
done

[[ "$(git branch --show-current)" == main ]] || { echo "Run from the main branch" >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "Commit or discard local changes before updating installed copies" >&2; exit 1; }

local_commit="$(git rev-parse HEAD)"
remote_commit="$(git ls-remote origin refs/heads/main | cut -f1)" || {
    echo "Could not read origin/main" >&2
    exit 1
}
[[ -n "$remote_commit" && "$local_commit" == "$remote_commit" ]] || {
    echo "Push this main commit to origin before updating installed copies" >&2
    exit 1
}

version="$(node - <<'NODE'
const fs = require('node:fs');
const read = path => JSON.parse(fs.readFileSync(path, 'utf8'));
const portable = read('plugin/plugin.json').version;
const claude = read('plugin/.claude-plugin/plugin.json').version;
const marketplace = read('.claude-plugin/marketplace.json').plugins.find(plugin => plugin.name === 'pitbox')?.version;
if (!portable || portable !== claude || portable !== marketplace) {
    console.error('Plugin versions must match in both manifests and the Claude marketplace');
    process.exit(1);
}
process.stdout.write(portable);
NODE
)"

get_claude_cache() {
    claude plugin list --json | node -e '
let input = "";
process.stdin.on("data", chunk => input += chunk);
process.stdin.on("end", () => {
    const plugin = JSON.parse(input).find(item => item.id === "pitbox@pitbox");
    if (!plugin?.installPath || !plugin.enabled) process.exit(1);
    process.stdout.write(plugin.installPath);
});
'
}

get_codex_cache() {
    codex mcp list --json | node -e '
let input = "";
process.stdin.on("data", chunk => input += chunk);
process.stdin.on("end", () => {
    const server = JSON.parse(input).find(item => item.name === "pitbox" && item.enabled);
    if (!server?.transport?.env?.PLUGIN_ROOT) process.exit(1);
    process.stdout.write(server.transport.env.PLUGIN_ROOT);
});
'
}

claude_cache="$(get_claude_cache)" || { echo "pitbox@pitbox must be installed and enabled in Claude" >&2; exit 1; }
codex_cache="$(get_codex_cache)" || { echo "The plugin-managed pitbox MCP server must be enabled in Codex" >&2; exit 1; }

installed_claude_version="$(node -p 'require(process.argv[1]).version' "$claude_cache/plugin.json")"
installed_codex_version="$(node -p 'require(process.argv[1]).version' "$codex_cache/plugin.json")"

if [[ "$version" == "$installed_claude_version" ]] && ! diff -qr --exclude=.in_use plugin "$claude_cache" >/dev/null; then
    echo "Claude has version $version with different files. Bump the plugin version before publishing changes." >&2
    exit 1
fi
if [[ "$version" == "$installed_codex_version" ]] && ! diff -qr --exclude=.in_use plugin "$codex_cache" >/dev/null; then
    echo "Codex has version $version with different files. Bump the plugin version before publishing changes." >&2
    exit 1
fi

claude plugin validate plugin --strict
codex plugin marketplace upgrade pitbox
codex plugin add pitbox@pitbox
claude plugin marketplace update pitbox
claude plugin update pitbox@pitbox

claude_cache="$(get_claude_cache)"
codex_cache="$(get_codex_cache)"
diff -qr --exclude=.in_use plugin "$claude_cache"
diff -qr --exclude=.in_use plugin "$codex_cache"

cli_target="${PITBOX_CLI_TARGET:-$HOME/.local/bin/pitbox}"
install -D -m 755 bin/pitbox "$cli_target"
cmp -s bin/pitbox "$cli_target"

echo "Updated Codex, Claude and $cli_target to pitbox $version. Start new agent sessions to load the updated plugin."
