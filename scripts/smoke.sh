#!/usr/bin/env bash
# Smoke test for pitbox: full CLI lifecycle in a throwaway repo, then an MCP stdio round-trip.
set -Eeuo pipefail

# Some environments shim `rm` with a wrapper that prints a status line on stdout
# (e.g. `~/.minimax/bin/mavis-trash`). That contaminates command substitutions
# like `$(pitbox claim ...)` that capture the real CLI's stdout. Strip those
# shims from PATH so the smoke test sees the real `rm` and the captured output
# stays clean.
PATH_CLEAN=""
IFS=: read -ra _parts <<< "$PATH"
for _p in "${_parts[@]}"; do
    if [[ "$_p" != *"/.minimax/shims" ]]; then
        if [[ -z "$PATH_CLEAN" ]]; then
            PATH_CLEAN="$_p"
        else
            PATH_CLEAN="$PATH_CLEAN:$_p"
        fi
    fi
done
PATH="$PATH_CLEAN"
export PATH

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
const cliVersion = fs.readFileSync('bin/pitbox', 'utf8').match(/^VERSION="([^"]+)"/m)?.[1];
const serverVersion = fs.readFileSync('mcp/server.mjs', 'utf8').match(/^const VERSION = "([^"]+)"/m)?.[1];
if (cliVersion !== portable || serverVersion !== portable) {
    console.error(`bin/pitbox (${cliVersion}) and mcp/server.mjs (${serverVersion}) must match the manifests (${portable})`);
    process.exit(1);
}
NODE

echo "== CLI smoke in $T"
git -C "$T" init -q -b main
git -C "$T" config user.email "smoke@example.com"
git -C "$T" config user.name "pitbox smoke"
git -C "$T" commit --allow-empty -qm "init"

cd "$T"
printf '# Project rules\n\n- Deploy before commit.\n' > AGENTS.md
agents_before="$(sha256sum AGENTS.md | cut -d' ' -f1)"
bash "$CLI" init --stack bun
[[ -f "$T/.pitbox/config" && -x "$T/.pitbox/setup.sh" ]] || { echo "init failed" >&2; exit 1; }
[[ "$(sha256sum AGENTS.md | cut -d' ' -f1)" == "$agents_before" ]] || { echo "init changed AGENTS.md" >&2; exit 1; }
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

expect "pitbox workflow guide" guide
bash "$CLI" init --stack bun --force >/dev/null
[[ "$(sha256sum AGENTS.md | cut -d' ' -f1)" == "$agents_before" ]] || { echo "init --force changed AGENTS.md" >&2; exit 1; }
# Hooks must not need bun in the test environment, replace with no-ops.
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/.pitbox/setup.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/.pitbox/release.sh"
# Pin the main branch, otherwise autodetection falls back to the current branch of the main
# checkout and the collect off-branch guard would have nothing to compare against.
echo "MAIN_BRANCH=main" >> "$T/.pitbox/config"
# The documented flow commits .pitbox, and the collect guard demands a clean main checkout.
git -C "$T" add .pitbox AGENTS.md
git -C "$T" commit -qm "slots"

# Slot state lives in the common git dir, shared by every worktree.
COMMON="$(git -C "$T" rev-parse --path-format=absolute --git-common-dir)"
STATE="$COMMON/pitbox/slots"

expect "no slots yet" status
expect "policy: ready=auto evidence=auto push=off" status
bash "$CLI" setup 2
[[ -d "$T/../$(basename "$T")-wt1" && -d "$T/../$(basename "$T")-wt2" ]] || { echo "setup failed" >&2; exit 1; }
[[ -f "$STATE/wt1.path" && -f "$STATE/wt2.path" ]] || { echo "setup did not register the slots" >&2; exit 1; }

# A lost registry is rebuilt from the git worktree list.
rm -rf "$COMMON/pitbox"
expect "wt1" status
[[ -f "$STATE/wt1.path" && -f "$STATE/wt2.path" ]] || { echo "status did not rebuild the slot registry" >&2; exit 1; }

WT1DIR="$T/../$(basename "$T")-wt1"
WT2DIR="$T/../$(basename "$T")-wt2"

expect_fail ready wt1                # ready must refuse a stub branch
bash "$CLI" claim wt1 task/demo
expect_fail claim wt1 task/dup       # claim must refuse a busy slot
bash "$CLI" claim wt2 task/temporary >/dev/null
expect_fail claim                      # do not create more slots when all are busy
bash "$CLI" release wt2 >/dev/null
git -C "$WT1DIR" commit --allow-empty -qm "work"
touch "$WT1DIR/dirty.txt"
expect_fail ready wt1                # ready must refuse a dirty slot
rm "$WT1DIR/dirty.txt"
main_before_ready="$(git -C "$T" rev-parse HEAD)"
bash "$CLI" ready wt1 "demo done"
[[ "$(git -C "$T" rev-parse HEAD)" == "$main_before_ready" ]] || { echo "ready changed the main branch" >&2; exit 1; }
[[ -f "$STATE/wt1.ready" ]] || { echo "ready must write the marker into the pitbox state" >&2; exit 1; }
[[ ! -f "$WT1DIR/TASK_READY.md" ]] || { echo "ready must not write TASK_READY.md into the slot" >&2; exit 1; }
grep -q "demo done" "$STATE/wt1.ready"
grep -q "^commit:" "$STATE/wt1.ready"
bash "$CLI" ready wt1 >/dev/null     # re-ready works
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
[[ -f "$STATE/wt1.collected" && ! -f "$STATE/wt1.ready" ]] || { echo "collect must turn ready into collected" >&2; exit 1; }
git -C "$T" log --merges --format=%s | grep -q "task/demo"
expect "already collected" collect ready   # a collected slot is skipped, collect stays resumable

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
[[ -f "$STATE/wt2.collected" ]] || { echo "collect wt2 must record collected state" >&2; exit 1; }
git -C "$T" log --merges --format=%s | grep -q "task/other"

# Release falls back to setup.sh when release.sh is missing, and clears the state.
echo '.setup-ran' >> "$T/.git/info/exclude"
# shellcheck disable=SC2016  # the hook must receive $1 literally
printf '#!/usr/bin/env bash\ntouch "$1/.setup-ran"\n' > "$T/.pitbox/setup.sh"
rm "$T/.pitbox/release.sh"
expect "released" release wt1
git -C "$T" show-ref --verify -q refs/heads/task/demo && { echo "task/demo should be deleted" >&2; exit 1; }
[[ "$(git -C "$WT1DIR" branch --show-current)" == "slot/wt1" ]]
[[ ! -f "$STATE/wt1.ready" && ! -f "$STATE/wt1.collected" ]] || { echo "release must clear the slot state" >&2; exit 1; }
[[ -f "$WT1DIR/.setup-ran" ]] || { echo "release must fall back to setup.sh when release.sh is missing" >&2; exit 1; }
bash "$CLI" status >/dev/null
# The rewritten hook files are uncommitted main-checkout dirt, a later collect would refuse them.
git -C "$T" add -A .pitbox
git -C "$T" commit -qm "test hooks"

# claim auto-picks the only free slot.
bash "$CLI" claim
[[ "$(git -C "$WT1DIR" branch --show-current)" == task/* ]] || { echo "claim should auto-pick the free wt1" >&2; exit 1; }
bash "$CLI" release wt1 >/dev/null
claim_output="$(bash "$CLI" claim task/named)"
[[ "$(git -C "$WT1DIR" branch --show-current)" == task/named ]] || { echo "claim should accept a branch name without a slot" >&2; exit 1; }
[[ "$claim_output" == *" at $(cd "$WT1DIR" && pwd)" ]] || { echo "claim should report the claimed path" >&2; exit 1; }
bash "$CLI" release wt1 >/dev/null

# A free slot can lag behind main. Claim must sync it before creating a task branch.
rm "$WT1DIR/.setup-ran"
git -C "$T" commit --allow-empty -qm "main advanced"
main_tip="$(git -C "$T" rev-parse HEAD)"
bash "$CLI" claim wt1 task/fresh
[[ "$(git -C "$WT1DIR" rev-parse HEAD)" == "$main_tip" ]] || { echo "claim started from a stale slot" >&2; exit 1; }
[[ -f "$WT1DIR/.setup-ran" ]] || { echo "claim skipped setup after syncing the slot" >&2; exit 1; }
bash "$CLI" release wt1 >/dev/null

# A pre-0.4 TASK_READY.md is imported into the pitbox state on first sight.
bash "$CLI" claim wt1 task/legacy >/dev/null
git -C "$WT1DIR" commit --allow-empty -qm "legacy work"
printf 'branch: %s\nslot: wt1\ncommit: %s\nupdated: 2020-01-01T00:00:00Z\nnotes: legacy\n' \
    "$(git -C "$WT1DIR" branch --show-current)" "$(git -C "$WT1DIR" rev-parse HEAD)" > "$WT1DIR/TASK_READY.md"
legacy_status="$(bash "$CLI" status)"
echo "$legacy_status" | grep -q "imported legacy TASK_READY.md for wt1" || { echo "legacy marker was not imported" >&2; exit 1; }
[[ -f "$STATE/wt1.ready" && ! -f "$WT1DIR/TASK_READY.md" ]] || { echo "legacy import must move the marker into the state" >&2; exit 1; }
expect "merging task/legacy" collect ready
bash "$CLI" release wt1 >/dev/null

# A claim lock from a dead process is stolen, a lock from a live process is not.
LOCK="$COMMON/pitbox/claim.lock"
mkdir -p "$LOCK"
sleep 0.01 & dead_pid=$!
wait "$dead_pid" 2>/dev/null || true
echo "$dead_pid" > "$LOCK/pid"
lock_out="$(bash "$CLI" claim wt1 task/locktest 2>&1)"
echo "$lock_out" | grep -q "stealing stale claim lock" || { echo "claim must steal a stale lock" >&2; exit 1; }
[[ "$(git -C "$WT1DIR" branch --show-current)" == task/locktest ]] || { echo "claim after stealing the lock failed" >&2; exit 1; }
bash "$CLI" release wt1 >/dev/null
mkdir -p "$LOCK"
echo $$ > "$LOCK/pid"
expect_fail claim wt1 task/nolock    # a live pid holds the lock
rm -rf "$LOCK"
bash "$CLI" claim wt1 task/afterlock >/dev/null
bash "$CLI" release wt1 >/dev/null

# A conflicted merge is flagged: resolve, commit, re-run collect, and the full-checks hint appears.
bash "$CLI" release wt2 >/dev/null
bash "$CLI" claim wt2 task/conflict >/dev/null
printf 'slot line\n' > "$WT2DIR/shared.txt"
git -C "$WT2DIR" add shared.txt
git -C "$WT2DIR" commit -qm "slot touch"
printf 'main line\n' > "$T/shared.txt"
git -C "$T" add shared.txt
git -C "$T" commit -qm "main touch"
expect_fail collect wt2               # the merge stops with conflicts
[[ -f "$STATE/wt2.conflict" ]] || { echo "conflicted collect must leave a conflict marker" >&2; exit 1; }
printf 'resolved\n' > "$T/shared.txt"
git -C "$T" add shared.txt
git -C "$T" commit -qm "resolve conflict"
collect_out="$(bash "$CLI" collect wt2 2>&1)"
echo "$collect_out" | grep -q "manually resolved conflicts" || { echo "resolved merge must print the full-checks hint" >&2; exit 1; }
grep -q "^conflicts: resolved" "$STATE/wt2.collected" || { echo "collected state must record resolved conflicts" >&2; exit 1; }
[[ ! -f "$STATE/wt2.conflict" ]] || { echo "resolved collect must clear the conflict marker" >&2; exit 1; }
bash "$CLI" release wt2 >/dev/null

# The guide is rendered from the policy config.
printf 'READY_MODE=confirm\nEVIDENCE=none\nINTEGRATE_CHECKS=ci\n' >> "$T/.pitbox/config"
guide_out="$(bash "$CLI" guide)"
echo "$guide_out" | grep -q "policy: ready=confirm evidence=none push=off checks=ci" || { echo "guide must print the policy" >&2; exit 1; }
echo "$guide_out" | grep -q "after the user explicitly confirms" || { echo "confirm mode must demand user confirmation" >&2; exit 1; }
echo "$guide_out" | grep -q "Checks belong to CI" || { echo "ci mode must delegate checks to CI" >&2; exit 1; }
if echo "$guide_out" | grep -qi "screenshot"; then echo "EVIDENCE=none must not mention screenshots" >&2; exit 1; fi
if echo "$guide_out" | grep -q "full checks"; then echo "INTEGRATE_CHECKS=ci must not demand a local full run" >&2; exit 1; fi
sed -i '/^READY_MODE=confirm$/d;/^EVIDENCE=none$/d;/^INTEGRATE_CHECKS=ci$/d' "$T/.pitbox/config"
guide_out="$(bash "$CLI" guide)"
echo "$guide_out" | grep -q "policy: ready=auto evidence=auto push=off checks=auto" || { echo "guide must return to the defaults" >&2; exit 1; }
echo "$guide_out" | grep -q "manually resolved conflicts" || { echo "auto mode must gate the full checks on conflicts" >&2; exit 1; }
echo "$guide_out" | grep -q "pool never waits for CI" || { echo "auto mode must keep the pool free of CI waits" >&2; exit 1; }

echo "INTEGRATE_CHECKS=full" >> "$T/.pitbox/config"
guide_out="$(bash "$CLI" guide)"
echo "$guide_out" | grep -q "checks=full" || { echo "guide must print checks=full" >&2; exit 1; }
echo "$guide_out" | grep -q "Run the repository's full checks" || { echo "full mode must demand the full checks" >&2; exit 1; }
sed -i '/^INTEGRATE_CHECKS=full$/d' "$T/.pitbox/config"

echo "READY_MODE=bogus" >> "$T/.pitbox/config"
expect_fail status                   # invalid policy values are refused
sed -i '/^READY_MODE=bogus$/d' "$T/.pitbox/config"
echo "INTEGRATE_CHECKS=bogus" >> "$T/.pitbox/config"
expect_fail status
sed -i '/^INTEGRATE_CHECKS=bogus$/d' "$T/.pitbox/config"

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
