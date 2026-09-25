#!/usr/bin/env bash
# Smoke test for pitbox: full CLI lifecycle in a throwaway repo, then an MCP stdio round-trip.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
REPO="$(pwd)"
CLI="$REPO/bin/pitbox"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# The plugin bundles its own copy of the MCP server, keep them identical.
diff -q "$REPO/mcp/server.mjs" "$REPO/plugin/mcp/server.mjs" || { echo "plugin/mcp/server.mjs is out of sync with mcp/server.mjs" >&2; exit 1; }

echo "== CLI smoke in $T"
git -C "$T" init -q -b main
git -C "$T" commit --allow-empty -qm "init"

cd "$T"
bash "$CLI" init --stack bun
[[ -f "$T/.slots/config" && -x "$T/.slots/setup.sh" ]] || { echo "init failed" >&2; exit 1; }
# Hooks must not need bun in the test environment, replace with no-ops.
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/.slots/setup.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/.slots/release.sh"

# Capturing output avoids SIGPIPE from grep -q under pipefail.
expect() {
    local pattern="$1"
    shift
    local out
    out="$(bash "$CLI" "$@")"
    echo "$out" | grep -q "$pattern"
}

expect "no slots yet" status
bash "$CLI" setup 2
[[ -d "$T/../$(basename "$T")-wt1" && -d "$T/../$(basename "$T")-wt2" ]] || { echo "setup failed" >&2; exit 1; }

WT1DIR="$T/../$(basename "$T")-wt1"
WT2DIR="$T/../$(basename "$T")-wt2"
bash "$CLI" ready wt1 >/dev/null 2>&1 && { echo "ready must refuse a stub branch" >&2; exit 1; }
git -C "$WT1DIR" checkout -q -b task/demo
git -C "$WT1DIR" commit --allow-empty -qm "work"
touch "$WT1DIR/dirty.txt"
bash "$CLI" ready wt1 >/dev/null 2>&1 && { echo "ready must refuse a dirty slot" >&2; exit 1; }
rm "$WT1DIR/dirty.txt"
bash "$CLI" ready wt1 "demo done"
grep -q "demo done" "$WT1DIR/TASK_READY.md"

expect "merging task/demo" collect ready
git -C "$T" log --merges --format=%s | grep -q "task/demo"

WT2DIR="$T/../$(basename "$T")-wt2"
git -C "$WT2DIR" checkout -q -b task/other
git -C "$WT2DIR" commit --allow-empty -qm "other work"
bash "$CLI" ready wt2 >/dev/null
expect "merging task/other" collect wt2
git -C "$T" log --merges --format=%s | grep -q "task/other"

expect "released" release wt1
git -C "$T" show-ref --verify -q refs/heads/task/demo && { echo "task/demo should be deleted" >&2; exit 1; }
[[ "$(git -C "$WT1DIR" branch --show-current)" == "slot/wt1" ]]
[[ ! -f "$WT1DIR/TASK_READY.md" ]]
bash "$CLI" status >/dev/null

echo "== MCP smoke"
node "$REPO/scripts/mcp-smoke.mjs" "$T"
echo "smoke: all checks passed"
