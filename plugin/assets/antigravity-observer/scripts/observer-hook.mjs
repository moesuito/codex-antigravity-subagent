import fs from "node:fs";
import path from "node:path";

const eventType = process.argv[2] || "Unknown";
const passiveResponse = eventType === "Stop" ? { decision: "stop" } : {};

function finish() {
  process.stdout.write(`${JSON.stringify(passiveResponse)}\n`);
}

async function readStdin() {
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  return Buffer.concat(chunks).toString("utf8");
}

try {
  const sessionKey = process.env.CODEX_AGY_SESSION_ID;
  const stateDirectory = process.env.CODEX_AGY_STATE_DIR;
  if (!sessionKey || !stateDirectory) {
    finish();
    process.exit(0);
  }

  const rawInput = await readStdin();
  const input = rawInput.trim() ? JSON.parse(rawInput) : {};
  const record = {
    schemaVersion: 1,
    sessionKey,
    eventType,
    observedAt: new Date().toISOString(),
    conversationId: input.conversationId ?? null,
    workspacePaths: Array.isArray(input.workspacePaths)
      ? input.workspacePaths.filter((value) => typeof value === "string")
      : [],
    transcriptPath:
      typeof input.transcriptPath === "string" ? input.transcriptPath : null,
    artifactDirectoryPath:
      typeof input.artifactDirectoryPath === "string"
        ? input.artifactDirectoryPath
        : null,
    stepIdx: Number.isInteger(input.stepIdx) ? input.stepIdx : null,
    invocationNum: Number.isInteger(input.invocationNum)
      ? input.invocationNum
      : null,
    initialNumSteps: Number.isInteger(input.initialNumSteps)
      ? input.initialNumSteps
      : null,
    executionNum: Number.isInteger(input.executionNum)
      ? input.executionNum
      : null,
    terminationReason:
      typeof input.terminationReason === "string"
        ? input.terminationReason
        : null,
    error: typeof input.error === "string" && input.error ? input.error : null,
    fullyIdle:
      typeof input.fullyIdle === "boolean" ? input.fullyIdle : null,
  };

  fs.mkdirSync(stateDirectory, { recursive: true });
  fs.appendFileSync(
    path.join(stateDirectory, "events.jsonl"),
    `${JSON.stringify(record)}\n`,
    { encoding: "utf8" },
  );
} catch (error) {
  // Observation must never block or alter the Antigravity execution loop.
  try {
    const stateDirectory = process.env.CODEX_AGY_STATE_DIR;
    if (stateDirectory) {
      fs.mkdirSync(stateDirectory, { recursive: true });
      fs.appendFileSync(
        path.join(stateDirectory, "observer-errors.log"),
        `${new Date().toISOString()} ${String(error?.message ?? error).replace(/[\r\n]+/g, " ")}\n`,
        { encoding: "utf8" },
      );
    }
  } catch {
    // Remain passive even when diagnostic logging fails.
  }
}

finish();
