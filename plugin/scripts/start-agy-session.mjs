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
const outputMode = request.outputMode ?? "silent";
if (!new Set(["silent", "verbose"]).has(outputMode)) {
  fail("outputMode must be silent or verbose");
}

const watchdogRequest = request.watchdog && typeof request.watchdog === "object" ? request.watchdog : {};
function watchdogSeconds(name, fallback) {
  const value = watchdogRequest[name] ?? fallback;
  if (!Number.isInteger(value) || value < 1) {
    fail(`watchdog.${name} must be a positive integer`);
  }
  return value;
}
const watchdog = {
  passiveCheckSeconds: watchdogSeconds("passiveCheckSeconds", 300),
  escalationAfterSeconds: watchdogSeconds("escalationAfterSeconds", 600),
  escalationIntervalSeconds: watchdogSeconds("escalationIntervalSeconds", 60),
};
if (watchdog.escalationAfterSeconds < watchdog.passiveCheckSeconds) {
  fail("watchdog.escalationAfterSeconds must be at least watchdog.passiveCheckSeconds");
}

let workspaceStats;
try {
  workspaceStats = fs.statSync(workspace);
} catch {
  fail(`workspace does not exist: ${workspace}`);
}
if (!workspaceStats.isDirectory()) {
  fail(`workspace is not a directory: ${workspace}`);
}

const stateRoot = process.env.CODEX_AGY_STATE_ROOT || path.join(os.homedir(), "AppData", "Local", "Codex", "antigravity-subagent");
const sessionDir = path.join(stateRoot, "sessions", sessionKey);
const metadataPath = path.join(sessionDir, "metadata.json");
const logPath = path.join(sessionDir, "agy.log");
const acpStorePath = process.env.CODEX_AGY_ACP_STORE_PATH || path.join(os.homedir(), ".openab", "agy-acp", "sessions.json");
fs.mkdirSync(sessionDir, { recursive: true });

function readJsonFile(filePath) {
  try {
    return JSON.parse(fs.readFileSync(filePath, "utf8"));
  } catch {
    return null;
  }
}

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
function resolvePersistedConversationId() {
  const metadataConversationId = readJsonFile(metadataPath)?.conversationId;
  if (typeof metadataConversationId === "string" && metadataConversationId) return metadataConversationId;
  let lines;
  try {
    lines = fs.readFileSync(path.join(sessionDir, "events.jsonl"), "utf8").split(/\r?\n/).reverse();
  } catch {
    return null;
  }
  for (const line of lines) {
    if (!line.trim()) continue;
    try {
      const candidate = JSON.parse(line).conversationId;
      if (typeof candidate === "string" && candidate) return candidate;
    } catch {}
  }
  return null;
}

let conversationId = resolvePersistedConversationId();
let toolCallStepCount = 1;
let lastWorkerActivityAt = Date.now();
let lastMetadataActivityAt = 0;
let executionFinished = false;
let watchdogTimer = null;
let nextWatchdogAt = Date.now() + watchdog.passiveCheckSeconds * 1000;

function updateMetadata(updates) {
  const metadata = readJsonFile(metadataPath) || {};
  const updatedAt = updates.updatedAt ?? new Date().toISOString();
  const nextMetadata = {
    ...metadata,
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
    logPath,
    ...updates,
    updatedAt,
  };
  fs.writeFileSync(metadataPath, JSON.stringify(nextMetadata, null, 2), "utf8");
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

function emitSignal(kind, details = {}) {
  process.stdout.write(`${kind}=${JSON.stringify({ sessionKey, ...details })}\n`);
}

function makeFailure(errorCode, message, terminationReason, recoveryHint, workerExitCode = null) {
  const error = new Error(message);
  error.errorCode = errorCode;
  error.terminationReason = terminationReason;
  error.recoveryHint = recoveryHint;
  error.workerExitCode = workerExitCode;
  return error;
}

function classifyFailure(error) {
  const message = String(error?.message ?? error ?? "Unknown Antigravity failure").trim();
  if (error?.errorCode) {
    return {
      errorCode: error.errorCode,
      terminationReason: error.terminationReason || "execution_error",
      recoveryHint: error.recoveryHint || "inspect_error_and_retry",
      workerExitCode: error.workerExitCode ?? null,
      message,
    };
  }
  if (/individual quota|quota.*reached|resource_exhausted|429/i.test(message)) {
    return { errorCode: "quota_exceeded", terminationReason: "quota_exceeded", recoveryHint: "wait_for_quota_reset", workerExitCode: 1, message };
  }
  if (/timeout|timed out|deadline exceeded/i.test(message)) {
    return { errorCode: "response_timeout", terminationReason: "response_timeout", recoveryHint: "resume_or_start_fresh", workerExitCode: 1, message };
  }
  if (/unknown sessionid/i.test(message)) {
    return { errorCode: "session_not_resumable", terminationReason: "session_not_resumable", recoveryHint: "start_fresh_conversation", workerExitCode: null, message };
  }
  if (/exited with status|exit(?:ed)? code|agy failed/i.test(message)) {
    return { errorCode: "worker_process_failed", terminationReason: "worker_process_failed", recoveryHint: "resume_or_start_fresh", workerExitCode: 1, message };
  }
  return { errorCode: "execution_error", terminationReason: "execution_error", recoveryHint: "inspect_error_and_retry", workerExitCode: null, message };
}

function resolvePersistedAcpSessionId() {
  const metadata = readJsonFile(metadataPath) || {};
  if (typeof metadata.acpSessionId === "string" && metadata.acpSessionId) {
    return metadata.acpSessionId;
  }
  const persistedConversationId = resolvePersistedConversationId();
  if (persistedConversationId) {
    const store = readJsonFile(acpStorePath);
    const match = Object.entries(store?.sessions || {}).find(([, value]) => value?.conversation_id === persistedConversationId);
    if (match) return match[0];
  }
  return null;
}

function noteWorkerActivity() {
  lastWorkerActivityAt = Date.now();
  // Keep watchdog health current without writing once per streamed token.
  if (lastWorkerActivityAt - lastMetadataActivityAt >= 15000) {
    lastMetadataActivityAt = lastWorkerActivityAt;
    updateMetadata({ workerLastActivityAt: new Date(lastWorkerActivityAt).toISOString() });
  }
}

function writeWatchdogCheckpoint(kind) {
  const now = Date.now();
  const checkpoint = {
    schemaVersion: 1,
    kind,
    observedAt: new Date(now).toISOString(),
    elapsedSeconds: Math.floor((now - new Date(readMetadataStartedAt()).getTime()) / 1000),
    inactiveSeconds: Math.floor((now - lastWorkerActivityAt) / 1000),
  };
  fs.writeFileSync(path.join(sessionDir, "watchdog.json"), JSON.stringify(checkpoint, null, 2), "utf8");
  return checkpoint;
}

function readMetadataStartedAt() {
  return readJsonFile(metadataPath)?.startedAt || new Date().toISOString();
}

function scheduleWatchdog() {
  if (executionFinished) return;
  const delay = Math.max(1, nextWatchdogAt - Date.now());
  watchdogTimer = setTimeout(runWatchdog, delay);
}

function runWatchdog() {
  if (executionFinished) return;
  const now = Date.now();
  const startedAt = new Date(readMetadataStartedAt()).getTime();
  const elapsedSeconds = Math.floor((now - startedAt) / 1000);
  if (elapsedSeconds >= watchdog.escalationAfterSeconds) {
    const checkpoint = writeWatchdogCheckpoint("escalation_check");
    if (now - lastWorkerActivityAt >= watchdog.escalationIntervalSeconds * 1000) {
      emitSignal("CODEX_AGY_WATCHDOG_REVIEW", {
        elapsedSeconds: checkpoint.elapsedSeconds,
        inactiveSeconds: checkpoint.inactiveSeconds,
      });
    }
    nextWatchdogAt = now + watchdog.escalationIntervalSeconds * 1000;
  } else {
    writeWatchdogCheckpoint("passive_check");
    nextWatchdogAt = startedAt + watchdog.escalationAfterSeconds * 1000;
  }
  scheduleWatchdog();
}

function finishExecution() {
  executionFinished = true;
  if (watchdogTimer) clearTimeout(watchdogTimer);
}

updateMetadata({
  startedAt: readJsonFile(metadataPath)?.startedAt || new Date().toISOString(),
  turnStartedAt: new Date().toISOString(),
  endedAt: null,
  exitCode: null,
  brokerExitCode: null,
  workerExitCode: null,
  launcherState: "running",
  finalResponse: null,
  error: null,
  errorCode: null,
  recoveryHint: null,
  terminationReason: null,
});
scheduleWatchdog();

// Output initial environment bindings for Codex log parser
process.stdout.write(`CODEX_AGY_SESSION_KEY=${sessionKey}\n`);
process.stdout.write(`CODEX_AGY_WORKSPACE=${workspace}\n`);
process.stdout.write(`CODEX_AGY_LOG_FILE=${logPath}\n`);
process.stdout.write(`CODEX_AGY_AUTONOMY=full-machine\n`);

// Set environment for agy
const env = { ...process.env };
env.AGY_EXTRA_ARGS = "--dangerously-skip-permissions";

// Spawn agy-acp
const pendingRequests = new Map();
let nextRequestId = 1;

const child = spawn(acpBinaryPath, [], {
  cwd: workspace,
  env,
  stdio: ["pipe", "pipe", "pipe"],
  shell: acpBinaryPath.endsWith(".bat") || acpBinaryPath.endsWith(".cmd") ? true : undefined,
});

// A missing executable or invalid child cwd is reported asynchronously by Node.
// Keep the failure inside the broker's normal completion path so metadata and
// status consumers never mistake an aborted launch for a running session.
let childSpawnError = null;
child.on("error", (error) => {
  childSpawnError = error;
  for (const pending of pendingRequests.values()) {
    pending.reject(error);
  }
  pendingRequests.clear();
});

child.on("close", (code, signal) => {
  if (executionFinished) return;
  const error = new Error(`agy-acp exited before completing the turn (code=${code ?? "null"}, signal=${signal ?? "none"})`);
  childSpawnError = error;
  for (const pending of pendingRequests.values()) {
    pending.reject(error);
  }
  pendingRequests.clear();
});

const logStream = fs.createWriteStream(logPath, { flags: "a" });
child.stderr.pipe(logStream);

const rl = readline.createInterface({
  input: child.stdout,
  terminal: false,
});

function sendRequest(method, params = {}) {
  if (childSpawnError) return Promise.reject(childSpawnError);
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
  noteWorkerActivity();

  if (update.sessionUpdate === "agent_message_chunk") {
    if (update.content && update.content.text) {
      fullResponseText += update.content.text;
      if (outputMode === "verbose") process.stdout.write(update.content.text);
    }
  } else if (update.sessionUpdate === "tool_call") {
    const title = update.title || "Tool Call";
    if (outputMode === "verbose") console.log(`\n⚙️ [Tool Call] ${title}`);
    appendEvent("PostToolUse", { stepIdx: toolCallStepCount++ });
  } else if (update.sessionUpdate === "tool_call_update") {
    const title = update.title || "Tool Call";
    const status = update.status || "completed";
    if (outputMode === "verbose") console.log(`✅ [Tool Completed] ${title} (${status})`);
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
  let sessionId;
  if (request.sessionKey) {
    sessionId = resolvePersistedAcpSessionId();
    if (!sessionId) {
      throw makeFailure(
        "session_not_resumable",
        `No persisted ACP session mapping exists for sessionKey: ${sessionKey}`,
        "session_not_resumable",
        "start_fresh_conversation",
      );
    }
    await sendRequest("session/load", { sessionId });
    updateMetadata({ acpSessionId: sessionId });
  } else {
    const res = await sendRequest("session/new", {});
    sessionId = res.sessionId;
    if (typeof sessionId !== "string" || !sessionId) {
      throw makeFailure("invalid_acp_response", "session/new returned no sessionId", "execution_error", "start_fresh_conversation");
    }
    updateMetadata({ acpSessionId: sessionId });
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

  if (promptRes?.stopReason && promptRes.stopReason !== "end_turn") {
    throw makeFailure(
      "worker_process_failed",
      `Antigravity stopped with reason: ${promptRes.stopReason}`,
      "worker_process_failed",
      "resume_or_start_fresh",
      1,
    );
  }

  if (!fullResponseText.trim()) {
    throw makeFailure(
      "missing_final_response",
      "Antigravity ended the turn without a final response.",
      "missing_final_response",
      "resume_or_start_fresh",
    );
  }

  // Read conversation_id from agy-acp state once the turn concludes
  try {
    if (fs.existsSync(acpStorePath)) {
      const store = JSON.parse(fs.readFileSync(acpStorePath, "utf8"));
      if (store.sessions && store.sessions[sessionId]) {
        conversationId = store.sessions[sessionId].conversation_id || null;
      }
    }
  } catch (err) {}

  updateMetadata({
    endedAt: new Date().toISOString(),
    exitCode: 0,
    brokerExitCode: 0,
    workerExitCode: 0,
    launcherState: "exited",
    conversationId,
    finalResponse: fullResponseText,
    error: null,
    errorCode: null,
    recoveryHint: null,
    terminationReason: "normal",
  });

  appendEvent("Stop", {
    fullyIdle: true,
    terminationReason: "normal",
  });

  finishExecution();
  emitSignal("CODEX_AGY_TURN_FINISHED", {
    status: "completed",
    terminationReason: "normal",
    hasFinalResponse: true,
    conversationId,
  });

  process.exit(0);
} catch (err) {
  finishExecution();
  const failure = classifyFailure(err);
  console.error("\n❌ Error during execution:", failure.message);
  
  updateMetadata({
    endedAt: new Date().toISOString(),
    exitCode: 1,
    brokerExitCode: 1,
    workerExitCode: failure.workerExitCode,
    launcherState: "failed",
    conversationId,
    finalResponse: null,
    error: failure.message,
    errorCode: failure.errorCode,
    recoveryHint: failure.recoveryHint,
    terminationReason: failure.terminationReason,
  });

  appendEvent("Stop", {
    fullyIdle: true,
    terminationReason: failure.terminationReason,
    error: failure.message,
    errorCode: failure.errorCode,
  });

  emitSignal("CODEX_AGY_TURN_FINISHED", {
    status: "failed",
    terminationReason: failure.terminationReason,
    hasFinalResponse: false,
    errorCode: failure.errorCode,
    recoveryHint: failure.recoveryHint,
  });

  process.exit(1);
}
