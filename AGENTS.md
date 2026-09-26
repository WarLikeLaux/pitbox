# Maintaining pitbox

- When `mcp/server.mjs` changes, copy it to `plugin/mcp/server.mjs` before testing.
- MCP plugin hosts can start the server in a cache directory. Repository tools must use the explicit absolute `repo` argument, never the server process's working directory.
- When any file under `plugin/` changes, increase the version in `plugin/plugin.json`, `plugin/.claude-plugin/plugin.json`, and `.claude-plugin/marketplace.json` together. CLI-only changes do not need a plugin version bump.
- Run `bash scripts/smoke.sh` before publishing changes.
- If this task publishes changes to `plugin/` or `bin/pitbox` on `origin/main`, run `bash scripts/update-installed.sh` from the clean main checkout after the push. Complete this local update in the same task and report the result. The script refreshes all agent plugins (Claude Code, Codex, MiniMax Code / mavis) and the standalone CLI, and additionally runs `mcode update` to refresh the MiniMax Code CLI itself. Pass `--only=claude|codex|mavis|mavis-cli|cli` to limit targets.
