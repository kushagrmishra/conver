import SwiftUI
import PDFKit
import UniformTypeIdentifiers
import ServiceManagement

enum Tab: String, CaseIterable, Identifiable {
    case home = "Drop Wheel"
    case convert = "Convert"
    case photo = "Photo"
    case audio = "Audio"
    case pdf = "PDF"
    case privacy = "Privacy"
    case qr = "QR"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .home: "circle.grid.cross.fill"
        case .convert: "arrow.triangle.2.circlepath"
        case .photo: "wand.and.stars"
        case .audio: "waveform"
        case .pdf: "doc.on.doc.fill"
        case .privacy: "lock.shield.fill"
        case .qr: "qrcode.viewfinder"
        }
    }
    var subtitle: String {
        switch self {
        case .home: "Radial drop wheel"
        case .convert: "Images, audio & video"
        case .photo: "Edit, crop, annotate, redact"
        case .audio: "Trim, bleep, channels"
        case .pdf: "Merge, reorder, flatten"
        case .privacy: "Find & strip metadata"
        case .qr: "Read codes from images"
        }
    }
}

struct PDFPageItem: Identifiable {
    let id = UUID()
    let page: PDFPage
    var rotation = 0
    var thumb: NSImage
}

@MainActor final class PDFModel: ObservableObject {
    @Published var sources: [URL] = []
    @Published var pages: [PDFPageItem] = []

    func load(_ urls: [URL]) {
        sources = urls.filter { $0.pathExtension.lowercased() == "pdf" }
        pages = []
        if sources.count == 1, let d = PDFDocument(url: sources[0]) {
            pages = (0..<d.pageCount).compactMap { i in
                d.page(at: i).map { PDFPageItem(page: $0, thumb: $0.thumbnail(of: CGSize(width: 180, height: 240), for: .cropBox)) }
            }
        }
    }
}

struct WheelMenuOption: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let icon: String
    let action: () -> Void
}

struct WheelActionMenu: Identifiable {
    let id = UUID()
    let wedgeTitle: String
    let detectedBadge: String
    let detectedIcon: String
    let options: [WheelMenuOption]
}

@MainActor final class Store: ObservableObject {
    static let shared = Store()
    @Published var tab: Tab = .photo
    @Published var outputDir: URL?
    @Published var toast: String?
    @Published var recents: [URL] = []
    @Published var wheelEnabled = true
    @Published var wheelVisible = false
    @Published var quickTarget: Target = .jpeg
    @Published var wheelBusy = false
    @Published var lastQR: String?
    @Published var launchAtLogin = true
    @Published var activeMenu: WheelActionMenu?
    @Published var isPickingFile = false
    @Published var stagedURLs: [URL] = []
    @Published var hoveredWedgeWhileHolding: Int? = nil
    @Published var wheelScale: Double = {
        let saved = UserDefaults.standard.double(forKey: "conver.wheel.scale")
        return saved >= 0.70 && saved <= 1.5 ? saved : 1.0
    }() {
        didSet {
            UserDefaults.standard.set(wheelScale, forKey: "conver.wheel.scale")
        }
    }

    var onToggleWheel: ((Bool?) -> Void)?
    var onOpenStudio: ((Tab) -> Void)?
    var onCheckAutoClose: (() -> Void)?
    var onTriggerWedge: ((Int, [URL]) -> Void)?
    var onHoverWheelPoint: ((CGPoint?) -> Void)?
    var onDropWheelURLs: (([URL], CGPoint) -> Void)?
    var lastAppKitDropTime: Date = .distantPast

    let photo = PhotoModel()
    let audio = AudioModel()
    let pdf = PDFModel()

    func say(_ s: String) {
        withAnimation(.spring(duration: 0.25)) {
            toast = s
        }
        Task {
            try? await Task.sleep(for: .seconds(2.4))
            if toast == s {
                withAnimation(.easeOut(duration: 0.2)) {
                    toast = nil
                }
            }
        }
    }

    func toggleWheel(_ show: Bool? = nil) {
        onToggleWheel?(show)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLogin = enabled
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                // Fallback to user LaunchAgent plist if ad-hoc signed
            }
        }
        configureLaunchAgent(enabled: enabled)
    }

    func configureLaunchAgent(enabled: Bool) {
        let fm = FileManager.default
        guard let lib = fm.urls(for: .libraryDirectory, in: .userDomainMask).first else { return }
        let agentsDir = lib.appendingPathComponent("LaunchAgents")
        let plistURL = agentsDir.appendingPathComponent("dev.conver.app.plist")
        if !enabled {
            try? fm.removeItem(at: plistURL)
            return
        }
        guard let execPath = Bundle.main.executablePath else { return }
        try? fm.createDirectory(at: agentsDir, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "Label": "dev.conver.app",
            "ProgramArguments": [execPath],
            "RunAtLoad": true,
            "KeepAlive": false
        ]
        if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
            try? data.write(to: plistURL)
        }
    }

    func pickFiles(types: [UTType], multiple: Bool = true) -> [URL] {
        isPickingFile = true
        defer {
            isPickingFile = false
        }
        NSApp.activate(ignoringOtherApps: true)
        let p = NSOpenPanel()
        p.allowedContentTypes = types
        p.allowsMultipleSelection = multiple
        return p.runModal() == .OK ? p.urls : []
    }

    func pickFolder() {
        isPickingFile = true
        defer { isPickingFile = false }
        NSApp.activate(ignoringOtherApps: true)
        let p = NSOpenPanel()
        p.canChooseFiles = false
        p.canChooseDirectories = true
        p.canCreateDirectories = true
        if p.runModal() == .OK { outputDir = p.url }
    }

    func reveal(_ u: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([u])
    }

    func addRecent(_ u: URL) {
        recents.removeAll { $0 == u }
        recents.insert(u, at: 0)
        if recents.count > 6 { recents.removeLast() }
    }

    func done(_ u: URL, reveal r: Bool = true) {
        addRecent(u)
        say("Saved \(u.lastPathComponent)")
        if r { reveal(u) }
    }

    /// Route any dropped file to the right studio or instant converter.
    func open(_ urls: [URL]) {
        guard let first = urls.first else { return }
        switch FileKind.of(first) {
        case .image:
            photo.load(first)
            tab = .photo
            onOpenStudio?(.photo)
        case .audio, .video:
            audio.load(first)
            tab = .audio
            onOpenStudio?(.audio)
        case .pdf:
            if urls.count >= 2, let merged = try? Engine.mergePDFs(urls, dir: outputDir) {
                done(merged)
            } else {
                pdf.load(urls)
                tab = .pdf
                onOpenStudio?(.pdf)
            }
        case .other:
            say("Unsupported file type")
        }
    }

    func handoff(url: URL, tab t: Tab, photoMode: PhotoModel.Mode?, audioMode: AudioModel.WaveMode?) {
        switch t {
        case .photo:
            photo.load(url)
            if let m = photoMode { photo.mode = m }
        case .audio:
            audio.load(url)
            if let m = audioMode { audio.mode = m }
        case .pdf:
            pdf.load([url])
        default:
            break
        }
        tab = t
        onOpenStudio?(t)
    }
}
