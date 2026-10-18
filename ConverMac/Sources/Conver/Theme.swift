import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - AppKit Visual Effect Blur View
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var state: NSVisualEffectView.State = .active

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
    }
}

// Window Transparency Accessor to make the NSWindow translucent
struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                window.isOpaque = false
                window.backgroundColor = .clear
                window.titlebarAppearsTransparent = true
                window.isMovableByWindowBackground = true
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Palette & Styling
extension Color {
    static let frostedBorder = Color.white.opacity(0.18)
    static let frostedHighlight = Color.white.opacity(0.24)
    static let frostedPanelBg = Color.white.opacity(0.06)

    // Backward compatibility aliases
    static let ink = Color(white: 0.08)
    static let kqOrange = Color.white
    static let kqPink = Color.white.opacity(0.85)
    static let kqViolet = Color.white.opacity(0.7)
    static let kqTeal = Color.white.opacity(0.75)
}

let kqGradient = LinearGradient(
    colors: [Color.white.opacity(0.95), Color.white.opacity(0.90)],
    startPoint: .top,
    endPoint: .bottom
)

// MARK: - Translucent Window Background
struct AuroraBackground: View {
    var body: some View {
        ZStack {
            VisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow)
                .ignoresSafeArea()
            Color.black.opacity(0.25)
                .ignoresSafeArea()
            WindowAccessor()
                .frame(width: 0, height: 0)
        }
    }
}

// MARK: - Frosted Glass Container Modifier
struct FrostedGlass: ViewModifier {
    var radius: CGFloat

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    if #available(macOS 26.0, *) {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(.clear)
                            .glassEffect(.clear, in: .rect(cornerRadius: radius, style: .continuous))
                    } else {
                        VisualEffectView(material: .popover, blendingMode: .withinWindow)
                            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(Color.white.opacity(0.05))
                    }
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.38), Color.white.opacity(0.10)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
            .shadow(color: Color.black.opacity(0.20), radius: 14, y: 5)
    }
}

extension View {
    func glass(_ radius: CGFloat = 18) -> some View {
        modifier(FrostedGlass(radius: radius))
    }

    @ViewBuilder
    func clearGlassCircle() -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.clear, in: .circle)
        } else {
            self.background(Material.ultraThinMaterial, in: Circle())
        }
    }

    @ViewBuilder
    func clearGlassRect(radius: CGFloat) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.clear, in: .rect(cornerRadius: radius, style: .continuous))
        } else {
            self.background(Material.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
    }

    @ViewBuilder
    func clearGlassCapsule() -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.clear, in: .capsule)
        } else {
            self.background(Material.ultraThinMaterial, in: Capsule())
        }
    }
}

// MARK: - Frosted Glass Buttons
struct GlowStyle: ButtonStyle {
    var prominent: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .foregroundStyle(prominent ? Color.black : Color.white)
            .background {
                if prominent {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(configuration.isPressed ? 0.82 : 0.96))
                        .shadow(color: Color.white.opacity(0.2), radius: 6)
                } else {
                    ZStack {
                        VisualEffectView(material: .selection, blendingMode: .withinWindow)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.white.opacity(0.07))
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.20), lineWidth: 1)
                    }
                }
            }
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == GlowStyle {
    static var glow: GlowStyle { GlowStyle(prominent: true) }
    static var soft: GlowStyle { GlowStyle(prominent: false) }
}

// MARK: - Headers & Labels
struct PageHeader: View {
    let title: String, subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(.white)
            Text(subtitle)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.60))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Caption: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(1.0)
            .foregroundStyle(Color.white.opacity(0.50))
    }
}

struct ToastView: View {
    @EnvironmentObject var store: Store
    var body: some View {
        Group {
            if let t = store.toast {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                    Text(t)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background {
                    ZStack {
                        VisualEffectView(material: .hudWindow, blendingMode: .withinWindow)
                            .clipShape(Capsule())
                        Capsule().fill(Color.white.opacity(0.08))
                        Capsule().strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
                    }
                }
                .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
                .padding(.bottom, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.35), value: store.toast)
    }
}

// MARK: - App Icon Mark
struct ConverMark: View {
    var body: some View {
        if let icon = NSApp.applicationIconImage {
            Image(nsImage: icon)
                .resizable()
                .scaledToFit()
        } else {
            ZStack {
                VisualEffectView(material: .popover, blendingMode: .withinWindow)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
                Image(systemName: "circle.grid.cross")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
    }
}

// MARK: - True Frosted Drop Zone
struct DropZone: View {
    let title: String, hint: String, symbol: String
    var types: [UTType] = [.item]
    var height: CGFloat = 150
    var onURLs: ([URL]) -> Void
    @EnvironmentObject var store: Store
    @State private var hot = false

    var body: some View {
        ZStack {
            VisualEffectView(material: .sidebar, blendingMode: .withinWindow)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(hot ? Color.white.opacity(0.12) : Color.white.opacity(0.04))
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    hot ? Color.white.opacity(0.5) : Color.white.opacity(0.18),
                    style: StrokeStyle(lineWidth: hot ? 2 : 1, dash: [8, 6])
                )
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.12))
                        .frame(width: 48, height: 48)
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.20), lineWidth: 1))
                    Image(systemName: symbol)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(hot ? .white : .white.opacity(0.9))
                }
                .scaleEffect(hot ? 1.08 : 1)
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                Text(hint)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .scaleEffect(hot ? 1.008 : 1)
        .animation(.easeOut(duration: 0.2), value: hot)
        .contentShape(Rectangle())
        .onTapGesture {
            let u = store.pickFiles(types: types)
            if !u.isEmpty { onURLs(u) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            onURLs(urls)
            return true
        } isTargeted: { hot = $0 }
    }
}
