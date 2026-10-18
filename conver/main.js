const { app, BrowserWindow, ipcMain, dialog, shell, globalShortcut, Tray, Menu, screen, nativeImage } = require('electron');
const path = require('path');
const fs = require('fs');
const { spawn, execFileSync } = require('child_process');
const sharp = require('sharp');
const { PDFDocument, degrees } = require('pdf-lib');
const exifr = require('exifr');

const IMG_OUT = ['png', 'jpg', 'webp', 'avif', 'tiff', 'gif'];
const AV_OUT = {
  mp3: ['-vn', '-c:a', 'libmp3lame', '-q:a', '2'],
  aac: ['-vn', '-c:a', 'aac', '-b:a', '192k'],
  wav: ['-vn', '-c:a', 'pcm_s16le'],
  flac: ['-vn', '-c:a', 'flac'],
  ogg: ['-vn', '-c:a', 'libvorbis', '-q:a', '5'],
  mp4: ['-c:v', 'libx264', '-crf', '23', '-preset', 'medium', '-c:a', 'aac', '-movflags', '+faststart'],
  webm: ['-c:v', 'libvpx-vp9', '-crf', '32', '-b:v', '0', '-c:a', 'libopus'],
  gifv: ['-vf', 'fps=15,scale=640:-1:flags=lanczos', '-loop', '0'],
};

let win;
let tray;
let isDialogOpen = false;
const presetsFile = () => path.join(app.getPath('userData'), 'presets.json');

function findBin(name) {
  const isWin = process.platform === 'win32';
  const binName = isWin ? `${name}.exe` : name;

  const localPaths = isWin ? [
    path.join(process.resourcesPath || '', 'bin', binName),
    path.join(__dirname, 'bin', binName),
    `C:\\ProgramData\\chocolatey\\bin\\${binName}`,
    `C:\\ffmpeg\\bin\\${binName}`,
  ] : [
    path.join(process.resourcesPath || '', 'bin', binName),
    `/opt/homebrew/bin/${binName}`,
    `/usr/local/bin/${binName}`,
    `/usr/bin/${binName}`,
    `/snap/bin/${binName}`,
  ];

  for (const p of localPaths) {
    if (fs.existsSync(p)) return p;
  }

  try {
    const cmd = isWin ? 'where' : 'which';
    const out = execFileSync(cmd, [binName], { stdio: ['ignore', 'pipe', 'ignore'] }).toString();
    return out.split(/\r?\n/)[0].trim() || null;
  } catch {
    return null;
  }
}

function outPath(src, ext, outDir, suffix = '') {
  const dir = outDir || path.dirname(src);
  const base = path.basename(src, path.extname(src));
  let p = path.join(dir, `${base}${suffix}.${ext}`);
  let i = 1;
  while (fs.existsSync(p)) p = path.join(dir, `${base}${suffix} (${i++}).${ext}`);
  return p;
}

function runFfmpeg(args, onProgress) {
  return new Promise((resolve, reject) => {
    const bin = findBin('ffmpeg');
    if (!bin) {
      const installHint = process.platform === 'win32'
        ? 'ffmpeg not found. Install with: winget install Gyan.FFmpeg'
        : process.platform === 'linux'
        ? 'ffmpeg not found. Install with: sudo apt install ffmpeg'
        : 'ffmpeg not found. Install with: brew install ffmpeg';
      return reject(new Error(installHint));
    }
    const p = spawn(bin, ['-y', '-hide_banner', '-progress', 'pipe:1', '-nostats', ...args]);
    let err = '';
    p.stderr.on('data', d => (err += d));
    p.stdout.on('data', d => onProgress && onProgress(d.toString()));
    p.on('close', c => (c === 0 ? resolve() : reject(new Error(err.split(/\r?\n/).slice(-4).join(' ')))));
  });
}

// Capture selected files from OS file manager (Windows Explorer / macOS Finder)
function captureSelectedFiles() {
  try {
    if (process.platform === 'win32') {
      const psScript = [
        '$shell = New-Object -ComObject Shell.Application',
        '$paths = @()',
        'foreach ($w in $shell.Windows()) {',
        '  try {',
        '    $sel = $w.Document.SelectedItems()',
        '    foreach ($item in $sel) { $paths += $item.Path }',
        '  } catch {}',
        '}',
        '$paths -join [Environment]::NewLine',
      ].join('; ');
      const out = execFileSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', psScript], {
        stdio: ['ignore', 'pipe', 'ignore'],
        timeout: 1200,
      }).toString().trim();
      if (out) {
        return out.split(/\r?\n/).map(s => s.trim()).filter(p => p && fs.existsSync(p));
      }
    } else if (process.platform === 'darwin') {
      const osa = `tell application "Finder"
        set sel to selection
        set out to ""
        repeat with f in sel
          set out to out & POSIX path of (f as alias) & "\\n"
        end repeat
        return out
      end tell`;
      const out = execFileSync('osascript', ['-e', osa], {
        stdio: ['ignore', 'pipe', 'ignore'],
        timeout: 1200,
      }).toString().trim();
      if (out) {
        return out.split(/\r?\n/).map(s => s.trim()).filter(p => p && fs.existsSync(p));
      }
    }
  } catch {
    // Ignore selection capture errors
  }
  return [];
}

function summonWheel() {
  if (!win) return;
  const selected = captureSelectedFiles();
  const cursor = screen.getCursorScreenPoint();
  const display = screen.getDisplayNearestPoint(cursor);
  const bounds = win.getBounds();
  const x = Math.max(
    display.workArea.x + 12,
    Math.min(cursor.x - Math.round(bounds.width / 2), display.workArea.x + display.workArea.width - bounds.width - 12)
  );
  const y = Math.max(
    display.workArea.y + 12,
    Math.min(cursor.y - Math.round(bounds.height / 2), display.workArea.y + display.workArea.height - bounds.height - 12)
  );
  win.setPosition(x, y, false);
  win.show();
  win.focus();
  win.webContents.send('wheel:summon', { files: selected });
}

function toggleWheel() {
  if (!win) return;
  if (win.isVisible() && win.isFocused()) {
    win.hide();
  } else {
    summonWheel();
  }
}

function createTray() {
  const iconFile = process.platform === 'win32' ? 'icon.ico' : 'icon.png';
  const iconPath = path.join(__dirname, 'build', iconFile);
  let img = fs.existsSync(iconPath) ? nativeImage.createFromPath(iconPath) : nativeImage.createEmpty();
  if (process.platform !== 'win32' && !img.isEmpty()) {
    img = img.resize({ width: 18, height: 18 });
  }
  tray = new Tray(img);
  tray.setToolTip('Conver — Drop Wheel (Shift+Z)');

  const updateMenu = () => {
    const loginSettings = app.getLoginItemSettings();
    const menu = Menu.buildFromTemplate([
      { label: 'Summon Drop Wheel (Shift+Z)', click: () => summonWheel() },
      { type: 'separator' },
      {
        label: 'Launch at Login',
        type: 'checkbox',
        checked: !!loginSettings.openAtLogin,
        click: (item) => {
          app.setLoginItemSettings({ openAtLogin: item.checked });
          updateMenu();
        },
      },
      { type: 'separator' },
      { label: 'Quit Conver', click: () => { app.isQuitting = true; app.quit(); } },
    ]);
    tray.setContextMenu(menu);
  };

  updateMenu();
  tray.on('click', () => toggleWheel());
}

function createWindow() {
  win = new BrowserWindow({
    width: 500,
    height: 540,
    frame: false,
    transparent: true,
    resizable: false,
    alwaysOnTop: true,
    hasShadow: false,
    backgroundColor: '#00000000',
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
    },
  });

  win.loadFile('renderer/index.html');

  // Click outside to close floating wheel (unless a file dialog is open)
  win.on('blur', () => {
    if (!isDialogOpen && win && win.isVisible()) {
      win.hide();
    }
  });

  win.on('close', (e) => {
    if (!app.isQuitting) {
      e.preventDefault();
      win.hide();
    }
  });
}

app.whenReady().then(() => {
  createWindow();
  createTray();

  // Register global Shift+Z shortcut across all apps on Windows, Linux, and macOS
  globalShortcut.register('Shift+Z', () => {
    toggleWheel();
  });
});

app.on('will-quit', () => {
  globalShortcut.unregisterAll();
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit();
});

ipcMain.handle('window:hide', () => {
  if (win) win.hide();
});

ipcMain.handle('window:moveBy', (_e, { dx, dy }) => {
  if (!win) return;
  const [x, y] = win.getPosition();
  win.setPosition(Math.round(x + dx), Math.round(y + dy), false);
});

ipcMain.handle('tools:status', () => ({
  ffmpeg: !!findBin('ffmpeg'),
  imageFormats: IMG_OUT,
  avFormats: Object.keys(AV_OUT),
}));

ipcMain.handle('dialog:open', async (_e, opts = {}) => {
  isDialogOpen = true;
  try {
    const r = await dialog.showOpenDialog(win, { properties: ['openFile', 'multiSelections'], ...opts });
    return r.canceled ? [] : r.filePaths;
  } finally {
    isDialogOpen = false;
    if (win) win.focus();
  }
});

ipcMain.handle('dialog:dir', async () => {
  isDialogOpen = true;
  try {
    const r = await dialog.showOpenDialog(win, { properties: ['openDirectory', 'createDirectory'] });
    return r.canceled ? null : r.filePaths[0];
  } finally {
    isDialogOpen = false;
    if (win) win.focus();
  }
});

ipcMain.handle('reveal', (_e, p) => shell.showItemInFolder(p));
ipcMain.handle('file:read', (_e, p) => fs.readFileSync(p).buffer.slice(0));

// ---- Convert (images via sharp, audio/video via ffmpeg) ----
ipcMain.handle('convert', async (e, { file, target, quality = 85, maxWidth = 0, outDir }) => {
  const send = (v) => e.sender.send('progress', { file, ...v });
  try {
    if (IMG_OUT.includes(target)) {
      let img = sharp(file, { animated: target === 'gif' || target === 'webp' }).rotate();
      if (maxWidth > 0) img = img.resize({ width: Number(maxWidth), withoutEnlargement: true });
      const fmt = target === 'jpg' ? 'jpeg' : target;
      img = img.toFormat(fmt, ['jpeg', 'webp', 'avif'].includes(fmt) ? { quality: Number(quality) } : {});
      const out = outPath(file, target, outDir);
      await img.toFile(out);
      send({ pct: 100 });
      return { ok: true, out };
    }
    if (AV_OUT[target]) {
      const ext = target === 'gifv' ? 'gif' : target;
      const out = outPath(file, ext, outDir);
      let dur = 0;
      try {
        dur = parseFloat(execFileSync(findBin('ffmpeg'), ['-i', file], { stdio: ['ignore', 'pipe', 'pipe'] }).toString());
      } catch (er) {
        const m = /Duration: (\d+):(\d+):([\d.]+)/.exec(String(er.stderr || ''));
        if (m) dur = +m[1] * 3600 + +m[2] * 60 + parseFloat(m[3]);
      }
      await runFfmpeg(['-i', file, ...AV_OUT[target], out], (chunk) => {
        const m = /out_time_ms=(\d+)/.exec(chunk);
        if (m && dur) send({ pct: Math.min(99, (+m[1] / 1e6 / dur) * 100) });
      });
      send({ pct: 100 });
      return { ok: true, out };
    }
    throw new Error('Unsupported target: ' + target);
  } catch (err) {
    return { ok: false, error: err.message };
  }
});

// ---- Compress (images, video, audio, PDF) ----
ipcMain.handle('compress', async (_e, { file, preset = 'medium', outDir }) => {
  try {
    const ext = path.extname(file).slice(1).toLowerCase();
    const qMap = { light: 82, medium: 68, extreme: 48 };
    const scaleMap = { light: 1.0, medium: 0.85, extreme: 0.65 };
    const q = qMap[preset] || 68;
    const scale = scaleMap[preset] || 0.85;

    if (['jpg', 'jpeg', 'png', 'webp', 'avif', 'tif', 'tiff'].includes(ext)) {
      const meta = await sharp(file).metadata();
      let img = sharp(file).rotate();
      if (scale < 1 && meta.width) {
        img = img.resize({ width: Math.max(64, Math.round(meta.width * scale)), withoutEnlargement: true });
      }
      const outExt = ext === 'png' ? 'webp' : (ext === 'jpeg' ? 'jpg' : ext);
      const fmt = outExt === 'jpg' ? 'jpeg' : outExt;
      const out = outPath(file, outExt, outDir, '-compressed');
      await img.toFormat(fmt, { quality: q }).toFile(out);
      return { ok: true, out, before: fs.statSync(file).size, after: fs.statSync(out).size };
    }
    if (ext === 'pdf') {
      const doc = await PDFDocument.load(fs.readFileSync(file), { ignoreEncryption: true });
      doc.setTitle(''); doc.setAuthor(''); doc.setSubject(''); doc.setKeywords([]);
      const out = outPath(file, 'pdf', outDir, '-compressed');
      const bytes = await doc.save({ useObjectStreams: true });
      fs.writeFileSync(out, bytes);
      return { ok: true, out, before: fs.statSync(file).size, after: bytes.length };
    }
    // Audio / Video via ffmpeg
    const crf = preset === 'light' ? '24' : preset === 'extreme' ? '32' : '28';
    const ab = preset === 'light' ? '160k' : preset === 'extreme' ? '96k' : '128k';
    const isAudio = ['mp3', 'wav', 'flac', 'aac', 'm4a', 'ogg', 'opus'].includes(ext);
    const outExt = isAudio ? 'mp3' : 'mp4';
    const out = outPath(file, outExt, outDir, '-compressed');
    const args = isAudio
      ? ['-i', file, '-vn', '-c:a', 'libmp3lame', '-b:a', ab, out]
      : ['-i', file, '-c:v', 'libx264', '-crf', crf, '-preset', 'fast', '-c:a', 'aac', '-b:a', ab, out];
    await runFfmpeg(args);
    return { ok: true, out, before: fs.statSync(file).size, after: fs.statSync(out).size };
  } catch (err) {
    return { ok: false, error: err.message };
  }
});

// ---- Photo Edit (rotate, flip, grayscale, resize) ----
ipcMain.handle('image:edit', async (_e, { file, op, outDir }) => {
  try {
    const ext = path.extname(file).slice(1).toLowerCase() || 'png';
    const outExt = ext === 'jpeg' ? 'jpg' : ext;
    let img = sharp(file).rotate();
    const meta = await sharp(file).metadata();

    if (op === 'rotate90') img = img.rotate(90);
    else if (op === 'rotate180') img = img.rotate(180);
    else if (op === 'flipH') img = img.flop();
    else if (op === 'flipV') img = img.flip();
    else if (op === 'grayscale') img = img.grayscale();
    else if (op === 'resize50' && meta.width) img = img.resize({ width: Math.max(32, Math.round(meta.width * 0.5)) });
    else if (op === 'resize1920' && meta.width) img = img.resize({ width: 1920, withoutEnlargement: true });

    const out = outPath(file, outExt, outDir, `-${op}`);
    await img.toFile(out);
    return { ok: true, out };
  } catch (err) {
    return { ok: false, error: err.message };
  }
});

// ---- Audio normalize ----
ipcMain.handle('audio:normalize', async (_e, { file, lufs = -16, outDir }) => {
  try {
    const out = outPath(file, path.extname(file).slice(1) || 'mp3', outDir, '-normalized');
    await runFfmpeg(['-i', file, '-af', `loudnorm=I=${lufs}:TP=-1.5:LRA=11`, out]);
    return { ok: true, out };
  } catch (err) { return { ok: false, error: err.message }; }
});

// ---- Audio redaction: mute or bleep time ranges ----
ipcMain.handle('audio:redact', async (_e, { file, ranges, mode = 'mute', outDir }) => {
  try {
    const out = outPath(file, path.extname(file).slice(1) || 'mp3', outDir, '-redacted');
    const enable = ranges.map(r => `between(t,${r.start},${r.end})`).join('+');
    let args;
    if (mode === 'bleep') {
      args = ['-i', file, '-f', 'lavfi', '-i', 'sine=frequency=1000',
        '-filter_complex', `[0:a]volume=enable='${enable}':volume=0[a];[1:a]volume=enable='${enable}':volume=0.3,volume=enable='not(${enable})':volume=0[b];[a][b]amix=inputs=2:duration=first:normalize=0`, out];
    } else {
      args = ['-i', file, '-af', `volume=enable='${enable}':volume=0`, out];
    }
    await runFfmpeg(args);
    return { ok: true, out };
  } catch (err) { return { ok: false, error: err.message }; }
});

// ---- Metadata ----
ipcMain.handle('meta:read', async (_e, file) => {
  try {
    const ext = path.extname(file).toLowerCase();
    if (['.jpg', '.jpeg', '.png', '.tif', '.tiff', '.heic', '.webp', '.avif'].includes(ext)) {
      const d = (await exifr.parse(file, { gps: true, xmp: true, iptc: true, icc: false })) || {};
      const flat = {};
      for (const [k, v] of Object.entries(d)) {
        if (v == null || (typeof v === 'object' && !(v instanceof Date) && !Array.isArray(v))) continue;
        flat[k] = v instanceof Date ? v.toISOString() : Array.isArray(v) ? v.join(', ') : v;
      }
      return { ok: true, tags: flat, sensitive: ['latitude', 'longitude', 'Make', 'Model', 'SerialNumber', 'Artist', 'Copyright'].filter(k => k in flat) };
    }
    if (findBin('ffmpeg')) {
      const bin = findBin('ffmpeg');
      const tags = {};
      const meta = execFileSync(bin, ['-i', file, '-f', 'ffmetadata', '-hide_banner', '-loglevel', 'error', '-'], { stdio: ['ignore', 'pipe', 'ignore'] }).toString();
      meta.split('\n').slice(1).forEach(l => { const i = l.indexOf('='); if (i > 0) tags[l.slice(0, i)] = l.slice(i + 1); });
      return { ok: true, tags, sensitive: ['artist', 'location', 'com.apple.quicktime.location.ISO6709'].filter(k => k in tags) };
    }
    return { ok: false, error: 'Unsupported file type' };
  } catch (err) { return { ok: false, error: err.message }; }
});

ipcMain.handle('meta:strip', async (_e, { file, outDir }) => {
  try {
    const ext = path.extname(file).slice(1).toLowerCase();
    const out = outPath(file, ext, outDir, '-clean');
    if (['jpg', 'jpeg', 'png', 'webp', 'avif', 'tif', 'tiff'].includes(ext)) {
      await sharp(file).rotate().toFile(out);
    } else {
      await runFfmpeg(['-i', file, '-map', '0', '-map_metadata', '-1', '-c', 'copy', out]);
    }
    return { ok: true, out };
  } catch (err) { return { ok: false, error: err.message }; }
});

// ---- PDF ----
ipcMain.handle('pdf:merge', async (_e, { files, outDir }) => {
  try {
    const merged = await PDFDocument.create();
    for (const f of files) {
      const src = await PDFDocument.load(fs.readFileSync(f), { ignoreEncryption: true });
      (await merged.copyPages(src, src.getPageIndices())).forEach(p => merged.addPage(p));
    }
    const out = outPath(files[0], 'pdf', outDir, '-merged');
    fs.writeFileSync(out, await merged.save({ useObjectStreams: true }));
    return { ok: true, out };
  } catch (err) { return { ok: false, error: err.message }; }
});

ipcMain.handle('pdf:split', async (_e, { file, outDir }) => {
  try {
    const src = await PDFDocument.load(fs.readFileSync(file), { ignoreEncryption: true });
    let lastOut = null;
    for (let i = 0; i < src.getPageCount(); i++) {
      const dst = await PDFDocument.create();
      const [cp] = await dst.copyPages(src, [i]);
      dst.addPage(cp);
      lastOut = outPath(file, 'pdf', outDir, `-page-${i + 1}`);
      fs.writeFileSync(lastOut, await dst.save({ useObjectStreams: true }));
    }
    return { ok: true, out: lastOut, count: src.getPageCount() };
  } catch (err) { return { ok: false, error: err.message }; }
});

ipcMain.handle('pdf:rotateAll', async (_e, { file, angle = 90, outDir }) => {
  try {
    const doc = await PDFDocument.load(fs.readFileSync(file), { ignoreEncryption: true });
    doc.getPages().forEach(p => p.setRotation(degrees((p.getRotation().angle + angle) % 360)));
    const out = outPath(file, 'pdf', outDir, `-rotated`);
    fs.writeFileSync(out, await doc.save({ useObjectStreams: true }));
    return { ok: true, out };
  } catch (err) { return { ok: false, error: err.message }; }
});

ipcMain.handle('pdf:organize', async (_e, { file, pages, outDir }) => {
  try {
    const src = await PDFDocument.load(fs.readFileSync(file), { ignoreEncryption: true });
    const dst = await PDFDocument.create();
    for (const pg of pages) {
      const [cp] = await dst.copyPages(src, [pg.index]);
      if (pg.rotate) cp.setRotation(degrees((cp.getRotation().angle + pg.rotate) % 360));
      dst.addPage(cp);
    }
    const out = outPath(file, 'pdf', outDir, '-organized');
    fs.writeFileSync(out, await dst.save({ useObjectStreams: true }));
    return { ok: true, out };
  } catch (err) { return { ok: false, error: err.message }; }
});

ipcMain.handle('pdf:optimize', async (_e, { file, outDir, stripMeta = true }) => {
  try {
    const doc = await PDFDocument.load(fs.readFileSync(file), { ignoreEncryption: true });
    if (stripMeta) {
      doc.setTitle(''); doc.setAuthor(''); doc.setSubject(''); doc.setKeywords([]);
      doc.setProducer('Conver'); doc.setCreator('Conver');
    }
    const out = outPath(file, 'pdf', outDir, '-optimized');
    const bytes = await doc.save({ useObjectStreams: true });
    fs.writeFileSync(out, bytes);
    return { ok: true, out, before: fs.statSync(file).size, after: bytes.length };
  } catch (err) { return { ok: false, error: err.message }; }
});

ipcMain.handle('pdf:fromImages', async (_e, { source, images, outDir, suffix = '-flattened' }) => {
  try {
    const doc = await PDFDocument.create();
    for (const d of images) {
      const buf = Buffer.from(d.data.split(',')[1], 'base64');
      const img = d.data.startsWith('data:image/png') ? await doc.embedPng(buf) : await doc.embedJpg(buf);
      const page = doc.addPage([d.w, d.h]);
      page.drawImage(img, { x: 0, y: 0, width: d.w, height: d.h });
    }
    const out = outPath(source, 'pdf', outDir, suffix);
    fs.writeFileSync(out, await doc.save());
    return { ok: true, out, before: fs.statSync(source).size, after: fs.statSync(out).size };
  } catch (err) { return { ok: false, error: err.message }; }
});

ipcMain.handle('save:dataUrl', async (_e, { source, dataUrl, ext = 'png', suffix = '', outDir }) => {
  try {
    const out = outPath(source, ext, outDir, suffix);
    fs.writeFileSync(out, Buffer.from(dataUrl.split(',')[1], 'base64'));
    return { ok: true, out };
  } catch (err) { return { ok: false, error: err.message }; }
});

ipcMain.handle('presets:get', () => {
  try { return JSON.parse(fs.readFileSync(presetsFile(), 'utf8')); } catch { return []; }
});
ipcMain.handle('presets:set', (_e, list) => { fs.writeFileSync(presetsFile(), JSON.stringify(list, null, 2)); return true; });
