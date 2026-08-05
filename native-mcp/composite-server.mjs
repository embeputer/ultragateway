/**
 * Composite MCP server: proxies cua-driver MCP tools and adds ultragateway native tools.
 * Stdio transport — launched by supergateway via run-gateway.sh.
 */
import { spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { randomBytes, randomUUID } from "node:crypto";
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

const SHARE_TTL_SECONDS = (() => {
  const n = Number(process.env.SHARE_TTL_SECONDS || "600");
  return Number.isFinite(n) && n > 0 ? n : 600;
})();
const SHARE_MAX_BYTES = (() => {
  const n = Number(process.env.SHARE_MAX_BYTES || String(50 * 1024 * 1024));
  return Number.isFinite(n) && n > 0 ? n : 50 * 1024 * 1024;
})();
/** Reuse an existing share for the same path when more than this many seconds remain. */
const SHARE_REUSE_MIN_REMAINING_SECONDS = 300;

const NOTIFY_QUEUE = path.join(SUPPORT_DIR, "notify-queue.jsonl");
const SHARES_DIR = path.join(SUPPORT_DIR, "shares");

const EXT_CONTENT_TYPES = {
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".gif": "image/gif",
  ".webp": "image/webp",
  ".svg": "image/svg+xml",
  ".pdf": "application/pdf",
  ".txt": "text/plain",
  ".md": "text/markdown",
  ".json": "application/json",
  ".html": "text/html",
  ".htm": "text/html",
  ".csv": "text/csv",
  ".mp4": "video/mp4",
  ".mp3": "audio/mpeg",
  ".wav": "audio/wav",
  ".zip": "application/zip",
};

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
  {
    name: "ultragateway_share_file",
    description:
      "Copy a local file into an ephemeral share store and return a public HTTPS (or tunnel) URL others can open/download. Links expire after a short TTL (default 10 minutes). Max size 50MB. If the same path is already shared with more than 5 minutes remaining, returns the existing URL; if under 5 minutes remain, revokes and remints. Does not serve arbitrary live paths — only minted share tokens.",
    inputSchema: {
      type: "object",
      properties: {
        path: {
          type: "string",
          description: "Absolute or relative path to a local file to share (e.g. an image).",
        },
      },
      required: ["path"],
    },
  },
  {
    name: "ultragateway_close_shares",
    description:
      "Immediately revoke all ephemeral file shares. Deletes every minted share under the share store so existing /share/{token} links stop working.",
    inputSchema: {
      type: "object",
      properties: {},
      additionalProperties: false,
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

function guessContentType(filename) {
  const ext = path.extname(filename).toLowerCase();
  return EXT_CONTENT_TYPES[ext] || "application/octet-stream";
}

function readFirstLine(filePath) {
  try {
    const text = fs.readFileSync(filePath, "utf8").trim();
    if (!text) return null;
    return text.split(/\r?\n/)[0].trim() || null;
  } catch {
    return null;
  }
}

function resolvePublicBaseUrl() {
  const baseFile = path.join(SUPPORT_DIR, "public-base-url.txt");
  const mcpFile = path.join(SUPPORT_DIR, "public-mcp-url.txt");

  let base = readFirstLine(baseFile);
  if (!base) {
    const mcp = readFirstLine(mcpFile);
    if (mcp) {
      base = mcp.replace(/\/sse\/?$/i, "").replace(/\/$/, "");
    }
  }
  if (base) {
    return base.replace(/\/$/, "");
  }

  const port = process.env.SUPERGATEWAY_PORT || "8000";
  return `http://127.0.0.1:${port}`;
}

function cleanupExpiredShares() {
  try {
    if (!fs.existsSync(SHARES_DIR)) return;
    const now = Date.now();
    for (const name of fs.readdirSync(SHARES_DIR)) {
      if (!name.endsWith(".json")) continue;
      const metaPath = path.join(SHARES_DIR, name);
      try {
        const meta = JSON.parse(fs.readFileSync(metaPath, "utf8"));
        const expiresAt = Date.parse(meta.expiresAt);
        if (!Number.isFinite(expiresAt) || expiresAt > now) continue;
        const token =
          typeof meta.token === "string" && meta.token
            ? meta.token
            : name.slice(0, -".json".length);
        fs.rmSync(path.join(SHARES_DIR, token), { recursive: true, force: true });
        fs.rmSync(metaPath, { force: true });
      } catch {
        // best-effort
      }
    }
  } catch {
    // best-effort
  }
}

async function closeAllShares() {
  if (!fs.existsSync(SHARES_DIR)) {
    return textResult(
      ["closed_count: 0", "No share store found — nothing to close."].join("\n"),
    );
  }

  const tokens = new Set();
  const errors = [];

  let entries;
  try {
    entries = fs.readdirSync(SHARES_DIR, { withFileTypes: true });
  } catch (err) {
    return textResult(`Failed to read share store: ${err.message}`, true);
  }

  for (const entry of entries) {
    if (entry.isDirectory()) {
      tokens.add(entry.name);
      continue;
    }
    if (entry.isFile() && entry.name.endsWith(".json")) {
      tokens.add(entry.name.slice(0, -".json".length));
    }
  }

  for (const token of tokens) {
    try {
      fs.rmSync(path.join(SHARES_DIR, token), { recursive: true, force: true });
      fs.rmSync(path.join(SHARES_DIR, `${token}.json`), { force: true });
    } catch (err) {
      errors.push(`${token}: ${err.message}`);
    }
  }

  // Remove any leftover non-token junk in the share store.
  try {
    for (const leftover of fs.readdirSync(SHARES_DIR)) {
      fs.rmSync(path.join(SHARES_DIR, leftover), { recursive: true, force: true });
    }
  } catch {
    // best-effort
  }

  const lines = [
    `closed_count: ${tokens.size}`,
    tokens.size === 0
      ? "No active shares to close."
      : `Revoked ${tokens.size} share${tokens.size === 1 ? "" : "s"}. Existing /share links will 404.`,
  ];
  if (errors.length) {
    lines.push(`errors: ${errors.join("; ")}`);
  }
  lines.push(
    "",
    JSON.stringify({
      closedCount: tokens.size,
      tokens: [...tokens],
      errors,
    }),
  );

  return textResult(lines.join("\n"), errors.length > 0);
}

function revokeShareToken(token) {
  if (!token) return;
  try {
    fs.rmSync(path.join(SHARES_DIR, token), { recursive: true, force: true });
  } catch {
    // best-effort
  }
  try {
    fs.rmSync(path.join(SHARES_DIR, `${token}.json`), { force: true });
  } catch {
    // best-effort
  }
}

function listShareMetas() {
  const results = [];
  if (!fs.existsSync(SHARES_DIR)) return results;
  let names;
  try {
    names = fs.readdirSync(SHARES_DIR);
  } catch {
    return results;
  }
  for (const name of names) {
    if (!name.endsWith(".json")) continue;
    const metaPath = path.join(SHARES_DIR, name);
    try {
      const meta = JSON.parse(fs.readFileSync(metaPath, "utf8"));
      const token =
        typeof meta.token === "string" && meta.token
          ? meta.token
          : name.slice(0, -".json".length);
      results.push({ meta, metaPath, token });
    } catch {
      // skip corrupt
    }
  }
  return results;
}

function findActiveShareForSource(sourcePath) {
  const now = Date.now();
  let best = null;
  for (const entry of listShareMetas()) {
    const { meta, token } = entry;
    if (meta.sourcePath !== sourcePath) continue;
    const expiresAtMs = Date.parse(meta.expiresAt);
    if (!Number.isFinite(expiresAtMs) || expiresAtMs <= now) continue;
    const remainingSeconds = Math.floor((expiresAtMs - now) / 1000);
    if (!best || remainingSeconds > best.remainingSeconds) {
      best = { ...entry, remainingSeconds, expiresAtMs };
    }
  }
  return best;
}

function buildShareResult({
  url,
  token,
  filename,
  contentType,
  sizeBytes,
  createdAt,
  expiresAt,
  expiresInSeconds,
  reused,
}) {
  const summary = [
    `url: ${url}`,
    `token: ${token}`,
    `filename: ${filename}`,
    `content_type: ${contentType}`,
    `size_bytes: ${sizeBytes}`,
    `created_at: ${createdAt}`,
    `expires_at: ${expiresAt}`,
    `expires_in_seconds: ${expiresInSeconds}`,
    `reused: ${reused ? "true" : "false"}`,
    "",
    JSON.stringify({
      url,
      token,
      filename,
      contentType,
      sizeBytes,
      createdAt,
      expiresAt,
      expiresInSeconds,
      reused: Boolean(reused),
    }),
  ].join("\n");
  return textResult(summary);
}

async function shareFile(args) {
  cleanupExpiredShares();

  const rawPath = String(args?.path ?? "").trim();
  if (!rawPath) {
    return textResult("path is required.", true);
  }

  const sourcePath = path.resolve(rawPath);

  let stat;
  try {
    stat = fs.statSync(sourcePath);
  } catch (err) {
    return textResult(`File not found or unreadable: ${sourcePath} (${err.message})`, true);
  }

  if (!stat.isFile()) {
    return textResult(`Not a regular file: ${sourcePath}`, true);
  }

  if (stat.size > SHARE_MAX_BYTES) {
    return textResult(
      `File too large: ${stat.size} bytes (max ${SHARE_MAX_BYTES} bytes / ${Math.round(SHARE_MAX_BYTES / (1024 * 1024))}MB).`,
      true,
    );
  }

  // Ensure readable before copying
  try {
    fs.accessSync(sourcePath, fs.constants.R_OK);
  } catch (err) {
    return textResult(`File is not readable: ${sourcePath} (${err.message})`, true);
  }

  let filename = path.basename(sourcePath);
  if (!filename || filename === "." || filename === "..") {
    filename = "file";
  }

  const existing = findActiveShareForSource(sourcePath);
  if (existing) {
    if (existing.remainingSeconds > SHARE_REUSE_MIN_REMAINING_SECONDS) {
      const baseUrl = resolvePublicBaseUrl();
      const url = `${baseUrl}/share/${existing.token}/${encodeURIComponent(existing.meta.filename || filename)}`;
      const createdAt =
        typeof existing.meta.createdAt === "string"
          ? existing.meta.createdAt
          : new Date(existing.expiresAtMs - SHARE_TTL_SECONDS * 1000).toISOString();
      return buildShareResult({
        url,
        token: existing.token,
        filename: existing.meta.filename || filename,
        contentType: existing.meta.contentType || guessContentType(filename),
        sizeBytes: stat.size,
        createdAt,
        expiresAt: existing.meta.expiresAt,
        expiresInSeconds: existing.remainingSeconds,
        reused: true,
      });
    }
    // Under 5 minutes remaining — revoke and remint.
    revokeShareToken(existing.token);
  }

  const token = randomBytes(32).toString("hex");
  const shareDir = path.join(SHARES_DIR, token);
  const destPath = path.join(shareDir, filename);
  const metaPath = path.join(SHARES_DIR, `${token}.json`);

  const createdAt = new Date();
  const expiresAt = new Date(createdAt.getTime() + SHARE_TTL_SECONDS * 1000);
  const contentType = guessContentType(filename);

  try {
    fs.mkdirSync(shareDir, { recursive: true });
    fs.copyFileSync(sourcePath, destPath);
    const meta = {
      token,
      filename,
      contentType,
      sourcePath,
      createdAt: createdAt.toISOString(),
      expiresAt: expiresAt.toISOString(),
    };
    fs.writeFileSync(metaPath, `${JSON.stringify(meta, null, 2)}\n`, "utf8");
  } catch (err) {
    try {
      fs.rmSync(shareDir, { recursive: true, force: true });
      fs.rmSync(metaPath, { force: true });
    } catch {
      // ignore rollback errors
    }
    return textResult(`Failed to prepare share: ${err.message}`, true);
  }

  const baseUrl = resolvePublicBaseUrl();
  const url = `${baseUrl}/share/${token}/${encodeURIComponent(filename)}`;

  return buildShareResult({
    url,
    token,
    filename,
    contentType,
    sizeBytes: stat.size,
    createdAt: createdAt.toISOString(),
    expiresAt: expiresAt.toISOString(),
    expiresInSeconds: SHARE_TTL_SECONDS,
    reused: false,
  });
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
    if (name === "ultragateway_share_file") {
      return await shareFile(args ?? {});
    }
    if (name === "ultragateway_close_shares") {
      return await closeAllShares();
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
