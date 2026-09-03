/*
 * marc — Electron main process.
 *
 * Owns the window, the native menu (the port of MarcApp's CommandGroup /
 * CommandMenu shortcuts), file I/O, native dialogs, and the on-disk stores that
 * replace macOS Application Support + UserDefaults.
 */
"use strict";

const { app, BrowserWindow, Menu, dialog, ipcMain, shell, clipboard, nativeTheme } = require("electron");
const fs = require("fs");
const fsp = require("fs/promises");
const os = require("os");
const path = require("path");
const { execFile } = require("child_process");

const MARKDOWN_EXTENSIONS = ["md", "markdown", "mdown", "mkd"];
const SELF_TEST = process.argv.includes("--self-test");

/*
 * Windows identifies an app by its Application User Model ID, and the installer
 * stamps this same id on the shortcuts it creates. Without it the running
 * window is not recognised as the pinned app: the taskbar shows a second,
 * generic Electron entry instead of lighting up the pin. It must match the
 * appId in package.json, and must be set before the first window opens.
 */
app.setAppUserModelId("com.jpineda.marc");

// A self-test run must never touch the real profile and must never outlive its
// budget: a renderer that throws before reporting used to hang the run forever.
const SELF_TEST_TIMEOUT = 120000;
const selfTestRoot = SELF_TEST
  ? fs.mkdtempSync(path.join(os.tmpdir(), "marc-self-test-"))
  : null;

let mainWindow = null;
let pendingFiles = [];
let quitting = false;
let flushed = false;
let selfTestTimer = null;

/* --------------------------------------------------------------- self test */

/*
 * The self test drives the real renderer against real files, so it is pointed
 * at a throwaway profile: settings, per-file preferences, the session, and the
 * scratch Markdown it opens all live under one temporary directory that is
 * removed when the run ends. Nothing it does can disturb the user's workspace.
 */
if (SELF_TEST) {
  app.setPath("userData", path.join(selfTestRoot, "profile"));
  fs.mkdirSync(path.join(selfTestRoot, "scratch"), { recursive: true });
  sweepSelfTestDirectories();
}

/*
 * Chromium still holds handles inside the profile when the run exits, so the
 * final cleanup below usually cannot remove the whole root. Each run therefore
 * also sweeps whatever earlier runs left behind, which keeps the temporary
 * directory from accumulating profiles over time.
 */
function sweepSelfTestDirectories() {
  const parent = os.tmpdir();
  let entries = [];
  try {
    entries = fs.readdirSync(parent);
  } catch (error) {
    return;
  }
  for (const entry of entries) {
    const candidate = path.join(parent, entry);
    if (!entry.startsWith("marc-self-test-") || candidate === selfTestRoot) continue;
    try {
      fs.rmSync(candidate, { recursive: true, force: true });
    } catch (error) {
      // A profile still locked by another run is left for the next sweep.
    }
  }
}

function finishSelfTest(text, failures) {
  if (selfTestTimer !== null) clearTimeout(selfTestTimer);
  process.stdout.write(`${text}\n`);
  try {
    fs.rmSync(selfTestRoot, { recursive: true, force: true });
  } catch (error) {
    // A locked scratch file must not change the reported result.
  }
  app.exit(failures > 0 ? 1 : 0);
}

/* ------------------------------------------------------------------ stores */

function storeDirectory() {
  return app.getPath("userData");
}

function storePath(name) {
  return path.join(storeDirectory(), name);
}

function readJSON(name, fallback) {
  try {
    const raw = fs.readFileSync(storePath(name), "utf8");
    const parsed = JSON.parse(raw);
    return parsed === null || parsed === undefined ? fallback : parsed;
  } catch (error) {
    return fallback;
  }
}

function writeJSON(name, value) {
  const target = storePath(name);
  const temporary = `${target}.tmp`;
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(temporary, JSON.stringify(value, null, 0), "utf8");
  fs.renameSync(temporary, target);
}

/* ------------------------------------------------------------- file helpers */

function isMarkdownPath(candidate) {
  const extension = path.extname(candidate).replace(".", "").toLowerCase();
  return MARKDOWN_EXTENSIONS.includes(extension);
}

function markdownFilesFromArgv(argv) {
  return argv
    .slice(1)
    .filter((argument) => !argument.startsWith("-"))
    .map((argument) => {
      try {
        return path.resolve(argument);
      } catch (error) {
        return null;
      }
    })
    .filter((candidate) => candidate !== null && isMarkdownPath(candidate) && fs.existsSync(candidate));
}

/* -------------------------------------------------------------------- menu */

function send(channel, payload) {
  if (mainWindow !== null && !mainWindow.isDestroyed()) {
    mainWindow.webContents.send(channel, payload);
  }
}

const command = (name, payload) => () => send("marc:command", { name, payload });

function buildMenu() {
  const template = [
    {
      label: "&File",
      submenu: [
        { label: "New Markdown File…", accelerator: "CommandOrControl+N", click: command("new") },
        { label: "Open…", accelerator: "CommandOrControl+O", click: command("open") },
        { label: "Save", accelerator: "CommandOrControl+S", click: command("save") },
        { type: "separator" },
        { label: "Close Tab", accelerator: "CommandOrControl+W", click: command("close-tab") },
        { type: "separator" },
        { label: "Copy File Path", click: command("copy-path") },
        { label: "Show in File Explorer", click: command("reveal") },
        { type: "separator" },
        { label: "Set marc as the Default Markdown App…", click: command("register-default") },
        { type: "separator" },
        { role: "quit", label: "Exit" }
      ]
    },
    {
      label: "&Edit",
      submenu: [
        { role: "undo" },
        { role: "redo" },
        { type: "separator" },
        { role: "cut" },
        { role: "copy" },
        { role: "paste" },
        { role: "selectAll" },
        { type: "separator" },
        { label: "Find in Document", accelerator: "CommandOrControl+F", click: command("find") }
      ]
    },
    {
      label: "&View",
      submenu: [
        { label: "Rendered", accelerator: "CommandOrControl+1", click: command("mode", "rendered") },
        { label: "Split", accelerator: "CommandOrControl+2", click: command("mode", "split") },
        { label: "Source", accelerator: "CommandOrControl+3", click: command("mode", "source") },
        { type: "separator" },
        {
          label: "Toggle Table of Contents",
          accelerator: "CommandOrControl+Shift+T",
          click: command("toggle-toc")
        },
        { label: "Move Contents to Left", click: command("toc-position", "left") },
        { label: "Move Contents to Right", click: command("toc-position", "right") },
        { type: "separator" },
        {
          label: "Toggle Linked Files",
          accelerator: "CommandOrControl+Shift+G",
          click: command("toggle-graph")
        },
        {
          label: "Analyze Attention",
          accelerator: "CommandOrControl+Shift+A",
          click: command("attention")
        },
        {
          label: "Document Theme",
          accelerator: "CommandOrControl+Shift+,",
          click: command("theme")
        },
        { type: "separator" },
        { role: "togglefullscreen" },
        { role: "reload" },
        { role: "toggledevtools" }
      ]
    },
    {
      label: "Te&xt Size",
      submenu: [
        { label: "Increase Text Size", accelerator: "CommandOrControl+Plus", click: command("font-size", 1) },
        { label: "Increase Text Size", accelerator: "CommandOrControl+=", visible: false, click: command("font-size", 1) },
        { label: "Decrease Text Size", accelerator: "CommandOrControl+-", click: command("font-size", -1) },
        { label: "Actual Size", accelerator: "CommandOrControl+0", click: command("font-size", 0) }
      ]
    },
    {
      label: "&Reading",
      submenu: [
        {
          label: "Previous Unread Passage",
          accelerator: "CommandOrControl+Alt+Up",
          click: command("pending", -1)
        },
        {
          label: "Next Unread Passage",
          accelerator: "CommandOrControl+Alt+Down",
          click: command("pending", 1)
        },
        { type: "separator" },
        { label: "Mark All Read", click: command("mark-all-read") }
      ]
    },
    {
      label: "&Project",
      submenu: [
        {
          label: "New Project Group…",
          accelerator: "CommandOrControl+Shift+N",
          click: command("new-group")
        },
        { type: "separator" },
        {
          label: "Sort Tabs",
          submenu: [
            { label: "Open Order", click: command("sort-tabs", "opened") },
            { label: "File Name", click: command("sort-tabs", "name") },
            { label: "Folder", click: command("sort-tabs", "folder") }
          ]
        }
      ]
    },
    {
      label: "&Help",
      submenu: [
        { label: "About marc", click: command("about") }
      ]
    }
  ];

  Menu.setApplicationMenu(Menu.buildFromTemplate(template));
}

/* ------------------------------------------------------------------ window */

function windowIcon() {
  // The icon is generated by scripts/generate-icon.js, the way the macOS build
  // generates its iconset, so a source checkout may not have one yet. Packaged
  // builds take their icon from the executable regardless.
  const candidate = path.join(__dirname, "..", "..", "build", "icon.ico");
  return fs.existsSync(candidate) ? candidate : undefined;
}

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1240,
    height: 820,
    minWidth: 900,
    minHeight: 600,
    show: false,
    backgroundColor: nativeTheme.shouldUseDarkColors ? "#1b1d21" : "#f4f4f6",
    title: "marc",
    icon: windowIcon(),
    webPreferences: {
      preload: path.join(__dirname, "preload.js"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
      spellcheck: false,
      // Keep the external-change poll and autosave timers running at full rate
      // when the window is minimized or covered, and keep the hidden self-test
      // window off Chromium's background clamp.
      backgroundThrottling: false
    }
  });

  mainWindow.once("ready-to-show", () => {
    if (!SELF_TEST) mainWindow.show();
  });

  if (SELF_TEST) {
    // Without these three guards a renderer that throws on startup leaves the
    // hidden window running and the process never exits.
    selfTestTimer = setTimeout(() => {
      finishSelfTest(`\nmarc self test timed out after ${SELF_TEST_TIMEOUT / 1000}s.`, 1);
    }, SELF_TEST_TIMEOUT);

    mainWindow.webContents.on("console-message", (event, level, message, line, sourceID) => {
      if (level >= 2) process.stdout.write(`  console ${path.basename(sourceID)}:${line} ${message}\n`);
    });

    mainWindow.webContents.on("render-process-gone", (event, details) => {
      finishSelfTest(`\nmarc self test renderer stopped: ${details.reason}.`, 1);
    });
  }

  mainWindow.on("close", (event) => {
    if (flushed || SELF_TEST) return;
    // Mirror NSApplication.willTerminateNotification: save dirty documents and
    // persist the session before the window goes away.
    event.preventDefault();
    quitting = true;
    send("marc:command", { name: "flush" });
    setTimeout(() => {
      flushed = true;
      if (mainWindow !== null && !mainWindow.isDestroyed()) mainWindow.close();
    }, 1200);
  });

  mainWindow.on("closed", () => {
    mainWindow = null;
  });

  mainWindow.loadFile(path.join(__dirname, "..", "renderer", "index.html"));
}

/* --------------------------------------------------------------------- IPC */

function registerIPC() {
  ipcMain.handle("marc:startup-files", () => {
    const files = pendingFiles;
    pendingFiles = [];
    return {
      files,
      selfTest: SELF_TEST,
      scratchDirectory: SELF_TEST ? path.join(selfTestRoot, "scratch") : null
    };
  });

  ipcMain.handle("marc:read-file", async (event, filePath) => {
    try {
      const content = await fsp.readFile(filePath, "utf8");
      const stats = await fsp.stat(filePath);
      return { ok: true, content: content.replace(/^﻿/u, ""), modified: stats.mtimeMs };
    } catch (error) {
      return { ok: false, error: error.message };
    }
  });

  ipcMain.handle("marc:write-file", async (event, filePath, content) => {
    try {
      const temporary = `${filePath}.marc-tmp`;
      await fsp.writeFile(temporary, content, "utf8");
      await fsp.rename(temporary, filePath);
      const stats = await fsp.stat(filePath);
      return { ok: true, modified: stats.mtimeMs };
    } catch (error) {
      return { ok: false, error: error.message };
    }
  });

  ipcMain.handle("marc:stat", async (event, filePaths) => {
    const results = {};
    await Promise.all(
      filePaths.map(async (filePath) => {
        try {
          const stats = await fsp.stat(filePath);
          results[filePath] = stats.mtimeMs;
        } catch (error) {
          results[filePath] = null;
        }
      })
    );
    return results;
  });

  ipcMain.handle("marc:exists", async (event, filePaths) => {
    const results = {};
    await Promise.all(
      filePaths.map(async (filePath) => {
        try {
          const stats = await fsp.stat(filePath);
          results[filePath] = stats.isFile();
        } catch (error) {
          results[filePath] = false;
        }
      })
    );
    return results;
  });

  ipcMain.handle("marc:open-dialog", async () => {
    const result = await dialog.showOpenDialog(mainWindow, {
      title: "Open Markdown",
      properties: ["openFile", "multiSelections"],
      filters: [
        { name: "Markdown", extensions: MARKDOWN_EXTENSIONS },
        { name: "Text", extensions: ["txt", "text"] },
        { name: "All Files", extensions: ["*"] }
      ]
    });
    return result.canceled ? [] : result.filePaths;
  });

  // Port of the NSSavePanel in DocumentStore.newDocument.
  ipcMain.handle("marc:save-dialog", async (event, options) => {
    const result = await dialog.showSaveDialog(mainWindow, {
      title: "New Markdown File",
      buttonLabel: "Create",
      defaultPath:
        options.directory === null || options.directory === undefined
          ? options.suggestedName
          : path.join(options.directory, options.suggestedName),
      properties: ["createDirectory", "showOverwriteConfirmation"],
      filters: [
        { name: "Markdown", extensions: MARKDOWN_EXTENSIONS },
        { name: "All Files", extensions: ["*"] }
      ]
    });
    return result.canceled ? null : result.filePath;
  });

  // Creates the file only when it is missing, so choosing an existing file in
  // the panel opens it rather than blanking it.
  ipcMain.handle("marc:create-file", async (event, filePath, content) => {
    try {
      await fsp.mkdir(path.dirname(filePath), { recursive: true });
      try {
        await fsp.writeFile(filePath, content, { encoding: "utf8", flag: "wx" });
      } catch (error) {
        if (error.code !== "EEXIST") throw error;
      }
      const stats = await fsp.stat(filePath);
      return { ok: true, modified: stats.mtimeMs };
    } catch (error) {
      return { ok: false, error: error.message };
    }
  });

  ipcMain.handle("marc:confirm-close", async (event, fileName) => {
    const result = await dialog.showMessageBox(mainWindow, {
      type: "warning",
      buttons: ["Save", "Cancel", "Don't Save"],
      defaultId: 0,
      cancelId: 1,
      message: `Save changes to ${fileName}?`,
      detail: "Your changes will be lost if you close without saving."
    });
    return ["save", "cancel", "discard"][result.response] ?? "cancel";
  });

  ipcMain.handle("marc:confirm", async (event, options) => {
    const result = await dialog.showMessageBox(mainWindow, {
      type: options.type ?? "question",
      buttons: options.buttons,
      defaultId: 0,
      cancelId: options.buttons.length - 1,
      message: options.message,
      detail: options.detail ?? ""
    });
    return result.response;
  });

  ipcMain.handle("marc:reveal", (event, filePath) => {
    shell.showItemInFolder(filePath);
  });

  ipcMain.handle("marc:copy", (event, text) => {
    clipboard.writeText(text);
  });

  ipcMain.handle("marc:open-external", (event, url) => {
    if (/^https?:/iu.test(url)) shell.openExternal(url);
  });

  ipcMain.handle("marc:read-store", (event, name, fallback) => readJSON(name, fallback));

  ipcMain.handle("marc:write-store", (event, name, value) => {
    try {
      writeJSON(name, value);
      return { ok: true };
    } catch (error) {
      return { ok: false, error: error.message };
    }
  });

  ipcMain.handle("marc:register-default", async () => registerDefaultHandler());

  ipcMain.handle("marc:self-test-result", (event, report) => {
    finishSelfTest(report.text, report.failures);
  });

  ipcMain.on("marc:flushed", () => {
    flushed = true;
    if (quitting && mainWindow !== null && !mainWindow.isDestroyed()) mainWindow.close();
  });

  ipcMain.on("marc:title", (event, title) => {
    if (mainWindow !== null && !mainWindow.isDestroyed()) mainWindow.setTitle(title);
  });
}

/* ------------------------------------------- default Markdown app (Windows) */

/*
 * Port of the macOS "Get Info > Open with > Change All" instructions. Only ever
 * runs from an explicit menu action after the user confirms, and only writes
 * under HKCU so it needs no elevation and affects no other user.
 */
function registerDefaultHandler() {
  return new Promise((resolve) => {
    const executable = process.env.PORTABLE_EXECUTABLE_FILE ?? process.execPath;
    const progID = "marc.MarkdownDocument";
    const classes = "HKCU\\Software\\Classes";
    const commands = [
      ["add", `${classes}\\${progID}`, "/ve", "/d", "Markdown Document", "/f"],
      ["add", `${classes}\\${progID}\\DefaultIcon`, "/ve", "/d", `${executable},0`, "/f"],
      ["add", `${classes}\\${progID}\\shell\\open\\command`, "/ve", "/d", `"${executable}" "%1"`, "/f"],
      ...MARKDOWN_EXTENSIONS.map((extension) => [
        "add",
        `${classes}\\.${extension}`,
        "/ve",
        "/d",
        progID,
        "/f"
      ])
    ];

    const runNext = (index) => {
      if (index >= commands.length) {
        resolve({ ok: true, executable });
        return;
      }
      execFile("reg", commands[index], (error) => {
        if (error) {
          resolve({ ok: false, error: error.message });
          return;
        }
        runNext(index + 1);
      });
    };
    runNext(0);
  });
}

/* -------------------------------------------------------------- app startup */

// LSMultipleInstancesProhibited: a second launch hands its files to this one.
if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.on("second-instance", (event, argv) => {
    const files = markdownFilesFromArgv(argv);
    if (mainWindow !== null && !mainWindow.isDestroyed()) {
      if (mainWindow.isMinimized()) mainWindow.restore();
      mainWindow.focus();
      if (files.length > 0) send("marc:open-files", files);
    } else {
      pendingFiles.push(...files);
    }
  });

  pendingFiles = markdownFilesFromArgv(process.argv);

  app.whenReady().then(() => {
    registerIPC();
    buildMenu();
    createWindow();

    app.on("activate", () => {
      if (BrowserWindow.getAllWindows().length === 0) createWindow();
    });
  });

  app.on("window-all-closed", () => {
    app.quit();
  });
}
