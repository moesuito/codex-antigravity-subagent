import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import path from "node:path";
import fs from "node:fs";
import os from "node:os";
import readline from "node:readline";
import crypto from "node:crypto";

function fail(message, code = 2) {
  process.stderr.write(`CODEX_AGY_REQUEST_ERROR=${message}\n`);
  process.exit(code);
}

function readRequestLine() {
  return new Promise((resolve, reject) => {
    let buffer = "";
    const input = process.stdin;
    input.setEncoding("utf8");
    if (typeof input.setRawMode === "function") input.setRawMode(true);
    input.resume();

    const cleanup = () => {
      input.off("data", onData);
      input.off("error", onError);
      if (typeof input.setRawMode === "function") input.setRawMode(false);
      input.pause();
    };
    const onError = (error) => {
      cleanup();
      reject(error);
    };
    const onData = (chunk) => {
      for (const character of chunk) {
        if (character === "\u0003") {
          cleanup();
          reject(new Error("request cancelled"));
          return;
        }
        if (character === "\r" || character === "\n") {
          if (!buffer.trim()) continue;
          cleanup();
          resolve(buffer);
          return;
        }
        buffer += character;
        if (Buffer.byteLength(buffer, "utf8") > 256 * 1024) {
          cleanup();
          reject(new Error("request exceeds 256 KiB"));
          return;
        }
      }
    };

    input.on("data", onData);
    input.on("error", onError);
  });
}

process.stdout.write("CODEX_AGY_REQUEST_READY=1\n");

let request;
try {
  request = JSON.parse(await readRequestLine());
} catch (error) {
  fail(String(error?.message ?? error));
}

if (!request || typeof request !== "object") fail("request must be a JSON object");
if (typeof request.workspace !== "string" || !request.workspace.trim()) {
  fail("workspace is required");
}
if (typeof request.task !== "string" || !request.task.trim()) {
  fail("task is required");
}

const workspace = path.resolve(request.workspace);
const prompt = request.task.trim();
const mode = request.mode ?? "accept-edits";
const modelTier = request.modelTier ?? "High";
const sessionKey = request.sessionKey || crypto.randomUUID();

const stateRoot = process.env.CODEX_AGY_STATE_ROOT || path.join(os.homedir(), "AppData", "Local", "Codex", "antigravity-subagent");
const sessionDir = path.join(stateRoot, "sessions", sessionKey);
fs.mkdirSync(sessionDir, { recursive: true });

// Workspace Exclusive Lock
const normalizedWorkspace = workspace.toLowerCase();
const workspaceHash = crypto.createHash("sha256").update(normalizedWorkspace, "utf8").digest("hex").toLowerCase();
const lockPath = path.join(stateRoot, "locks", `${workspaceHash}.lock`);

try {
  fs.mkdirSync(path.join(stateRoot, "locks"), { recursive: true });
  if (fs.existsSync(lockPath)) {
    try {
      const lockData = JSON.parse(fs.readFileSync(lockPath, "utf8"));
      process.kill(lockData.pid, 0); // Throws error if process is dead
      console.error(`An Antigravity session is already active (PID ${lockData.pid}) for workspace: ${workspace}`);
      process.exit(73);
    } catch (e) {
      // Process is dead, we can overwrite the lock file safely
    }
  }
  fs.writeFileSync(lockPath, JSON.stringify({ pid: process.pid, sessionKey, startedAt: new Date().toISOString() }), "utf8");
} catch (err) {
  fail(`Failed to acquire lock: ${err.message}`);
}

function releaseLock() {
  try {
    if (fs.existsSync(lockPath)) {
      fs.unlinkSync(lockPath);
    }
  } catch (err) {}
}

process.on("exit", releaseLock);
process.on("SIGINT", () => process.exit(1));
process.on("SIGTERM", () => process.exit(1));

// Resolve agy-acp binary path
const currentDir = path.dirname(fileURLToPath(import.meta.url));
const acpBinaryPath = process.env.CODEX_AGY_ACP_PATH || path.join(currentDir, "..", "bin", "agy-acp.exe");

if (!process.env.CODEX_AGY_ACP_PATH && !fs.existsSync(acpBinaryPath)) {
  fail(`agy-acp binary not found at ${acpBinaryPath}. Ensure it is compiled.`);
}

// Initial Metadata
let conversationId = null;
let toolCallStepCount = 1;

function updateMetadata(updates) {
  let metadata = {};
  const metadataPath = path.join(sessionDir, "metadata.json");
  if (fs.existsSync(metadataPath)) {
    try {
      metadata = JSON.parse(fs.readFileSync(metadataPath, "utf8"));
    } catch (err) {}
  }
  metadata = {
    schemaVersion: 1,
    sessionKey,
    workspace,
    normalizedWorkspace,
    workspaceHash,
    launcherPid: process.pid,
    agyPath: "agy-acp",
    model: `Gemini 3.5 Flash (${modelTier})`,
    mode,
    autonomy: "full-machine",
    startedAt: metadata.startedAt || new Date().toISOString(),
    updatedAt: new Date().toISOString(),
    endedAt: null,
    exitCode: null,
    launcherState: "running",
    logPath: path.join(sessionDir, "agy.log"),
    ...metadata,
    ...updates,
  };
  fs.writeFileSync(metadataPath, JSON.stringify(metadata, null, 2), "utf8");
}

function appendEvent(eventType, extra = {}) {
  const event = {
    schemaVersion: 1,
    sessionKey,
    eventType,
    observedAt: new Date().toISOString(),
    conversationId,
    ...extra,
  };
  fs.appendFileSync(path.join(sessionDir, "events.jsonl"), JSON.stringify(event) + "\n", "utf8");
}

updateMetadata({ startedAt: new Date().toISOString(), launcherState: "running" });

// Output initial environment bindings for Codex log parser
process.stdout.write(`CODEX_AGY_SESSION_KEY=${sessionKey}\n`);
process.stdout.write(`CODEX_AGY_WORKSPACE=${workspace}\n`);
process.stdout.write(`CODEX_AGY_LOG_FILE=${path.join(sessionDir, "agy.log")}\n`);
process.stdout.write(`CODEX_AGY_AUTONOMY=full-machine\n`);

// Set environment for agy
const env = { ...process.env };
env.AGY_EXTRA_ARGS = "--dangerously-skip-permissions";

// Spawn agy-acp
const child = spawn(acpBinaryPath, [], {
  cwd: workspace,
  env,
  stdio: ["pipe", "pipe", "pipe"],
  shell: acpBinaryPath.endsWith(".bat") || acpBinaryPath.endsWith(".cmd") ? true : undefined,
});

const logStream = fs.createWriteStream(path.join(sessionDir, "agy.log"), { flags: "a" });
child.stderr.pipe(logStream);

const rl = readline.createInterface({
  input: child.stdout,
  terminal: false,
});

const pendingRequests = new Map();
let nextRequestId = 1;

function sendRequest(method, params = {}) {
  const id = nextRequestId++;
  const payload = JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n";
  child.stdin.write(payload);
  return new Promise((resolve, reject) => {
    pendingRequests.set(id, { resolve, reject });
  });
}

let fullResponseText = "";

function handleUpdate(update) {
  if (!update) return;

  if (update.sessionUpdate === "agent_message_chunk") {
    if (update.content && update.content.text) {
      process.stdout.write(update.content.text);
      fullResponseText += update.content.text;
    }
  } else if (update.sessionUpdate === "tool_call") {
    const title = update.title || "Tool Call";
    console.log(`\n⚙️ [Tool Call] ${title}`);
    appendEvent("PostToolUse", { stepIdx: toolCallStepCount++ });
  } else if (update.sessionUpdate === "tool_call_update") {
    const title = update.title || "Tool Call";
    const status = update.status || "completed";
    console.log(`✅ [Tool Completed] ${title} (${status})`);
  }
}

rl.on("line", (line) => {
  if (!line.trim()) return;
  try {
    const msg = JSON.parse(line);
    if (msg.method === "session/update") {
      handleUpdate(msg.params?.update);
    } else if (msg.id !== undefined && msg.id !== null) {
      const pending = pendingRequests.get(msg.id);
      if (pending) {
        pendingRequests.delete(msg.id);
        if (msg.error) {
          pending.reject(msg.error);
        } else {
          pending.resolve(msg.result);
        }
      }
    }
  } catch (err) {
    fs.appendFileSync(path.join(sessionDir, "agy-acp-raw-errors.log"), `${line}\n`);
  }
});

// JSON-RPC ACP Handshake & Turn execution
try {
  appendEvent("PreInvocation");

  // 1. Initialize
  await sendRequest("initialize", {});

  // 2. session/new or session/load
  let sessionId = sessionKey;
  if (request.sessionKey) {
    await sendRequest("session/load", { sessionId });
  } else {
    const res = await sendRequest("session/new", {});
    sessionId = res.sessionId;
  }

  // 3. Set Config model
  const mappedModel = `Gemini 3.5 Flash (${modelTier})`;
  await sendRequest("session/setConfigOption", {
    sessionId,
    configId: "model",
    value: mappedModel,
  });

  // 4. session/prompt
  const promptRes = await sendRequest("session/prompt", {
    sessionId,
    prompt: [{ type: "text", text: prompt }],
  });

  // Read conversation_id from agy-acp state once the turn concludes
  try {
    const openabSessionsPath = path.join(os.homedir(), ".openab", "agy-acp", "sessions.json");
    if (fs.existsSync(openabSessionsPath)) {
      const store = JSON.parse(fs.readFileSync(openabSessionsPath, "utf8"));
      if (store.sessions && store.sessions[sessionId]) {
        conversationId = store.sessions[sessionId].conversation_id || null;
      }
    }
  } catch (err) {}

  updateMetadata({
    endedAt: new Date().toISOString(),
    exitCode: 0,
    launcherState: "exited",
    conversationId,
    finalResponse: fullResponseText,
  });

  appendEvent("Stop", {
    fullyIdle: true,
    terminationReason: "model_stop",
  });

  process.exit(0);
} catch (err) {
  console.error("\n❌ Error during execution:", err);
  
  updateMetadata({
    endedAt: new Date().toISOString(),
    exitCode: 1,
    launcherState: "failed",
    conversationId,
  });

  appendEvent("Stop", {
    fullyIdle: true,
    terminationReason: "error",
    error: err.message || String(err),
  });

  process.exit(1);
}
