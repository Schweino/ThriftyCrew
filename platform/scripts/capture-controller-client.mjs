import net from "node:net";
import { readFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

export const CAPTURE_CONTROLLER_PIPE = "\\\\.\\pipe\\ThriftyCrew.GroceryV3.CaptureController";

async function controllerToken(environment) {
  if (environment.TC_CAPTURE_CONTROLLER_TOKEN) return environment.TC_CAPTURE_CONTROLLER_TOKEN;
  const file = path.join(environment.LOCALAPPDATA || path.join(os.homedir(), "AppData", "Local"), "ThriftyCrew", "grocery-v3", "pc-capture-client.json");
  const config = JSON.parse(await readFile(file, "utf8").then((value) => value.replace(/^\uFEFF/, "")));
  if (typeof config.controllerToken !== "string" || config.controllerToken.length < 32) throw new Error("capture controller token is unavailable");
  return config.controllerToken;
}

export async function captureControllerRequest(pathname, body = {}, environment = process.env, timeoutMs = 1000) {
  if (environment.TC_CAPTURE_CONTROLLER_ORIGIN === "disabled") return null;
  const token = await controllerToken(environment).catch(() => null);
  if (!token) return null;
  return await new Promise((resolve) => {
    const socket = net.createConnection(CAPTURE_CONTROLLER_PIPE);
    let settled = false;
    let response = "";
    const finish = (value) => {
      if (settled) return;
      settled = true;
      socket.destroy();
      resolve(value);
    };
    socket.setTimeout(timeoutMs, () => finish(null));
    socket.on("error", () => finish(null));
    socket.on("connect", () => socket.write(`${JSON.stringify({ token, pathname, body })}\n`));
    socket.on("data", (chunk) => {
      response += chunk.toString("utf8");
      const newline = response.indexOf("\n");
      if (newline < 0) return;
      try { finish({ ...JSON.parse(response.slice(0, newline)), controllerReachable: true }); }
      catch { finish(null); }
    });
    socket.on("end", () => finish(null));
  });
}
