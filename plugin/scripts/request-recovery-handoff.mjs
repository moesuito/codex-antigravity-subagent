import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const builderPath = fileURLToPath(
  new URL("./build-recovery-handoff.ps1", import.meta.url),
);

function fail(message, code = 2) {
  process.stderr.write(`CODEX_AGY_HANDOFF_ERROR=${message}\n`);
  process.exit(code);
}

function readRequestLine() {
  return new Promise((resolve, reject) => {
    let buffer = "";
    process.stdin.setEncoding("utf8");
    if (typeof process.stdin.setRawMode === "function") process.stdin.setRawMode(true);
    process.stdin.resume();
    const cleanup = () => {
      process.stdin.off("data", onData);
      if (typeof process.stdin.setRawMode === "function") process.stdin.setRawMode(false);
      process.stdin.pause();
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
    process.stdin.on("data", onData);
  });
}

process.stdout.write("CODEX_AGY_HANDOFF_READY=1\n");

let request;
try {
  request = JSON.parse(await readRequestLine());
} catch (error) {
  fail(String(error?.message ?? error));
}

for (const key of ["workspace", "originalTask", "failureReason"]) {
  if (typeof request?.[key] !== "string" || !request[key].trim()) {
    fail(`${key} is required`);
  }
}

const encode = (value) =>
  Buffer.from(typeof value === "string" ? value : "", "utf8").toString("base64");
const args = [
  "-NoProfile",
  "-File",
  builderPath,
  "-WorkspaceBase64",
  encode(request.workspace),
  "-OriginalTaskBase64",
  encode(request.originalTask),
  "-FailureReasonBase64",
  encode(request.failureReason),
  "-AcceptanceCriteriaBase64",
  encode(request.acceptanceCriteria),
  "-VerifiedWorkBase64",
  encode(request.verifiedWork),
  "-RemainingWorkBase64",
  encode(request.remainingWork),
  "-TestResultsBase64",
  encode(request.testResults),
];
args.push(
  "-SessionKeysBase64",
  encode(
    JSON.stringify(
      Array.isArray(request.sessionKeys)
        ? request.sessionKeys.filter((value) => typeof value === "string")
        : [],
    ),
  ),
);
if (typeof request.stateRoot === "string" && request.stateRoot) {
  args.push("-StateRoot", request.stateRoot);
}

const child = spawn("pwsh", args, {
  env: process.env,
  stdio: ["ignore", "pipe", "inherit"],
  windowsHide: true,
});
let output = "";
child.stdout.setEncoding("utf8");
child.stdout.on("data", (chunk) => {
  output += chunk;
});
child.on("error", (error) => fail(String(error?.message ?? error), 1));
child.on("exit", (code) => {
  if (code !== 0) process.exit(code ?? 1);
  process.stdout.write(output);
  process.exit(0);
});
