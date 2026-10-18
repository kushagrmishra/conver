# Conver for macOS (Native Swift + Clear Liquid Glass)

> **100% Free · On-Device · Native Clear Liquid Glass Drop Wheel (`Shift + Z`)**  
> Standalone native macOS utility built with Swift, SwiftUI, AppKit, AVFoundation, PDFKit, and CoreImage.

---

## ✨ Key Features

- **⚡ Global `Shift + Z` Drop Wheel**: Hold or press `Shift + Z` from any app or Finder window to summon the floating Clear Liquid Glass Drop Wheel.
- **🎯 Instant Selection & Drag-and-Drop**: Automatically captures selected files from Finder/Desktop, or lets you drag and drop files directly onto any of the 8 radial wedges (`Quick Convert`, `Compress`, `Photo Edit`, `Redact`, `Strip EXIF`, `PDF Tools`, `Audio Tools`, `Scan QR`).
- **🔄 Shape-Morphing Contextual Menu**: Automatically detects file types (`Image`, `Audio`, `Video`, `PDF`) and morphs from a circular wheel into a Clear Glass rounded-rectangle menu with tailored conversion formats.
- **🚀 Menu Bar & Launch at Login**: Lives in the macOS Menu Bar with a native `SMAppService` **Launch at Login** toggle.

---

## 🛠️ Building & Packaging

```bash
# Build signed Conver.app and dist/Conver.dmg
./package.sh
```
Or open `Conver.xcodeproj` in Xcode and press **⌘R**.
