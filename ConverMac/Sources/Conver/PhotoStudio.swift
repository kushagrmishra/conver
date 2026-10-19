import SwiftUI
import UniformTypeIdentifiers

// MARK: - Models
struct Annotation: Identifiable {
    enum Kind: String, CaseIterable, Identifiable {
        case arrow, rect, ellipse, pen, text
        var id: String { rawValue }
        var icon: String {
            switch self { case .arrow: "arrow.up.right"; case .rect: "rectangle"; case .ellipse: "circle"; case .pen: "scribble"; case .text: "textformat" }
        }
    }
    let id = UUID()
    var kind: Kind
    var pts: [CGPoint]          // normalized to image
    var color: Color
    var width: CGFloat          // fraction of image width
    var text = ""
}

struct BGStyle {
    static let presets: [(name: String, colors: [Color])] = [
        ("Sunset", [Color(red: 1, green: 0.6, blue: 0.2), Color(red: 1, green: 0.28, blue: 0.5)]),
        ("Ocean", [Color(red: 0.1, green: 0.8, blue: 1), Color(red: 0.2, green: 0.4, blue: 1)]),
        ("Aurora", [Color(red: 0.1, green: 0.9, blue: 0.7), Color(red: 0.5, green: 0.3, blue: 1)]),
        ("Peach", [Color(red: 1, green: 0.85, blue: 0.7), Color(red: 1, green: 0.7, blue: 0.8)]),
        ("Mint", [Color(red: 0.7, green: 1, blue: 0.85), Color(red: 0.4, green: 0.85, blue: 0.9)]),
        ("Midnight", [Color(red: 0.12, green: 0.1, blue: 0.3), Color(red: 0.02, green: 0.02, blue: 0.08)]),
        ("Candy", [Color(red: 1, green: 0.45, blue: 0.75), Color(red: 0.6, green: 0.35, blue: 1)]),
        ("Lime", [Color(red: 0.8, green: 1, blue: 0.3), Color(red: 0.1, green: 0.8, blue: 0.4)]),
        ("Lava", [Color(red: 1, green: 0.2, blue: 0.2), Color(red: 1, green: 0.65, blue: 0.1)]),
        ("Dusk", [Color(red: 0.45, green: 0.3, blue: 0.9), Color(red: 1, green: 0.55, blue: 0.4)]),
        ("Snow", [Color.white, Color(red: 0.82, green: 0.85, blue: 0.92)]),
        ("Graphite", [Color(red: 0.35, green: 0.37, blue: 0.42), Color(red: 0.12, green: 0.13, blue: 0.16)]),
    ]
    var enabled = false
    var preset = 0
    var padding: CGFloat = 0.08
    var corner: CGFloat = 0.025
    var shadow = true
    var fill: LinearGradient { LinearGradient(colors: Self.presets[preset].colors, startPoint: .topLeading, endPoint: .bottomTrailing) }
}

func fitRect(_ size: CGSize, in box: CGSize, margin: CGFloat = 0) -> CGRect {
    let bw = max(1, box.width - margin * 2), bh = max(1, box.height - margin * 2)
    let s = min(bw / size.width, bh / size.height)
    let w = size.width * s, h = size.height * s
    return CGRect(x: (box.width - w) / 2, y: (box.height - h) / 2, width: w, height: h)
}

@MainActor final class PhotoModel: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case adjust = "Adjust", crop = "Crop", background = "Background", annotate = "Annotate", redact = "Redact"
        var id: String { rawValue }
        var icon: String {
            switch self { case .adjust: "slider.horizontal.3"; case .crop: "crop"; case .background: "rectangle.inset.filled"
            case .annotate: "pencil.tip.crop.circle"; case .redact: "eye.slash" }
        }
    }
    enum Aspect: String, CaseIterable, Identifiable {
        case free = "Free", square = "1:1", r43 = "4:3", r32 = "3:2", r169 = "16:9", r916 = "9:16"
        var id: String { rawValue }
        var ratio: CGFloat? {
            switch self { case .free: nil; case .square: 1; case .r43: 4.0 / 3; case .r32: 1.5; case .r169: 16.0 / 9; case .r916: 9.0 / 16 }
        }
    }

    @Published var url: URL?
    @Published var mode: Mode = .adjust
    @Published var adjust = Engine.Adjust() { didSet { refresh() } }
    @Published var rotate = 0 { didSet { crop = CGRect(x: 0, y: 0, width: 1, height: 1); refresh() } }
    @Published var flip = false { didSet { refresh() } }
    @Published var crop = CGRect(x: 0, y: 0, width: 1, height: 1) { didSet { refresh() } }
    @Published var aspect: Aspect = .free
    @Published var boxes: [Engine.Box] = [] { didSet { refresh() } }
    @Published var pixelate = false { didSet { refresh() } }
    @Published var annotations: [Annotation] = []
    @Published var tool: Annotation.Kind = .arrow
    @Published var color: Color = .kqPink
    @Published var strokeWidth: CGFloat = 0.008
    @Published var bg = BGStyle()
    @Published var stage: NSImage?
    @Published var full: NSImage?
    @Published var stageAspect: CGFloat = 1
    @Published var fullSize = CGSize(width: 1, height: 1)

    private var source: CGImage?
    private var loading = false

    func load(_ u: URL) {
        loading = true
        defer { loading = false; refresh() }
        guard let img = try? Engine.loadCGImage(u, maxPixel: 1800) else { return }
        url = u; source = img
        adjust = Engine.Adjust(); rotate = 0; flip = false
        crop = CGRect(x: 0, y: 0, width: 1, height: 1); aspect = .free
        boxes = []; annotations = []; bg = BGStyle(); mode = .adjust
    }

    func close() { url = nil; source = nil; stage = nil; full = nil }

    func refresh() {
        guard !loading, let s = source else { return }
        if let f = Engine.stage1(s, adjust: adjust, rotate: rotate, flip: flip, crop: nil, boxes: [], pixelate: false) {
            full = NSImage(cgImage: f, size: NSSize(width: f.width, height: f.height))
            fullSize = CGSize(width: f.width, height: f.height)
        }
        if let st = Engine.stage1(s, adjust: adjust, rotate: rotate, flip: flip, crop: crop, boxes: boxes, pixelate: pixelate) {
            stage = NSImage(cgImage: st, size: NSSize(width: st.width, height: st.height))
            stageAspect = CGFloat(st.height) / CGFloat(st.width)
        }
    }

    func applyAspect(_ a: Aspect) {
        aspect = a
        guard let r = a.ratio else { crop = CGRect(x: 0, y: 0, width: 1, height: 1); return }
        let W = fullSize.width, H = fullSize.height
        var w = W, h = W / r
        if h > H { h = H; w = H * r }
        crop = CGRect(x: (1 - w / W) / 2, y: (1 - h / H) / 2, width: w / W, height: h / H)
    }

    func renderFinal() throws -> CGImage {
        guard let url else { throw KQError.msg("No photo") }
        let orig = try Engine.loadCGImage(url)
        guard let st = Engine.stage1(orig, adjust: adjust, rotate: rotate, flip: flip, crop: crop, boxes: boxes, pixelate: pixelate) else {
            throw KQError.msg("Render failed")
        }
        let img = NSImage(cgImage: st, size: NSSize(width: st.width, height: st.height))
        let iw = CGFloat(st.width), ih = CGFloat(st.height)
        let pad = bg.enabled ? bg.padding * iw : 0
        let view = Composition(image: img, imgAspect: ih / iw, annotations: annotations, bg: bg)
            .frame(width: iw + 2 * pad, height: ih + 2 * pad)
        let r = ImageRenderer(content: view); r.scale = 1
        guard let cg = r.cgImage else { throw KQError.msg("Export failed") }
        return cg
    }

    func export(png: Bool, dir: URL?) throws -> URL {
        let cg = try renderFinal()
        let out = Engine.outURL(url!, ext: png ? "png" : "jpg", suffix: "-conver", dir: dir)
        try Engine.writeImage(cg, to: out, type: png ? .png : .jpeg, quality: 0.92)
        return out
    }

    func copyToClipboard() throws {
        let cg = try renderFinal()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))])
    }

    func upscale(scale: Double? = nil, targetDimension: Int? = nil, dir: URL?) throws -> URL {
        guard let url else { throw KQError.msg("No photo") }
        let cg = try renderFinal()
        let cgUp = try Engine.upscaleCGImage(cg, scale: scale, targetDimension: targetDimension)
        let tag = targetDimension != nil ? (targetDimension! >= 7000 ? "-8K" : "-4K") : "-\(Int(scale ?? 2.0))x"
        let out = Engine.outURL(url, ext: "png", suffix: tag, dir: dir)
        try Engine.writeImage(cgUp, to: out, type: .png, quality: 0.95)
        return out
    }
}

// MARK: - Composition (preview == export)
struct AnnotationView: View {
    let a: Annotation
    let size: CGSize
    var body: some View {
        let lw = max(2, a.width * size.width)
        let p = a.pts.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
        ZStack {
            if a.kind == .text, let f = p.first {
                Text(a.text).font(.system(size: lw * 6.5, weight: .heavy, design: .rounded)).foregroundStyle(a.color)
                    .shadow(color: .black.opacity(0.35), radius: lw * 0.6, y: lw * 0.3)
                    .fixedSize().position(x: f.x, y: f.y)
            } else {
                Path { path in
                    guard let f = p.first, let l = p.last else { return }
                    let r = CGRect(x: min(f.x, l.x), y: min(f.y, l.y), width: abs(l.x - f.x), height: abs(l.y - f.y))
                    switch a.kind {
                    case .rect: path.addRoundedRect(in: r, cornerSize: CGSize(width: lw, height: lw))
                    case .ellipse: path.addEllipse(in: r)
                    case .arrow:
                        path.move(to: f); path.addLine(to: l)
                        let ang = atan2(l.y - f.y, l.x - f.x), len = lw * 5
                        path.move(to: l); path.addLine(to: CGPoint(x: l.x - len * cos(ang - 0.5), y: l.y - len * sin(ang - 0.5)))
                        path.move(to: l); path.addLine(to: CGPoint(x: l.x - len * cos(ang + 0.5), y: l.y - len * sin(ang + 0.5)))
                    case .pen:
                        path.move(to: f); for q in p.dropFirst() { path.addLine(to: q) }
                    case .text: break
                    }
                }
                .stroke(a.color, style: StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round))
                .shadow(color: .black.opacity(0.25), radius: lw * 0.5, y: lw * 0.25)
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

struct Composition: View {
    let image: NSImage
    let imgAspect: CGFloat
    let annotations: [Annotation]
    let bg: BGStyle
    var body: some View {
        GeometryReader { g in
            let padF = bg.enabled ? bg.padding : 0
            let iw = g.size.width / (1 + 2 * padF)
            let ih = iw * imgAspect
            ZStack {
                if bg.enabled { Rectangle().fill(bg.fill) }
                ZStack {
                    Image(nsImage: image).resizable().frame(width: iw, height: ih)
                    ForEach(annotations) { AnnotationView(a: $0, size: CGSize(width: iw, height: ih)) }
                }
                .frame(width: iw, height: ih)
                .clipShape(RoundedRectangle(cornerRadius: bg.enabled ? bg.corner * iw : 0, style: .continuous))
                .shadow(color: .black.opacity(bg.enabled && bg.shadow ? 0.38 : 0), radius: iw * 0.035, y: iw * 0.015)
            }
            .frame(width: g.size.width, height: g.size.height)
        }
    }
}

// MARK: - Views
struct PhotoStudioView: View {
    @EnvironmentObject var store: Store
    @ObservedObject var m: PhotoModel

    var body: some View {
        VStack(spacing: 18) {
            HStack(alignment: .center) {
                PageHeader(title: "Photo Studio", subtitle: m.url?.lastPathComponent ?? "Adjust, crop, frame, annotate and redact in one place.")
                if m.url != nil {
                    Button("Reset", systemImage: "arrow.counterclockwise") { if let u = m.url { m.load(u) } }.buttonStyle(.soft)
                    Button("New", systemImage: "photo.badge.plus") { m.close() }.buttonStyle(.soft)
                    Button("Copy", systemImage: "doc.on.doc") {
                        do { try m.copyToClipboard(); store.say("Copied to clipboard") } catch { store.say(error.localizedDescription) }
                    }.buttonStyle(.soft)
                    Menu {
                        Section("AI Super-Resolution") {
                            Button("AI Upscale 2× (200%)") { runUpscale(scale: 2.0) }
                            Button("AI Upscale 4× (400%)") { runUpscale(scale: 4.0) }
                            Button("Upscale to 4K Ultra HD") { runUpscale(dim: 3840) }
                            Button("Upscale to 8K Master") { runUpscale(dim: 7680) }
                        }
                        Divider()
                        Section("Standard Export") {
                            Button("Export PNG") { export(png: true) }
                            Button("Export JPEG") { export(png: false) }
                        }
                    } label: { Label("Export & Upscale", systemImage: "sparkles") }
                        .menuStyle(.button).buttonStyle(.glow).fixedSize()
                }
            }
            if m.stage == nil {
                DropZone(title: "Drop a photo to start", hint: "JPG · PNG · HEIC · TIFF · GIF", symbol: "photo.badge.plus", types: [.image], height: 260) { urls in
                    m.load(urls[0])
                }
                Spacer()
            } else {
                HStack(alignment: .top, spacing: 18) {
                    ZStack {
                        if m.mode == .crop { CropEditor(m: m) } else { PhotoCanvas(m: m) }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color.black.opacity(0.28)))
                    .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.08)))
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    Inspector(m: m).frame(width: 320)
                }
            }
        }
        .padding(30).padding(.top, 10)
        .dropDestination(for: URL.self) { urls, _ in
            if let u = urls.first, FileKind.of(u) == .image { m.load(u); return true }; return false
        }
    }

    func export(png: Bool) {
        do { store.done(try m.export(png: png, dir: store.outputDir)) } catch { store.say(error.localizedDescription) }
    }

    func runUpscale(scale: Double? = nil, dim: Int? = nil) {
        do {
            let out = try m.upscale(scale: scale, targetDimension: dim, dir: store.outputDir)
            store.done(out)
        } catch {
            store.say("Upscale Error: \(error.localizedDescription)")
        }
    }
}

struct Inspector: View {
    @ObservedObject var m: PhotoModel
    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 4) {
                ForEach(PhotoModel.Mode.allCases) { mode in
                    Button { withAnimation(.spring(duration: 0.3)) { m.mode = mode } } label: {
                        VStack(spacing: 4) {
                            Image(systemName: mode.icon).font(.system(size: 15, weight: .semibold))
                            Text(mode.rawValue).font(.system(size: 9.5, weight: .bold, design: .rounded))
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                        .foregroundStyle(m.mode == mode ? Color.black.opacity(0.85) : .white.opacity(0.6))
                        .background { if m.mode == mode { RoundedRectangle(cornerRadius: 11, style: .continuous).fill(kqGradient) } }
                    }.buttonStyle(.plain)
                }
            }
            .padding(5).glass(16)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    switch m.mode {
                    case .adjust: AdjustPanel(m: m)
                    case .crop: CropPanel(m: m)
                    case .background: BackgroundPanel(m: m)
                    case .annotate: AnnotatePanel(m: m)
                    case .redact: RedactPanel(m: m)
                    }
                }.padding(16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).glass(22)
        }
    }
}

struct AdjSlider: View {
    let label: String
    @Binding var value: Double
    var range: ClosedRange<Double> = -1...1
    var scale: Double = 100
    var unit = ""
    var body: some View {
        VStack(spacing: 3) {
            HStack {
                Text(label).font(.system(size: 12.5, weight: .medium))
                Spacer()
                Text(String(format: value == 0 ? "0%@" : "%+.0f%@", value * scale, unit)).font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(value == 0 ? .white.opacity(0.4) : Color.kqOrange)
                Button { withAnimation(.spring(duration: 0.25)) { value = 0 } } label: { Image(systemName: "arrow.counterclockwise").font(.system(size: 10)) }
                    .buttonStyle(.plain).opacity(value == 0 ? 0.2 : 0.8).disabled(value == 0)
            }
            Slider(value: $value, in: range).tint(.kqOrange).controlSize(.small)
        }
    }
}

struct AdjustPanel: View {
    @ObservedObject var m: PhotoModel
    var body: some View {
        Caption("Light")
        AdjSlider(label: "Exposure", value: $m.adjust.exposure, range: -2...2, scale: 1, unit: " EV")
        AdjSlider(label: "Brightness", value: $m.adjust.brightness)
        AdjSlider(label: "Contrast", value: $m.adjust.contrast)
        AdjSlider(label: "Highlights", value: $m.adjust.highlights)
        AdjSlider(label: "Shadows", value: $m.adjust.shadows)
        Caption("Color")
        AdjSlider(label: "Saturation", value: $m.adjust.saturation)
        AdjSlider(label: "Warmth", value: $m.adjust.warmth)
        Caption("Detail")
        AdjSlider(label: "Sharpness", value: $m.adjust.sharpness, range: 0...1)
        AdjSlider(label: "Vignette", value: $m.adjust.vignette, range: 0...1)
        Button("Reset all", systemImage: "arrow.counterclockwise") { withAnimation { m.adjust = Engine.Adjust() } }
            .buttonStyle(.soft).frame(maxWidth: .infinity)
    }
}

struct CropPanel: View {
    @ObservedObject var m: PhotoModel
    var body: some View {
        Caption("Aspect ratio")
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 8)], spacing: 8) {
            ForEach(PhotoModel.Aspect.allCases) { a in
                Button(a.rawValue) { withAnimation(.spring(duration: 0.3)) { m.applyAspect(a) } }
                    .buttonStyle(GlowStyle(prominent: m.aspect == a)).frame(maxWidth: .infinity)
            }
        }
        Caption("Transform")
        HStack(spacing: 8) {
            Button { m.rotate = (m.rotate + 3) % 4 } label: { Label("Left", systemImage: "rotate.left") }.buttonStyle(.soft)
            Button { m.rotate = (m.rotate + 1) % 4 } label: { Label("Right", systemImage: "rotate.right") }.buttonStyle(.soft)
        }
        Button { m.flip.toggle() } label: { Label("Flip horizontally", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
            .buttonStyle(.soft)
        Text("Drag the corners on the photo, or drag inside to move the frame.").font(.caption).foregroundStyle(.white.opacity(0.45))
    }
}

struct BackgroundPanel: View {
    @ObservedObject var m: PhotoModel
    var body: some View {
        Toggle(isOn: $m.bg.enabled.animation(.spring(duration: 0.3))) { Text("Add background").font(.system(size: 14, weight: .semibold, design: .rounded)) }
            .toggleStyle(.switch).tint(.kqOrange)
        if m.bg.enabled {
            Caption("Gradient")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(Array(BGStyle.presets.enumerated()), id: \.offset) { i, p in
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(LinearGradient(colors: p.colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(height: 38)
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(m.bg.preset == i ? Color.white : .white.opacity(0.12), lineWidth: m.bg.preset == i ? 2.5 : 1))
                        .scaleEffect(m.bg.preset == i ? 1.06 : 1)
                        .onTapGesture { withAnimation(.spring(duration: 0.25)) { m.bg.preset = i } }
                }
            }
            Caption("Frame")
            VStack(spacing: 3) {
                HStack { Text("Padding").font(.system(size: 12.5, weight: .medium)); Spacer(); Text("\(Int(m.bg.padding * 100))%").font(.system(size: 11.5, weight: .semibold, design: .monospaced)).foregroundStyle(.white.opacity(0.5)) }
                Slider(value: $m.bg.padding, in: 0.02...0.30).tint(.kqOrange).controlSize(.small)
            }
            VStack(spacing: 3) {
                HStack { Text("Corner radius").font(.system(size: 12.5, weight: .medium)); Spacer(); Text("\(Int(m.bg.corner * 400))").font(.system(size: 11.5, weight: .semibold, design: .monospaced)).foregroundStyle(.white.opacity(0.5)) }
                Slider(value: $m.bg.corner, in: 0...0.08).tint(.kqOrange).controlSize(.small)
            }
            Toggle("Drop shadow", isOn: $m.bg.shadow).toggleStyle(.switch).tint(.kqOrange)
        }
    }
}

struct AnnotatePanel: View {
    @ObservedObject var m: PhotoModel
    static let palette: [Color] = [.kqPink, .kqOrange, Color(red: 1, green: 0.85, blue: 0.2), Color(red: 0.3, green: 0.9, blue: 0.5), .kqTeal, Color(red: 0.3, green: 0.6, blue: 1), .kqViolet, .white, .black]
    var body: some View {
        Caption("Tool")
        HStack(spacing: 6) {
            ForEach(Annotation.Kind.allCases) { k in
                Button { m.tool = k } label: { Image(systemName: k.icon).frame(width: 24, height: 20) }
                    .buttonStyle(GlowStyle(prominent: m.tool == k))
            }
        }
        Caption("Color")
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
            ForEach(Array(Self.palette.enumerated()), id: \.offset) { _, c in
                Circle().fill(c).frame(width: 28, height: 28)
                    .overlay(Circle().strokeBorder(.white.opacity(m.color == c ? 1 : 0.2), lineWidth: m.color == c ? 3 : 1))
                    .onTapGesture { m.color = c }
            }
        }
        VStack(spacing: 3) {
            HStack { Text("Thickness").font(.system(size: 12.5, weight: .medium)); Spacer() }
            Slider(value: $m.strokeWidth, in: 0.003...0.025).tint(.kqOrange).controlSize(.small)
        }
        HStack {
            Button("Undo", systemImage: "arrow.uturn.backward") { _ = m.annotations.popLast() }.buttonStyle(.soft).disabled(m.annotations.isEmpty)
            Button("Clear", systemImage: "trash") { m.annotations = [] }.buttonStyle(.soft).disabled(m.annotations.isEmpty)
        }
        Text(m.tool == .text ? "Click on the photo to place text." : "Drag on the photo to draw.").font(.caption).foregroundStyle(.white.opacity(0.45))
    }
}

struct RedactPanel: View {
    @ObservedObject var m: PhotoModel
    var body: some View {
        Caption("Style")
        Picker("", selection: $m.pixelate) { Text("Black box").tag(false); Text("Pixelate").tag(true) }.pickerStyle(.segmented).labelsHidden()
        HStack {
            Button("Undo", systemImage: "arrow.uturn.backward") { _ = m.boxes.popLast() }.buttonStyle(.soft).disabled(m.boxes.isEmpty)
            Button("Clear", systemImage: "trash") { m.boxes = [] }.buttonStyle(.soft).disabled(m.boxes.isEmpty)
        }
        Label("\(m.boxes.count) redaction\(m.boxes.count == 1 ? "" : "s")", systemImage: "eye.slash.fill").font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(m.boxes.isEmpty ? .white.opacity(0.4) : Color.kqOrange)
        Text("Drag over faces, plates or text. Redactions are baked into the exported pixels and can't be undone from the file.").font(.caption).foregroundStyle(.white.opacity(0.45))
    }
}

// MARK: - Canvas (annotate / redact)
struct PhotoCanvas: View {
    @ObservedObject var m: PhotoModel
    @State private var live: Annotation?
    @State private var liveBox: Engine.Box?

    var body: some View {
        GeometryReader { g in
            let pad = m.bg.enabled ? m.bg.padding : 0
            let totalW = 1 + 2 * pad, totalH = m.stageAspect + 2 * pad
            let fit = fitRect(CGSize(width: totalW, height: totalH), in: g.size, margin: 26)
            let iw = fit.width / totalW
            let imgRect = CGRect(x: fit.minX + pad * iw, y: fit.minY + pad * iw, width: iw, height: iw * m.stageAspect)
            ZStack {
                if let img = m.stage {
                    Composition(image: img, imgAspect: m.stageAspect, annotations: m.annotations + (live.map { [$0] } ?? []), bg: m.bg)
                        .frame(width: fit.width, height: fit.height).position(x: fit.midX, y: fit.midY)
                        .shadow(color: .black.opacity(m.bg.enabled ? 0 : 0.4), radius: 18, y: 8)
                }
                if let b = liveBox {
                    Rectangle().strokeBorder(Color.kqOrange, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .background(Rectangle().fill(Color.black.opacity(m.pixelate ? 0.15 : 0.55)))
                        .frame(width: b.w * imgRect.width, height: b.h * imgRect.height)
                        .position(x: imgRect.minX + (b.x + b.w / 2) * imgRect.width, y: imgRect.minY + (b.y + b.h / 2) * imgRect.height)
                }
                if m.mode == .annotate || m.mode == .redact {
                    Color.clear.contentShape(Rectangle())
                        .frame(width: imgRect.width, height: imgRect.height)
                        .position(x: imgRect.midX, y: imgRect.midY)
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { v in change(v, imgRect.size) }
                            .onEnded { v in end(v, imgRect.size) })
                        .onHover { inside in if inside { NSCursor.crosshair.push() } else { NSCursor.pop() } }
                }
            }
        }
        .animation(.spring(duration: 0.35), value: m.bg.enabled)
    }

    private func norm(_ p: CGPoint, _ s: CGSize) -> CGPoint {
        CGPoint(x: min(1, max(0, p.x / s.width)), y: min(1, max(0, p.y / s.height)))
    }
    private func change(_ v: DragGesture.Value, _ s: CGSize) {
        let a = norm(v.startLocation, s), b = norm(v.location, s)
        if m.mode == .redact {
            liveBox = Engine.Box(x: min(a.x, b.x), y: min(a.y, b.y), w: abs(b.x - a.x), h: abs(b.y - a.y)); return
        }
        switch m.tool {
        case .pen:
            if live == nil { live = Annotation(kind: .pen, pts: [a], color: m.color, width: m.strokeWidth) }
            live?.pts.append(b)
        case .text: break
        default: live = Annotation(kind: m.tool, pts: [a, b], color: m.color, width: m.strokeWidth)
        }
    }
    private func end(_ v: DragGesture.Value, _ s: CGSize) {
        defer { live = nil; liveBox = nil }
        if m.mode == .redact, let b = liveBox, b.w > 0.01, b.h > 0.01 { m.boxes.append(b); return }
        guard m.mode == .annotate else { return }
        if m.tool == .text {
            if let t = askText() { m.annotations.append(Annotation(kind: .text, pts: [norm(v.location, s)], color: m.color, width: m.strokeWidth, text: t)) }
            return
        }
        if let l = live, l.pts.count >= 2 { m.annotations.append(l) }
    }
}

func askText() -> String? {
    let alert = NSAlert()
    alert.messageText = "Add text"
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
    alert.accessoryView = field
    alert.addButton(withTitle: "Add"); alert.addButton(withTitle: "Cancel")
    alert.window.initialFirstResponder = field
    return alert.runModal() == .alertFirstButtonReturn && !field.stringValue.isEmpty ? field.stringValue : nil
}

// MARK: - Crop
struct CropEditor: View {
    @ObservedObject var m: PhotoModel
    @State private var moveStart: CGRect?
    @State private var anchor: CGPoint?

    var body: some View {
        GeometryReader { g in
            let fit = fitRect(m.fullSize, in: g.size, margin: 30)
            let c = m.crop
            let r = CGRect(x: fit.minX + c.minX * fit.width, y: fit.minY + c.minY * fit.height, width: c.width * fit.width, height: c.height * fit.height)
            ZStack {
                if let f = m.full { Image(nsImage: f).resizable().frame(width: fit.width, height: fit.height).position(x: fit.midX, y: fit.midY) }
                Path { p in p.addRect(fit); p.addRect(r) }.fill(Color.black.opacity(0.58), style: FillStyle(eoFill: true))
                Rectangle().strokeBorder(.white, lineWidth: 1.5).frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY)
                // rule of thirds
                Path { p in
                    for i in 1...2 {
                        let x = r.minX + r.width * CGFloat(i) / 3, y = r.minY + r.height * CGFloat(i) / 3
                        p.move(to: CGPoint(x: x, y: r.minY)); p.addLine(to: CGPoint(x: x, y: r.maxY))
                        p.move(to: CGPoint(x: r.minX, y: y)); p.addLine(to: CGPoint(x: r.maxX, y: y))
                    }
                }.stroke(.white.opacity(0.35), lineWidth: 0.7)
                Color.clear.contentShape(Rectangle()).frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY)
                    .gesture(DragGesture()
                        .onChanged { v in
                            if moveStart == nil { moveStart = m.crop }
                            guard let s = moveStart else { return }
                            let nx = min(1 - s.width, max(0, s.minX + v.translation.width / fit.width))
                            let ny = min(1 - s.height, max(0, s.minY + v.translation.height / fit.height))
                            m.crop = CGRect(x: nx, y: ny, width: s.width, height: s.height)
                        }
                        .onEnded { _ in moveStart = nil })
                ForEach(0..<4, id: \.self) { i in
                    let pt = CGPoint(x: i % 2 == 0 ? r.minX : r.maxX, y: i < 2 ? r.minY : r.maxY)
                    Circle().fill(.white).frame(width: 18, height: 18).shadow(radius: 3)
                        .overlay(Circle().fill(Color.kqOrange).frame(width: 8, height: 8))
                        .position(pt)
                        .gesture(DragGesture(coordinateSpace: .named("crop"))
                            .onChanged { v in drag(i, v.location, fit) }
                            .onEnded { _ in anchor = nil })
                }
            }
            .coordinateSpace(name: "crop")
        }
    }

    private func drag(_ i: Int, _ loc: CGPoint, _ fit: CGRect) {
        if anchor == nil {
            let c = m.crop
            anchor = CGPoint(x: i % 2 == 0 ? c.maxX : c.minX, y: i < 2 ? c.maxY : c.minY)
        }
        guard let a = anchor else { return }
        let nx = min(1, max(0, (loc.x - fit.minX) / fit.width)), ny = min(1, max(0, (loc.y - fit.minY) / fit.height))
        var w = abs(nx - a.x), h = abs(ny - a.y)
        if let ratio = m.aspect.ratio {
            let W = m.fullSize.width, H = m.fullSize.height
            h = (w * W / ratio) / H
            let avail = ny >= a.y ? 1 - a.y : a.y
            if h > avail { h = avail; w = (h * H * ratio) / W }
        }
        guard w > 0.03, h > 0.03 else { return }
        let x = nx >= a.x ? a.x : a.x - w, y = ny >= a.y ? a.y : a.y - h
        m.crop = CGRect(x: max(0, x), y: max(0, y), width: min(w, 1), height: min(h, 1))
    }
}
