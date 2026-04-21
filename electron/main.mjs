import { app, BrowserWindow, Menu, dialog, shell } from "electron";
import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import net from "node:net";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const repoRoot = path.resolve(__dirname, "..");

let mainWindow = null;
let backendProcess = null;
let currentReviewURL = null;
let backendStarted = false;
let isQuitting = false;
let launchSequence = 0;
let backendRestartMoments = [];
let recentBackendLogs = [];

if (!app.requestSingleInstanceLock()) {
  app.quit();
}

app.on("second-instance", () => {
  if (!mainWindow) return;
  if (mainWindow.isMinimized()) mainWindow.restore();
  mainWindow.focus();
});

app.on("before-quit", () => {
  isQuitting = true;
  stopBackend();
});

app.whenReady().then(async () => {
  buildMenu();
  createWindow();
  await launchBackend();

  app.on("activate", async () => {
    if (!BrowserWindow.getAllWindows().length) {
      createWindow();
    }
    if (!backendProcess) {
      await launchBackend();
    }
  });
});

app.on("window-all-closed", () => {
  if (process.platform !== "darwin") {
    app.quit();
  }
});

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1440,
    height: 940,
    minWidth: 1120,
    minHeight: 760,
    show: false,
    backgroundColor: "#efe6d8",
    titleBarStyle: "hiddenInset",
    trafficLightPosition: { x: 18, y: 18 },
    vibrancy: "under-window",
    webPreferences: {
      preload: path.join(__dirname, "preload.cjs"),
      contextIsolation: true,
      nodeIntegration: false,
      spellcheck: false,
    },
  });

  mainWindow.on("ready-to-show", () => {
    mainWindow?.show();
  });

  mainWindow.on("closed", () => {
    mainWindow = null;
  });

  mainWindow.webContents.setWindowOpenHandler(({ url }) => {
    shell.openExternal(url);
    return { action: "deny" };
  });

  void mainWindow.loadFile(path.join(__dirname, "splash.html"));
}

async function launchBackend() {
  const sequence = ++launchSequence;
  stopBackend();

  const backendBinary = resolveBackendBinary();
  const backendPort = await reservePort();
  const reviewURL = `http://127.0.0.1:${backendPort}/`;
  const env = { ...process.env };
  delete env.ELECTRON_RUN_AS_NODE;

  backendStarted = false;
  currentReviewURL = null;

  backendProcess = spawn(backendBinary, ["serve", "--no-open", "--port", String(backendPort)], {
    cwd: resolveBackendWorkingDirectory(),
    env,
    stdio: ["ignore", "pipe", "pipe"],
  });

  backendProcess.stdout.setEncoding("utf8");
  backendProcess.stderr.setEncoding("utf8");

  let stdoutBuffer = "";
  backendProcess.stdout.on("data", (chunk) => {
    stdoutBuffer += chunk;
    const lines = stdoutBuffer.split(/\r?\n/);
    stdoutBuffer = lines.pop() ?? "";

    for (const line of lines) {
      if (!line.trim()) continue;
      rememberBackendLog(`stdout: ${line}`);
      console.log(`[duplicate-me] ${line}`);
    }
  });

  backendProcess.stderr.on("data", (chunk) => {
    const text = chunk.toString().trim();
    if (text) {
      for (const line of text.split(/\r?\n/)) {
        if (!line.trim()) continue;
        rememberBackendLog(`stderr: ${line}`);
        console.error(`[duplicate-me] ${line}`);
      }
    }
  });

  backendProcess.once("error", async (error) => {
    if (sequence !== launchSequence || isQuitting) {
      return;
    }

    await dialog.showMessageBox({
      type: "error",
      title: "Backend did not start",
      message: "DuplicateMe could not launch its local scan engine.",
      detail: `Failed to start:\n${backendBinary}\n\n${String(error)}`,
    });
  });

  backendProcess.once("exit", async (code, signal) => {
    const expectedStop = isQuitting || !backendStarted;
    backendProcess = null;
    currentReviewURL = null;

    if (isQuitting) {
      return;
    }

    if (!expectedStop) {
      if ((code === 0 || code === null) && canAutoRestartBackend()) {
        noteBackendRestart();
        if (mainWindow) {
          await mainWindow.loadFile(path.join(__dirname, "splash.html"));
        }
        await launchBackend();
        return;
      }

      await dialog.showMessageBox({
        type: "error",
        title: "DuplicateMe backend stopped",
        message: "The local scan engine stopped unexpectedly.",
        detail: `Exit code: ${code ?? "none"}\nSignal: ${signal ?? "none"}${formatRecentBackendLogs()}`,
      });
      if (mainWindow) {
        void mainWindow.loadFile(path.join(__dirname, "splash.html"));
      }
    }
  });

  const ready = await waitForBackendReady(reviewURL, sequence, 20000);

  if (ready && sequence === launchSequence && !isQuitting && backendProcess) {
    currentReviewURL = reviewURL;
    backendStarted = true;
    backendRestartMoments = [];
    if (mainWindow) {
      await mainWindow.loadURL(reviewURL);
    }
    return;
  }

  if (sequence !== launchSequence || isQuitting || backendStarted) {
    return;
  }

  await dialog.showMessageBox({
    type: "error",
    title: "Backend did not start",
    message: "DuplicateMe could not launch its local scan engine.",
    detail: `Expected backend binary at:\n${backendBinary}\n\nExpected local review URL:\n${reviewURL}`,
  });
}

function stopBackend() {
  if (!backendProcess) {
    return;
  }

  backendProcess.removeAllListeners("exit");
  backendProcess.kill("SIGTERM");
  backendProcess = null;
  currentReviewURL = null;
  backendStarted = false;
}

function resolveBackendBinary() {
  if (app.isPackaged) {
    return path.join(process.resourcesPath, "backend", "duplicate-me");
  }

  const candidates = [
    path.join(repoRoot, ".build", "arm64-apple-macosx", "debug", "duplicate-me"),
    path.join(repoRoot, ".build", "debug", "duplicate-me"),
  ];

  const match = candidates.find((candidate) => existsSync(candidate));
  if (!match) {
    throw new Error("Missing Swift backend binary. Run `swift build` first.");
  }
  return match;
}

function resolveBackendWorkingDirectory() {
  if (app.isPackaged) {
    return path.join(process.resourcesPath, "backend");
  }
  return repoRoot;
}

async function reservePort() {
  return await new Promise((resolve, reject) => {
    const server = net.createServer();
    server.unref();

    server.on("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      if (!address || typeof address === "string") {
        server.close(() => reject(new Error("Could not reserve a localhost port.")));
        return;
      }

      const port = address.port;
      server.close((error) => {
        if (error) {
          reject(error);
          return;
        }
        resolve(port);
      });
    });
  });
}

async function waitForBackendReady(reviewURL, sequence, timeoutMs) {
  const startedAt = Date.now();

  while (Date.now() - startedAt < timeoutMs) {
    if (sequence !== launchSequence || isQuitting || !backendProcess) {
      return false;
    }

    try {
      const response = await fetch(new URL("health", reviewURL));
      if (response.ok) {
        return true;
      }
    } catch {
      // Backend is still starting up.
    }

    await sleep(250);
  }

  return false;
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function rememberBackendLog(line) {
  recentBackendLogs.push(line);
  if (recentBackendLogs.length > 18) {
    recentBackendLogs = recentBackendLogs.slice(-18);
  }
}

function noteBackendRestart() {
  const now = Date.now();
  backendRestartMoments = backendRestartMoments.filter((moment) => now - moment < 60_000);
  backendRestartMoments.push(now);
}

function canAutoRestartBackend() {
  const now = Date.now();
  backendRestartMoments = backendRestartMoments.filter((moment) => now - moment < 60_000);
  return backendRestartMoments.length < 2;
}

function formatRecentBackendLogs() {
  if (!recentBackendLogs.length) {
    return "";
  }

  return `\n\nRecent backend log:\n${recentBackendLogs.join("\n")}`;
}

function buildMenu() {
  const template = [
    {
      label: "DuplicateMe",
      submenu: [
        { role: "about" },
        { type: "separator" },
        {
          label: "Restart Backend",
          click: async () => {
            if (mainWindow) {
              await mainWindow.loadFile(path.join(__dirname, "splash.html"));
            }
            await launchBackend();
          },
        },
        {
          label: "Open In Browser",
          click: () => {
            if (currentReviewURL) {
              void shell.openExternal(currentReviewURL);
            }
          },
        },
        { type: "separator" },
        { role: "services" },
        { type: "separator" },
        { role: "hide" },
        { role: "hideOthers" },
        { role: "unhide" },
        { type: "separator" },
        { role: "quit" },
      ],
    },
    {
      label: "File",
      submenu: [
        {
          label: "Reload Workspace",
          accelerator: "CmdOrCtrl+R",
          click: () => {
            if (mainWindow) {
              void mainWindow.reload();
            }
          },
        },
        {
          label: "Restart Backend",
          accelerator: "CmdOrCtrl+Shift+R",
          click: async () => {
            if (mainWindow) {
              await mainWindow.loadFile(path.join(__dirname, "splash.html"));
            }
            await launchBackend();
          },
        },
        { type: "separator" },
        { role: "close" },
      ],
    },
    {
      label: "Edit",
      submenu: [
        { role: "undo" },
        { role: "redo" },
        { type: "separator" },
        { role: "cut" },
        { role: "copy" },
        { role: "paste" },
        { role: "selectAll" },
      ],
    },
    {
      label: "View",
      submenu: [
        { role: "reload" },
        { role: "forceReload" },
        { role: "togglefullscreen" },
        { type: "separator" },
        { role: "toggleDevTools" },
      ],
    },
    {
      label: "Window",
      submenu: [
        { role: "minimize" },
        { role: "zoom" },
        { role: "front" },
      ],
    },
  ];

  Menu.setApplicationMenu(Menu.buildFromTemplate(template));
}
