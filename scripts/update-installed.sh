#!/usr/bin/env bash
# Refresh locally installed pitbox components from a published main commit.
# Targets: claude plugin, codex plugin, mavis (MiniMax Code) plugin + mavis CLI, standalone CLI.
# Every target is optional: a missing CLI is skipped with a warning.
# Use --only=claude|codex|mavis|mavis-cli|cli to limit targets.
set -Eeuo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

only=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --only=*) only="${1#--only=}"; shift ;;
        *) { echo "Unknown argument: $1 (supported: --only=claude|codex|mavis|mavis-cli|cli)" >&2; exit 1; } ;;
    esac
done
case "$only" in
    ""|claude|codex|mavis|mavis-cli|cli) ;;
    *) { echo "Unknown --only target: $only (supported: claude, codex, mavis, mavis-cli, cli)" >&2; exit 1; } ;;
esac

wanted() { [[ -z "$only" || "$only" == "$1" ]]; }

for command_name in git node diff install cmp; do
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

update_claude() {
    command -v claude >/dev/null || { echo "claude CLI not found, skipping the Claude plugin update" >&2; return 0; }
    local cache installed
    cache="$(claude plugin list --json | node -e '
let input = "";
process.stdin.on("data", chunk => input += chunk);
process.stdin.on("end", () => {
    const plugin = JSON.parse(input).find(item => item.id === "pitbox@pitbox");
    if (!plugin?.installPath || !plugin.enabled) process.exit(1);
    process.stdout.write(plugin.installPath);
});
')" || { echo "pitbox@pitbox must be installed and enabled in Claude" >&2; exit 1; }
    installed="$(node -p 'require(process.argv[1]).version' "$cache/plugin.json")"
    if [[ "$version" == "$installed" ]] && ! diff -qr --exclude=.in_use plugin "$cache" >/dev/null; then
        { echo "Claude has version $version with different files. Bump the plugin version before publishing changes." >&2; exit 1; }
    fi
    claude plugin validate plugin --strict
    claude plugin marketplace update pitbox
    claude plugin update pitbox@pitbox
    cache="$(claude plugin list --json | node -e '
let input = "";
process.stdin.on("data", chunk => input += chunk);
process.stdin.on("end", () => {
    const plugin = JSON.parse(input).find(item => item.id === "pitbox@pitbox");
    if (!plugin?.installPath || !plugin.enabled) process.exit(1);
    process.stdout.write(plugin.installPath);
});
')"
    diff -qr --exclude=.in_use plugin "$cache"
}

update_codex() {
    command -v codex >/dev/null || { echo "codex CLI not found, skipping the Codex plugin update" >&2; return 0; }
    local cache installed
    cache="$(codex mcp list --json | node -e '
let input = "";
process.stdin.on("data", chunk => input += chunk);
process.stdin.on("end", () => {
    const server = JSON.parse(input).find(item => item.name === "pitbox" && item.enabled);
    if (!server?.transport?.env?.PLUGIN_ROOT) process.exit(1);
    process.stdout.write(server.transport.env.PLUGIN_ROOT);
});
')" || { echo "The plugin-managed pitbox MCP server must be enabled in Codex" >&2; exit 1; }
    installed="$(node -p 'require(process.argv[1]).version' "$cache/plugin.json")"
    if [[ "$version" == "$installed" ]] && ! diff -qr --exclude=.in_use plugin "$cache" >/dev/null; then
        { echo "Codex has version $version with different files. Bump the plugin version before publishing changes." >&2; exit 1; }
    fi
    codex plugin marketplace upgrade pitbox
    codex plugin add pitbox@pitbox
    cache="$(codex mcp list --json | node -e '
let input = "";
process.stdin.on("data", chunk => input += chunk);
process.stdin.on("end", () => {
    const server = JSON.parse(input).find(item => item.name === "pitbox" && item.enabled);
    if (!server?.transport?.env?.PLUGIN_ROOT) process.exit(1);
    process.stdout.write(server.transport.env.PLUGIN_ROOT);
});
')"
    diff -qr --exclude=.in_use plugin "$cache"
}

update_cli() {
    local cli_target="${PITBOX_CLI_TARGET:-$HOME/.local/bin/pitbox}"
    install -D -m 755 bin/pitbox "$cli_target"
    cmp -s bin/pitbox "$cli_target"
    echo "Updated the standalone CLI at $cli_target to pitbox $version"
}

update_mavis() {
    # MiniMax Code (mavis / mcode) discovers local plugins from a directory:
    # the local marketplace is `directory /home/<user>/.minimax/plugins` and
    # any subdirectory that looks like a plugin (has plugin.json / .minimax-plugin/plugin.json /
    # .claude-plugin/plugin.json) gets picked up automatically by `mcode plugin list`.
    # There is no install command for local plugins, so we just refresh the copy.
    local target="${PITBOX_MAVIS_TARGET:-$HOME/.minimax/plugins/pitbox}"
    if [[ ! -d "$target" ]]; then
        echo "Mavis plugin directory $target does not exist, skipping (create it manually to enable Mavis support)" >&2
        return 0
    fi
    local installed
    installed="$(node -p 'require(process.argv[1]).version' "$target/plugin.json" 2>/dev/null || echo unknown)"
    if [[ "$version" == "$installed" ]] && diff -qr --exclude=.in_use plugin "$target" >/dev/null 2>&1; then
        echo "Mavis plugin already at version $version"
        return 0
    fi
    if [[ "$version" == "$installed" ]]; then
        { echo "Mavis has version $version with different files. Bump the plugin version before publishing changes." >&2; exit 1; }
    fi
    # Prefer the runtime's recoverable deletion if it ships one (rm is shimmed there).
    if command -v mavis-trash >/dev/null 2>&1; then
        mavis-trash "$target"
    else
        rm -rf "$target"
    fi
    mkdir -p "$target"
    cp -r plugin/. "$target/"
    # Ask Mavis to refresh its local plugin snapshot.
    command -v mcode >/dev/null && mcode plugin marketplace upgrade >/dev/null 2>&1 || true
    echo "Updated the Mavis plugin at $target from version $installed to $version"
}

update_mavis_cli() {
    # MiniMax Code ships its own updater (`mcode update`). It checks for a newer
    # release and replaces the npm-managed install under ~/.nvm/.../lib/node_modules/@minimax-ai/code.
    if ! command -v mcode >/dev/null 2>&1; then
        echo "mcode (MiniMax Code CLI) is not on PATH, skipping" >&2
        return 0
    fi
    local before
    before="$(mcode --version 2>/dev/null || echo unknown)"
    if mcode update; then
        local after
        after="$(mcode --version 2>/dev/null || echo unknown)"
        if [[ "$before" == "$after" ]]; then
            echo "MiniMax Code CLI already at $before"
        else
            echo "Updated MiniMax Code CLI: $before -> $after"
        fi
    else
        { echo "MiniMax Code CLI update failed; leaving $before in place" >&2; return 0; }
    fi
}

if wanted claude; then update_claude; fi
if wanted codex; then update_codex; fi
if wanted mavis; then update_mavis; fi
if wanted mavis-cli; then update_mavis_cli; fi
if wanted cli; then update_cli; fi

if [[ -n "$only" ]]; then
    echo "Updated pitbox $version target: $only"
else
    echo "Updated pitbox $version targets (claude, codex, mavis, mavis-cli, cli). Start new agent sessions to load the updated plugin."
fi
