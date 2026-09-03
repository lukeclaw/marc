/*
 * marc — Windows icon generator.
 *
 * Port of scripts/generate-icon.swift, which draws the macOS iconset with
 * AppKit. There is no AppKit here, so the same artwork is drawn on a canvas in
 * an offscreen window and packed into build/icon.ico: a rounded, gradient tile
 * with a white "m" over three cyan reading lines.
 *
 * Run it with `npm run icon`. Windows picks icon sizes out of the .ico itself,
 * so every size Explorer and the taskbar ask for is rendered separately rather
 * than scaled from one bitmap.
 */
"use strict";

const { app, BrowserWindow, nativeImage } = require("electron");
const fs = require("fs");
const path = require("path");

// 256 is stored as PNG, the rest as uncompressed BMP, which is the layout
// Windows shells and electron-builder both read without complaint.
const SIZES = [16, 24, 32, 48, 64, 128, 256];
const PNG_THRESHOLD = 256;

const OUTPUT = path.join(__dirname, "..", "build", "icon.ico");

/* ------------------------------------------------------------------ drawing */

/*
 * Runs in the offscreen window. Kept as one self-contained function so it can
 * be handed to executeJavaScript as source text.
 */
function drawIcon(size) {
  const canvas = document.createElement("canvas");
  canvas.width = size;
  canvas.height = size;
  const context = canvas.getContext("2d");

  const inset = size * 0.06;
  const side = size - inset * 2;
  const radius = size * 0.22;

  // The Swift version draws its gradient at -50 degrees across the tile.
  const angle = (-50 * Math.PI) / 180;
  const gradient = context.createLinearGradient(
    inset + side / 2 - (Math.cos(angle) * side) / 2,
    inset + side / 2 + (Math.sin(angle) * side) / 2,
    inset + side / 2 + (Math.cos(angle) * side) / 2,
    inset + side / 2 - (Math.sin(angle) * side) / 2
  );
  gradient.addColorStop(0, "rgb(23, 33, 61)");
  gradient.addColorStop(1, "rgb(51, 87, 158)");

  context.beginPath();
  context.roundRect(inset, inset, side, side, radius);
  context.fillStyle = gradient;
  context.fill();

  // Three reading lines under the mark, matching the macOS artwork.
  const lineWidth = Math.max(1, size * 0.025);
  context.strokeStyle = "rgba(120, 212, 255, 0.9)";
  context.lineWidth = lineWidth;
  context.lineCap = "round";
  for (const offset of [0, 0.055, 0.11]) {
    const y = size * (0.81 + offset);
    context.beginPath();
    context.moveTo(size * 0.35, y);
    context.lineTo(size * 0.65, y);
    context.stroke();
  }

  // Centre the glyph's ink box in the area above the lines rather than trusting
  // font metrics, so the mark sits identically at every size.
  context.font = `700 ${size * 0.57}px "Segoe UI Variable Display", "Segoe UI", system-ui, sans-serif`;
  context.fillStyle = "#ffffff";
  context.textAlign = "center";
  context.textBaseline = "alphabetic";

  const metrics = context.measureText("m");
  const inkTop = size * 0.17;
  const inkBottom = size * 0.74;
  const inkHeight = metrics.actualBoundingBoxAscent + metrics.actualBoundingBoxDescent;
  const baseline = inkTop + (inkBottom - inkTop - inkHeight) / 2 + metrics.actualBoundingBoxAscent;
  context.fillText("m", size / 2, baseline);

  return canvas.toDataURL("image/png");
}

/* -------------------------------------------------------------- ico packing */

/*
 * A 32-bit BMP icon image: a BITMAPINFOHEADER whose height covers the colour
 * rows plus the legacy AND mask, then bottom-up BGRA rows, then the mask. The
 * alpha channel does the real work, so the mask is left empty.
 */
function bmpImage(bgra, size) {
  const header = Buffer.alloc(40);
  const maskStride = Math.ceil(size / 32) * 4;
  const maskSize = maskStride * size;
  const pixelSize = size * size * 4;

  header.writeUInt32LE(40, 0); // biSize
  header.writeInt32LE(size, 4); // biWidth
  header.writeInt32LE(size * 2, 8); // biHeight: colour rows plus mask rows
  header.writeUInt16LE(1, 12); // biPlanes
  header.writeUInt16LE(32, 14); // biBitCount
  header.writeUInt32LE(0, 16); // biCompression: BI_RGB
  header.writeUInt32LE(pixelSize + maskSize, 20); // biSizeImage

  const pixels = Buffer.alloc(pixelSize);
  const stride = size * 4;
  for (let row = 0; row < size; row += 1) {
    // BMP rows run bottom-up; nativeImage hands back top-down BGRA.
    bgra.copy(pixels, row * stride, (size - 1 - row) * stride, (size - row) * stride);
  }

  return Buffer.concat([header, pixels, Buffer.alloc(maskSize)]);
}

function buildIco(images) {
  const header = Buffer.alloc(6);
  header.writeUInt16LE(0, 0); // reserved
  header.writeUInt16LE(1, 2); // type: icon
  header.writeUInt16LE(images.length, 4);

  const directory = Buffer.alloc(images.length * 16);
  let offset = header.length + directory.length;

  images.forEach((image, index) => {
    const entry = index * 16;
    // 256 is stored as 0: the field is a single byte.
    directory.writeUInt8(image.size >= 256 ? 0 : image.size, entry);
    directory.writeUInt8(image.size >= 256 ? 0 : image.size, entry + 1);
    directory.writeUInt8(0, entry + 2); // palette entries
    directory.writeUInt8(0, entry + 3); // reserved
    directory.writeUInt16LE(1, entry + 4); // colour planes
    directory.writeUInt16LE(32, entry + 6); // bits per pixel
    directory.writeUInt32LE(image.data.length, entry + 8);
    directory.writeUInt32LE(offset, entry + 12);
    offset += image.data.length;
  });

  return Buffer.concat([header, directory, ...images.map((image) => image.data)]);
}

/* ------------------------------------------------------------------- driver */

async function main() {
  const window_ = new BrowserWindow({ show: false, width: 512, height: 512 });
  await window_.loadURL("about:blank");

  const images = [];
  for (const size of SIZES) {
    const dataURL = await window_.webContents.executeJavaScript(`(${drawIcon.toString()})(${size})`);
    const image = nativeImage.createFromDataURL(dataURL);
    const { width, height } = image.getSize();
    if (width !== size || height !== size) {
      throw new Error(`Rendered ${width}x${height} for the ${size}px variant`);
    }
    images.push({
      size,
      data: size >= PNG_THRESHOLD ? image.toPNG() : bmpImage(image.toBitmap(), size)
    });
  }

  fs.mkdirSync(path.dirname(OUTPUT), { recursive: true });
  fs.writeFileSync(OUTPUT, buildIco(images));
  process.stdout.write(`Wrote ${OUTPUT} (${SIZES.join(", ")}px)\n`);
  app.exit(0);
}

app.whenReady().then(() => {
  main().catch((error) => {
    process.stderr.write(`${error.stack ?? error}\n`);
    app.exit(1);
  });
});
