# Conver for Windows & Linux (`Shift + Z` Clear Glass Drop Wheel)

> **Open-source, offline floating Clear Glass Drop Wheel for Windows and Linux.**

---

## ⚡ Features

- **Global `Shift + Z` Shortcut**: Summon or hide the floating Clear Glass Drop Wheel over any application.
- **Windows Explorer Selection Capture**: Select files in File Explorer and press `Shift + Z` (or drag and drop files onto any wedge).
- **8 Radial Wedges**:
  - **Quick Convert** (`PNG`, `JPG`, `WebP`, `AVIF`, `TIFF`, `GIF`, `MP4`, `WebM`, `MP3`, `WAV`, `FLAC`, `AAC`, `OGG`)
  - **Compress** (`Light`, `Balanced`, `Maximum`)
  - **Photo Edit** (`Rotate 90°/180°`, `Flip H/V`, `Grayscale`, `Scale 50%`)
  - **Redact** (Interactive blackout & pixelation)
  - **Strip EXIF** (Inspect & scrub GPS / camera metadata)
  - **PDF Tools** (Merge, Optimize, Split pages, Rotate pages)
  - **Audio Tools** (Loudness normalize `-16 LUFS` / `-14 LUFS`, convert formats)
  - **Scan QR** (Offline QR decoding & clipboard copy)
- **System Tray & Launch at Login**: Runs in the Windows/Linux system tray with a one-click **Launch at Login** option.

---

## 🪟 Windows Build & Run

```powershell
# Install dependencies
npm install

# Run in development
npm start

# Package Windows Installer (.exe) & Portable executable into dist/
npm run dist:win
```

---

## 🐧 Linux Build & Run

```bash
# Install dependencies (ensure ffmpeg is installed: sudo apt install ffmpeg)
npm install

# Run in development
npm start

# Package Linux AppImage & .deb into dist/
npm run dist:linux
```
