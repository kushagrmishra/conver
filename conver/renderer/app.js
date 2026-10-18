const $ = (s) => document.querySelector(s);
const $$ = (s) => [...document.querySelectorAll(s)];
const base = (p) => p.split(/[\\/]/).pop();
const ext = (p) => (p.split('.').pop() || '').toLowerCase();

let outDir = null;
let currentAction = 'quick';
let currentFiles = [];
let rdBoxes = [];
let rdImgEl = null;

const IMG = ['jpg', 'jpeg', 'png', 'webp', 'avif', 'tif', 'tiff', 'gif', 'heic', 'bmp'];
const AUD = ['mp3', 'wav', 'flac', 'aac', 'm4a', 'ogg', 'opus'];
const VID = ['mp4', 'mov', 'mkv', 'webm', 'avi', 'm4v'];

const ACTION_TITLES = {
  quick: '⚡ Quick Convert',
  compress: '🗜️ Compress',
  edit: '🪄 Photo Edit',
  redact: '🕶️ Redact',
  exif: '🛡️ Strip EXIF & GPS',
  pdf: '📄 PDF Tools',
  audio: '🎵 Audio Tools',
  qr: '📷 Scan QR',
};

function toast(msg) {
  const t = $('#toast');
  t.textContent = msg;
  t.classList.add('show');
  clearTimeout(toast.t);
  toast.t = setTimeout(() => t.classList.remove('show'), 2400);
}

function setStatus(msg) {
  const s = $('#statusText');
  if (s) s.textContent = msg;
}

function detectCategory(files) {
  if (!files || !files.length) return 'unknown';
  const e = ext(files[0]);
  if (IMG.includes(e)) return 'image';
  if (AUD.includes(e)) return 'audio';
  if (VID.includes(e)) return 'video';
  if (e === 'pdf') return 'pdf';
  return 'unknown';
}

// ---------- Window Dragging (move wheel anywhere on screen) ----------
let winDrag = null;
function attachWindowDrag(el) {
  el.addEventListener('mousedown', (e) => {
    if (e.button !== 0) return;
    if (e.target.closest('button')) return;
    winDrag = { x: e.screenX, y: e.screenY, moved: false };
  });
}
window.addEventListener('mousemove', (e) => {
  if (!winDrag) return;
  const dx = e.screenX - winDrag.x;
  const dy = e.screenY - winDrag.y;
  if (Math.abs(dx) > 2 || Math.abs(dy) > 2) {
    winDrag.moved = true;
    winDrag.x = e.screenX;
    winDrag.y = e.screenY;
    kq.moveWindowBy({ dx, dy });
  }
});
window.addEventListener('mouseup', () => {
  if (winDrag) setTimeout(() => { winDrag = null; }, 0);
});

attachWindowDrag($('#wheelCenter'));
attachWindowDrag($('#menuDragHandle'));
attachWindowDrag($('#radialWheel'));

// Close on Escape or clicking empty stage outside wheel/card
window.addEventListener('keydown', (e) => {
  if (e.key === 'Escape') {
    if (!$('#menuCard').hidden) {
      showWheelView();
    } else {
      kq.hideWindow();
    }
  }
});
$('#stage').addEventListener('mousedown', (e) => {
  if (e.target === $('#stage') || e.target === $('#wheelView')) {
    kq.hideWindow();
  }
});

// ---------- Switch between Wheel View & Morphed Menu Card ----------
function showWheelView() {
  $('#menuCard').hidden = true;
  $('#wheelView').hidden = false;
}

function openActionMenu(action, files) {
  currentAction = action;
  currentFiles = files;
  $('#wheelView').hidden = true;
  $('#menuCard').hidden = false;

  const cat = detectCategory(files);
  $('#menuTitle').textContent = ACTION_TITLES[action] || 'Conver';
  $('#menuBadge').textContent = `${files.length} ${cat.toUpperCase()} file${files.length > 1 ? 's' : ''}`;

  $('#fileStrip').innerHTML = files
    .map((f) => `<div class="file-chip" title="${f}">📄 ${base(f)}</div>`)
    .join('');

  renderMenuOptions(action, cat, files);
}

$('#backBtn').onclick = () => showWheelView();
$('#addFilesBtn').onclick = async () => {
  const picked = await kq.open();
  if (picked && picked.length) {
    openActionMenu(currentAction, [...currentFiles, ...picked]);
  }
};

$('#outBtn').onclick = async () => {
  if (outDir) {
    outDir = null;
    $('#outBtn').textContent = '📁 Same folder';
    return;
  }
  const d = await kq.pickDir();
  if (d) {
    outDir = d;
    $('#outBtn').textContent = '📁 ' + base(d);
  }
};

// ---------- Summoned via Shift+Z ----------
kq.onSummon(({ files }) => {
  if (files && files.length) {
    currentFiles = files;
    $('#hubTitle').textContent = `${files.length} SELECTED`;
    $('#hubSub').textContent = 'Click any wedge!';
    toast(`Captured ${files.length} selected file(s)`);
  } else {
    showWheelView();
    $('#hubIcon').textContent = '⊕';
    $('#hubTitle').textContent = 'DROP FILES';
    $('#hubSub').textContent = 'Shift+Z · Drag to move';
  }
});

// ---------- Radial Wheel Wedges ----------
$$('.wheel-wedge').forEach((w) => {
  const action = w.dataset.wedge;
  w.addEventListener('mouseenter', () => {
    $('#hubIcon').textContent = w.querySelector('.w-icon').textContent;
    $('#hubTitle').textContent = w.querySelector('.w-title').textContent.toUpperCase();
    $('#hubSub').textContent = currentFiles.length
      ? `Use ${currentFiles.length} file(s)`
      : 'Drop or click';
  });
  w.addEventListener('mouseleave', () => {
    $('#hubIcon').textContent = '⊕';
    $('#hubTitle').textContent = currentFiles.length ? `${currentFiles.length} SELECTED` : 'DROP FILES';
    $('#hubSub').textContent = currentFiles.length ? 'Click any wedge!' : 'Shift+Z · Drag to move';
  });
  w.addEventListener('click', async () => {
    if (currentFiles.length) {
      openActionMenu(action, currentFiles);
      return;
    }
    const picked = await kq.open();
    if (picked && picked.length) {
      openActionMenu(action, picked);
    }
  });
  w.addEventListener('dragover', (e) => {
    e.preventDefault();
    w.classList.add('over');
    $('#hubIcon').textContent = w.querySelector('.w-icon').textContent;
    $('#hubTitle').textContent = w.querySelector('.w-title').textContent.toUpperCase();
    $('#hubSub').textContent = 'Release to open options';
  });
  w.addEventListener('dragleave', () => w.classList.remove('over'));
  w.addEventListener('drop', (e) => {
    e.preventDefault();
    w.classList.remove('over');
    const files = [...e.dataTransfer.files].map((f) => kq.pathOf(f)).filter(Boolean);
    if (files.length) openActionMenu(action, files);
  });
});

// Center Hub drop & click
const center = $('#wheelCenter');
center.addEventListener('click', async () => {
  if (winDrag && winDrag.moved) return;
  if (currentFiles.length) {
    openActionMenu('quick', currentFiles);
    return;
  }
  const picked = await kq.open();
  if (picked && picked.length) openActionMenu('quick', picked);
});
center.addEventListener('dragover', (e) => { e.preventDefault(); center.classList.add('over'); });
center.addEventListener('dragleave', () => center.classList.remove('over'));
center.addEventListener('drop', (e) => {
  e.preventDefault();
  center.classList.remove('over');
  const files = [...e.dataTransfer.files].map((f) => kq.pathOf(f)).filter(Boolean);
  if (files.length) openActionMenu('quick', files);
});

// ---------- Render Contextual Options inside Morphed Card ----------
async function renderMenuOptions(action, cat, files) {
  const body = $('#menuBody');
  body.innerHTML = '';
  setStatus('Select an option to run');

  if (action === 'quick') {
    let formats = [];
    if (cat === 'image') {
      formats = [
        { fmt: 'png', label: 'PNG', sub: 'Lossless' },
        { fmt: 'jpg', label: 'JPG', sub: 'Compact photo' },
        { fmt: 'webp', label: 'WebP', sub: 'Modern web' },
        { fmt: 'avif', label: 'AVIF', sub: 'Ultra small' },
        { fmt: 'tiff', label: 'TIFF', sub: 'Print archival' },
        { fmt: 'gif', label: 'GIF', sub: 'Animation' },
      ];
    } else if (cat === 'audio') {
      formats = [
        { fmt: 'mp3', label: 'MP3', sub: 'Universal audio' },
        { fmt: 'wav', label: 'WAV', sub: 'Uncompressed' },
        { fmt: 'flac', label: 'FLAC', sub: 'Lossless studio' },
        { fmt: 'aac', label: 'AAC', sub: 'Apple / M4A' },
        { fmt: 'ogg', label: 'OGG', sub: 'Open Vorbis' },
      ];
    } else if (cat === 'video') {
      formats = [
        { fmt: 'mp4', label: 'MP4', sub: 'H.264 video' },
        { fmt: 'webm', label: 'WebM', sub: 'VP9 web video' },
        { fmt: 'gifv', label: 'GIF', sub: 'Animated clip' },
        { fmt: 'mp3', label: 'Extract MP3', sub: 'Audio only' },
        { fmt: 'wav', label: 'Extract WAV', sub: 'Lossless audio' },
      ];
    } else if (cat === 'pdf') {
      return renderMenuOptions('pdf', cat, files);
    } else {
      formats = [
        { fmt: 'png', label: 'PNG', sub: 'Image' },
        { fmt: 'jpg', label: 'JPG', sub: 'Image' },
        { fmt: 'webp', label: 'WebP', sub: 'Image' },
        { fmt: 'mp4', label: 'MP4', sub: 'Video' },
        { fmt: 'mp3', label: 'MP3', sub: 'Audio' },
        { fmt: 'wav', label: 'WAV', sub: 'Audio' },
      ];
    }

    const grid = document.createElement('div');
    grid.className = 'option-grid';
    formats.forEach((item) => {
      const btn = document.createElement('button');
      btn.className = 'option-btn';
      btn.innerHTML = `<span class="o-title">To ${item.label}</span><span class="o-sub">${item.sub}</span>`;
      btn.onclick = () => runBatchConvert(files, item.fmt);
      grid.appendChild(btn);
    });
    body.appendChild(grid);
    return;
  }

  if (action === 'compress') {
    const presets = [
      { id: 'light', label: 'Light', sub: 'High quality · ~30% smaller' },
      { id: 'medium', label: 'Balanced', sub: 'Recommended · ~55% smaller' },
      { id: 'extreme', label: 'Maximum', sub: 'Smallest size · ~75% smaller' },
    ];
    const grid = document.createElement('div');
    grid.className = 'option-grid';
    presets.forEach((p) => {
      const btn = document.createElement('button');
      btn.className = 'option-btn';
      btn.innerHTML = `<span class="o-title">${p.label}</span><span class="o-sub">${p.sub}</span>`;
      btn.onclick = async () => {
        setStatus(`Compressing (${p.label})…`);
        let last;
        for (const file of files) {
          last = await kq.compress({ file, preset: p.id, outDir });
        }
        finishAction(last);
      };
      grid.appendChild(btn);
    });
    body.appendChild(grid);
    return;
  }

  if (action === 'edit') {
    const ops = [
      { id: 'rotate90', label: 'Rotate 90°', sub: 'Clockwise' },
      { id: 'rotate180', label: 'Rotate 180°', sub: 'Upside down' },
      { id: 'flipH', label: 'Flip Horiz', sub: 'Mirror X' },
      { id: 'flipV', label: 'Flip Vert', sub: 'Mirror Y' },
      { id: 'grayscale', label: 'B&W Mono', sub: 'Grayscale' },
      { id: 'resize50', label: 'Scale 50%', sub: 'Half dimensions' },
    ];
    const grid = document.createElement('div');
    grid.className = 'option-grid';
    ops.forEach((op) => {
      const btn = document.createElement('button');
      btn.className = 'option-btn';
      btn.innerHTML = `<span class="o-title">${op.label}</span><span class="o-sub">${op.sub}</span>`;
      btn.onclick = async () => {
        setStatus(`Applying ${op.label}…`);
        let last;
        for (const file of files) {
          last = await kq.imageEdit({ file, op: op.id, outDir });
        }
        finishAction(last);
      };
      grid.appendChild(btn);
    });
    body.appendChild(grid);
    return;
  }

  if (action === 'exif') {
    const metaBox = document.createElement('div');
    metaBox.className = 'meta-box';
    metaBox.textContent = 'Inspecting EXIF & GPS metadata…';
    body.appendChild(metaBox);

    const btn = document.createElement('button');
    btn.className = 'option-btn';
    btn.style.width = '100%';
    btn.innerHTML = `<span class="o-title">🧹 Strip All EXIF &amp; GPS Metadata</span><span class="o-sub">Saves clean copy of ${files.length} file(s)</span>`;
    btn.onclick = async () => {
      setStatus('Scrubbing metadata…');
      let last;
      for (const file of files) {
        last = await kq.metaStrip({ file, outDir });
      }
      finishAction(last);
    };
    body.appendChild(btn);

    const r = await kq.metaRead(files[0]);
    if (r && r.ok) {
      const keys = Object.keys(r.tags || {});
      metaBox.innerHTML = keys.length
        ? keys.slice(0, 20).map((k) => `<div class="meta-row ${r.sensitive.includes(k) ? 'hot' : ''}"><span>${k}</span><span>${String(r.tags[k]).slice(0, 36)}</span></div>`).join('')
        : 'No metadata found — file is already clean.';
    } else {
      metaBox.textContent = 'Ready to strip embedded metadata.';
    }
    return;
  }

  if (action === 'pdf') {
    const ops = [
      {
        label: 'Merge PDFs',
        sub: `${files.length} file(s) → 1 PDF`,
        run: async () => kq.pdfMerge({ files, outDir }),
      },
      {
        label: 'Optimize PDF',
        sub: 'Strip metadata & shrink',
        run: async () => kq.pdfOptimize({ file: files[0], outDir }),
      },
      {
        label: 'Split Pages',
        sub: '1 PDF per page',
        run: async () => kq.pdfSplit({ file: files[0], outDir }),
      },
      {
        label: 'Rotate 90°',
        sub: 'Rotate all pages',
        run: async () => kq.pdfRotateAll({ file: files[0], angle: 90, outDir }),
      },
    ];
    const grid = document.createElement('div');
    grid.className = 'option-grid';
    ops.forEach((op) => {
      const btn = document.createElement('button');
      btn.className = 'option-btn';
      btn.innerHTML = `<span class="o-title">${op.label}</span><span class="o-sub">${op.sub}</span>`;
      btn.onclick = async () => {
        setStatus(`${op.label}…`);
        finishAction(await op.run());
      };
      grid.appendChild(btn);
    });
    body.appendChild(grid);
    return;
  }

  if (action === 'audio') {
    const ops = [
      {
        label: 'Normalize (-16 LUFS)',
        sub: 'Podcast / broadcast level',
        run: async () => {
          let last;
          for (const file of files) last = await kq.normalize({ file, lufs: -16, outDir });
          return last;
        },
      },
      {
        label: 'Normalize (-14 LUFS)',
        sub: 'Spotify / YouTube level',
        run: async () => {
          let last;
          for (const file of files) last = await kq.normalize({ file, lufs: -14, outDir });
          return last;
        },
      },
      {
        label: 'To MP3 (320k)',
        sub: 'Universal audio',
        run: async () => {
          let last;
          for (const file of files) last = await kq.convert({ file, target: 'mp3', outDir });
          return last;
        },
      },
      {
        label: 'To WAV',
        sub: 'Uncompressed PCM',
        run: async () => {
          let last;
          for (const file of files) last = await kq.convert({ file, target: 'wav', outDir });
          return last;
        },
      },
      {
        label: 'To FLAC',
        sub: 'Lossless studio',
        run: async () => {
          let last;
          for (const file of files) last = await kq.convert({ file, target: 'flac', outDir });
          return last;
        },
      },
    ];
    const grid = document.createElement('div');
    grid.className = 'option-grid';
    ops.forEach((op) => {
      const btn = document.createElement('button');
      btn.className = 'option-btn';
      btn.innerHTML = `<span class="o-title">${op.label}</span><span class="o-sub">${op.sub}</span>`;
      btn.onclick = async () => {
        setStatus(`${op.label}…`);
        finishAction(await op.run());
      };
      grid.appendChild(btn);
    });
    body.appendChild(grid);
    return;
  }

  if (action === 'qr') {
    const box = document.createElement('div');
    box.className = 'meta-box';
    box.textContent = 'Scanning QR code…';
    body.appendChild(box);

    const buf = await kq.readFile(files[0]);
    const bmp = await createImageBitmap(new Blob([buf]));
    const c = $('#qrCanvas');
    c.width = bmp.width;
    c.height = bmp.height;
    const ctx = c.getContext('2d');
    ctx.drawImage(bmp, 0, 0);
    const d = ctx.getImageData(0, 0, c.width, c.height);
    const code = window.jsQR ? window.jsQR(d.data, c.width, c.height, { inversionAttempts: 'attemptBoth' }) : null;
    if (code && code.data) {
      box.innerHTML = `<div class="meta-row"><span>Decoded:</span><span><strong>${code.data.replace(/</g, '&lt;')}</strong></span></div>`;
      const copyBtn = document.createElement('button');
      copyBtn.className = 'option-btn';
      copyBtn.style.width = '100%';
      copyBtn.innerHTML = `<span class="o-title">📋 Copy Decoded Text</span><span class="o-sub">Copied to clipboard</span>`;
      navigator.clipboard.writeText(code.data);
      toast('QR copied to clipboard!');
      copyBtn.onclick = () => {
        navigator.clipboard.writeText(code.data);
        toast('Copied!');
      };
      body.appendChild(copyBtn);
    } else {
      box.textContent = 'No QR code detected in this image.';
    }
    return;
  }

  if (action === 'redact') {
    const wrap = document.createElement('div');
    wrap.className = 'canvas-wrap';
    wrap.innerHTML = `<canvas id="rdCanvas"></canvas>`;
    body.appendChild(wrap);

    const actions = document.createElement('div');
    actions.className = 'option-grid';
    actions.innerHTML = `
      <button class="option-btn" id="rdUndoBtn"><span class="o-title">Undo</span><span class="o-sub">Last box</span></button>
      <button class="option-btn" id="rdSaveBlack"><span class="o-title">Save Blackout</span><span class="o-sub">Export PNG</span></button>
      <button class="option-btn" id="rdSaveBlur"><span class="o-title">Save Pixelated</span><span class="o-sub">Export PNG</span></button>
    `;
    body.appendChild(actions);

    const buf = await kq.readFile(files[0]);
    rdImgEl = await createImageBitmap(new Blob([buf]));
    rdBoxes = [];
    const rdc = $('#rdCanvas');
    let dragPt = null;
    const getPt = (e) => {
      const r = rdc.getBoundingClientRect();
      return {
        x: ((e.clientX - r.left) * rdc.width) / r.width,
        y: ((e.clientY - r.top) * rdc.height) / r.height,
      };
    };
    const draw = (style = 'black', live = null) => {
      rdc.width = rdImgEl.width;
      rdc.height = rdImgEl.height;
      const ctx = rdc.getContext('2d');
      ctx.drawImage(rdImgEl, 0, 0);
      [...rdBoxes, ...(live ? [live] : [])].forEach((b) => {
        if (style === 'black' || b === live) {
          ctx.fillStyle = b === live ? 'rgba(0,0,0,0.65)' : '#000';
          ctx.fillRect(b.x, b.y, b.w, b.h);
        } else {
          const px = Math.max(8, Math.round(Math.min(b.w, b.h) / 6));
          const sm = document.createElement('canvas');
          sm.width = Math.max(1, (b.w / px) | 0);
          sm.height = Math.max(1, (b.h / px) | 0);
          sm.getContext('2d').drawImage(rdc, b.x, b.y, b.w, b.h, 0, 0, sm.width, sm.height);
          ctx.imageSmoothingEnabled = false;
          ctx.drawImage(sm, 0, 0, sm.width, sm.height, b.x, b.y, b.w, b.h);
          ctx.imageSmoothingEnabled = true;
        }
      });
    };
    draw();
    setStatus('Drag across image to redact areas');

    rdc.onmousedown = (e) => { dragPt = getPt(e); };
    rdc.onmousemove = (e) => {
      if (!dragPt) return;
      const p = getPt(e);
      draw('black', {
        x: Math.min(dragPt.x, p.x),
        y: Math.min(dragPt.y, p.y),
        w: Math.abs(p.x - dragPt.x),
        h: Math.abs(p.y - dragPt.y),
      });
    };
    window.onmouseup = (e) => {
      if (!dragPt) return;
      const p = getPt(e);
      const b = {
        x: Math.min(dragPt.x, p.x) | 0,
        y: Math.min(dragPt.y, p.y) | 0,
        w: Math.abs(p.x - dragPt.x) | 0,
        h: Math.abs(p.y - dragPt.y) | 0,
      };
      dragPt = null;
      if (b.w > 4 && b.h > 4) rdBoxes.push(b);
      draw();
    };
    $('#rdUndoBtn').onclick = () => { rdBoxes.pop(); draw(); };
    $('#rdSaveBlack').onclick = async () => {
      draw('black');
      finishAction(await kq.saveDataUrl({ source: files[0], dataUrl: rdc.toDataURL('image/png'), suffix: '-redacted', outDir }));
    };
    $('#rdSaveBlur').onclick = async () => {
      draw('pixelate');
      finishAction(await kq.saveDataUrl({ source: files[0], dataUrl: rdc.toDataURL('image/png'), suffix: '-redacted', outDir }));
    };
  }
}

async function runBatchConvert(files, target) {
  setStatus(`Converting ${files.length} file(s) to ${target.toUpperCase()}…`);
  let last;
  for (const file of files) {
    last = await kq.convert({ file, target, quality: 88, maxWidth: 0, outDir });
  }
  finishAction(last);
}

function finishAction(res) {
  if (!res) return;
  if (res.ok) {
    setStatus('Saved ' + base(res.out));
    toast('Saved ' + base(res.out));
    kq.reveal(res.out);
  } else {
    setStatus('Error: ' + res.error);
    toast('Error: ' + res.error);
  }
}
