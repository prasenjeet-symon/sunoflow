#!/usr/bin/env node
// Generates the five tray icons (.ico) for SunoFlow for Windows.
// Each icon is a 32x32 32-bit RGBA image (a microphone glyph over a colored
// rounded background), wrapped in the ICO container format. Mirrors the macOS
// SF Symbol states: idle (mic), recording (filled mic), offline (warning),
// processing (hourglass), plus an app icon.
//
// ICO layout: ICONDIR (6 bytes) + N x ICONDIRENTRY (16 bytes each) + image data.
// We embed a single 32x32 PNG (ICO supports PNG-encoded entries on Vista+).
const fs = require('fs');
const zlib = require('zlib');
const path = require('path');

const SIZE = 32;

// Color palette per state (r,g,b).
const COLORS = {
  'mic-idle':       [120, 120, 128],
  'mic-recording':  [235, 80, 80],
  'mic-offline':    [200, 160, 40],
  'mic-processing': [80, 140, 235],
  'app-icon':       [90, 150, 230],
};

function makeRgba(key) {
  const [r, g, b] = COLORS[key];
  const buf = Buffer.alloc(SIZE * SIZE * 4);
  for (let y = 0; y < SIZE; y++) {
    for (let x = 0; x < SIZE; x++) {
      const i = (y * SIZE + x) * 4;
      // Fully transparent outside; we only draw a rounded square + glyph.
      buf[i] = 0; buf[i + 1] = 0; buf[i + 2] = 0; buf[i + 3] = 0;
    }
  }
  // Rounded-square background (corner radius ~7).
  const radius = 7;
  const inset = 2;
  for (let y = 0; y < SIZE; y++) {
    for (let x = 0; x < SIZE; x++) {
      const i = (y * SIZE + x) * 4;
      if (!inRoundedRect(x, y, inset, inset, SIZE - inset, SIZE - inset, radius)) continue;
      buf[i] = r; buf[i + 1] = g; buf[i + 2] = b; buf[i + 3] = 255;
    }
  }
  // Draw a white microphone glyph in the center.
  drawMic(buf);
  return buf;
}

function inRoundedRect(x, y, x0, y0, x1, y1, r) {
  if (x < x0 || x >= x1 || y < y0 || y >= y1) return false;
  // corner checks
  const cx = x < x0 + r ? x0 + r : (x >= x1 - r ? x1 - r : x);
  const cy = y < y0 + r ? y0 + r : (y >= y1 - r ? y1 - r : y);
  const dx = x - cx, dy = y - cy;
  return dx * dx + dy * dy <= r * r;
}

function setPx(buf, x, y, r, g, b, a = 255) {
  x = Math.round(x); y = Math.round(y);
  if (x < 0 || x >= SIZE || y < 0 || y >= SIZE) return;
  const i = (y * SIZE + x) * 4;
  buf[i] = r; buf[i + 1] = g; buf[i + 2] = b; buf[i + 3] = a;
}

// Filled disc (for the capsule body).
function disc(buf, cx, cy, rad) {
  for (let y = -rad; y <= rad; y++)
    for (let x = -rad; x <= rad; x++)
      if (x * x + y * y <= rad * rad) setPx(buf, cx + x, cy + y, 255, 255, 255);
}

function hline(buf, x0, x1, y) {
  for (let x = x0; x <= x1; x++) setPx(buf, x, y, 255, 255, 255);
}

function vline(buf, x, y0, y1) {
  for (let y = y0; y <= y1; y++) setPx(buf, x, y, 255, 255, 255);
}

// Simple microphone: capsule body, stem, base.
function drawMic(buf) {
  // capsule (rounded rect) body, centered, ~9px wide, ~13px tall.
  const bx0 = 12, by0 = 7, bw = 8, bh = 13;
  for (let y = 0; y < bh; y++)
    for (let x = 0; x < bw; x++) {
      const px = bx0 + x, py = by0 + y;
      // rounded corners on the capsule
      if (x === 0 && (y === 0 || y === bh - 1)) continue;
      if (x === bw - 1 && (y === 0 || y === bh - 1)) continue;
      setPx(buf, px, py, 255, 255, 255);
    }
  // arc cradle (a half-circle bracket) around the body.
  // approximate with two vertical side lines + a top arc.
  const arcCx = 16, arcCy = 13, arcR = 9;
  for (let a = 20; a <= 160; a++) {
    const rad = a * Math.PI / 180;
    const x = Math.round(arcCx + arcR * Math.cos(rad));
    const y = Math.round(arcCy - arcR * Math.sin(rad));
    setPx(buf, x, y, 255, 255, 255);
  }
  // stem
  vline(buf, 16, 20, 25);
  // base
  hline(buf, 12, 20, 26);
}

// --- PNG encoder (minimal, 32-bit RGBA) ---
function crc32Table() {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c >>> 0;
  }
  return t;
}
const CRC = crc32Table();
function crc32(buf) {
  let c = 0xffffffff;
  for (let i = 0; i < buf.length; i++) c = CRC[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}
function chunk(type, data) {
  const len = Buffer.alloc(4); len.writeUInt32BE(data.length, 0);
  const t = Buffer.from(type, 'ascii');
  const crcBuf = Buffer.alloc(4);
  crcBuf.writeUInt32BE(crc32(Buffer.concat([t, data])), 0);
  return Buffer.concat([len, t, data, crcBuf]);
}
function encodePng(rgba) {
  const sig = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(SIZE, 0); ihdr.writeUInt32BE(SIZE, 4);
  ihdr[8] = 8; ihdr[9] = 6; ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0; // 8-bit RGBA
  // raw scanlines with filter byte 0.
  const raw = Buffer.alloc((SIZE * 4 + 1) * SIZE);
  for (let y = 0; y < SIZE; y++) {
    raw[y * (SIZE * 4 + 1)] = 0;
    rgba.copy(raw, y * (SIZE * 4 + 1) + 1, y * SIZE * 4, (y + 1) * SIZE * 4);
  }
  const idat = zlib.deflateSync(raw);
  return Buffer.concat([sig, chunk('IHDR', ihdr), chunk('IDAT', idat), chunk('IEND', Buffer.alloc(0))]);
}

function writeIco(name, png, outDir) {
  // ICONDIR (little-endian): reserved(2)=0, type(2)=1, count(2)=1
  const dir = Buffer.alloc(6);
  dir.writeUInt16LE(0, 0); dir.writeUInt16LE(1, 2); dir.writeUInt16LE(1, 4);
  // ICONDIRENTRY (little-endian): width(1), height(1), colors(1)=0, reserved(1)=0,
  // planes(2)=1, bpp(2)=32, size(4), offset(4).
  const entry = Buffer.alloc(16);
  entry[0] = SIZE; entry[1] = SIZE; entry[2] = 0; entry[3] = 0;
  entry.writeUInt16LE(1, 4); entry.writeUInt16LE(32, 6);
  entry.writeUInt32LE(png.length, 8); entry.writeUInt32LE(6 + 16, 12);
  const ico = Buffer.concat([dir, entry, png]);
  fs.writeFileSync(path.join(outDir, name + '.ico'), ico);
}

fs.mkdirSync(path.join(__dirname, '..', 'Assets'), { recursive: true });
const outDir = path.join(__dirname, '..', 'Assets');
for (const key of Object.keys(COLORS)) {
  const rgba = makeRgba(key);
  writeIco(key, encodePng(rgba), outDir);
  console.log('wrote', key + '.ico');
}