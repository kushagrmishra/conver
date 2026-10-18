const { contextBridge, ipcRenderer, webUtils } = require('electron');

const invoke = (ch) => (...a) => ipcRenderer.invoke(ch, ...a);

contextBridge.exposeInMainWorld('kq', {
  status: invoke('tools:status'),
  open: invoke('dialog:open'),
  pickDir: invoke('dialog:dir'),
  reveal: invoke('reveal'),
  readFile: invoke('file:read'),
  pathOf: (f) => webUtils.getPathForFile(f),
  hideWindow: invoke('window:hide'),
  moveWindowBy: invoke('window:moveBy'),
  convert: invoke('convert'),
  compress: invoke('compress'),
  imageEdit: invoke('image:edit'),
  normalize: invoke('audio:normalize'),
  redactAudio: invoke('audio:redact'),
  metaRead: invoke('meta:read'),
  metaStrip: invoke('meta:strip'),
  pdfMerge: invoke('pdf:merge'),
  pdfSplit: invoke('pdf:split'),
  pdfRotateAll: invoke('pdf:rotateAll'),
  pdfOrganize: invoke('pdf:organize'),
  pdfOptimize: invoke('pdf:optimize'),
  pdfFromImages: invoke('pdf:fromImages'),
  saveDataUrl: invoke('save:dataUrl'),
  presetsGet: invoke('presets:get'),
  presetsSet: invoke('presets:set'),
  onProgress: (cb) => ipcRenderer.on('progress', (_e, d) => cb(d)),
  onSummon: (cb) => ipcRenderer.on('wheel:summon', (_e, d) => cb(d)),
});
