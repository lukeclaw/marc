/*
 * marc — preload bridge.
 *
 * The renderer keeps no direct Node access; every filesystem, dialog, and
 * persistence operation crosses this narrow, explicitly enumerated surface.
 */
"use strict";

const { contextBridge, ipcRenderer } = require("electron");
const path = require("path");

contextBridge.exposeInMainWorld("marc", {
  startupFiles: () => ipcRenderer.invoke("marc:startup-files"),
  readFile: (filePath) => ipcRenderer.invoke("marc:read-file", filePath),
  writeFile: (filePath, content) => ipcRenderer.invoke("marc:write-file", filePath, content),
  stat: (filePaths) => ipcRenderer.invoke("marc:stat", filePaths),
  exists: (filePaths) => ipcRenderer.invoke("marc:exists", filePaths),
  openDialog: () => ipcRenderer.invoke("marc:open-dialog"),
  saveDialog: (options) => ipcRenderer.invoke("marc:save-dialog", options),
  createFile: (filePath, content) => ipcRenderer.invoke("marc:create-file", filePath, content),
  confirmClose: (fileName) => ipcRenderer.invoke("marc:confirm-close", fileName),
  confirm: (options) => ipcRenderer.invoke("marc:confirm", options),
  reveal: (filePath) => ipcRenderer.invoke("marc:reveal", filePath),
  copy: (text) => ipcRenderer.invoke("marc:copy", text),
  openExternal: (url) => ipcRenderer.invoke("marc:open-external", url),
  readStore: (name, fallback) => ipcRenderer.invoke("marc:read-store", name, fallback),
  writeStore: (name, value) => ipcRenderer.invoke("marc:write-store", name, value),
  registerDefault: () => ipcRenderer.invoke("marc:register-default"),
  reportSelfTest: (report) => ipcRenderer.invoke("marc:self-test-result", report),
  flushed: () => ipcRenderer.send("marc:flushed"),
  setTitle: (title) => ipcRenderer.send("marc:title", title),

  onCommand: (handler) => ipcRenderer.on("marc:command", (event, payload) => handler(payload)),
  onOpenFiles: (handler) => ipcRenderer.on("marc:open-files", (event, files) => handler(files)),

  // Path helpers, so the renderer never needs the Node path module directly.
  path: {
    basename: (value, extension) => path.basename(value, extension),
    dirname: (value) => path.dirname(value),
    extname: (value) => path.extname(value),
    join: (...parts) => path.join(...parts),
    resolve: (...parts) => path.resolve(...parts),
    sep: path.sep
  }
});
