# Conver — Floating Clear Glass Drop Wheel (`Shift + Z`)

> **100% Free · 100% Offline · Open Source**  
> Summon a floating Clear Glass Drop Wheel anywhere on **macOS**, **Windows**, and **Linux** with **`Shift + Z`**. Drop or select files to auto-detect their format and instantly convert, compress, edit photos, scrub EXIF/GPS metadata, redact sensitive areas, merge/split PDFs, normalize audio, or scan QR codes.

---

## ⬇️ Download & Install (3 Platforms)

Choose your operating system below — you can either **Directly Download the App** or **Install via Terminal**:

### 1. 🍎 macOS (Apple Silicon & Intel)

- **Direct App Download:**
  - [**📦 Download `Conver.dmg` for macOS (Direct Download)**](../../releases/latest/download/Conver.dmg)
- **Download & Install via Terminal (Recommended · Skips Gatekeeper):**
  ```bash
  curl -fsSL https://raw.githubusercontent.com/kushagrmishra/conver/main/install.sh | bash
  ```
  > 💡 **Note on macOS Security ("Apple cannot verify..."):** Conver is 100% safe, open-source, and offline. Because it is free community software without a commercial Apple cert:
  > - **Easiest:** Use the terminal command above (auto-approves the app).
  > - **Or if opening the DMG:** Right-click (Control-click) `Conver.app` → choose **Open** → click **Open** (or click **Open Anyway** in **System Settings → Privacy & Security**).

---

### 2. 🪟 Windows (Windows 10 / 11 · 64-bit)

- **Direct App Download:**
  - [**📦 Download `Conver-Setup.exe` (Windows Installer)**](../../releases/latest/download/Conver-Setup.exe)
  - [**⚡ Download `Conver-Portable.exe` (No-Install Portable)**](../../releases/latest/download/Conver-Portable.exe)
- **Download & Install via Terminal (PowerShell):**
  ```powershell
  irm https://raw.githubusercontent.com/kushagrmishra/conver/main/install.ps1 | iex
  ```
  *(Or download only via terminal: `curl.exe -fLO https://github.com/kushagrmishra/conver/releases/latest/download/Conver-Setup.exe`)*

---

### 3. 🐧 Linux (`AppImage` & Debian/Ubuntu `.deb`)

- **Direct App Download:**
  - [**📦 Download `Conver.AppImage` (Universal Linux)**](../../releases/latest/download/Conver.AppImage)
  - [**📦 Download `Conver.deb` (Ubuntu / Debian)**](../../releases/latest/download/Conver.deb)
- **Download & Install via Terminal:**
  ```bash
  curl -fsSL https://raw.githubusercontent.com/kushagrmishra/conver/main/install.sh | bash
  ```
  *(Or install the `.deb` package via terminal:)*
  ```bash
  curl -fLO https://github.com/kushagrmishra/conver/releases/latest/download/Conver.deb && sudo dpkg -i Conver.deb
  ```

---

## ✨ Features

- **⚡ Global `Shift + Z` Drop Wheel**: Summon the radial Drop Wheel over any app or file manager. Select files and press `Shift + Z` (or drag files directly onto any wedge).
- **🧠 Smart Auto-Detection & Shape-Morphing Menu**: Automatically detects whether your files are **Images**, **Audio**, **Video**, or **PDFs** and morphs the circular wheel into a Clear Glass rounded-rectangle menu with tailored target formats.
- **🛠️ 8 Built-In Wedges**:
  1. **Quick Convert** — `PNG`, `JPG`, `WebP`, `AVIF`, `HEIC`, `TIFF`, `GIF`, `MP4`, `WebM`, `MP3`, `WAV`, `FLAC`, `AAC`, `OGG`
  2. **Compress** — Light, Balanced, and Maximum size reduction presets
  3. **Photo Edit** — Rotate 90°/180°, Mirror Horizontal/Vertical, Grayscale, 50% Scale
  4. **Redact** — Interactive blackout or pixelation for sensitive image regions & audio timestamps
  5. **Strip EXIF** — Inspect & scrub GPS coordinates, camera serial numbers, and author metadata
  6. **PDF Tools** — Merge multiple PDFs, split pages, rotate pages, and optimize/flatten
  7. **Audio Tools** — EBU R128 loudness normalization (`-16 LUFS` / `-14 LUFS`) & lossless extraction
  8. **Scan QR** — Offline QR code detection & instant clipboard copy
- **🖥️ System Tray / Menu Bar & Launch at Login**: Runs quietly in your macOS Menu Bar or Windows/Linux System Tray with a one-click **Launch at Login** toggle.

---

## 🛠️ Build from Source

```text
.
├── ConverMac/          # Native macOS app (Swift 6, SwiftUI, AppKit, Liquid Glass)
├── conver/             # Windows & Linux desktop app (Electron, Sharp, pdf-lib, FFmpeg)
├── install.sh          # One-line terminal installer for macOS & Linux
├── install.ps1         # One-line PowerShell installer for Windows
├── build.sh            # Unified build script for macOS & Linux
├── build.bat           # Unified build script for Windows
└── Makefile            # Make targets (make mac, make linux, make windows)
```

| Platform | Build from Terminal | Output Binary |
| :--- | :--- | :--- |
| **macOS** | `./build.sh mac` *(or `make mac`)* | `ConverMac/dist/Conver.dmg` |
| **Linux** | `./build.sh linux` *(or `make linux`)* | `conver/dist/Conver.AppImage` & `Conver.deb` |
| **Windows** | `build.bat` *(or `npm run build:win`)* | `conver/dist/Conver-Setup.exe` & `Conver-Portable.exe` |

---

## 🔒 Privacy

Conver runs **100% locally on your device**. No files are ever uploaded to any cloud server, and there is zero analytics or telemetry.

## 📄 License

Released under the [MIT License](LICENSE).
