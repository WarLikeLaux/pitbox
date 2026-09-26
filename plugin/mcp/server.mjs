#!/usr/bin/env node
// pitbox MCP server: zero-dependency stdio JSON-RPC facade over the pitbox CLI.
// The workflow rules are repository-specific and rendered by `pitbox guide`
// from .pitbox/config, so descriptions here only say when to call a tool.
import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { dirname, isAbsolute, join } from "node:path";
import { fileURLToPath } from "node:url";
import readline from "node:readline";

const VERSION = "0.4.0";
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

const MODE_RULE = "Workflow rule: one task = work in the main checkout, two or three parallel tasks = one slot each, the main checkout belongs to the integrator.";

// Plugin hosts can start this server inside their cache, so initialize cannot
// infer the caller's repository from process.cwd().
function serverInstructions() {
    return "pitbox manages a fixed pool of git worktree slots per repository. " +
        "Pass repo as the absolute path to the target repository or worktree on every call. " +
        "Lifecycle: an agent claims a slot, works in it, commits, and marks it ready; only on an explicit user " +
        "request the integrator collects ready slots, runs the checks the repository policy defines, deploys once, pushes, " +
        "and releases the slots. A ready marker never merges or deploys. " +
        "The workflow rules are repository-specific: call guide with the repo path and follow its output. " +
        "If the repository has no .pitbox/config, run init, review and commit .pitbox/, then run setup.";
}

const TOOLS = [
    {
        name: "guide",
        description:
            "Print the workflow rules for this repository, rendered from its .pitbox/config policy " +
            "(ready mode, evidence, push requirement) with the priority over AGENTS.md delivery rules. " +
            "Call it before slot work and follow it.",
        inputSchema: { type: "object", properties: {}, additionalProperties: false },
        args: () => ["guide"],
    },
    {
        name: "status",
        description:
            "Show the pitbox slot pool for the repository: branch, dirty files, commits ahead of main, " +
            "state (work/ready/collected) per slot and the active policy line. " + MODE_RULE,
        inputSchema: { type: "object", properties: {}, additionalProperties: false },
        args: () => ["status"],
    },
    {
        name: "setup",
        description:
            "Create the fixed slot worktrees wt1..wtN next to the main checkout and register them. " +
            "Slots are a fixed pool: create them once and reuse them, never spawn ad-hoc worktrees. " +
            "Call when a new parallel task starts and no free slot exists. " + MODE_RULE,
        inputSchema: {
            type: "object",
            properties: { count: { type: "integer", minimum: 1, maximum: 10, default: 3, description: "How many slots to create, default 3" } },
            additionalProperties: false,
        },
        args: (a) => (a.count !== undefined ? ["setup", String(a.count)] : ["setup"]),
    },
    {
        name: "claim",
        description:
            "Take a free slot for a new parallel task: pitbox books a slot atomically and creates your task " +
            "branch in it. Omit slot to auto-pick the first free one. Never book a slot from status by hand, " +
            "two agents can race. Work in the returned path, never touch other slots. " + MODE_RULE,
        inputSchema: {
            type: "object",
            properties: {
                slot: { type: "string", description: "Slot name, e.g. wt1; the first free slot is auto-picked when omitted" },
                name: { type: "string", description: "Task branch name, e.g. task/feat-auth; a timestamped task/* name is generated when omitted" },
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
        description:
            "Mark the slot's task ready after the work is committed: records the branch and its exact HEAD in the " +
            "pitbox state inside .git. Never merges, deploys, or starts collection. When to call it (immediately " +
            "after checks, or only after user confirmation) and what proof of work to show is defined by the " +
            "repository policy, see guide.",
        inputSchema: {
            type: "object",
            properties: {
                slot: { type: "string", description: "Slot name, e.g. wt1" },
                note: { type: "string", description: "Optional note recorded with the marker" },
            },
            required: ["slot"],
            additionalProperties: false,
        },
        args: (a) => ["ready", a.slot, ...(a.note ? [a.note] : [])],
    },
    {
        name: "collect",
        description:
            "Integrator tool, call only on an explicit user request: merge the slot's task branch into the main " +
            "branch with a --no-ff merge commit. Pass the literal string 'ready' to collect every ready slot; " +
            "already collected slots are skipped until released. If the merge stops with conflicts, resolve them " +
            "in the main checkout, commit, and run collect again. Refusals are final, do not force. After " +
            "collecting, run the checks the repository policy defines (guide renders them), push, release each collected slot, and deploy at the policy-defined time. The pool never waits for CI.",
        inputSchema: {
            type: "object",
            properties: { slot: { type: "string", description: "Slot name, e.g. wt1, or the literal string 'ready'" } },
            required: ["slot"],
            additionalProperties: false,
        },
        args: (a) => ["collect", a.slot],
    },
    {
        name: "release",
        description:
            "Integrator tool: reset the slot to the main branch, delete the merged task branch, clear its state, " +
            "run .pitbox/release.sh (or setup.sh). Call only after collect succeeded and the main branch passed " +
            "its checks, and was deployed and pushed when the repository's rules require it.",
        inputSchema: {
            type: "object",
            properties: { slot: { type: "string", description: "Slot name, e.g. wt1" } },
            required: ["slot"],
            additionalProperties: false,
        },
        args: (a) => ["release", a.slot],
    },
    {
        name: "init",
        description:
            "Write .pitbox/ templates (config, setup.sh, release.sh) for this repository so pitbox knows how to " +
            "prepare and clean slots. Auto-detects the stack (bun, php-docker) or takes an explicit stack. " +
            "Run once per repository, review and commit the result.",
        inputSchema: {
            type: "object",
            properties: {
                stack: { type: "string", enum: ["bun", "php-docker"], description: "Stack template, auto-detected when omitted" },
                force: { type: "boolean", description: "Overwrite an existing .pitbox/ directory", default: false },
            },
            additionalProperties: false,
        },
        args: (a) => ["init", ...(a.stack ? ["--stack", a.stack] : []), ...(a.force ? ["--force"] : [])],
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
