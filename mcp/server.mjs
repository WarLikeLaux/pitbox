#!/usr/bin/env node
// pitbox MCP server: zero-dependency stdio JSON-RPC facade over the pitbox CLI.
import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { dirname, isAbsolute, join } from "node:path";
import { fileURLToPath } from "node:url";
import readline from "node:readline";

const VERSION = "0.7.0";
const PROTOCOL_VERSION = "2025-06-18";
const DEFAULT_TIMEOUT_MS = 120000;

const here = dirname(fileURLToPath(import.meta.url));
function cliPath() {
    if (process.env.PITBOX_BIN) return process.env.PITBOX_BIN;
    const bundled = join(here, "..", "bin", "pitbox");
    if (existsSync(bundled)) return bundled;
    return "pitbox";
}

function runCli(args, repo) {
    const timeoutMs = Number(process.env.PITBOX_TIMEOUT_MS) || DEFAULT_TIMEOUT_MS;
    return new Promise((resolve) => {
        const child = spawn("bash", [cliPath(), ...args], { cwd: repo });
        let out = "";
        let err = "";
        let timedOut = false;
        const timer = setTimeout(() => {
            timedOut = true;
            child.kill("SIGKILL");
        }, timeoutMs);
        child.stdout.on("data", (chunk) => { out += chunk; });
        child.stderr.on("data", (chunk) => { err += chunk; });
        child.on("error", (e) => {
            clearTimeout(timer);
            resolve({ code: 127, out, err: `${err}${err ? "\n" : ""}${e.message}` });
        });
        child.on("close", (code) => {
            clearTimeout(timer);
            if (timedOut) {
                resolve({ code: 124, out, err: `${err}${err ? "\n" : ""}pitbox: timed out after ${timeoutMs}ms, a .pitbox hook may be hanging` });
                return;
            }
            resolve({ code: code ?? 1, out, err });
        });
    });
}

// Plugin hosts can run this server from a cache, so each tool requires an explicit repo path.
function serverInstructions() {
    return "Pitbox manages reusable Git worktree slots and handoff markers. " +
        "Pass repo as the absolute path to the target repository or worktree on every call. " +
        "Follow repository instructions for task routing, checks, review, CI, push, and deployment. " +
        "A worker claims a slot, commits its work, and marks the slot ready. " +
        "Only a separate session explicitly asked by the user collects ready slots. " +
        "After repository delivery steps, the integrator releases collected slots. " +
        "Pitbox does not run tests, check CI, or deploy.";
}

const TOOLS = [
    {
        name: "status",
        description: "Show the registered slot paths, branches, dirty counts, commits ahead of main, and work, ready, or collected state.",
        inputSchema: { type: "object", properties: {}, additionalProperties: false },
        args: () => ["status"],
    },
    {
        name: "setup",
        description: "Create the fixed slot pool. Omit count to use SLOTS from .pitbox/config or three slots by default.",
        inputSchema: {
            type: "object",
            properties: { count: { type: "integer", minimum: 1, maximum: 10, description: "Number of slots to create" } },
            additionalProperties: false,
        },
        args: (a) => (a.count !== undefined ? ["setup", String(a.count)] : ["setup"]),
    },
    {
        name: "claim",
        description: "Atomically take a free slot and create a task branch. Omit slot to let Pitbox choose one. Continue work in the returned path.",
        inputSchema: {
            type: "object",
            properties: {
                slot: { type: "string", description: "Slot name, e.g. wt1; omit to choose a free slot" },
                name: { type: "string", description: "Task branch name; omit to generate one" },
            },
            additionalProperties: false,
        },
        args: (a) => {
            if (a.slot) return ["claim", a.slot, ...(a.name ? [a.name] : [])];
            if (a.name) return ["claim", a.name];
            return ["claim"];
        },
    },
    {
        name: "ready",
        description: "Record a clean task branch and its exact HEAD as ready. This does not run checks or merge the branch.",
        inputSchema: {
            type: "object",
            properties: {
                slot: { type: "string", description: "Slot name, e.g. wt1" },
                note: { type: "string", description: "Optional handoff note" },
            },
            required: ["slot"],
            additionalProperties: false,
        },
        args: (a) => ["ready", a.slot, ...(a.note ? [a.note] : [])],
    },
    {
        name: "unready",
        description: "Remove the ready marker while continuing work in a slot after feedback.",
        inputSchema: {
            type: "object",
            properties: { slot: { type: "string", description: "Slot name, e.g. wt1" } },
            required: ["slot"],
            additionalProperties: false,
        },
        args: (a) => ["unready", a.slot],
    },
    {
        name: "collect",
        description: "Merge a slot branch into main when the user explicitly requests integration. Use slot=ready for only marked slots. A named unmarked slot produces a warning. Refuses dirty main or changed ready HEAD.",
        inputSchema: {
            type: "object",
            properties: { slot: { type: "string", description: "Slot name or the literal string ready" } },
            required: ["slot"],
            additionalProperties: false,
        },
        args: (a) => ["collect", a.slot],
    },
    {
        name: "release",
        description: "Return a slot to the pool after repository delivery or an intentional task abort. Resets the worktree, preserves unmerged branches, and runs its optional release hook.",
        inputSchema: {
            type: "object",
            properties: { slot: { type: "string", description: "Slot name, e.g. wt1" } },
            required: ["slot"],
            additionalProperties: false,
        },
        args: (a) => ["release", a.slot],
    },
].map((tool) => ({
    ...tool,
    description: "Pass repo as the absolute path to the target Git repository or worktree. " + tool.description,
    inputSchema: {
        ...tool.inputSchema,
        properties: {
            repo: { type: "string", description: "Absolute path to the target Git repository or worktree" },
            ...tool.inputSchema.properties,
        },
        required: ["repo", ...(tool.inputSchema.required ?? [])],
    },
}));

function send(msg) {
    process.stdout.write(`${JSON.stringify(msg)}\n`);
}

function result(id, payload) {
    send({ jsonrpc: "2.0", id, result: payload });
}

function error(id, code, message) {
    send({ jsonrpc: "2.0", id, error: { code, message } });
}

async function callTool(id, name, args) {
    const tool = TOOLS.find((t) => t.name === name);
    if (!tool) {
        error(id, -32602, `unknown tool: ${name}`);
        return;
    }
    const repo = args?.repo;
    if (typeof repo !== "string" || !isAbsolute(repo) || !existsSync(repo)) {
        result(id, { content: [{ type: "text", text: "repo must be an absolute path to an existing Git repository or worktree" }], isError: true });
        return;
    }
    try {
        const { code, out, err } = await runCli(tool.args(args ?? {}), repo);
        const text = `${out}${err ? (out ? "\n" : "") + err : ""}`.trim();
        result(id, { content: [{ type: "text", text: text || "(no output)" }], isError: code !== 0 });
    } catch (e) {
        result(id, { content: [{ type: "text", text: `pitbox-mcp error: ${e.message}` }], isError: true });
    }
}

async function handleMessage(msg) {
    const { id, method, params } = msg;
    const isNotification = id === undefined || id === null;
    switch (method) {
        case "initialize":
            result(id, {
                protocolVersion: PROTOCOL_VERSION,
                capabilities: { tools: {} },
                serverInfo: { name: "pitbox-mcp", version: VERSION },
                instructions: serverInstructions(),
            });
            return;
        case "ping":
            result(id, {});
            return;
        case "tools/list":
            result(id, {
                tools: TOOLS.map(({ name, description, inputSchema }) => ({ name, description, inputSchema })),
            });
            return;
        case "tools/call":
            await callTool(id, params?.name, params?.arguments);
            return;
        default:
            if (!isNotification) error(id, -32601, `method not found: ${method}`);
    }
}

const rl = readline.createInterface({ input: process.stdin, terminal: false });
rl.on("line", (line) => {
    const trimmed = line.trim();
    if (!trimmed) return;
    let msg;
    try {
        msg = JSON.parse(trimmed);
    } catch {
        error(null, -32700, "parse error");
        return;
    }
    handleMessage(msg).catch((e) => {
        if (msg?.id !== undefined && msg?.id !== null) error(msg.id, -32603, `internal error: ${e.message}`);
    });
});
rl.on("close", () => process.exit(0));
