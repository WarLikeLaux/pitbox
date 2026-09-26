#!/usr/bin/env node
// MCP stdio round-trip: initialize, tools/list, tools/call (guide, status, init).
// Usage: node scripts/mcp-smoke.mjs <git-repo-path>
import { spawn } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { strict as assert } from "node:assert";

const here = dirname(fileURLToPath(import.meta.url));
const serverPath = join(here, "..", "mcp", "server.mjs");
const repo = process.argv[2] ?? process.cwd();

// A plugin host may start the server outside the repository.
const child = spawn("node", [serverPath], { cwd: dirname(repo) });
let buffer = "";
const pending = new Map();
let nextId = 1;

child.stdout.on("data", (chunk) => {
    buffer += chunk;
    let idx;
    while ((idx = buffer.indexOf("\n")) !== -1) {
        const line = buffer.slice(0, idx);
        buffer = buffer.slice(idx + 1);
        if (!line.trim()) continue;
        const msg = JSON.parse(line);
        const resolve = pending.get(msg.id);
        if (resolve) {
            pending.delete(msg.id);
            resolve(msg);
        }
    }
});

function request(method, params) {
    const id = nextId++;
    return new Promise((resolve, reject) => {
        pending.set(id, resolve);
        child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`);
        setTimeout(() => {
            if (pending.has(id)) {
                pending.delete(id);
                reject(new Error(`timeout waiting for ${method}`));
            }
        }, 15000);
    });
}

function notification(method) {
    child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", method })}\n`);
}

const init = await request("initialize", {
    protocolVersion: "9999.99.99-does-not-exist",
    capabilities: {},
    clientInfo: { name: "pitbox-smoke", version: "0.0.0" },
});
// The server reports its own supported protocol version, it never echoes the client's.
assert.equal(init.result.protocolVersion, "2025-06-18");
assert.equal(init.result.serverInfo.name, "pitbox-mcp");
assert.ok(typeof init.result.instructions === "string" && init.result.instructions.includes("pitbox"), "missing server instructions");
assert.ok(init.result.instructions.includes("repo"));
notification("notifications/initialized");

const list = await request("tools/list", {});
const names = list.result.tools.map((t) => t.name);
for (const expected of ["guide", "status", "claim", "setup", "ready", "collect", "release", "init"]) {
    assert.ok(names.includes(expected), `missing tool ${expected}`);
}
assert.ok(list.result.tools.every((t) => t.inputSchema && t.description.length > 40));
for (const tool of list.result.tools) {
    assert.ok(tool.inputSchema.required.includes("repo"), `${tool.name} must require repo`);
}

const guide = await request("tools/call", { name: "guide", arguments: { repo } });
assert.equal(guide.result.isError, false);
assert.ok(guide.result.content[0].text.includes("pitbox workflow guide"));

const missingRepo = await request("tools/call", { name: "status", arguments: {} });
assert.equal(missingRepo.result.isError, true);

const bogusRepo = await request("tools/call", { name: "guide", arguments: { repo: "not/absolute" } });
assert.equal(bogusRepo.result.isError, true);

const status = await request("tools/call", { name: "status", arguments: { repo } });
assert.equal(status.result.isError, false);
assert.ok(status.result.content[0].text.includes("main branch"));

const claim = await request("tools/call", { name: "claim", arguments: { repo, name: "task/mcp" } });
assert.equal(claim.result.isError, false, `claim failed: ${claim.result.content[0].text}`);
assert.ok(claim.result.content[0].text.includes("claimed") && claim.result.content[0].text.includes("task/mcp"));

const initCall = await request("tools/call", { name: "init", arguments: { repo, stack: "bun", force: true } });
assert.equal(initCall.result.isError, false, `init failed: ${initCall.result.content[0].text}`);
assert.ok(initCall.result.content[0].text.includes(".pitbox/"));

const bogus = await request("tools/call", { name: "nope", arguments: {} });
assert.equal(bogus.error.code, -32602);

child.stdin.end();
console.log("mcp-smoke: all checks passed");
