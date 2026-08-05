/**
 * Composite MCP server: proxies cua-driver MCP tools and adds ultragateway native tools.
 * Stdio transport — launched by supergateway via run-gateway.sh.
 */
import { spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { randomUUID } from "node:crypto";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const SUPPORT_DIR =
  process.env.ULTRAGATEWAY_SUPPORT_DIR ||
  path.join(os.homedir(), "Library/Application Support/ultragateway");

const CUA_DRIVER_BIN =
  process.env.CUA_DRIVER_BIN || path.join(os.homedir(), ".local/bin/cua-driver");

const SHELL_ENABLED = process.env.NATIVE_SHELL_ENABLED !== "0";
const SHELL_TIMEOUT_DEFAULT = Number(process.env.NATIVE_SHELL_TIMEOUT || "30");
const SHELL_TIMEOUT_MAX = Number(process.env.NATIVE_SHELL_TIMEOUT_MAX || "300");
const NOTIFY_ENABLED = process.env.NATIVE_NOTIFY_ENABLED !== "0";

const NOTIFY_QUEUE = path.join(SUPPORT_DIR, "notify-queue.jsonl");

const NATIVE_TOOLS = [
  {
    name: "ultragateway_run_zsh",
    description:
      "Run a shell command in zsh on the user's Mac. Returns stdout, stderr, and exit code. Use for local automation only.",
    inputSchema: {
      type: "object",
      properties: {
        command: {
          type: "string",
          description: "Shell command to run (executed via zsh -lc).",
        },
        working_directory: {
          type: "string",
          description: "Optional working directory (defaults to user home).",
        },
        timeout_seconds: {
          type: "number",
          description: "Max seconds to wait (default 30, max 300).",
        },
      },
      required: ["command"],
    },
  },
  {
    name: "ultragateway_notify",
    description:
      "Show a macOS notification branded as ultragateway (Notification Center). Requires the ultragateway menu bar app for the app icon.",
    inputSchema: {
      type: "object",
      properties: {
        message: {
          type: "string",
          description: "Notification body text.",
        },
        title: {
          type: "string",
          description: "Notification title (default: ultragateway).",
        },
        subtitle: {
          type: "string",
          description: "Optional subtitle shown under the title.",
        },
      },
      required: ["message"],
    },
  },
];

function log(...args) {
  console.error("[ultragateway-mcp]", ...args);
}

function textResult(text, isError = false) {
  return {
    content: [{ type: "text", text }],
    isError,
  };
}

function shellQuote(value) {
  return `'${String(value).replace(/'/g, `'\\''`)}'`;
}

function menubarRunning() {
  try {
    const r = spawn("pgrep", ["-f", "ultragateway-menubar"], { stdio: "ignore" });
    return new Promise((resolve) => {
      r.on("close", (code) => resolve(code === 0));
      r.on("error", () => resolve(false));
    });
  } catch {
    return false;
  }
}

async function runZsh(args) {
  if (!SHELL_ENABLED) {
    return textResult("Shell commands are disabled (NATIVE_SHELL_ENABLED=0).", true);
  }

  const command = String(args?.command ?? "").trim();
  if (!command) {
    return textResult("command is required.", true);
  }

  const cwd = args?.working_directory
    ? path.resolve(String(args.working_directory))
    : os.homedir();

  if (!fs.existsSync(cwd)) {
    return textResult(`working_directory does not exist: ${cwd}`, true);
  }

  let timeoutSec = Number(args?.timeout_seconds ?? SHELL_TIMEOUT_DEFAULT);
  if (!Number.isFinite(timeoutSec) || timeoutSec <= 0) {
    timeoutSec = SHELL_TIMEOUT_DEFAULT;
  }
  timeoutSec = Math.min(timeoutSec, SHELL_TIMEOUT_MAX);

  return new Promise((resolve) => {
    const child = spawn("/bin/zsh", ["-lc", command], {
      cwd,
      env: { ...process.env, LANG: process.env.LANG || "en_US.UTF-8" },
      stdio: ["ignore", "pipe", "pipe"],
    });

    let stdout = "";
    let stderr = "";
    let killed = false;

    const timer = setTimeout(() => {
      killed = true;
      child.kill("SIGTERM");
      setTimeout(() => child.kill("SIGKILL"), 1000);
    }, timeoutSec * 1000);

    child.stdout?.on("data", (chunk) => {
      stdout += chunk.toString();
      if (stdout.length > 512_000) stdout = stdout.slice(0, 512_000) + "\n…(truncated)";
    });
    child.stderr?.on("data", (chunk) => {
      stderr += chunk.toString();
      if (stderr.length > 512_000) stderr = stderr.slice(0, 512_000) + "\n…(truncated)";
    });

    child.on("close", (code, signal) => {
      clearTimeout(timer);
      const exitCode = killed ? 124 : code ?? 1;
      const summary = [
        `exit_code: ${exitCode}`,
        killed ? `timed_out: true (${timeoutSec}s)` : `timed_out: false`,
        signal ? `signal: ${signal}` : null,
        `working_directory: ${cwd}`,
        "",
        "--- stdout ---",
        stdout || "(empty)",
        "",
        "--- stderr ---",
        stderr || "(empty)",
      ]
        .filter(Boolean)
        .join("\n");
      resolve(textResult(summary, exitCode !== 0));
    });

    child.on("error", (err) => {
      clearTimeout(timer);
      resolve(textResult(`Failed to spawn zsh: ${err.message}`, true));
    });
  });
}

async function osascriptNotify(title, message, subtitle) {
  const parts = [`display notification ${shellQuote(message)} with title ${shellQuote(title)}`];
  if (subtitle) {
    parts[0] += ` subtitle ${shellQuote(subtitle)}`;
  }
  const script = parts[0];
  return new Promise((resolve) => {
    const child = spawn("osascript", ["-e", script], { stdio: "ignore" });
    child.on("close", (code) => resolve(code === 0));
    child.on("error", () => resolve(false));
  });
}

async function queueNotification(entry) {
  fs.mkdirSync(SUPPORT_DIR, { recursive: true });
  fs.appendFileSync(NOTIFY_QUEUE, `${JSON.stringify(entry)}\n`, "utf8");
}

async function notify(args) {
  if (!NOTIFY_ENABLED) {
    return textResult("Notifications are disabled (NATIVE_NOTIFY_ENABLED=0).", true);
  }

  const message = String(args?.message ?? "").trim();
  if (!message) {
    return textResult("message is required.", true);
  }

  const title = String(args?.title ?? "ultragateway").trim() || "ultragateway";
  const subtitle = args?.subtitle ? String(args.subtitle).trim() : "";

  const entry = {
    id: randomUUID(),
    title,
    body: message,
    subtitle,
    timestamp: Date.now(),
  };

  await queueNotification(entry);

  const hasMenubar = await menubarRunning();
  if (hasMenubar) {
  } else {
    await osascriptNotify(title, message, subtitle);
  }

  return textResult(
    `Notification queued (id: ${entry.id}).${
      hasMenubar
        ? " ultragateway menu bar app will display it."
        : " Menu bar app not running — sent via system notification fallback."
    }`,
  );
}

async function connectCuaClient() {
  if (!fs.existsSync(CUA_DRIVER_BIN)) {
    log(`cua-driver not found at ${CUA_DRIVER_BIN} — only native tools available`);
    return null;
  }

  const transport = new StdioClientTransport({
    command: CUA_DRIVER_BIN,
    args: ["mcp"],
    env: process.env,
    cwd: os.homedir(),
    stderr: "pipe",
  });

  // Drain stderr so the child never blocks once the pipe buffer fills (~8KB).
  // Attach before connect() so early startup output is not lost.
  transport.stderr?.on("data", (chunk) => {
    const text = chunk.toString().trimEnd();
    if (text) log(`[cua-driver] ${text}`);
  });

  const client = new Client(
    { name: "ultragateway-cua-proxy", version: "1.0.0" },
    { capabilities: {} },
  );

  try {
    await client.connect(transport);
    log(`Connected to cua-driver at ${CUA_DRIVER_BIN}`);
    return client;
  } catch (err) {
    log(`Failed to connect cua-driver: ${err.message}`);
    return null;
  }
}

async function main() {
  const cuaClient = await connectCuaClient();

  const server = new Server(
    { name: "ultragateway", version: "1.0.0" },
    { capabilities: { tools: {} } },
  );

  server.setRequestHandler(ListToolsRequestSchema, async () => {
    const tools = [...NATIVE_TOOLS];
    if (cuaClient) {
      try {
        const result = await cuaClient.listTools();
        tools.push(...(result.tools ?? []));
      } catch (err) {
        log(`listTools from cua-driver failed: ${err.message}`);
      }
    }
    return { tools };
  });

  server.setRequestHandler(CallToolRequestSchema, async (request) => {
    const { name, arguments: args } = request.params;

    if (name === "ultragateway_run_zsh") {
      return await runZsh(args ?? {});
    }
    if (name === "ultragateway_notify") {
      return await notify(args ?? {});
    }

    if (!cuaClient) {
      return textResult(`Unknown tool: ${name} (cua-driver not connected)`, true);
    }

    try {
      return await cuaClient.callTool({ name, arguments: args ?? {} });
    } catch (err) {
      return textResult(`cua-driver tool error: ${err.message}`, true);
    }
  });

  const transport = new StdioServerTransport();
  await server.connect(transport);
  log("ultragateway composite MCP server listening on stdio");
}

main().catch((err) => {
  log("Fatal:", err);
  process.exit(1);
});
