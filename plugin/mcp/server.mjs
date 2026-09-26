#!/usr/bin/env node
// pitbox MCP server: zero-dependency stdio JSON-RPC facade over the pitbox CLI.
// The workflow rules live in the tool descriptions and in the `guide` tool,
// so agents follow pitbox without any AGENTS.md edits.
import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { dirname, isAbsolute, join } from "node:path";
import { fileURLToPath } from "node:url";
import readline from "node:readline";

const VERSION = "0.3.1";

const here = dirname(fileURLToPath(import.meta.url));
function cliPath() {
    if (process.env.PITBOX_BIN) return process.env.PITBOX_BIN;
    const bundled = join(here, "..", "bin", "pitbox");
    if (existsSync(bundled)) return bundled;
    return "pitbox";
}

function runCli(args, repo) {
    return new Promise((resolve) => {
        const child = spawn("bash", [cliPath(), ...args], { cwd: repo });
        let out = "";
        let err = "";
        child.stdout.on("data", (chunk) => { out += chunk; });
        child.stderr.on("data", (chunk) => { err += chunk; });
        child.on("error", (e) => resolve({ code: 127, out, err: `${err}${err ? "\n" : ""}${e.message}` }));
        child.on("close", (code) => resolve({ code: code ?? 1, out, err }));
    });
}

const MODE_RULE = "Workflow rule: one task = work in the main checkout, two or three parallel tasks = one slot each, the main checkout belongs to the integrator.";

// Plugin hosts can start this server inside their cache, so initialize cannot
// infer the caller's repository from process.cwd().
function serverInstructions() {
    return "pitbox manages a fixed pool of git worktree slots. For every repository tool call, pass repo as the absolute path " +
        "to the target repository or worktree. If the repository has no .pitbox/config, run init, review and commit .pitbox/, " +
        "then run setup. The task lifecycle is claim, work, ready, collect, release. " +
        "Slot agents claim a free slot, verify work, preview visual changes with screenshots without deploying, " +
        "honor user acceptance requirements, commit, and call ready. A request to collect a shown visual result counts as acceptance. " +
        "In slot mode, defer repository deploy-before-commit requirements until integration: slot agents never deploy. " +
        "The integrator calls collect, runs the full checks, deploys once, pushes, then calls release. " +
        "Call guide for the full rules and status for the pool state.";
}

const TOOLS = [
    {
        name: "guide",
        description:
            "Print the full pitbox workflow rules: modes (one task in the main checkout, two or three parallel tasks in slots), " +
            "slot agent duties, integrator duties, override rules. Read this once before using the other pitbox tools.",
        inputSchema: { type: "object", properties: {}, additionalProperties: false },
        args: () => ["guide"],
    },
    {
        name: "status",
        description:
            "Show the pitbox slot pool for the current repository: branch, dirty files, commits ahead of main, " +
            "TASK_READY.md readiness and path per slot. Call this to see the pool state, when checking whether work is ready, " +
            "and before integrating. To start a new parallel task use claim, never book a slot by hand. " + MODE_RULE,
        inputSchema: { type: "object", properties: {}, additionalProperties: false },
        args: () => ["status"],
    },
    {
        name: "setup",
        description:
            "Create the fixed slot worktrees wt1..wtN next to the main checkout and run .pitbox/setup.sh in each new one. " +
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
            "Take a free slot for a new parallel task: pitbox books a slot atomically and creates your task branch in it. " +
            "Pass a branch name for the task branch, omit slot to auto-pick the first free one. " +
            "Never pick a slot from status and create branches by hand, two agents can race for the same slot. " +
            "One task per slot, never touch other slots. " + MODE_RULE,
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
            "Mark the slot's task ready for integration: writes TASK_READY.md recording the branch and its exact HEAD, refuses if the " +
            "slot is dirty, still on its slot/wtN stub branch, or (when REQUIRE_PUSH=1) has unpushed commits. Call it only after you " +
            "verified the work and committed the task branch. For visual work, a local preview or Playwright screenshot can " +
            "satisfy the review step before user acceptance; defer any repository deploy-before-commit rule to integration. " +
            "Never merge into the main branch, never deploy, never touch other " +
            "slots, the integrator does that.",
        inputSchema: {
            type: "object",
            properties: {
                slot: { type: "string", description: "Slot name, e.g. wt1" },
                note: { type: "string", description: "Optional note recorded in TASK_READY.md" },
            },
            required: ["slot"],
            additionalProperties: false,
        },
        args: (a) => ["ready", a.slot, ...(a.note ? [a.note] : [])],
    },
    {
        name: "collect",
        description:
            "Integrator tool: merge the slot's task branch into the main branch with a --no-ff merge commit. " +
            "Pass the literal string 'ready' as slot to collect every slot with TASK_READY.md. " +
            "collect refuses to run when the main worktree is off the main branch or dirty, and when a slot changed after its " +
            "marker was written. After collecting, run the repository's full checks, perform the deferred deployment once, " +
            "push, then release each collected slot. Report refusals, do not force.",
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
            "Integrator tool: reset the slot to the main branch, delete the merged task branch, clear TASK_READY.md, " +
            "run .pitbox/release.sh (or setup.sh). Call only after collect succeeded and the main branch passed its checks, " +
            "and was deployed and pushed when the repository's rules require it.",
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
            "Write .pitbox/ templates (config, setup.sh, release.sh) for this repository so pitbox knows how to prepare and " +
            "clean slots. Auto-detects the stack (bun, php-docker) or take an explicit stack. Writes files into the repository " +
            "root, run once per repository, commit the result.",
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
].map((tool) => tool.name === "guide" ? tool : {
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
});

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
    const repo = name === "guide" ? process.cwd() : args?.repo;
    if (name !== "guide" && (typeof repo !== "string" || !isAbsolute(repo) || !existsSync(repo))) {
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
                protocolVersion: params?.protocolVersion ?? "2025-06-18",
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
