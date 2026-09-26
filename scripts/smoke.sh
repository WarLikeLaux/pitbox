#!/usr/bin/env bash
# Smoke test for pitbox: full CLI lifecycle in a throwaway repo, then an MCP stdio round-trip.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
REPO="$(pwd)"
CLI="$REPO/bin/pitbox"

T="$(mktemp -d)"
# Slot dirs and the bare remote live next to T, not inside it, clean them too.
trap 'rm -rf "$T" "$T"-wt1 "$T"-wt2 "$T"-smoke-remote.git "$T"-legacy' EXIT

# The plugin bundles its own copy of the MCP server, keep them identical.
diff -q "$REPO/mcp/server.mjs" "$REPO/plugin/mcp/server.mjs" || { echo "plugin/mcp/server.mjs is out of sync with mcp/server.mjs" >&2; exit 1; }

node - <<'NODE'
const fs = require('node:fs');
const read = path => JSON.parse(fs.readFileSync(path, 'utf8'));
const portable = read('plugin/plugin.json').version;
const claude = read('plugin/.claude-plugin/plugin.json').version;
const marketplace = read('.claude-plugin/marketplace.json').plugins.find(plugin => plugin.name === 'pitbox')?.version;
if (!portable || portable !== claude || portable !== marketplace) {
    console.error('Plugin versions must match in both manifests and the Claude marketplace');
    process.exit(1);
}
NODE

echo "== CLI smoke in $T"
git -C "$T" init -q -b main
git -C "$T" config user.email "smoke@example.com"
git -C "$T" config user.name "pitbox smoke"
git -C "$T" commit --allow-empty -qm "init"

cd "$T"
bash "$CLI" init --stack bun
[[ -f "$T/.pitbox/config" && -x "$T/.pitbox/setup.sh" ]] || { echo "init failed" >&2; exit 1; }
# Hooks must not need bun in the test environment, replace with no-ops.
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/.pitbox/setup.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/.pitbox/release.sh"
# Pin the main branch, otherwise autodetection falls back to the current branch of the main
# checkout and the collect off-branch guard would have nothing to compare against.
echo "MAIN_BRANCH=main" >> "$T/.pitbox/config"
# The documented flow commits .pitbox, and the collect guard demands a clean main checkout.
git -C "$T" add .pitbox
git -C "$T" commit -qm "slots"

# Capturing output avoids SIGPIPE from grep -q under pipefail.
expect() {
    local pattern="$1"
    shift
    local out
    out="$(bash "$CLI" "$@")"
    echo "$out" | grep -q "$pattern"
}

expect_fail() {
    if bash "$CLI" "$@" >/dev/null 2>&1; then
        echo "expected failure: pitbox $*" >&2
        exit 1
    fi
}

expect "no slots yet" status
bash "$CLI" setup 2
[[ -d "$T/../$(basename "$T")-wt1" && -d "$T/../$(basename "$T")-wt2" ]] || { echo "setup failed" >&2; exit 1; }

WT1DIR="$T/../$(basename "$T")-wt1"
WT2DIR="$T/../$(basename "$T")-wt2"

expect_fail ready wt1                # ready must refuse a stub branch
bash "$CLI" claim wt1 task/demo
expect_fail claim wt1 task/dup       # claim must refuse a busy slot
git -C "$WT1DIR" commit --allow-empty -qm "work"
touch "$WT1DIR/dirty.txt"
expect_fail ready wt1                # ready must refuse a dirty slot
rm "$WT1DIR/dirty.txt"
bash "$CLI" ready wt1 "demo done"
grep -q "demo done" "$WT1DIR/TASK_READY.md"
grep -q "^commit:" "$WT1DIR/TASK_READY.md"
bash "$CLI" ready wt1 >/dev/null     # re-ready works, the marker itself never counts as dirt
git -C "$WT1DIR" commit --allow-empty -qm "late work"
expect_fail collect ready            # collect must refuse a slot changed after its marker
git -C "$WT1DIR" reset -q --hard HEAD~1
touch "$T/main-dirty.txt"
expect_fail collect ready            # collect must refuse a dirty main checkout
rm "$T/main-dirty.txt"
git -C "$T" checkout -q -b offmain
expect_fail collect ready            # collect must refuse a main worktree off the main branch
git -C "$T" checkout -q main
git -C "$T" branch -q -D offmain
expect "merging task/demo" collect ready
git -C "$T" log --merges --format=%s | grep -q "task/demo"

git -C "$WT2DIR" checkout -q -b task/other
git -C "$WT2DIR" commit --allow-empty -qm "other work"
echo "REQUIRE_PUSH=1" >> "$T/.pitbox/config"
expect_fail ready wt2                # REQUIRE_PUSH=1 must refuse an unpushed branch
git -C "$T" init -q --bare "${T}-smoke-remote.git"
git -C "$WT2DIR" remote add origin "${T}-smoke-remote.git"
git -C "$WT2DIR" push -q -u origin task/other
bash "$CLI" ready wt2 >/dev/null
sed -i '/^REQUIRE_PUSH=1$/d' "$T/.pitbox/config"
expect "merging task/other" collect wt2
git -C "$T" log --merges --format=%s | grep -q "task/other"

# Release falls back to setup.sh when release.sh is missing.
printf '#!/usr/bin/env bash\ntouch "$1/.setup-ran"\n' > "$T/.pitbox/setup.sh"
rm "$T/.pitbox/release.sh"
expect "released" release wt1
git -C "$T" show-ref --verify -q refs/heads/task/demo && { echo "task/demo should be deleted" >&2; exit 1; }
[[ "$(git -C "$WT1DIR" branch --show-current)" == "slot/wt1" ]]
[[ ! -f "$WT1DIR/TASK_READY.md" ]]
[[ -f "$WT1DIR/.setup-ran" ]] || { echo "release must fall back to setup.sh when release.sh is missing" >&2; exit 1; }
bash "$CLI" status >/dev/null

# claim auto-picks the only free slot.
bash "$CLI" claim
[[ "$(git -C "$WT1DIR" branch --show-current)" == task/* ]] || { echo "claim should auto-pick the free wt1" >&2; exit 1; }
bash "$CLI" release wt1 >/dev/null

echo "== MCP smoke"
node "$REPO/scripts/mcp-smoke.mjs" "$T"

# A legacy .slots directory must not supply configuration to the new CLI.
LEGACY="${T}-legacy"
git -C "$(dirname "$LEGACY")" init -q -b main "$LEGACY"
git -C "$LEGACY" config user.email "smoke@example.com"
git -C "$LEGACY" config user.name "pitbox smoke"
git -C "$LEGACY" commit --allow-empty -qm "init"
mkdir "$LEGACY/.slots"
echo "MAIN_BRANCH=bogus" > "$LEGACY/.slots/config"
legacy_status="$(cd "$LEGACY" && bash "$CLI" status)"
[[ "$legacy_status" == "main branch: main"* ]] || { echo "legacy .slots/config was read" >&2; exit 1; }
echo "smoke: all checks passed"
