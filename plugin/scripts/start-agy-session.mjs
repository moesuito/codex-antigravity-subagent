import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const launcherPath = fileURLToPath(new URL("./launch-agy.ps1", import.meta.url));

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

const mode = request.mode ?? "accept-edits";
const modelTier = request.modelTier ?? "High";
if (!new Set(["accept-edits", "plan"]).has(mode)) fail("invalid mode");
if (!new Set(["High", "Medium", "Low"]).has(modelTier)) fail("invalid modelTier");

const args = [
  "-NoProfile",
  "-File",
  launcherPath,
  "-WorkspaceBase64",
  Buffer.from(request.workspace, "utf8").toString("base64"),
  "-PromptBase64",
  Buffer.from(request.task, "utf8").toString("base64"),
  "-Mode",
  mode,
  "-ModelTier",
  modelTier,
];
if (typeof request.sessionKey === "string" && request.sessionKey) {
  args.push("-SessionKey", request.sessionKey);
}
if (typeof request.stateRoot === "string" && request.stateRoot) {
  args.push("-StateRoot", request.stateRoot);
}

const child = spawn("pwsh", args, {
  cwd: request.workspace,
  env: process.env,
  stdio: "inherit",
  windowsHide: true,
});

child.on("error", (error) => fail(String(error?.message ?? error), 1));
child.on("exit", (code, signal) => {
  if (signal) {
    process.stderr.write(`CODEX_AGY_CHILD_SIGNAL=${signal}\n`);
    process.exit(1);
  }
  process.exit(code ?? 1);
});
