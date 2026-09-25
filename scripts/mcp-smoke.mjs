#!/usr/bin/env node
// MCP stdio round-trip: initialize, tools/list, tools/call (guide, status, init).
// Usage: node scripts/mcp-smoke.mjs <cwd-inside-a-git-repo>
import { spawn } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { strict as assert } from "node:assert";

const here = dirname(fileURLToPath(import.meta.url));
const serverPath = join(here, "..", "mcp", "server.mjs");
const cwd = process.argv[2] ?? process.cwd();

const child = spawn("node", [serverPath], { cwd });
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
    protocolVersion: "2025-06-18",
    capabilities: {},
    clientInfo: { name: "pitbox-smoke", version: "0.0.0" },
});
assert.equal(init.result.serverInfo.name, "pitbox-mcp");
notification("notifications/initialized");

const list = await request("tools/list", {});
const names = list.result.tools.map((t) => t.name);
for (const expected of ["guide", "status", "setup", "ready", "collect", "release", "init"]) {
    assert.ok(names.includes(expected), `missing tool ${expected}`);
}
assert.ok(list.result.tools.every((t) => t.inputSchema && t.description.length > 40));

const guide = await request("tools/call", { name: "guide", arguments: {} });
assert.equal(guide.result.isError, false);
assert.ok(guide.result.content[0].text.includes("pitbox workflow guide"));

const status = await request("tools/call", { name: "status", arguments: {} });
assert.equal(status.result.isError, false);
assert.ok(status.result.content[0].text.includes("main branch"));

const initCall = await request("tools/call", { name: "init", arguments: { stack: "bun", force: true } });
assert.equal(initCall.result.isError, false, `init failed: ${initCall.result.content[0].text}`);
assert.ok(initCall.result.content[0].text.includes(".slots/"));

const bogus = await request("tools/call", { name: "nope", arguments: {} });
assert.equal(bogus.error.code, -32602);

child.stdin.end();
console.log("mcp-smoke: all checks passed");
