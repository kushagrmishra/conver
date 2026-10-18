import SwiftUI
import AVFoundation

struct BleepRange: Identifiable { let id = UUID(); var start: Double; var end: Double }

@MainActor final class AudioModel: ObservableObject {
    enum WaveMode: String, CaseIterable, Identifiable {
        case trim = "Trim", bleep = "Bleep"
        var id: String { rawValue }
    }
    @Published var url: URL?
    @Published var peaks: [Float] = []
    @Published var duration = 0.0
    @Published var trimStart = 0.0
    @Published var trimEnd = 0.0
    @Published var bleeps: [BleepRange] = []
    @Published var channels: ChannelMode = .original
    @Published var gainL = 1.0
    @Published var gainR = 1.0
    @Published var normalize = false
    @Published var m4a = true
    @Published var mode: WaveMode = .trim
    @Published var playhead = -1.0
    @Published var isPlaying = false
    @Published var loading = false
    @Published var error: String?

    private var player: AVAudioPlayer?
    private var timer: Timer?

    func load(_ u: URL) {
        stop()
        url = u; loading = true; error = nil; peaks = []; bleeps = []
        channels = .original; gainL = 1; gainR = 1; normalize = false; mode = .trim
        Task {
            do {
                let (p, d) = try await Task.detached(priority: .userInitiated) { try Engine.waveform(u) }.value
                peaks = p; duration = d; trimStart = 0; trimEnd = d
            } catch { self.error = "Can't read audio from this file."; url = nil }
            loading = false
        }
    }
    private var tmpPreviewURL: URL?

    func close() {
        stop()
        url = nil
        peaks = []
    }

    var job: AudioJob {
        AudioJob(trimStart: trimStart, trimEnd: trimEnd, bleeps: bleeps.map { $0.start...$0.end },
                 channels: channels, gainL: Float(gainL), gainR: Float(gainR), normalize: normalize, m4a: m4a)
    }

    func stop() {
        timer?.invalidate()
        player?.stop()
        player = nil
        isPlaying = false
        playhead = -1
        if let t = tmpPreviewURL {
            try? FileManager.default.removeItem(at: t)
            tmpPreviewURL = nil
        }
    }

    func playSelection() {
        stop()
        guard let url else { return }
        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.currentTime = trimStart; player?.play(); isPlaying = true
            runTimer(offset: 0, end: trimEnd)
        } catch { self.error = error.localizedDescription }
    }

    func previewOutput() {
        stop()
        guard let url else { return }
        let j = job
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("kq-preview-\(UUID().uuidString).wav")
        tmpPreviewURL = tmp
        var pj = j; pj.m4a = false
        Task {
            do {
                try await Task.detached(priority: .userInitiated) { try Engine.processAudio(url, job: pj, to: tmp) }.value
                player = try AVAudioPlayer(contentsOf: tmp); player?.play(); isPlaying = true
                runTimer(offset: trimStart, end: nil)
            } catch { self.error = error.localizedDescription }
        }
    }

    private func runTimer(offset: Double, end: Double?) {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let p = self.player else { return }
                self.playhead = offset + p.currentTime - (offset == 0 ? 0 : 0)
                if !p.isPlaying || (end != nil && p.currentTime >= end!) { self.stop() }
            }
        }
    }

    func export(dir: URL?) async throws -> URL {
        guard let url else { throw KQError.msg("No audio") }
        let j = job
        let out = Engine.outURL(url, ext: j.m4a ? "m4a" : "wav", suffix: "-edited", dir: dir)
        try await Task.detached(priority: .userInitiated) { try Engine.processAudio(url, job: j, to: out) }.value
        return out
    }
}

struct WaveformView: View {
    @ObservedObject var m: AudioModel
    @State private var handle: Int?
    @State private var live: ClosedRange<Double>?

    private func xPos(for time: Double, width: CGFloat) -> CGFloat {
        let dur = max(m.duration, 0.001)
        return CGFloat(time / dur) * width
    }

    private func time(for xPos: CGFloat, width: CGFloat) -> Double {
        let dur = max(m.duration, 0.001)
        guard width > 0 else { return 0 }
        return min(dur, max(0, Double(xPos / width) * dur))
    }

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    let n = m.peaks.count; guard n > 0 else { return }
                    let bw = size.width / CGFloat(n)
                    for i in 0..<n {
                        let tt = Double(i) / Double(n) * m.duration
                        let inside = tt >= m.trimStart && tt <= m.trimEnd
                        let ph = max(3, CGFloat(m.peaks[i]) * size.height * 0.9)
                        let r = CGRect(x: CGFloat(i) * bw + bw * 0.16, y: (size.height - ph) / 2, width: bw * 0.68, height: ph)
                        ctx.fill(Path(roundedRect: r, cornerRadius: bw * 0.34), with: .color(inside ? .white.opacity(0.85) : .white.opacity(0.20)))
                    }
                }
                ForEach(m.bleeps) { b in
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.red.opacity(0.32))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.red.opacity(0.9), lineWidth: 1.5))
                        .overlay(Text("BLEEP").font(.system(size: 9, weight: .heavy, design: .rounded)).foregroundStyle(.white.opacity(0.9)).padding(3), alignment: .top)
                        .frame(width: max(4, xPos(for: b.end, width: w) - xPos(for: b.start, width: w)), height: h).offset(x: xPos(for: b.start, width: w))
                }
                if let l = live {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.red.opacity(0.25))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.red.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
                        .frame(width: max(2, xPos(for: l.upperBound, width: w) - xPos(for: l.lowerBound, width: w)), height: h).offset(x: xPos(for: l.lowerBound, width: w))
                }
                // trim handles
                ForEach([0, 1], id: \.self) { i in
                    Capsule().fill(.white).frame(width: 5, height: h * 0.72)
                        .overlay(Capsule().fill(Color.white.opacity(0.4)).frame(width: 2, height: h * 0.5))
                        .shadow(color: .black.opacity(0.3), radius: 3)
                        .offset(x: xPos(for: i == 0 ? m.trimStart : m.trimEnd, width: w) - 2.5, y: h * 0.14)
                        .opacity(m.mode == .trim ? 1 : 0.35)
                }
                if m.playhead >= 0 {
                    Rectangle().fill(.white).frame(width: 2, height: h).offset(x: xPos(for: m.playhead, width: w) - 1).shadow(color: .white.opacity(0.7), radius: 4)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if m.mode == .trim {
                        if handle == nil {
                            handle = abs(v.startLocation.x - xPos(for: m.trimStart, width: w)) <= abs(v.startLocation.x - xPos(for: m.trimEnd, width: w)) ? 0 : 1
                        }
                        let tt = time(for: v.location.x, width: w)
                        if handle == 0 { m.trimStart = min(tt, m.trimEnd - 0.05) } else { m.trimEnd = max(tt, m.trimStart + 0.05) }
                    } else {
                        let a = time(for: v.startLocation.x, width: w), b = time(for: v.location.x, width: w)
                        live = min(a, b)...max(a, b)
                    }
                }
                .onEnded { _ in
                    if m.mode == .bleep, let l = live, l.upperBound - l.lowerBound > 0.03 {
                        m.bleeps.append(BleepRange(start: l.lowerBound, end: l.upperBound))
                    }
                    handle = nil; live = nil
                })
        }
    }
}

func timeString(_ s: Double) -> String {
    let m = Int(s) / 60, sec = Int(s) % 60, cs = Int((s - floor(s)) * 100)
    return String(format: "%d:%02d.%02d", m, sec, cs)
}

struct AudioStudioView: View {
    @EnvironmentObject var store: Store
    @ObservedObject var m: AudioModel
    @State private var exporting = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 18) {
                HStack {
                    PageHeader(title: "Audio Studio", subtitle: m.url?.lastPathComponent ?? "Trim, bleep out words, convert channels, normalize.")
                    if m.url != nil { Button("New", systemImage: "waveform.badge.plus") { m.close() }.buttonStyle(.soft) }
                }
                if m.url == nil {
                    DropZone(title: m.loading ? "Reading audio…" : "Drop an audio or video file", hint: "MP3 · M4A · WAV · FLAC · AIFF · MP4 · MOV", symbol: "waveform", height: 240) { urls in m.load(urls[0]) }
                    if let e = m.error { Text(e).foregroundStyle(.red) }
                } else {
                    waveformCard
                    HStack(alignment: .top, spacing: 18) {
                        channelsCard
                        outputCard
                    }
                    if !m.bleeps.isEmpty { bleepList }
                }
            }.padding(30).padding(.top, 10)
        }
        .dropDestination(for: URL.self) { urls, _ in
            if let u = urls.first, [.audio, .video].contains(FileKind.of(u)) { m.load(u); return true }; return false
        }
    }

    var waveformCard: some View {
        VStack(spacing: 14) {
            HStack {
                Picker("", selection: $m.mode) { ForEach(AudioModel.WaveMode.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).frame(width: 190).labelsHidden()
                Text(m.mode == .trim ? "Drag the handles to trim" : "Drag across the waveform to add a bleep").font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.5))
                Spacer()
                Text("\(timeString(m.trimEnd - m.trimStart)) selected").font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundStyle(Color.kqOrange)
            }
            WaveformView(m: m).frame(height: 190)
                .padding(10).background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.black.opacity(0.3)))
            HStack {
                Text("Start \(timeString(m.trimStart))").font(.system(size: 12, design: .monospaced)).foregroundStyle(.white.opacity(0.55))
                Spacer()
                Button(m.isPlaying ? "Stop" : "Play selection", systemImage: m.isPlaying ? "stop.fill" : "play.fill") {
                    m.isPlaying ? m.stop() : m.playSelection()
                }.buttonStyle(.soft)
                Button("Preview result", systemImage: "headphones") { m.previewOutput() }.buttonStyle(.soft)
                Spacer()
                Text("End \(timeString(m.trimEnd))").font(.system(size: 12, design: .monospaced)).foregroundStyle(.white.opacity(0.55))
            }
        }.padding(18).glass(26)
    }

    var channelsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Caption("Channels")
            Picker("", selection: $m.channels) { ForEach(ChannelMode.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).labelsHidden()
            VStack(spacing: 3) {
                HStack { Text(m.channels == .mono ? "Level" : "Left").font(.system(size: 12.5, weight: .medium)); Spacer(); Text("\(Int(m.gainL * 100))%").font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(.white.opacity(0.55)) }
                Slider(value: $m.gainL, in: 0...1.5).tint(.kqOrange).controlSize(.small)
            }
            if m.channels != .mono {
                VStack(spacing: 3) {
                    HStack { Text("Right").font(.system(size: 12.5, weight: .medium)); Spacer(); Text("\(Int(m.gainR * 100))%").font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(.white.opacity(0.55)) }
                    Slider(value: $m.gainR, in: 0...1.5).tint(.kqOrange).controlSize(.small)
                }
            }
            Toggle(isOn: $m.normalize) { Text("Normalize loudness").font(.system(size: 13, weight: .medium)) }.toggleStyle(.switch).tint(.kqOrange)
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).glass(22)
    }

    var outputCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Caption("Output")
            Picker("", selection: $m.m4a) { Text("M4A · AAC").tag(true); Text("WAV · lossless").tag(false) }.pickerStyle(.segmented).labelsHidden()
            Text("\(m.bleeps.count) bleep\(m.bleeps.count == 1 ? "" : "s") · \(m.channels.rawValue.lowercased()) · \(m.normalize ? "normalized" : "as recorded")")
                .font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.55))
            Spacer(minLength: 0)
            Button {
                exporting = true
                Task {
                    do { store.done(try await m.export(dir: store.outputDir)) } catch { store.say(error.localizedDescription) }
                    exporting = false
                }
            } label: {
                HStack { if exporting { ProgressView().controlSize(.small) }; Image(systemName: "square.and.arrow.down"); Text(exporting ? "Exporting…" : "Export audio") }.frame(maxWidth: .infinity)
            }.buttonStyle(.glow).disabled(exporting)
        }.padding(18).frame(maxWidth: .infinity, minHeight: 190, alignment: .leading).glass(22)
    }

    var bleepList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Caption("Bleeps")
            ForEach(m.bleeps) { b in
                HStack {
                    Image(systemName: "speaker.slash.fill").foregroundStyle(.red)
                    Text("\(timeString(b.start)) → \(timeString(b.end))").font(.system(size: 13, design: .monospaced))
                    Spacer()
                    Button { m.bleeps.removeAll { $0.id == b.id } } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.5))
                }
                .padding(.horizontal, 12).padding(.vertical, 8).background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.05)))
            }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).glass(22)
    }
}
