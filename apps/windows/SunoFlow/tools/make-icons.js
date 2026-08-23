#!/usr/bin/env node
// Generates the tray + app icons (.ico) for SunoFlow for Windows.
//
// Every icon is the SunoFlow brand mark — an ear receiving sound — in white on
// a coloured rounded square, mirroring the macOS menu-bar states: idle (ear
// listening), recording (filled ear), processing (ear alone, no sound arriving),
// offline (ear struck through), plus the app icon on the brand gradient.
//
// The mark's four path strings are copied verbatim from the website's wordmark
// (site/assets/favicon.svg) and rasterised here, so Windows, macOS
// (SunoFlowApp/Sources/SunoFlow/BrandMark.swift) and the web app all draw the
// same geometry.
//
// ICO layout: ICONDIR (6 bytes) + N x ICONDIRENTRY (16 bytes) + image data.
// Each entry is a PNG (ICO supports PNG-encoded entries on Vista+).
//
// Usage: node tools/make-icons.js
const fs = require('fs');
const zlib = require('zlib');
const path = require('path');

// --- The brand mark -----------------------------------------------------------

// SVG path data in a 24x24 box, stroked at width 2 with round caps and joins.
const EAR = 'M8.9 4.3c2.8 0 4.7 2 4.7 4.8 0 2.5-1.8 3.7-2.9 5.1-.7.9-.9 1.8-.9 2.9 0 1.5-1.2 2.6-2.6 2.6s-2.6-1.2-2.6-2.6c0-1.2.4-2 .4-3.1 0-1.6-1-2.8-1-4.9 0-2.8 2.1-4.8 4.9-4.8z';
const CURL = 'M8.9 7.4c1.4 0 2.2 1 2.2 2.1 0 1.3-1.1 1.9-1.7 2.8-.4.6-.5 1.2-.5 1.9';
const WAVES = ['M16.6 10.2a3.6 3.6 0 0 0 0 5.2', 'M19.9 8.2a6.8 6.8 0 0 0 0 9.2'];
const BOX = 24;
const STROKE = 2;

// Windows has no template-image tinting, so each state carries its own colour
// the way the macOS menu bar carries its own shape.
const VARIANTS = {
  'tray-idle':       { bg: [120, 120, 128], waves: true,  filled: false, slashed: false },
  'tray-recording':  { bg: [235, 80, 80],   waves: true,  filled: true,  slashed: false },
  'tray-processing': { bg: [80, 140, 235],  waves: false, filled: false, slashed: false },
  'tray-offline':    { bg: [200, 160, 40],  waves: false, filled: false, slashed: true },
  // The app icon uses the same violet→indigo gradient as the macOS .icns.
  'app-icon':        { bg: [124, 92, 255], bgBottom: [75, 46, 214], waves: true, filled: false, slashed: false },
};

// The sizes Windows asks for: 16–32 for the tray at assorted DPIs, the rest for
// Explorer, Alt-Tab and the installer.
const SIZES = [16, 20, 24, 32, 40, 48, 64, 256];

// --- SVG path reading ---------------------------------------------------------

// A deliberately small reader: it understands exactly the commands the mark uses
// (M, L, C, S, A, Z and their relative forms), and returns flattened polylines
// so the rasteriser below only ever deals with straight segments.
function flatten(d, steps) {
  const subpaths = [];
  let points = null;
  let cur = [0, 0];
  let start = [0, 0];
  let lastControl = null;
  let command = 'M';
  let i = 0;

  const isSep = (c) => c === ' ' || c === ',' || c === '\n' || c === '\t' || c === '\r';
  const skip = () => { while (i < d.length && isSep(d[i])) i++; };

  function number() {
    skip();
    let s = '';
    if (d[i] === '-' || d[i] === '+') s += d[i++];
    let dot = false;
    while (i < d.length) {
      const c = d[i];
      if (c >= '0' && c <= '9') { s += c; i++; }
      else if (c === '.' && !dot) { dot = true; s += c; i++; }
      else break;
    }
    return parseFloat(s) || 0;
  }

  function point(x, y) {
    return command === command.toLowerCase() ? [cur[0] + x, cur[1] + y] : [x, y];
  }

  function begin() {
    if (points && points.length > 1) subpaths.push({ points, closed: false });
    points = [];
  }

  // Fixed-step subdivision: at icon sizes the error is far below a pixel.
  function cubic(c1, c2, end) {
    const [x0, y0] = cur;
    for (let s = 1; s <= steps; s++) {
      const t = s / steps, u = 1 - t;
      points.push([
        u * u * u * x0 + 3 * u * u * t * c1[0] + 3 * u * t * t * c2[0] + t * t * t * end[0],
        u * u * u * y0 + 3 * u * u * t * c1[1] + 3 * u * t * t * c2[1] + t * t * t * end[1],
      ]);
    }
    cur = end;
  }

  while (true) {
    skip();
    if (i >= d.length) break;
    if (/[a-zA-Z]/.test(d[i])) command = d[i++];

    switch (command.toLowerCase()) {
      case 'm': {
        const p = point(number(), number());
        begin();
        points.push(p);
        cur = p; start = p; lastControl = null;
        command = command === 'm' ? 'l' : 'L';   // Extra pairs are implicit linetos.
        break;
      }
      case 'l': {
        const p = point(number(), number());
        points.push(p); cur = p; lastControl = null;
        break;
      }
      case 'c': {
        const c1 = point(number(), number());
        const c2 = point(number(), number());
        cubic(c1, c2, point(number(), number()));
        lastControl = c2;
        break;
      }
      case 's': {
        // Smooth curve: the first control point mirrors the previous one.
        const prev = lastControl || cur;
        const c1 = [2 * cur[0] - prev[0], 2 * cur[1] - prev[1]];
        const c2 = point(number(), number());
        cubic(c1, c2, point(number(), number()));
        lastControl = c2;
        break;
      }
      case 'a': {
        const rx = number(), ry = number(), rot = number();
        const largeArc = number() !== 0, sweep = number() !== 0;
        arc(cur, point(number(), number()), rx, ry, rot, largeArc, sweep, cubic);
        lastControl = null;
        break;
      }
      case 'z': {
        if (points && points.length > 1) subpaths.push({ points, closed: true });
        points = [start.slice()];
        cur = start; lastControl = null;
        break;
      }
      default:
        begin();
        return subpaths;   // An unsupported command: stop rather than guess.
    }
  }
  begin();
  return subpaths.filter((s) => s.points.length > 1);
}

// Endpoint-parameterised elliptical arc to cubic Béziers (SVG spec F.6.5).
function arc(p0, p1, rxIn, ryIn, degrees, largeArc, sweep, emit) {
  if (p0[0] === p1[0] && p0[1] === p1[1]) return;
  let rx = Math.abs(rxIn), ry = Math.abs(ryIn);
  if (rx === 0 || ry === 0) { emit(p0, p1, p1); return; }

  const phi = (degrees * Math.PI) / 180;
  const cosPhi = Math.cos(phi), sinPhi = Math.sin(phi);
  const dx = (p0[0] - p1[0]) / 2, dy = (p0[1] - p1[1]) / 2;
  const x1 = cosPhi * dx + sinPhi * dy;
  const y1 = -sinPhi * dx + cosPhi * dy;

  // Grow the radii if they're too small to span the chord (spec F.6.6).
  const lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry);
  if (lambda > 1) { const s = Math.sqrt(lambda); rx *= s; ry *= s; }

  const sign = largeArc !== sweep ? 1 : -1;
  const numerator = Math.max(0, rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1);
  const denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1;
  const coefficient = denominator === 0 ? 0 : sign * Math.sqrt(numerator / denominator);
  const cx1 = (coefficient * rx * y1) / ry;
  const cy1 = (-coefficient * ry * x1) / rx;
  const cx = cosPhi * cx1 - sinPhi * cy1 + (p0[0] + p1[0]) / 2;
  const cy = sinPhi * cx1 + cosPhi * cy1 + (p0[1] + p1[1]) / 2;

  const angle = (ux, uy, vx, vy) => {
    const len = Math.hypot(ux, uy) * Math.hypot(vx, vy);
    if (len === 0) return 0;
    let a = Math.acos(Math.min(1, Math.max(-1, (ux * vx + uy * vy) / len)));
    if (ux * vy - uy * vx < 0) a = -a;
    return a;
  };

  const ux = (x1 - cx1) / rx, uy = (y1 - cy1) / ry;
  const vx = (-x1 - cx1) / rx, vy = (-y1 - cy1) / ry;
  let theta = angle(1, 0, ux, uy);
  let sweepAngle = angle(ux, uy, vx, vy);
  if (!sweep && sweepAngle > 0) sweepAngle -= 2 * Math.PI;
  if (sweep && sweepAngle < 0) sweepAngle += 2 * Math.PI;

  // A cubic approximates at most a quarter turn well; split beyond that.
  const segments = Math.max(1, Math.ceil(Math.abs(sweepAngle) / (Math.PI / 2)));
  const step = sweepAngle / segments;
  const k = (4 / 3) * Math.tan(step / 4);
  let from = p0;

  for (let s = 0; s < segments; s++) {
    const next = theta + step;
    const on = (t) => [
      cx + rx * cosPhi * Math.cos(t) - ry * sinPhi * Math.sin(t),
      cy + rx * sinPhi * Math.cos(t) + ry * cosPhi * Math.sin(t),
    ];
    const tangent = (t) => [
      -rx * cosPhi * Math.sin(t) - ry * sinPhi * Math.cos(t),
      -rx * sinPhi * Math.sin(t) + ry * cosPhi * Math.cos(t),
    ];
    const end = on(next), d0 = tangent(theta), d1 = tangent(next);
    emit([from[0] + k * d0[0], from[1] + k * d0[1]],
         [end[0] - k * d1[0], end[1] - k * d1[1]], end);
    from = end; theta = next;
  }
}

// --- Rasterising --------------------------------------------------------------

function blend(buf, size, x, y, [r, g, b], alpha) {
  if (alpha <= 0 || x < 0 || y < 0 || x >= size || y >= size) return;
  const i = (y * size + x) * 4;
  const dstA = buf[i + 3] / 255;
  const outA = alpha + dstA * (1 - alpha);
  if (outA <= 0) { buf[i + 3] = 0; return; }
  buf[i] = Math.round((r * alpha + buf[i] * dstA * (1 - alpha)) / outA);
  buf[i + 1] = Math.round((g * alpha + buf[i + 1] * dstA * (1 - alpha)) / outA);
  buf[i + 2] = Math.round((b * alpha + buf[i + 2] * dstA * (1 - alpha)) / outA);
  buf[i + 3] = Math.round(outA * 255);
}

function distanceToSegments(segments, px, py, limit) {
  let best = Infinity;
  for (const [ax, ay, bx, by] of segments) {
    // Cheap reject: skip segments whose bounding box is already too far away.
    if (px < Math.min(ax, bx) - limit || px > Math.max(ax, bx) + limit ||
        py < Math.min(ay, by) - limit || py > Math.max(ay, by) + limit) continue;
    const dx = bx - ax, dy = by - ay;
    const lengthSq = dx * dx + dy * dy;
    let t = lengthSq === 0 ? 0 : ((px - ax) * dx + (py - ay) * dy) / lengthSq;
    t = t < 0 ? 0 : t > 1 ? 1 : t;
    const d = Math.hypot(px - (ax + t * dx), py - (ay + t * dy));
    if (d < best) best = d;
  }
  return best;
}

// Round caps and joins come for free: the distance to a polyline *is* the
// round-stroked outline.
function strokePolylines(buf, size, polylines, width, colour) {
  const half = width / 2;
  const segments = [];
  let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
  for (const line of polylines) {
    for (let i = 1; i < line.length; i++) {
      const [ax, ay] = line[i - 1], [bx, by] = line[i];
      segments.push([ax, ay, bx, by]);
      minX = Math.min(minX, ax, bx); maxX = Math.max(maxX, ax, bx);
      minY = Math.min(minY, ay, by); maxY = Math.max(maxY, ay, by);
    }
  }
  if (!segments.length) return;

  const pad = half + 1;
  for (let y = Math.max(0, Math.floor(minY - pad)); y <= Math.min(size - 1, Math.ceil(maxY + pad)); y++) {
    for (let x = Math.max(0, Math.floor(minX - pad)); x <= Math.min(size - 1, Math.ceil(maxX + pad)); x++) {
      const d = distanceToSegments(segments, x + 0.5, y + 0.5, pad);
      // Antialias over the one-pixel band straddling the stroke's edge.
      const coverage = Math.min(1, Math.max(0, half - d + 0.5));
      if (coverage > 0) blend(buf, size, x, y, colour, coverage);
    }
  }
}

// Nonzero-winding fill, 4x4 supersampled. Only the recording state needs it.
function fillPolygon(buf, size, points, colour) {
  let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
  for (const [x, y] of points) {
    minX = Math.min(minX, x); maxX = Math.max(maxX, x);
    minY = Math.min(minY, y); maxY = Math.max(maxY, y);
  }
  const inside = (px, py) => {
    let winding = 0;
    for (let i = 0, j = points.length - 1; i < points.length; j = i++) {
      const [xi, yi] = points[i], [xj, yj] = points[j];
      if (yi <= py) {
        if (yj > py && (xj - xi) * (py - yi) - (px - xi) * (yj - yi) > 0) winding++;
      } else if (yj <= py && (xj - xi) * (py - yi) - (px - xi) * (yj - yi) < 0) winding--;
    }
    return winding !== 0;
  };

  const N = 4;
  for (let y = Math.max(0, Math.floor(minY)); y <= Math.min(size - 1, Math.ceil(maxY)); y++) {
    for (let x = Math.max(0, Math.floor(minX)); x <= Math.min(size - 1, Math.ceil(maxX)); x++) {
      let hits = 0;
      for (let sy = 0; sy < N; sy++) {
        for (let sx = 0; sx < N; sx++) {
          if (inside(x + (sx + 0.5) / N, y + (sy + 0.5) / N)) hits++;
        }
      }
      if (hits) blend(buf, size, x, y, colour, hits / (N * N));
    }
  }
}

// Below ~20px there aren't enough pixels to spend on breathing room: the chip
// runs to the edge and the mark grows into it, or the ear turns to mush.
function metrics(size) {
  const tight = size <= 20;
  return {
    inset: tight ? 0 : (size * 2) / 32,
    radius: tight ? (size * 6) / 32 : (size * 7) / 32,
    glyphInset: tight ? (size * 3) / 32 : (size * 5.5) / 32,
  };
}

function roundedRectCoverage(x, y, x0, y0, x1, y1, r) {
  // Distance to the rounded rect, sampled at the pixel centre.
  const px = x + 0.5, py = y + 0.5;
  const cx = px < x0 + r ? x0 + r : px > x1 - r ? x1 - r : px;
  const cy = py < y0 + r ? y0 + r : py > y1 - r ? y1 - r : py;
  if (px < x0 - 1 || px > x1 + 1 || py < y0 - 1 || py > y1 + 1) return 0;
  const d = Math.hypot(px - cx, py - cy);
  return Math.min(1, Math.max(0, r - d + 0.5));
}

function render(size, variant) {
  const buf = Buffer.alloc(size * size * 4);   // Transparent to start with.

  // Background: a rounded square, proportioned like the original 32px icons.
  const { inset, radius, glyphInset } = metrics(size);
  const x0 = inset, y0 = inset, x1 = size - inset, y1 = size - inset;
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      const coverage = roundedRectCoverage(x, y, x0, y0, x1, y1, radius);
      if (coverage <= 0) continue;
      const colour = variant.bgBottom
        ? variant.bg.map((c, i) => Math.round(c + (variant.bgBottom[i] - c) * (y / (size - 1))))
        : variant.bg;
      blend(buf, size, x, y, colour, coverage);
    }
  }

  // The mark, in white, centred inside the rounded square.
  const scale = (size - glyphInset * 2) / BOX;
  const place = (subpaths) => subpaths.map((s) =>
    s.points.map(([x, y]) => [glyphInset + x * scale, glyphInset + y * scale]));

  // Curve subdivision fine enough that the error stays under a pixel.
  const steps = Math.max(4, Math.min(24, Math.round(size / 3)));
  const white = [255, 255, 255];
  const width = STROKE * scale;

  const ear = place(flatten(EAR, steps));
  if (variant.filled) {
    // Fill *and* stroke, so the silhouette keeps the same outer edge as the
    // outlined states and the mark doesn't jump size when recording starts.
    for (const polygon of ear) fillPolygon(buf, size, polygon, white);
    strokePolylines(buf, size, ear, width, white);
  } else {
    strokePolylines(buf, size, ear, width, white);
    strokePolylines(buf, size, place(flatten(CURL, steps)), width, white);
  }
  if (variant.waves) {
    for (const wave of WAVES) strokePolylines(buf, size, place(flatten(wave, steps)), width, white);
  }
  if (variant.slashed) {
    const slash = [[[4.2, 19.8], [19.8, 4.2]].map(([x, y]) => [glyphInset + x * scale, glyphInset + y * scale])];
    // Punch a gap out from under the slash first, so it reads as one stroke
    // crossing the mark rather than a line tangled up in it.
    clearPolylines(buf, size, slash, width * 2.4);
    strokePolylines(buf, size, slash, width, white);
  }
  return buf;
}

// Erases back to the background colour under a stroke (the ICO has no separate
// mask to draw into, so the gap is punched by re-blending the background).
function clearPolylines(buf, size, polylines, width) {
  const half = width / 2;
  const segments = [];
  for (const line of polylines) {
    for (let i = 1; i < line.length; i++) {
      segments.push([line[i - 1][0], line[i - 1][1], line[i][0], line[i][1]]);
    }
  }
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      const d = distanceToSegments(segments, x + 0.5, y + 0.5, half + 1);
      const coverage = Math.min(1, Math.max(0, half - d + 0.5));
      if (coverage <= 0) continue;
      const i = (y * size + x) * 4;
      // Fade back towards the background, which is whatever the rounded square
      // put here before the mark was drawn over it.
      const bg = currentBackground(x, y, size);
      buf[i] = Math.round(buf[i] * (1 - coverage) + bg[0] * coverage);
      buf[i + 1] = Math.round(buf[i + 1] * (1 - coverage) + bg[1] * coverage);
      buf[i + 2] = Math.round(buf[i + 2] * (1 - coverage) + bg[2] * coverage);
      buf[i + 3] = Math.round(buf[i + 3] * (1 - coverage) + bg[3] * coverage);
    }
  }
}

let backgroundPlate = null;   // Set by writeIcon before each render.
function currentBackground(x, y, size) {
  const i = (y * size + x) * 4;
  return [backgroundPlate[i], backgroundPlate[i + 1], backgroundPlate[i + 2], backgroundPlate[i + 3]];
}

// --- PNG encoder (minimal, 32-bit RGBA) ---------------------------------------

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
function encodePng(rgba, size) {
  const sig = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(size, 0); ihdr.writeUInt32BE(size, 4);
  ihdr[8] = 8; ihdr[9] = 6; ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0; // 8-bit RGBA
  const raw = Buffer.alloc((size * 4 + 1) * size);
  for (let y = 0; y < size; y++) {
    raw[y * (size * 4 + 1)] = 0;   // Filter type 0 (none).
    rgba.copy(raw, y * (size * 4 + 1) + 1, y * size * 4, (y + 1) * size * 4);
  }
  const idat = zlib.deflateSync(raw, { level: 9 });
  return Buffer.concat([sig, chunk('IHDR', ihdr), chunk('IDAT', idat), chunk('IEND', Buffer.alloc(0))]);
}

// --- ICO container ------------------------------------------------------------

function writeIco(name, entries, outDir) {
  // ICONDIR (little-endian): reserved(2)=0, type(2)=1, count(2).
  const dir = Buffer.alloc(6);
  dir.writeUInt16LE(0, 0); dir.writeUInt16LE(1, 2); dir.writeUInt16LE(entries.length, 4);

  // ICONDIRENTRY: width(1), height(1), colours(1)=0, reserved(1)=0,
  // planes(2)=1, bpp(2)=32, size(4), offset(4). 256 is stored as 0.
  let offset = 6 + 16 * entries.length;
  const table = [];
  for (const { size, png } of entries) {
    const entry = Buffer.alloc(16);
    entry[0] = size >= 256 ? 0 : size;
    entry[1] = size >= 256 ? 0 : size;
    entry.writeUInt16LE(1, 4); entry.writeUInt16LE(32, 6);
    entry.writeUInt32LE(png.length, 8); entry.writeUInt32LE(offset, 12);
    table.push(entry);
    offset += png.length;
  }
  const ico = Buffer.concat([dir, ...table, ...entries.map((e) => e.png)]);
  fs.writeFileSync(path.join(outDir, name + '.ico'), ico);
  return ico.length;
}

// --- Entry point --------------------------------------------------------------

const outDir = path.join(__dirname, '..', 'Assets');
fs.mkdirSync(outDir, { recursive: true });

for (const [name, variant] of Object.entries(VARIANTS)) {
  const entries = SIZES.map((size) => {
    // Render the background on its own first, so the slash can punch a gap back
    // down to it.
    backgroundPlate = render(size, { bg: variant.bg, bgBottom: variant.bgBottom });
    return { size, png: encodePng(render(size, variant), size) };
  });
  const bytes = writeIco(name, entries, outDir);
  console.log(`wrote ${name}.ico (${SIZES.length} sizes, ${bytes} bytes)`);
}
