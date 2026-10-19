import Foundation
import ImageIO
import UniformTypeIdentifiers
import AVFoundation
import PDFKit
import Vision
import CoreImage
import AppKit

enum KQError: LocalizedError {
    case msg(String)
    var errorDescription: String? { if case .msg(let m) = self { return m }; return nil }
}

enum Kind { case image, audio, video, document }

enum FileKind {
    case image, audio, video, pdf, document, other
    static func of(_ u: URL) -> FileKind {
        let ext = u.pathExtension.lowercased()
        let docExts: Set<String> = [
            "docx", "doc", "rtf", "rtfd", "txt", "html", "htm", "odt",
            "pages", "markdown", "md", "webarchive", "log"
        ]
        if docExts.contains(ext) { return .document }

        guard let t = UTType(filenameExtension: ext) else { return .other }
        if t.conforms(to: .image) { return .image }
        if t.conforms(to: .pdf) { return .pdf }
        if t.conforms(to: .audio) { return .audio }
        if t.conforms(to: .movie) || t.conforms(to: .video) { return .video }
        return .other
    }
}

enum Target: String, CaseIterable, Identifiable {
    case jpeg, png, heic, tiff, bmp, gif, m4a, wav, flac, aiff, mp4, mov, pdf
    var id: String { rawValue }
    var label: String {
        switch self {
        case .jpeg: "JPEG"; case .png: "PNG"; case .heic: "HEIC"; case .tiff: "TIFF"; case .bmp: "BMP"; case .gif: "GIF"
        case .m4a: "M4A (AAC)"; case .wav: "WAV"; case .flac: "FLAC"; case .aiff: "AIFF"
        case .mp4: "MP4 (H.264)"; case .mov: "MOV"
        case .pdf: "PDF"
        }
    }
    var shortLabel: String { self == .jpeg ? "JPG" : rawValue.uppercased() }
    var kind: Kind {
        switch self {
        case .jpeg, .png, .heic, .tiff, .bmp, .gif: .image
        case .m4a, .wav, .flac, .aiff: .audio
        case .mp4, .mov: .video
        case .pdf: .document
        }
    }
    var ext: String { self == .jpeg ? "jpg" : rawValue }
    var utType: UTType? {
        switch self {
        case .jpeg: .jpeg; case .png: .png; case .heic: .heic; case .tiff: .tiff; case .bmp: .bmp; case .gif: .gif
        case .pdf: .pdf
        default: nil
        }
    }
}

enum ChannelMode: String, CaseIterable, Identifiable {
    case original = "Original", mono = "Mono", stereo = "Stereo"
    var id: String { rawValue }
}

struct AudioJob {
    var trimStart: Double
    var trimEnd: Double
    var bleeps: [ClosedRange<Double>] = []
    var channels: ChannelMode = .original
    var gainL: Float = 1
    var gainR: Float = 1
    var normalize = false
    var m4a = true
}

enum Engine {
    struct Box: Identifiable { let id = UUID(); var x: Double; var y: Double; var w: Double; var h: Double } // normalized, top-left origin

    struct Adjust: Equatable {
        var exposure = 0.0, brightness = 0.0, contrast = 0.0, highlights = 0.0, shadows = 0.0
        var saturation = 0.0, warmth = 0.0, sharpness = 0.0, vignette = 0.0
    }

    static let ciContext = CIContext()

    static func resolveFileURL(_ url: URL) -> URL {
        if let filePathURL = (url as NSURL).filePathURL {
            return filePathURL.standardizedFileURL
        }
        return url.standardizedFileURL
    }

    static func outURL(_ rawSrc: URL, ext: String, suffix: String = "", dir: URL?) -> URL {
        let src = resolveFileURL(rawSrc)
        var folder = (dir.map(resolveFileURL)) ?? src.deletingLastPathComponent()
        if !FileManager.default.isWritableFile(atPath: folder.path) {
            folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
        }
        let base = src.deletingPathExtension().lastPathComponent + suffix
        var url = folder.appendingPathComponent(base).appendingPathExtension(ext)
        var i = 1
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) (\(i))").appendingPathExtension(ext); i += 1
        }
        return url
    }

    static func sizeString(_ urls: [URL]) -> String {
        let total = urls.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    // MARK: Images
    static func loadCGImage(_ rawURL: URL, maxPixel: Int = 0) throws -> CGImage {
        let url = resolveFileURL(rawURL)
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        // Handle PDF first-page rendering if a PDF is passed to image conversion
        if url.pathExtension.lowercased() == "pdf",
           let doc = PDFDocument(url: url),
           let page = doc.page(at: 0) {
            let rect = page.bounds(for: .mediaBox)
            let scale: CGFloat = 2.0
            let w = max(Int(rect.width * scale), 1)
            let h = max(Int(rect.height * scale), 1)
            if let ctx = CGContext(
                data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) {
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
                ctx.scaleBy(x: scale, y: scale)
                page.draw(with: .mediaBox, to: ctx)
                if let cg = ctx.makeImage() { return cg }
            }
        }

        if let src = CGImageSourceCreateWithURL(url as CFURL, nil) {
            var longest = maxPixel
            if let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
                let w = (p[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
                let h = (p[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
                if w > 0 && h > 0 {
                    longest = maxPixel > 0 ? min(maxPixel, max(w, h)) : max(w, h)
                }
            }
            if longest > 0 {
                let opts: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: longest,
                ]
                if let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) {
                    return img
                }
            }
            if let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                return img
            }
        }

        if let nsImg = NSImage(contentsOf: url),
           let cg = nsImg.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return cg
        }

        throw KQError.msg("Can't read image (\(url.lastPathComponent))")
    }

    static func normalizeCGImage(_ img: CGImage, opaqueBackground: Bool) -> CGImage? {
        let w = max(img.width, 1)
        let h = max(img.height, 1)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let alphaInfo: CGImageAlphaInfo = opaqueBackground ? .noneSkipLast : .premultipliedLast
        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: alphaInfo.rawValue
        ) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        if opaqueBackground {
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(rect)
        }
        ctx.draw(img, in: rect)
        return ctx.makeImage()
    }

    static func writeImage(_ img: CGImage, to url: URL, type: UTType, quality: Double = 0.85) throws {
        let needsOpaque = (type == .jpeg || type == .bmp)
        var props: [CFString: Any] = [:]
        if type == .jpeg || type == .heic {
            props[kCGImageDestinationLossyCompressionQuality] = quality
        }

        // First attempt with normalized image if opaque format has alpha, or raw CGImage
        let candidate = (needsOpaque ? (normalizeCGImage(img, opaqueBackground: true) ?? img) : img)
        if let d = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(d, candidate, props as CFDictionary)
            if CGImageDestinationFinalize(d) {
                return
            }
        }

        // Fallback: normalize to 8-bit sRGB RGBA/RGB and retry
        if let norm = normalizeCGImage(img, opaqueBackground: needsOpaque),
           let d2 = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(d2, norm, props as CFDictionary)
            if CGImageDestinationFinalize(d2) {
                return
            }
        }

        // Final fallback via NSBitmapImageRep for PNG/JPEG/TIFF/BMP/GIF
        let rep = NSBitmapImageRep(cgImage: candidate)
        let fileType: NSBitmapImageRep.FileType? = switch type {
        case .png: .png
        case .jpeg: .jpeg
        case .tiff: .tiff
        case .bmp: .bmp
        case .gif: .gif
        default: nil
        }
        if let fileType,
           let data = rep.representation(using: fileType, properties: [.compressionFactor: quality]) {
            try data.write(to: url, options: .atomic)
            return
        }

        throw KQError.msg("Write failed for \(url.lastPathComponent)")
    }

    static func convertVideoToGIF(_ src: URL, dir: URL?) async throws -> URL {
        let asset = AVURLAsset(url: src)
        let dur = (try? await asset.load(.duration).seconds) ?? 3.0
        let clippedDur = min(max(dur, 0.5), 6.0)
        let fps = 10
        let frameCount = max(Int(clippedDur * Double(fps)), 2)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 640, height: 640)
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero

        let out = outURL(src, ext: "gif", dir: dir)
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString, frameCount, nil) else {
            throw KQError.msg("Could not create GIF")
        }
        let gifProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary
        CGImageDestinationSetProperties(dest, gifProps)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / Double(fps)]] as CFDictionary

        for i in 0..<frameCount {
            let t = CMTime(seconds: Double(i) / Double(fps), preferredTimescale: 600)
            if let cg = (try? await gen.image(at: t).image) {
                CGImageDestinationAddImage(dest, cg, frameProps)
            }
        }
        guard CGImageDestinationFinalize(dest) else {
            throw KQError.msg("Failed to finalize GIF")
        }
        return out
    }

    // MARK: Convert
    static func convert(_ rawSrc: URL, to requestedTarget: Target, quality: Double, maxPixel: Int, dir: URL?) async throws -> URL {
        let src = resolveFileURL(rawSrc)
        let scoped = src.startAccessingSecurityScopedResource()
        defer { if scoped { src.stopAccessingSecurityScopedResource() } }

        let srcKind = FileKind.of(src)
        var t = requestedTarget

        // Smart cross-media compatibility so dropping any file onto Quick Convert works seamlessly
        switch srcKind {
        case .document:
            if t == .pdf {
                return try await MainActor.run {
                    try convertDocumentToPDF(src, dir: dir)
                }
            } else if t.kind == .image {
                let tempPDF = try await MainActor.run {
                    try convertDocumentToPDF(src, dir: nil)
                }
                defer { try? FileManager.default.removeItem(at: tempPDF) }
                let img = try loadCGImage(tempPDF, maxPixel: maxPixel)
                let out = outURL(src, ext: t.ext, dir: dir)
                try writeImage(img, to: out, type: t.utType!, quality: quality)
                return out
            } else {
                return try await MainActor.run {
                    try convertDocumentToPDF(src, dir: dir)
                }
            }
        case .image, .pdf:
            if t == .pdf {
                if srcKind == .image {
                    return try imagesToPDF([src], dir: dir)
                }
                return src
            }
            if t.kind != .image {
                t = (src.pathExtension.lowercased() == "jpg" || src.pathExtension.lowercased() == "jpeg") ? .png : .jpeg
            }
        case .audio:
            if t.kind != .audio {
                t = (src.pathExtension.lowercased() == "m4a") ? .wav : .m4a
            }
        case .video:
            if t == .gif {
                return try await convertVideoToGIF(src, dir: dir)
            } else if t.kind == .image {
                t = (src.pathExtension.lowercased() == "mp4") ? .mov : .mp4
            }
        case .other:
            break
        }

        switch t.kind {
        case .document:
            return try await MainActor.run {
                try convertDocumentToPDF(src, dir: dir)
            }
        case .image:
            let img = try loadCGImage(src, maxPixel: maxPixel)
            let out = outURL(src, ext: t.ext, dir: dir)
            try writeImage(img, to: out, type: t.utType!, quality: quality)
            return out
        case .audio where t != .m4a:
            // If input is a video container, extract audio track first or read via AVAudioFile
            var audioSrc = src
            var tempM4A: URL?
            if srcKind == .video {
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
                let asset = AVURLAsset(url: src)
                if let s = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) {
                    try await s.export(to: tmp, as: .m4a)
                    audioSrc = tmp
                    tempM4A = tmp
                }
            }
            defer { if let tempM4A { try? FileManager.default.removeItem(at: tempM4A) } }

            let inF = try AVAudioFile(forReading: audioSrc)
            let fmt = inF.processingFormat
            let out = outURL(src, ext: t.ext, dir: dir)
            var settings: [String: Any] = [AVSampleRateKey: fmt.sampleRate, AVNumberOfChannelsKey: fmt.channelCount]
            switch t {
            case .flac: settings[AVFormatIDKey] = kAudioFormatFLAC
            case .aiff:
                settings[AVFormatIDKey] = kAudioFormatLinearPCM; settings[AVLinearPCMBitDepthKey] = 16
                settings[AVLinearPCMIsFloatKey] = false; settings[AVLinearPCMIsBigEndianKey] = true
            default:
                settings[AVFormatIDKey] = kAudioFormatLinearPCM; settings[AVLinearPCMBitDepthKey] = 16
                settings[AVLinearPCMIsFloatKey] = false; settings[AVLinearPCMIsBigEndianKey] = false
            }
            let outF = try AVAudioFile(
                forWriting: out,
                settings: settings,
                commonFormat: fmt.commonFormat,
                interleaved: fmt.isInterleaved
            )
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 65_536) else { throw KQError.msg("Buffer") }
            while inF.framePosition < inF.length { try inF.read(into: buf); try outF.write(from: buf) }
            return out
        case .audio, .video:
            let asset = AVURLAsset(url: src)
            let (preset, type): (String, AVFileType) = switch t {
            case .m4a: (AVAssetExportPresetAppleM4A, .m4a)
            case .mov: (AVAssetExportPresetHighestQuality, .mov)
            default: (quality > 0.8 ? AVAssetExportPresetHighestQuality : AVAssetExportPreset1280x720, .mp4)
            }
            guard let s = AVAssetExportSession(asset: asset, presetName: preset) else { throw KQError.msg("Unsupported source for this format") }
            let out = outURL(src, ext: t.ext, dir: dir)
            try await s.export(to: out, as: type)
            return out
        }
    }

    // MARK: Super-Resolution Upscaling (Lanczos + Edge & Luminance Reconstruction)
    static func upscaleCGImage(_ cgSrc: CGImage, scale: Double? = nil, targetDimension: Int? = nil) throws -> CGImage {
        let origW = Double(cgSrc.width)
        let origH = Double(cgSrc.height)
        guard origW > 0 && origH > 0 else {
            throw KQError.msg("Invalid image dimensions")
        }

        let factor: Double
        if let targetDimension, targetDimension > 0 {
            let maxDim = max(origW, origH)
            factor = max(1.0, Double(targetDimension) / maxDim)
        } else {
            factor = max(1.0, scale ?? 2.0)
        }

        let newW = min(16384.0, origW * factor)
        let newH = min(16384.0, origH * factor)
        let clampedFactor = newW / origW

        let ciSrc = CIImage(cgImage: cgSrc)

        // 1. Sinc-windowed Lanczos Scale Transform
        guard let lanczos = CIFilter(name: "CILanczosScaleTransform") else {
            throw KQError.msg("Lanczos filter unavailable")
        }
        lanczos.setValue(ciSrc, forKey: kCIInputImageKey)
        lanczos.setValue(clampedFactor, forKey: kCIInputScaleKey)
        lanczos.setValue(1.0, forKey: kCIInputAspectRatioKey)

        guard var workingCI = lanczos.outputImage else {
            throw KQError.msg("Scale transform failed")
        }
        workingCI = workingCI.cropped(to: CGRect(x: 0, y: 0, width: newW, height: newH))

        // 2. Intelligent Luminance-Aware Edge Sharpening (avoids noise magnification)
        if let sharpen = CIFilter(name: "CISharpenLuminance") {
            sharpen.setValue(workingCI, forKey: kCIInputImageKey)
            let sharpnessValue = clampedFactor >= 3.0 ? 0.65 : 0.45
            sharpen.setValue(sharpnessValue, forKey: "inputSharpness")
            if let shOut = sharpen.outputImage {
                workingCI = shOut.cropped(to: CGRect(x: 0, y: 0, width: newW, height: newH))
            }
        }

        // 3. High-Frequency Micro-Texture Unsharp Mask
        if let unsharp = CIFilter(name: "CIUnsharpMask") {
            unsharp.setValue(workingCI, forKey: kCIInputImageKey)
            let radius = max(1.2, clampedFactor * 0.6)
            unsharp.setValue(radius, forKey: kCIInputRadiusKey)
            unsharp.setValue(0.38, forKey: kCIInputIntensityKey)
            if let unOut = unsharp.outputImage {
                workingCI = unOut.cropped(to: CGRect(x: 0, y: 0, width: newW, height: newH))
            }
        }

        let colorSpace = cgSrc.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let cgOut = ciContext.createCGImage(workingCI, from: workingCI.extent, format: .RGBA8, colorSpace: colorSpace) else {
            throw KQError.msg("Failed to render upscaled image")
        }
        return cgOut
    }

    static func upscaleImage(
        _ rawSrc: URL,
        scale: Double? = nil,
        targetDimension: Int? = nil,
        dir: URL? = nil
    ) throws -> URL {
        let src = resolveFileURL(rawSrc)
        let scoped = src.startAccessingSecurityScopedResource()
        defer { if scoped { src.stopAccessingSecurityScopedResource() } }

        let cgSrc = try loadCGImage(src)
        let cgOut = try upscaleCGImage(cgSrc, scale: scale, targetDimension: targetDimension)

        let suffixTag: String
        if let targetDimension, targetDimension > 0 {
            suffixTag = targetDimension >= 7000 ? "-8K" : (targetDimension >= 3500 ? "-4K" : "-\(targetDimension)px")
        } else {
            let s = scale ?? 2.0
            suffixTag = s == 2.0 ? "-2x" : (s == 4.0 ? "-4x" : "-\(Int(s))x")
        }

        let ext = src.pathExtension.lowercased()
        let outExt = ["jpg", "jpeg"].contains(ext) ? "jpg" : "png"
        let outType: UTType = outExt == "jpg" ? .jpeg : .png
        let out = outURL(src, ext: outExt, suffix: suffixTag, dir: dir)
        try writeImage(cgOut, to: out, type: outType, quality: 0.95)
        return out
    }

    static func compressImage(_ src: URL, dir: URL?) throws -> URL {
        let isHeic = src.pathExtension.lowercased() == "heic"
        let img = try loadCGImage(src, maxPixel: 2560)
        let out = outURL(src, ext: isHeic ? "heic" : "jpg", suffix: "-compressed", dir: dir)
        try writeImage(img, to: out, type: isHeic ? .heic : .jpeg, quality: 0.6)
        return out
    }

    static func compressVideo(_ src: URL, preset: String, dir: URL?) async throws -> URL {
        let asset = AVURLAsset(url: src)
        guard let s = AVAssetExportSession(asset: asset, presetName: preset) else { throw KQError.msg("Can't compress this video") }
        let out = outURL(src, ext: "mp4", suffix: "-compressed", dir: dir)
        try await s.export(to: out, as: .mp4)
        return out
    }

    static func imagesToPDF(_ urls: [URL], dir: URL?) throws -> URL {
        let doc = PDFDocument()
        for u in urls {
            guard let img = NSImage(contentsOf: u), let p = PDFPage(image: img) else { continue }
            doc.insert(p, at: doc.pageCount)
        }
        guard doc.pageCount > 0 else { throw KQError.msg("No images to convert") }
        let out = outURL(urls[0], ext: "pdf", dir: dir)
        doc.write(to: out); return out
    }

    // MARK: Document to PDF (DOCX, DOC, RTF, RTFD, TXT, HTML, ODT, PAGES, MD)
    @MainActor
    static func convertDocumentToPDF(_ rawSrc: URL, dir: URL?) throws -> URL {
        let src = resolveFileURL(rawSrc)
        let scoped = src.startAccessingSecurityScopedResource()
        defer { if scoped { src.stopAccessingSecurityScopedResource() } }

        let out = outURL(src, ext: "pdf", dir: dir)
        let ext = src.pathExtension.lowercased()

        var attrString: NSAttributedString?
        var docAttributes: NSDictionary?

        // 1. Specific format hint
        let specificOptions: [NSAttributedString.DocumentReadingOptionKey: Any]
        switch ext {
        case "docx":
            specificOptions = [.documentType: NSAttributedString.DocumentType.officeOpenXML]
        case "doc":
            specificOptions = [.documentType: NSAttributedString.DocumentType.docFormat]
        case "rtf", "rtfd":
            specificOptions = [.documentType: NSAttributedString.DocumentType.rtf]
        case "html", "htm":
            specificOptions = [.documentType: NSAttributedString.DocumentType.html]
        default:
            specificOptions = [:]
        }

        if !specificOptions.isEmpty {
            attrString = try? NSAttributedString(url: src, options: specificOptions, documentAttributes: &docAttributes)
        }

        // 2. Auto-detecting options
        if attrString == nil {
            attrString = try? NSAttributedString(url: src, options: [:], documentAttributes: &docAttributes)
        }

        // 3. Fallback via /usr/bin/textutil to HTML if direct loading failed
        if attrString == nil && FileManager.default.fileExists(atPath: "/usr/bin/textutil") {
            let tmpHTML = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".html")
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
            proc.arguments = ["-convert", "html", src.path, "-output", tmpHTML.path]
            try? proc.run()
            proc.waitUntilExit()

            if FileManager.default.fileExists(atPath: tmpHTML.path) {
                defer { try? FileManager.default.removeItem(at: tmpHTML) }
                attrString = try? NSAttributedString(
                    url: tmpHTML,
                    options: [.documentType: NSAttributedString.DocumentType.html],
                    documentAttributes: &docAttributes
                )
            }
        }

        // 4. Plain text fallback
        if attrString == nil {
            if let plain = try? String(contentsOf: src, encoding: .utf8) {
                attrString = NSAttributedString(string: plain)
            }
        }

        guard let str = attrString, str.length > 0 else {
            throw KQError.msg("Could not open or parse document \(src.lastPathComponent)")
        }

        // Multi-page paginated print rendering
        let printInfo = NSPrintInfo()
        printInfo.paperSize = NSSize(width: 595.28, height: 841.89) // Standard A4 (210 x 297 mm)
        printInfo.topMargin = 40
        printInfo.bottomMargin = 40
        printInfo.leftMargin = 40
        printInfo.rightMargin = 40
        printInfo.isHorizontallyCentered = false
        printInfo.isVerticallyCentered = false
        printInfo.jobDisposition = .save
        printInfo.dictionary().setObject(out, forKey: NSPrintInfo.AttributeKey.jobSavingURL as NSCopying)

        let textStorage = NSTextStorage(attributedString: str)
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let contentWidth = printInfo.paperSize.width - printInfo.leftMargin - printInfo.rightMargin
        let textContainer = NSTextContainer(containerSize: NSSize(width: contentWidth, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: 100), textContainer: textContainer)
        let op = NSPrintOperation(view: textView, printInfo: printInfo)
        op.showsPrintPanel = false
        op.showsProgressPanel = false

        guard op.run() && FileManager.default.fileExists(atPath: out.path) else {
            throw KQError.msg("Failed to write PDF for \(src.lastPathComponent)")
        }

        return out
    }

    // MARK: Metadata
    static func readMetadata(_ rawURL: URL) -> [(String, String)] {
        let url = resolveFileURL(rawURL)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else { return [] }
        var rows: [(String, String)] = []
        func walk(_ d: [String: Any], _ prefix: String) {
            for (k, v) in d.sorted(by: { $0.key < $1.key }) {
                if let sub = v as? [String: Any] { walk(sub, prefix + k + " › ") }
                else { rows.append((prefix + k, "\(v)")) }
            }
        }
        walk(props, "")
        return rows
    }
    static func isSensitive(_ key: String) -> Bool {
        let sensitivePatterns = [
            "GPS", "Latitude", "Longitude", "Altitude", "Speed", "DestBearing",
            "Make", "Model", "Serial", "Artist", "Copyright", "Software",
            "LensModel", "Owner", "Creator", "CameraOwner", "BodySerialNumber",
            "LensSerialNumber", "UniqueID", "UserComment", "ImageDescription",
            "DateTime", "CreateDate", "ModifyDate"
        ]
        return sensitivePatterns.contains { key.localizedCaseInsensitiveContains($0) }
    }
    static func stripMetadata(_ rawURL: URL, dir: URL?) throws -> URL {
        let url = resolveFileURL(rawURL)
        let img = try loadCGImage(url)
        let ext = url.pathExtension.lowercased()
        let type = UTType(filenameExtension: ext) ?? .png
        let out = outURL(url, ext: ext.isEmpty ? "png" : ext, suffix: "-clean", dir: dir)
        try writeImage(img, to: out, type: type, quality: 0.95)
        return out
    }

    // MARK: QR & OCR
    static func scanQR(_ img: CGImage) throws -> [String] {
        let req = VNDetectBarcodesRequest()
        try VNImageRequestHandler(cgImage: img).perform([req])
        return (req.results ?? []).compactMap { $0.payloadStringValue }
    }

    /// Neural OCR text recognition using Apple Vision framework
    static func extractText(_ cg: CGImage) throws -> String {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        try handler.perform([req])
        let observations = req.results ?? []
        let lines = observations.compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func extractText(from url: URL) throws -> String {
        let resolved = resolveFileURL(url)
        let ext = resolved.pathExtension.lowercased()
        if ext == "pdf", let doc = PDFDocument(url: resolved) {
            let pdfText = (0..<doc.pageCount).compactMap { doc.page(at: $0)?.string }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !pdfText.isEmpty {
                return pdfText
            }
        }
        if FileKind.of(resolved) == .document {
            if let attr = try? NSAttributedString(url: resolved, options: [:], documentAttributes: nil),
               !attr.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return attr.string.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let docxAttr = try? NSAttributedString(url: resolved, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil),
               !docxAttr.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return docxAttr.string.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let str = try? String(contentsOf: resolved, encoding: .utf8), !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return str.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        let cg = try loadCGImage(resolved)
        return try extractText(cg)
    }

    // MARK: PDF
    static func mergePDFs(_ urls: [URL], dir: URL?) throws -> URL {
        let doc = PDFDocument()
        for u in urls {
            guard let d = PDFDocument(url: u) else { throw KQError.msg("Can't open \(u.lastPathComponent)") }
            for i in 0..<d.pageCount { if let p = d.page(at: i) { doc.insert(p, at: doc.pageCount) } }
        }
        let out = outURL(urls[0], ext: "pdf", suffix: "-merged", dir: dir)
        doc.write(to: out); return out
    }
    static func savePDF(pages: [PDFPage], source: URL, suffix: String, dir: URL?) throws -> URL {
        let doc = PDFDocument()
        for p in pages { doc.insert(p.copy() as! PDFPage, at: doc.pageCount) }
        doc.documentAttributes = [:]
        let out = outURL(source, ext: "pdf", suffix: suffix, dir: dir)
        guard doc.write(to: out) else { throw KQError.msg("Couldn't write PDF") }
        return out
    }
    static func flattenPDF(_ src: URL, dir: URL?, scale: CGFloat = 2) throws -> URL {
        guard let d = PDFDocument(url: src) else { throw KQError.msg("Can't open PDF") }
        let out = PDFDocument()
        for i in 0..<d.pageCount {
            guard let p = d.page(at: i) else { continue }
            let b = p.bounds(for: .mediaBox)
            let img = p.thumbnail(of: CGSize(width: b.width * scale, height: b.height * scale), for: .mediaBox)
            if let np = PDFPage(image: img) { out.insert(np, at: out.pageCount) }
        }
        let url = outURL(src, ext: "pdf", suffix: "-flattened", dir: dir)
        out.write(to: url); return url
    }
    static func exportPNGs(_ src: URL, dir: URL?) throws -> [URL] {
        guard let d = PDFDocument(url: src) else { throw KQError.msg("Can't open PDF") }
        var outs: [URL] = []
        for i in 0..<d.pageCount {
            guard let p = d.page(at: i) else { continue }
            let b = p.bounds(for: .mediaBox)
            let img = p.thumbnail(of: CGSize(width: b.width * 2, height: b.height * 2), for: .mediaBox)
            guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            let url = outURL(src, ext: "png", suffix: "-page\(i + 1)", dir: dir)
            try writeImage(cg, to: url, type: .png); outs.append(url)
        }
        return outs
    }

    // MARK: Photo pipeline (Core Image)
    static func adjusted(_ cg: CGImage, _ a: Adjust, rotate: Int, flip: Bool) -> CIImage {
        var img = CIImage(cgImage: cg)
        if flip { img = img.oriented(.upMirrored) }
        switch ((rotate % 4) + 4) % 4 {
        case 1: img = img.oriented(.right)
        case 2: img = img.oriented(.down)
        case 3: img = img.oriented(.left)
        default: break
        }
        img = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
        if a.exposure != 0 { img = img.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: a.exposure]) }
        if a.brightness != 0 || a.contrast != 0 || a.saturation != 0 {
            img = img.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: a.brightness * 0.35,
                kCIInputContrastKey: 1 + a.contrast * 0.4,
                kCIInputSaturationKey: 1 + a.saturation])
        }
        if a.highlights != 0 || a.shadows != 0 {
            img = img.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": 1 + min(0, a.highlights), "inputShadowAmount": a.shadows])
            if a.highlights > 0 {
                img = img.applyingFilter("CIToneCurve", parameters: [
                    "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 0.25, y: 0.25),
                    "inputPoint2": CIVector(x: 0.5, y: 0.5), "inputPoint3": CIVector(x: 0.75, y: 0.75 + 0.12 * a.highlights),
                    "inputPoint4": CIVector(x: 1, y: 1)])
            }
        }
        if a.warmth != 0 {
            img = img.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500 + a.warmth * 2200, y: 0), "inputTargetNeutral": CIVector(x: 6500, y: 0)])
        }
        if a.sharpness != 0 { img = img.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: a.sharpness * 1.5]) }
        if a.vignette != 0 { img = img.applyingFilter("CIVignette", parameters: [kCIInputIntensityKey: a.vignette * 1.6, kCIInputRadiusKey: 2.0]) }
        return img
    }

    static func redactCI(_ ci: CIImage, boxes: [Box], pixelate: Bool) -> CIImage {
        let W = Double(ci.extent.width), H = Double(ci.extent.height)
        var out = ci
        for b in boxes {
            let r = CGRect(x: b.x * W, y: (1 - b.y - b.h) * H, width: b.w * W, height: b.h * H)
            let patch: CIImage = pixelate
                ? ci.applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: max(14.0, min(r.width, r.height) / 5)]).cropped(to: r)
                : CIImage(color: .black).cropped(to: r)
            out = patch.composited(over: out)
        }
        return out
    }

    /// adjust → crop → redact. crop is normalized with a top-left origin.
    static func stage1(_ cg: CGImage, adjust: Adjust, rotate: Int, flip: Bool, crop: CGRect?, boxes: [Box], pixelate: Bool) -> CGImage? {
        var ci = adjusted(cg, adjust, rotate: rotate, flip: flip)
        if let c = crop, c != CGRect(x: 0, y: 0, width: 1, height: 1) {
            let W = ci.extent.width, H = ci.extent.height
            let r = CGRect(x: c.minX * W, y: (1 - c.minY - c.height) * H, width: c.width * W, height: c.height * H).integral
            ci = ci.cropped(to: r).transformed(by: CGAffineTransform(translationX: -r.minX, y: -r.minY))
        }
        if !boxes.isEmpty { ci = redactCI(ci, boxes: boxes, pixelate: pixelate) }
        return ciContext.createCGImage(ci, from: ci.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    // MARK: Audio
    static func waveform(_ url: URL, bins: Int = 420) throws -> ([Float], Double) {
        let f = try AVAudioFile(forReading: url)
        let total = Int(f.length), sr = f.processingFormat.sampleRate, nc = Int(f.processingFormat.channelCount)
        guard total > 0, let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: 16_384) else { throw KQError.msg("Empty audio") }
        let per = max(1, total / bins)
        var peaks = [Float](repeating: 0, count: bins)
        var pos = 0
        while pos < total {
            try f.read(into: buf)
            let n = Int(buf.frameLength); if n == 0 { break }
            let ch = buf.floatChannelData!
            for i in 0..<n {
                var m: Float = 0
                for c in 0..<nc { m = max(m, abs(ch[c][i])) }
                let b = min(bins - 1, (pos + i) / per)
                if m > peaks[b] { peaks[b] = m }
            }
            pos += n
        }
        let mx = max(peaks.max() ?? 1, 0.0001)
        return (peaks.map { $0 / mx }, Double(total) / sr)
    }

    static func processAudio(_ src: URL, job: AudioJob, to out: URL) throws {
        let inF = try AVAudioFile(forReading: src)
        let fmt = inF.processingFormat
        let sr = fmt.sampleRate, nIn = Int(fmt.channelCount)
        let startF = AVAudioFramePosition(max(0, job.trimStart) * sr)
        let endF = min(inF.length, AVAudioFramePosition(job.trimEnd * sr))
        guard endF > startF else { throw KQError.msg("Selection is empty") }
        let nOut = job.channels == .original ? nIn : (job.channels == .mono ? 1 : 2)
        guard let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: AVAudioChannelCount(nOut), interleaved: false) else {
            throw KQError.msg("Bad format")
        }
        let settings: [String: Any] = job.m4a
            ? [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sr, AVNumberOfChannelsKey: nOut, AVEncoderBitRateKey: 192_000]
            : [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sr, AVNumberOfChannelsKey: nOut,
               AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        let outF = try AVAudioFile(forWriting: out, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 32_768),
              let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: 32_768) else { throw KQError.msg("Buffer") }

        func pass(write: Bool, scale: Float) throws -> Float {
            inF.framePosition = startF
            var pos = startF
            var peak: Float = 0
            while pos < endF {
                let want = AVAudioFrameCount(min(32_768, endF - pos))
                try inF.read(into: inBuf, frameCount: want)
                let n = Int(inBuf.frameLength); if n == 0 { break }
                outBuf.frameLength = AVAudioFrameCount(n)
                let inp = inBuf.floatChannelData!, o = outBuf.floatChannelData!
                for i in 0..<n {
                    let t = Double(pos + AVAudioFramePosition(i)) / sr
                    let bleep = job.bleeps.contains { $0.contains(t) }
                    for c in 0..<nOut {
                        var s: Float
                        switch job.channels {
                        case .original: s = inp[c][i] * (c == 0 ? job.gainL : (c == 1 ? job.gainR : 1))
                        case .mono:
                            var sum: Float = 0
                            for k in 0..<nIn { sum += inp[k][i] }
                            s = sum / Float(nIn) * (job.gainL + job.gainR) / 2
                        case .stereo: s = inp[min(c, nIn - 1)][i] * (c == 0 ? job.gainL : job.gainR)
                        }
                        peak = max(peak, abs(s))
                        s = bleep ? Float(sin(2 * Double.pi * 1000 * t)) * 0.28 : s * scale
                        o[c][i] = s
                    }
                }
                if write { try outF.write(from: outBuf) }
                pos += AVAudioFramePosition(n)
            }
            return peak
        }

        if job.normalize {
            let peak = try pass(write: false, scale: 1)
            _ = try pass(write: true, scale: peak > 0 ? 0.97 / peak : 1)
        } else {
            _ = try pass(write: true, scale: 1)
        }
    }

    static func normalizeAudio(_ src: URL, dir: URL?) async throws -> URL {
        let f = try AVAudioFile(forReading: src)
        let dur = Double(f.length) / f.processingFormat.sampleRate
        let lossless = ["wav", "aiff", "aif", "flac", "caf"].contains(src.pathExtension.lowercased())
        let out = outURL(src, ext: lossless ? "wav" : "m4a", suffix: "-normalized", dir: dir)
        try processAudio(src, job: AudioJob(trimStart: 0, trimEnd: dur, normalize: true, m4a: !lossless), to: out)
        return out
    }
}
