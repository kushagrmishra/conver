import SwiftUI
import AppKit
import Carbon
import CoreGraphics
import ApplicationServices
import AVFoundation
import PDFKit
import UniformTypeIdentifiers

// MARK: - Selection Capture (Auto-detects selected files in Finder / Desktop / Active Drag when pressing Shift+Z)
enum SelectionCapture {
    @MainActor private static var lastDragChangeCount: Int = NSPasteboard(name: .drag).changeCount
    @MainActor private static var launchGeneralChangeCount: Int = NSPasteboard.general.changeCount

    /// Fast synchronous check (<1ms): active drag pasteboard + Accessibility selected file URLs.
    @MainActor
    static func captureImmediate() -> [URL] {
        // 1. Active Drag Session (if mouse button is held down)
        let dragPB = NSPasteboard(name: .drag)
        let isDraggingMouse = (NSEvent.pressedMouseButtons & 1) != 0
        if isDraggingMouse {
            lastDragChangeCount = dragPB.changeCount
            let dragged = WheelHitNSView.extractDroppedURLs(from: dragPB).filter {
                FileManager.default.fileExists(atPath: $0.path)
            }
            let normalized = normalizeFileURLs(dragged)
            if !normalized.isEmpty {
                return normalized
            }
        }

        // 2. Accessibility API (AXUIElement) on frontmost app and Finder
        let axURLs = captureViaAccessibility()
        let normalizedAX = normalizeFileURLs(axURLs)
        if !normalizedAX.isEmpty {
            return normalizedAX
        }

        return []
    }

    /// Queries Finder's current selection (works for both Finder windows and Desktop icons).
    static func captureFromFinder() -> [URL] {
        let scriptSource = """
        tell application "Finder"
            set sel to selection
            set outPaths to ""
            repeat with anItem in sel
                try
                    set p to POSIX path of (anItem as alias)
                    set outPaths to outPaths & p & linefeed
                end try
            end repeat
            return outPaths
        end tell
        """
        if let script = NSAppleScript(source: scriptSource) {
            var errorInfo: NSDictionary?
            let result = script.executeAndReturnError(&errorInfo)
            if let str = result.stringValue, !str.isEmpty {
                let parsed = parseNewlinePOSIXPaths(str)
                if !parsed.isEmpty {
                    return parsed
                }
            }
        }

        // Fallback via /usr/bin/osascript
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", scriptSource]
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                let parsed = parseNewlinePOSIXPaths(str)
                if !parsed.isEmpty {
                    return parsed
                }
            }
        } catch {}

        return []
    }

    /// Checks if the user copied file(s) to the clipboard during this session.
    @MainActor
    static func captureFromRecentClipboard() -> [URL] {
        let pb = NSPasteboard.general
        guard pb.changeCount != launchGeneralChangeCount else { return [] }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return normalizeFileURLs(urls)
        }
        return []
    }

    private static func parseNewlinePOSIXPaths(_ raw: String) -> [URL] {
        let urls = raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: $0).standardizedFileURL }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        return normalizeFileURLs(urls)
    }

    static func normalizeFileURLs(_ urls: [URL]) -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        var seen = Set<String>()

        for raw in urls {
            let u = Engine.resolveFileURL(raw)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                // If a folder was selected, include its top-level non-hidden files
                if let children = try? fm.contentsOfDirectory(
                    at: u,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                ) {
                    for child in children {
                        var childDir: ObjCBool = false
                        if fm.fileExists(atPath: child.path, isDirectory: &childDir), !childDir.boolValue {
                            let resolvedChild = Engine.resolveFileURL(child)
                            if seen.insert(resolvedChild.path).inserted {
                                out.append(resolvedChild)
                            }
                        }
                    }
                }
            } else {
                if seen.insert(u.path).inserted {
                    out.append(u)
                }
            }
        }
        return out
    }

    @MainActor
    private static func captureViaAccessibility() -> [URL] {
        var pids: [pid_t] = []
        let selfPID = ProcessInfo.processInfo.processIdentifier
        if let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           frontPID != selfPID {
            pids.append(frontPID)
        }
        if let finderPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.processIdentifier,
           !pids.contains(finderPID) {
            pids.append(finderPID)
        }

        for pid in pids {
            let appElem = AXUIElementCreateApplication(pid)
            var found: [URL] = []

            var focusedRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(appElem, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
               let focused = focusedRef {
                extractSelectedURLs(from: focused as! AXUIElement, into: &found, depth: 0)
            }

            if found.isEmpty {
                var winRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(appElem, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
                   let win = winRef {
                    extractSelectedURLs(from: win as! AXUIElement, into: &found, depth: 0)
                }
            }

            if !found.isEmpty {
                return found
            }
        }
        return []
    }

    private static func extractSelectedURLs(from element: AXUIElement, into results: inout [URL], depth: Int) {
        guard depth <= 4 else { return }

        for attr in [kAXSelectedChildrenAttribute, kAXSelectedRowsAttribute] {
            var selRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attr as CFString, &selRef) == .success,
               let items = selRef as? [AXUIElement], !items.isEmpty {
                for item in items {
                    if let u = urlFromAXElement(item) {
                        results.append(u)
                    }
                }
                if !results.isEmpty { return }
            }
        }

        var childrenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
           let children = childrenRef as? [AXUIElement] {
            for child in children.prefix(16) {
                extractSelectedURLs(from: child, into: &results, depth: depth + 1)
                if !results.isEmpty { return }
            }
        }
    }

    private static func urlFromAXElement(_ element: AXUIElement) -> URL? {
        var urlRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &urlRef) == .success,
           let ref = urlRef {
            if let url = ref as? URL, url.isFileURL { return url }
            if CFGetTypeID(ref) == CFURLGetTypeID() { return (ref as! CFURL) as URL }
            if let str = ref as? String, let url = URL(string: str), url.isFileURL { return url }
        }
        var childrenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
           let children = childrenRef as? [AXUIElement] {
            for child in children.prefix(6) {
                var childURLRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(child, kAXURLAttribute as CFString, &childURLRef) == .success,
                   let ref = childURLRef {
                    if let url = ref as? URL, url.isFileURL { return url }
                    if CFGetTypeID(ref) == CFURLGetTypeID() { return (ref as! CFURL) as URL }
                    if let str = ref as? String, let url = URL(string: str), url.isFileURL { return url }
                }
            }
        }
        return nil
    }
}

@main
struct ConverApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

// MARK: - Borderless Non-Activating Floating Drop Wheel Panel
final class DropWheelPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Menu Bar Drag Receiver View (auto-opens wheel when dragging a file to menu bar icon)
final class StatusBarDragView: NSView {
    var onDragEntered: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { nil }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDragEntered?()
        return .copy
    }
}

// MARK: - AppDelegate: Menu Bar Icon, Shift+Z Hold-to-Open, Launch at Login & Clear Glass Wheel
@MainActor
enum AppRelocator {
    @MainActor
    static func checkAndPromptToMoveToApplications() {
        let bundleURL = Bundle.main.bundleURL
        let bundlePath = bundleURL.path

        // Skip if already in /Applications or ~/Applications
        if bundlePath.hasPrefix("/Applications/") || bundlePath.hasPrefix(NSHomeDirectory() + "/Applications/") {
            return
        }

        // Skip in dev build directory
        if bundlePath.contains("/.build/") || bundlePath.contains("/DerivedData/") {
            return
        }

        let alert = NSAlert()
        alert.messageText = "Move Conver to Applications folder?"
        alert.informativeText = "Conver works best when installed in your Applications folder so it can run globally and respond to Shift + Z."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Do Not Move")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let targetURL = URL(fileURLWithPath: "/Applications/Conver.app")
            let fm = FileManager.default
            do {
                if fm.fileExists(atPath: targetURL.path) {
                    try fm.removeItem(at: targetURL)
                }
                try fm.copyItem(at: bundleURL, to: targetURL)

                let xattr = Process()
                xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
                xattr.arguments = ["-cr", targetURL.path]
                try? xattr.run()
                xattr.waitUntilExit()

                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                NSWorkspace.shared.openApplication(at: targetURL, configuration: config) { _, error in
                    if error == nil {
                        DispatchQueue.main.async {
                            NSApp.terminate(nil)
                        }
                    }
                }
            } catch {
                NSLog("Failed to move Conver to Applications: \(error)")
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?

    private var statusItem: NSStatusItem!
    private var wheelPanel: DropWheelPanel!
    private var studioWindow: NSWindow?
    private var wasShiftZDown = false
    private var wasMouseDown = false
    private var pinnedByMenuBar = false
    private var hotkeyPollTimer: Timer?
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyEventHandler: EventHandlerRef?

    private let panelSize = NSSize(width: 560, height: 620)
    private let posXKey = "conver.wheel.originX"
    private let posYKey = "conver.wheel.originY"
    private let hasPosKey = "conver.wheel.hasCustomPos"

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self

        // 0. Prompt to move to Applications if opened from DMG / Downloads
        AppRelocator.checkAndPromptToMoveToApplications()

        let store = Store.shared

        // 1. Automatically enable Open at Login
        store.setLaunchAtLogin(true)

        // 2. Wire Store callbacks
        store.onToggleWheel = { [weak self] show in
            guard let self else { return }
            let target = show ?? !store.wheelVisible
            self.pinnedByMenuBar = target
            self.toggleWheel(force: target)
        }
        store.onOpenStudio = { [weak self] tab in
            self?.openStudioWindow(tab: tab)
        }
        store.onCheckAutoClose = { [weak self] in
            self?.checkAutoCloseAfterAction()
        }

        // 3. Create Top Menu Bar Icon (next to Wi-Fi symbol)
        setupMenuBarItem()

        // 4. Create Floating Radial Drop Wheel Panel
        setupWheelPanel()

        // 5. Register Global Carbon Hotkey (Shift + Z) & Click-Outside-on-Screen Exit Monitor
        registerCarbonShiftZHotKey()
        setupShiftZMonitor()

        // 6. Show Drop Wheel smoothly on launch
        showWheel()
    }

    // MARK: Menu Bar Item (Sits in top bar next to Wi-Fi)
    private func setupMenuBarItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }

        button.image = Self.makeMenuBarLogo()
        button.image?.isTemplate = true
        button.toolTip = "Conver Drop Wheel (Hold ⇧+Z to open)"
        button.target = self
        button.action = #selector(statusBarClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        let dragOverlay = StatusBarDragView(frame: button.bounds)
        dragOverlay.autoresizingMask = [.width, .height]
        dragOverlay.onDragEntered = { [weak self] in
            Task { @MainActor in
                self?.pinnedByMenuBar = true
                self?.showWheel()
            }
        }
        button.addSubview(dragOverlay)
    }

    /// Draws the Conver layered C-mark silhouette as a crisp macOS Menu Bar template icon.
    static func makeMenuBarLogo() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

            // Outer rounded squircle frame
            let outer = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 1.5, width: 15, height: 15), xRadius: 4.2, yRadius: 4.2)
            outer.lineWidth = 1.5
            NSColor.black.setStroke()
            outer.stroke()

            // Inner Conver C-curve + center drop dot (matching conver.icon)
            let arc = NSBezierPath()
            arc.appendArc(withCenter: NSPoint(x: 9, y: 9), radius: 4.2, startAngle: 42, endAngle: 318, clockwise: false)
            arc.lineWidth = 1.8
            arc.lineCapStyle = .round
            arc.stroke()

            ctx.fillEllipse(in: CGRect(x: 7.7, y: 7.7, width: 2.6, height: 2.6))
            return true
        }
        img.isTemplate = true
        return img
    }

    @objc private func statusBarClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            pinnedByMenuBar = !Store.shared.wheelVisible
            toggleWheel(force: pinnedByMenuBar)
            return
        }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showStatusMenu()
        } else {
            showStatusMenu()
        }
    }

    func showStatusMenu() {
        let store = Store.shared
        let menu = NSMenu()

        let toggleItem = NSMenuItem(
            title: store.wheelVisible ? "Hide Drop Wheel (Hold ⇧+Z)" : "Pin Drop Wheel Open (or Hold ⇧+Z)",
            action: #selector(menuToggleWheel),
            keyEquivalent: ""
        )
        toggleItem.target = self
        menu.addItem(toggleItem)

        let resetPosItem = NSMenuItem(
            title: "Reset Wheel Position to Screen Center",
            action: #selector(menuResetPosition),
            keyEquivalent: ""
        )
        resetPosItem.target = self
        menu.addItem(resetPosItem)

        menu.addItem(.separator())

        // Output Folder
        let folderTitle = store.outputDir.map { "Output: \($0.lastPathComponent)" } ?? "Output: Same as Input Folder"
        let folderItem = NSMenuItem(title: folderTitle, action: #selector(menuPickFolder), keyEquivalent: "")
        folderItem.target = self
        menu.addItem(folderItem)

        if store.outputDir != nil {
            let resetFolder = NSMenuItem(title: "Reset Output to Same as Input", action: #selector(menuResetFolder), keyEquivalent: "")
            resetFolder.target = self
            menu.addItem(resetFolder)
        }

        menu.addItem(.separator())

        // Wheel Size Submenu
        let sizeMenu = NSMenu()
        let sizes: [(String, Double)] = [
            ("Compact (85%)", 0.85),
            ("Standard (100%)", 1.0),
            ("Large (115%)", 1.15),
            ("Extra Large (130%)", 1.30)
        ]
        for (name, scale) in sizes {
            let item = NSMenuItem(title: name, action: #selector(menuSetScale(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = scale
            item.state = abs(store.wheelScale - scale) < 0.05 ? .on : .off
            sizeMenu.addItem(item)
        }
        let sizeSubmenuItem = NSMenuItem(title: "Wheel Size", action: nil, keyEquivalent: "")
        sizeSubmenuItem.submenu = sizeMenu
        menu.addItem(sizeSubmenuItem)

        menu.addItem(.separator())

        // Open at Login
        let loginItem = NSMenuItem(title: "Open at Login", action: #selector(menuToggleLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = store.launchAtLogin ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Conver", action: #selector(menuQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func menuToggleWheel() {
        pinnedByMenuBar = !Store.shared.wheelVisible
        toggleWheel(force: pinnedByMenuBar)
    }
    @objc private func menuResetPosition() {
        UserDefaults.standard.set(false, forKey: hasPosKey)
        positionWheelPanel()
        pinnedByMenuBar = true
        showWheel()
    }
    @objc private func menuPickFolder() { Store.shared.pickFolder() }
    @objc private func menuResetFolder() { Store.shared.outputDir = nil }
    @objc private func menuToggleLogin() {
        Store.shared.setLaunchAtLogin(!Store.shared.launchAtLogin)
    }
    @objc private func menuSetScale(_ sender: NSMenuItem) {
        if let scale = sender.representedObject as? Double {
            Store.shared.wheelScale = scale
        }
    }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    // MARK: Floating Drop Wheel Panel Setup & User-Movable Position
    private func setupWheelPanel() {
        let rect = NSRect(origin: .zero, size: panelSize)
        wheelPanel = DropWheelPanel(contentRect: rect)
        let host = NSHostingView(rootView: FloatingDropWheelRootView(
            onWindowMoved: { [weak self] newOrigin in
                self?.saveCustomOrigin(newOrigin)
            }
        ).environmentObject(Store.shared))
        host.frame = rect
        wheelPanel.contentView = host
        positionWheelPanel()
    }

    private func saveCustomOrigin(_ origin: NSPoint) {
        UserDefaults.standard.set(Double(origin.x), forKey: posXKey)
        UserDefaults.standard.set(Double(origin.y), forKey: posYKey)
        UserDefaults.standard.set(true, forKey: hasPosKey)
    }

    private func positionWheelPanel() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }

        var origin: NSPoint
        if UserDefaults.standard.bool(forKey: hasPosKey) {
            let savedX = CGFloat(UserDefaults.standard.double(forKey: posXKey))
            let savedY = CGFloat(UserDefaults.standard.double(forKey: posYKey))
            origin = NSPoint(x: savedX, y: savedY)
            // Ensure saved position is still within one of the connected screens
            let inAnyScreen = NSScreen.screens.contains { s in
                s.visibleFrame.intersects(NSRect(origin: origin, size: panelSize))
            }
            if !inAnyScreen {
                origin = NSPoint(x: visible.midX - panelSize.width / 2, y: visible.midY - panelSize.height / 2)
            }
        } else {
            origin = NSPoint(
                x: visible.midX - panelSize.width / 2,
                y: visible.midY - panelSize.height / 2
            )
        }
        wheelPanel.setFrameOrigin(origin)
    }

    func toggleWheel(force: Bool?) {
        let target = force ?? !Store.shared.wheelVisible
        if target {
            showWheel()
        } else {
            hideWheel()
        }
    }

    private var hotKeyRef2: EventHotKeyRef?
    private var hideWheelTask: Task<Void, Never>?
    private var isHoldingShiftZ = false
    private var mousePositionAtWheelOpen: NSPoint = .zero

    func showWheel() {
        let wasVisible = Store.shared.wheelVisible
        hideWheelTask?.cancel()
        hideWheelTask = nil
        let mouseDownNow = (NSEvent.pressedMouseButtons & 1) != 0
        wasMouseDown = mouseDownNow
        if mouseDownNow {
            isExternalDragSessionActive = true
            mouseDownStartedOutsideWheel = true
        }
        if !wasVisible {
            mousePositionAtWheelOpen = NSEvent.mouseLocation
            Store.shared.hoveredWedgeWhileHolding = nil
            captureSelectedItemsIntoWheel()
        }
        positionWheelPanel()
        wheelPanel.alphaValue = 1.0
        wheelPanel.orderFrontRegardless()
        withAnimation(.spring(response: 0.24, dampingFraction: 0.78)) {
            Store.shared.wheelVisible = true
        }
    }

    /// Automatically detects currently selected files in Finder / Desktop / Active Drag and drops them into the wheel.
    private func captureSelectedItemsIntoWheel() {
        let store = Store.shared
        let immediate = SelectionCapture.captureImmediate()
        if !immediate.isEmpty {
            store.stagedURLs = immediate
            return
        }

        Task.detached(priority: .userInitiated) {
            let finderURLs = SelectionCapture.captureFromFinder()
            if !finderURLs.isEmpty {
                await MainActor.run {
                    Store.shared.stagedURLs = finderURLs
                }
            }
        }
    }

    func hideWheel() {
        hideWheelTask?.cancel()
        Store.shared.activeMenu = nil
        Store.shared.hoveredWedgeWhileHolding = nil
        Store.shared.stagedURLs = []
        Store.shared.onHoverWheelPoint?(nil)
        withAnimation(.spring(response: 0.20, dampingFraction: 0.86)) {
            Store.shared.wheelVisible = false
        }
        hideWheelTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(160))
            guard !Task.isCancelled else { return }
            if !Store.shared.wheelVisible {
                self?.wheelPanel.orderOut(nil)
            }
        }
    }

    func checkAutoCloseAfterAction() {
        let store = Store.shared
        guard store.activeMenu == nil && !store.isPickingFile && !store.wheelBusy else { return }
        if !isHoldingShiftZ && !pinnedByMenuBar {
            hideWheel()
        }
    }

    private var appHotKeyEventHandler: EventHandlerRef?
    private var openedViaCarbonHotKey = false

    // MARK: Global Carbon Hotkey (Shift + Z) — Press Opens Wheel, Release Closes Wheel
    private func registerCarbonShiftZHotKey() {
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let callback: EventHandlerUPP = { _, event, _ in
            let kind = GetEventKind(event)
            if kind == UInt32(kEventHotKeyPressed) {
                DispatchQueue.main.async {
                    AppDelegate.shared?.handleShiftZPressed(fromCarbon: true)
                }
            } else if kind == UInt32(kEventHotKeyReleased) {
                DispatchQueue.main.async {
                    AppDelegate.shared?.handleShiftZReleased()
                }
            }
            return noErr
        }
        if let appTarget = GetApplicationEventTarget() {
            InstallEventHandler(
                appTarget,
                callback,
                eventTypes.count,
                &eventTypes,
                nil,
                &appHotKeyEventHandler
            )
        }
        if let dispTarget = GetEventDispatcherTarget() {
            InstallEventHandler(
                dispTarget,
                callback,
                eventTypes.count,
                &eventTypes,
                nil,
                &hotKeyEventHandler
            )
        }
        let target = GetApplicationEventTarget() ?? GetEventDispatcherTarget()
        let hotKeyID1 = EventHotKeyID(signature: OSType(0x434E5652), id: 1)
        let s1 = RegisterEventHotKey(
            UInt32(kVK_ANSI_Z),
            UInt32(shiftKey),
            hotKeyID1,
            target,
            0,
            &hotKeyRef
        )
        let logMsg = "RegisterEventHotKey Shift+Z status1=\(s1)\n"
        try? logMsg.write(toFile: "/tmp/conver_hotkey.log", atomically: true, encoding: .utf8)
    }

    func handleShiftZPressed(fromCarbon: Bool = false) {
        lastShiftZTrigger = Date()
        if fromCarbon {
            openedViaCarbonHotKey = true
        } else if !isHoldingShiftZ {
            openedViaCarbonHotKey = false
        }
        isHoldingShiftZ = true
        pinnedByMenuBar = false
        if (NSEvent.pressedMouseButtons & 1) != 0 {
            isExternalDragSessionActive = true
            mouseDownStartedOutsideWheel = true
        }
        showWheel()
    }

    func handleShiftZReleased() {
        guard isHoldingShiftZ else { return }
        isHoldingShiftZ = false
        openedViaCarbonHotKey = false
        wasShiftZDown = false
        let store = Store.shared

        // If the user is currently holding the mouse button down (dragging files into the wheel),
        // keep the wheel open until they finish dropping the files!
        if (NSEvent.pressedMouseButtons & 1) != 0 || isExternalDragSessionActive {
            return
        }

        if store.activeMenu == nil && !store.isPickingFile && !store.wheelBusy && !pinnedByMenuBar {
            hideWheel()
        }
    }

    private func isPointInsideWheel(_ mouse: NSPoint) -> Bool {
        guard wheelPanel.isVisible && Store.shared.wheelVisible else { return false }
        let frame = wheelPanel.frame
        let center = NSPoint(x: frame.midX, y: frame.midY)
        return hypot(mouse.x - center.x, mouse.y - center.y) <= 208
    }

    private func localWheelPoint(for screenPt: NSPoint) -> CGPoint {
        let frame = wheelPanel.frame
        let dx = screenPt.x - frame.midX
        let dy = frame.midY - screenPt.y
        return CGPoint(x: 199.0 + dx, y: 199.0 + dy)
    }

    private func isPointInsideAppUI(_ mouse: NSPoint) -> Bool {
        if wheelPanel.isVisible && Store.shared.wheelVisible {
            let frame = wheelPanel.frame
            if Store.shared.activeMenu != nil {
                let cardRect = frame.insetBy(dx: 16, dy: 10)
                if NSMouseInRect(mouse, cardRect, false) {
                    return true
                }
            } else {
                let center = NSPoint(x: frame.midX, y: frame.midY)
                if hypot(mouse.x - center.x, mouse.y - center.y) <= 208 {
                    return true
                }
            }
        }
        if let win = studioWindow, win.isVisible, NSMouseInRect(mouse, win.frame, false) {
            return true
        }
        if let btnWin = statusItem?.button?.window, NSMouseInRect(mouse, btnWin.frame, false) {
            return true
        }
        return false
    }

    @MainActor
    private func closeIfClickedOutside(at mouse: NSPoint) {
        guard !Store.shared.isPickingFile else { return }
        // Never close while the user is holding Shift+Z or actively dragging a file into the wheel!
        guard !isHoldingShiftZ && !isExternalDragSessionActive else { return }
        if !isPointInsideAppUI(mouse) {
            if Store.shared.wheelVisible {
                pinnedByMenuBar = false
                isHoldingShiftZ = false
                openedViaCarbonHotKey = false
                hideWheel()
            }
            if let win = studioWindow, win.isVisible {
                win.orderOut(nil)
            }
        }
    }

    // MARK: Shift + Z Hold-to-Open / Release-to-Close & Click-Outside-on-Screen to Exit
    private func setupShiftZMonitor() {
        // 1. Global mouse click monitor
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                // If an action menu or studio window is open, clicking outside closes immediately.
                // When the circular drop wheel is open, wait for mouse-up if leftMouseDown so the user can drag files into the wheel!
                if event.type != .leftMouseDown || Store.shared.activeMenu != nil || (self.studioWindow?.isVisible == true) {
                    self.closeIfClickedOutside(at: NSEvent.mouseLocation)
                }
            }
        }

        // 1b. Global keyDown / keyUp / flagsChanged monitor
        NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            if event.type == .keyDown && event.keyCode == 6 {
                let clean = event.modifierFlags.intersection([.shift, .command, .option, .control])
                if clean == .shift {
                    Task { @MainActor in
                        self?.handleShiftZPressed(fromCarbon: false)
                    }
                }
            } else if event.type == .keyUp && event.keyCode == 6 {
                Task { @MainActor in
                    self?.handleShiftZReleased()
                }
            } else if event.type == .flagsChanged && !event.modifierFlags.contains(.shift) {
                Task { @MainActor in
                    self?.handleShiftZReleased()
                }
            }
        }

        // 2. Local Escape & Shift+Z press/release handling
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            if event.type == .keyDown && event.keyCode == 53 { // Escape closes menu or exits wheel
                Task { @MainActor in
                    if Store.shared.activeMenu != nil {
                        Store.shared.activeMenu = nil
                    } else {
                        self?.pinnedByMenuBar = false
                        self?.isHoldingShiftZ = false
                        self?.openedViaCarbonHotKey = false
                        self?.hideWheel()
                        self?.studioWindow?.orderOut(nil)
                    }
                }
                return nil
            }
            if event.type == .keyDown && event.keyCode == 6 && event.modifierFlags.contains(.shift) {
                Task { @MainActor in
                    self?.handleShiftZPressed(fromCarbon: false)
                }
                return nil
            }
            if event.type == .keyUp && event.keyCode == 6 {
                Task { @MainActor in
                    self?.handleShiftZReleased()
                }
                return nil
            }
            if event.type == .flagsChanged && !event.modifierFlags.contains(.shift) {
                Task { @MainActor in
                    self?.handleShiftZReleased()
                }
            }
            return event
        }

        // 3. Hardware poll (25ms): detects mouse drag-hover, drop-into-wheel, click-outside & Shift+Z press/release
        lastObservedDragPBCount = NSPasteboard(name: .drag).changeCount
        hotkeyPollTimer = Timer.scheduledTimer(withTimeInterval: 0.025, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollShiftZAndMouseState()
            }
        }
    }

    private var lastShiftZTrigger = Date.distantPast
    private var lastObservedDragPBCount: Int = 0
    private var lastConsumedDragPBCount: Int = -1
    private var isExternalDragSessionActive = false
    private var mouseDownStartedOutsideWheel = false

    @MainActor
    private func pollShiftZAndMouseState() {
        let store = Store.shared
        let mouse = NSEvent.mouseLocation
        let isMouseDown = (NSEvent.pressedMouseButtons & 1) != 0
        let dragPB = NSPasteboard(name: .drag)
        let currentDragCount = dragPB.changeCount

        // Detect when Finder / any app starts a file drag
        if currentDragCount != lastObservedDragPBCount {
            lastObservedDragPBCount = currentDragCount
            if isMouseDown {
                isExternalDragSessionActive = true
            }
        }

        // A. Track mouse down / drag over wheel / mouse up (drop or click-outside)
        if isMouseDown && !wasMouseDown {
            wasMouseDown = true
            mouseDownStartedOutsideWheel = !isPointInsideAppUI(mouse)
            if store.activeMenu != nil {
                closeIfClickedOutside(at: mouse)
            }
        } else if isMouseDown {
            // While dragging a file (or holding Shift+Z with mouse down), live-highlight the wedge under the cursor!
            if store.wheelVisible && store.activeMenu == nil && (isExternalDragSessionActive || mouseDownStartedOutsideWheel) {
                if isPointInsideWheel(mouse) {
                    let localPt = localWheelPoint(for: mouse)
                    store.onHoverWheelPoint?(localPt)
                } else {
                    store.onHoverWheelPoint?(nil)
                }
            }
        } else if !isMouseDown && wasMouseDown {
            wasMouseDown = false
            let wasDraggingExternal = isExternalDragSessionActive || mouseDownStartedOutsideWheel
            isExternalDragSessionActive = false
            mouseDownStartedOutsideWheel = false

            if store.wheelVisible && store.activeMenu == nil && wasDraggingExternal && isPointInsideWheel(mouse) {
                // User released the mouse inside the wheel after dragging from outside!
                let dropPt = localWheelPoint(for: mouse)
                let pbCountAtRelease = currentDragCount
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(35))
                    guard let self else { return }
                    // If AppKit's performDragOperation didn't already fire, complete the drop from NSPasteboard(name: .drag)
                    if Date().timeIntervalSince(store.lastAppKitDropTime) > 0.25 && pbCountAtRelease != self.lastConsumedDragPBCount {
                        let urls = WheelHitNSView.extractDroppedURLs(from: NSPasteboard(name: .drag)).filter {
                            FileManager.default.fileExists(atPath: $0.path)
                        }
                        if !urls.isEmpty {
                            self.lastConsumedDragPBCount = pbCountAtRelease
                            store.onHoverWheelPoint?(nil)
                            store.onDropWheelURLs?(SelectionCapture.normalizeFileURLs(urls), dropPt)
                            return
                        }
                    }
                    self.checkAutoCloseAfterAction()
                }
            } else if !isPointInsideAppUI(mouse) {
                closeIfClickedOutside(at: mouse)
            }
        }

        // B. Detect Shift modifier release if the user released Shift before Z
        let flags = CGEventSource.flagsState(.combinedSessionState)
        let shiftHeld = flags.contains(.maskShift)
        if isHoldingShiftZ && !shiftHeld && Date().timeIntervalSince(lastShiftZTrigger) > 0.08 {
            handleShiftZReleased()
            return
        }

        // C. Hardware poll for simultaneous Z+Shift press (only triggers release if NOT opened via Carbon)
        let zPressed = CGEventSource.keyState(.combinedSessionState, key: 6)
        let shiftOnly = shiftHeld
            && !flags.contains(.maskCommand)
            && !flags.contains(.maskAlternate)
            && !flags.contains(.maskControl)

        let isShiftZNow = zPressed && shiftOnly
        if isShiftZNow && !wasShiftZDown {
            wasShiftZDown = true
            if !isHoldingShiftZ {
                handleShiftZPressed(fromCarbon: false)
            }
        } else if !isShiftZNow && wasShiftZDown {
            wasShiftZDown = false
            if isHoldingShiftZ && !openedViaCarbonHotKey {
                handleShiftZReleased()
            }
        }
    }

    // MARK: On-Demand Studio Window (Only when opening Photo/Redact/Audio/PDF Editor)
    func openStudioWindow(tab: Tab) {
        pinnedByMenuBar = false
        hideWheel()
        if studioWindow == nil {
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 960, height: 660),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            win.titlebarAppearsTransparent = true
            win.titleVisibility = .hidden
            win.isOpaque = false
            win.backgroundColor = .clear
            win.isReleasedWhenClosed = false
            win.center()
            win.contentView = NSHostingView(rootView: StudioContainerView(onClose: { [weak win] in
                win?.orderOut(nil)
            }).environmentObject(Store.shared))
            studioWindow = win
        }
        NSApp.activate(ignoringOtherApps: true)
        studioWindow?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Pure Clear Glass Radial Drop Wheel Root View (No Bottom Bar)
struct FloatingDropWheelRootView: View {
    @EnvironmentObject var store: Store
    var onWindowMoved: (NSPoint) -> Void

    var body: some View {
        ZStack {
            VStack(spacing: 10) {
                RadialDropWheel(wheelSize: 380 * CGFloat(store.wheelScale), onWindowMoved: onWindowMoved)

                // Clear Glass Toast Pill with Instant Drag-Out & Copy to Clipboard
                if let toast = store.toast {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color(red: 0.25, green: 0.88, blue: 0.55))
                            .font(.system(size: 13, weight: .bold))

                        Text(toast)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        if let latest = store.recents.first {
                            // Instant Copy to Clipboard
                            Button {
                                store.copyToClipboard(latest)
                            } label: {
                                HStack(spacing: 3) {
                                    Image(systemName: store.copiedFileRecently ? "checkmark" : "doc.on.doc")
                                        .font(.system(size: 9.5, weight: .bold))
                                    Text(store.copiedFileRecently ? "Copied" : "Copy")
                                }
                            }
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3.5)
                            .background(Capsule().fill(Color.white.opacity(store.copiedFileRecently ? 0.40 : 0.22)))
                            .buttonStyle(.plain)

                            // Show in Finder
                            Button("Show") {
                                store.reveal(latest)
                            }
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3.5)
                            .background(Capsule().fill(Color.white.opacity(0.22)))
                            .buttonStyle(.plain)

                            // Drag Out Badge Handle (Draggable to Slack, Figma, Discord, Mail, Browser)
                            HStack(spacing: 3.5) {
                                Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                                    .font(.system(size: 9, weight: .heavy))
                                Text("Drag Out")
                                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                            }
                            .padding(.horizontal, 8.5)
                            .padding(.vertical, 3.5)
                            .background(Capsule().fill(Color.white.opacity(0.32)))
                            .overlay(Capsule().strokeBorder(Color.white.opacity(0.60), lineWidth: 0.8))
                            .help("Drag directly into Slack, Figma, Discord, Mail, or Browser")
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.50), lineWidth: 1))
                    .clearGlassCapsule()
                    .shadow(color: .black.opacity(0.20), radius: 8, y: 3)
                    .onDrag {
                        if let latest = store.recents.first {
                            return NSItemProvider(object: latest as NSURL)
                        }
                        return NSItemProvider()
                    }
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
                }
            }
            .scaleEffect(store.wheelVisible ? 1.0 : 0.72)
            .opacity(store.wheelVisible ? 1.0 : 0.0)
            .animation(.spring(response: 0.24, dampingFraction: 0.78), value: store.wheelVisible)
            .animation(.spring(response: 0.22, dampingFraction: 0.82), value: store.wheelScale)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Annular Pie Wedge Shape for Radial Drop Wheel
struct AnnularWedgeShape: Shape {
    var startDegrees: Double
    var endDegrees: Double
    var innerRadiusRatio: CGFloat = 0.31

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outerR = min(rect.width, rect.height) * 0.5
        let innerR = outerR * innerRadiusRatio
        let start = Angle.degrees(startDegrees)
        let end = Angle.degrees(endDegrees)

        var p = Path()
        p.addArc(center: center, radius: outerR, startAngle: start, endAngle: end, clockwise: false)
        p.addArc(center: center, radius: innerR, startAngle: end, endAngle: start, clockwise: true)
        p.closeSubpath()
        return p
    }
}

// MARK: - Native Polar Hit-Testing, Drag-to-Move & File Drop Overlay
final class WheelHitNSView: NSView {
    var onHoverPoint: ((CGPoint?) -> Void)?
    var onClickPoint: ((CGPoint) -> Void)?
    var onDropURLs: (([URL], CGPoint) -> Void)?
    var onWindowMoved: ((NSPoint) -> Void)?

    private var trackingArea: NSTrackingArea?
    private var mouseDownScreenPt: NSPoint?
    private var initialWindowOrigin: NSPoint?
    private var didDragWindow = false

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([
            .fileURL,
            .URL,
            .png,
            .tiff,
            NSPasteboard.PasteboardType("NSFilenamesPboardType")
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        onHoverPoint?(pt)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverPoint?(nil)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownScreenPt = NSEvent.mouseLocation
        initialWindowOrigin = window?.frame.origin
        didDragWindow = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownScreenPt,
              let winOrigin = initialWindowOrigin,
              let win = window else { return }
        let curr = NSEvent.mouseLocation
        let dx = curr.x - start.x
        let dy = curr.y - start.y
        if !didDragWindow && hypot(dx, dy) > 4.0 {
            didDragWindow = true
            onHoverPoint?(nil)
        }
        if didDragWindow {
            let newOrigin = NSPoint(x: winOrigin.x + dx, y: winOrigin.y + dy)
            win.setFrameOrigin(newOrigin)
            onWindowMoved?(newOrigin)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let wasDragging = didDragWindow
        mouseDownScreenPt = nil
        initialWindowOrigin = nil
        didDragWindow = false

        if !wasDragging {
            let pt = convert(event.locationInWindow, from: nil)
            onClickPoint?(pt)
        }
    }

    override func magnify(with event: NSEvent) {
        Task { @MainActor in
            let current = Store.shared.wheelScale
            let delta = Double(event.magnification)
            let newScale = min(max(current + delta, 0.70), 1.45)
            Store.shared.wheelScale = newScale
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let pt = convert(sender.draggingLocation, from: nil)
        onHoverPoint?(pt)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let pt = convert(sender.draggingLocation, from: nil)
        onHoverPoint?(pt)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onHoverPoint?(nil)
    }

    static func extractDroppedURLs(from pb: NSPasteboard) -> [URL] {
        var resolved: [URL] = []

        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL], !urls.isEmpty {
            resolved = urls.map { Engine.resolveFileURL($0) }
        }

        if resolved.isEmpty,
           let paths = pb.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] {
            resolved = paths.map { URL(fileURLWithPath: $0).standardizedFileURL }
        }

        if resolved.isEmpty,
           let items = pb.pasteboardItems {
            for item in items {
                if let str = item.string(forType: .fileURL),
                   let u = URL(string: str) {
                    resolved.append(Engine.resolveFileURL(u))
                }
            }
        }

        if resolved.isEmpty,
           let img = NSImage(pasteboard: pb),
           let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("Dropped-\(Int(Date().timeIntervalSince1970)).png")
            if (try? Engine.writeImage(cg, to: tmp, type: .png, quality: 1.0)) != nil {
                resolved = [tmp]
            }
        }

        return resolved
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pt = convert(sender.draggingLocation, from: nil)
        onHoverPoint?(nil)
        let urls = Self.extractDroppedURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        Task { @MainActor in
            Store.shared.lastAppKitDropTime = Date()
        }
        onDropURLs?(urls, pt)
        return true
    }
}

struct WheelHitOverlay: NSViewRepresentable {
    var onHoverPoint: (CGPoint?) -> Void
    var onClickPoint: (CGPoint) -> Void
    var onDropURLs: ([URL], CGPoint) -> Void
    var onWindowMoved: (NSPoint) -> Void

    func makeNSView(context: Context) -> WheelHitNSView {
        let v = WheelHitNSView()
        v.onHoverPoint = onHoverPoint
        v.onClickPoint = onClickPoint
        v.onDropURLs = onDropURLs
        v.onWindowMoved = onWindowMoved
        return v
    }

    func updateNSView(_ nsView: WheelHitNSView, context: Context) {
        nsView.onHoverPoint = onHoverPoint
        nsView.onClickPoint = onClickPoint
        nsView.onDropURLs = onDropURLs
        nsView.onWindowMoved = onWindowMoved
    }
}

// MARK: - Interactive Clear Liquid Glass Radial Drop Wheel & Shape-Morphing Contextual Menu
struct RadialDropWheel: View {
    @EnvironmentObject var store: Store
    var wheelSize: CGFloat = 380
    var onWindowMoved: (NSPoint) -> Void
    @State private var activeWedge: Int?
    @State private var centerTargeted = false
    @State private var hoveredOptionID: UUID?
    @Namespace private var glassMorphNS

    struct WedgeSpec: Identifiable {
        let id: Int
        let label: String
        let subtitle: String
        let icon: String
        let types: [UTType]
        let action: ([URL]) -> Void
    }

    var wedges: [WedgeSpec] {
        [
            WedgeSpec(
                id: 0,
                label: "Quick Convert",
                subtitle: "Auto-detect format",
                icon: "bolt.horizontal.circle.fill",
                types: [.item]
            ) { urls in
                presentQuickConvertMenu(for: urls)
            },
            WedgeSpec(
                id: 1,
                label: "Upscale & Resize",
                subtitle: "Super-res & shrink",
                icon: "arrow.up.left.and.arrow.down.right.circle.fill",
                types: [.item]
            ) { urls in
                presentCompressMenu(for: urls)
            },
            WedgeSpec(
                id: 2,
                label: "Photo Edit",
                subtitle: "Crop, tune & frame",
                icon: "wand.and.stars",
                types: [.image, .pdf]
            ) { urls in
                presentPhotoEditMenu(for: urls)
            },
            WedgeSpec(
                id: 3,
                label: "Redact",
                subtitle: "Blur & privacy",
                icon: "eye.slash.fill",
                types: [.image, .pdf]
            ) { urls in
                presentRedactMenu(for: urls)
            },
            WedgeSpec(
                id: 4,
                label: "Strip EXIF",
                subtitle: "Scrub GPS/meta",
                icon: "lock.shield.fill",
                types: [.image, .pdf]
            ) { urls in
                presentStripEXIFMenu(for: urls)
            },
            WedgeSpec(
                id: 5,
                label: "PDF & Docs",
                subtitle: "Word, PDF, RTF & split",
                icon: "doc.richtext.fill",
                types: [.pdf, .image, .item]
            ) { urls in
                presentPDFMenu(for: urls)
            },
            WedgeSpec(
                id: 6,
                label: "Audio Tools",
                subtitle: "Trim, bleep & mix",
                icon: "waveform",
                types: [.audio, .movie]
            ) { urls in
                presentAudioMenu(for: urls)
            },
            WedgeSpec(
                id: 7,
                label: "Extract Text",
                subtitle: "OCR & QR Scanner",
                icon: "text.viewfinder",
                types: [.image, .pdf, .item]
            ) { urls in
                presentTextAndQRMenu(for: urls)
            }
        ]
    }

    enum HitZone {
        case none
        case center
        case wedge(Int)
    }

    private func hitTest(_ pt: CGPoint) -> HitZone {
        let total = wheelSize + 18
        let cx = total * 0.5
        let cy = total * 0.5
        let dx = pt.x - cx
        let dy = pt.y - cy
        let dist = hypot(dx, dy)
        let outerR = wheelSize * 0.5
        let innerR = outerR * 0.31

        if dist <= innerR {
            return .center
        } else if dist <= outerR + 10 {
            var deg = atan2(dy, dx) * 180.0 / .pi + 90.0
            if deg < 0 { deg += 360.0 }
            let count = Double(wedges.count)
            let step = 360.0 / count
            let idx = Int(((deg + step * 0.5).truncatingRemainder(dividingBy: 360.0)) / step) % wedges.count
            return .wedge(idx)
        } else {
            return .none
        }
    }

    private func updateHover(_ pt: CGPoint?) {
        guard let pt else {
            activeWedge = nil
            centerTargeted = false
            store.hoveredWedgeWhileHolding = nil
            return
        }
        switch hitTest(pt) {
        case .none:
            activeWedge = nil
            centerTargeted = false
            store.hoveredWedgeWhileHolding = nil
        case .center:
            activeWedge = nil
            centerTargeted = true
            store.hoveredWedgeWhileHolding = -1
        case .wedge(let idx):
            activeWedge = idx
            centerTargeted = false
            store.hoveredWedgeWhileHolding = idx
        }
    }

    /// Returns the items already dropped/selected in the wheel (or captures current Finder selection),
    /// only opening the file picker dialog if nothing is selected.
    private func resolveInputFiles(for types: [UTType]) -> [URL] {
        if !store.stagedURLs.isEmpty {
            return store.stagedURLs
        }
        let immediate = SelectionCapture.captureImmediate()
        if !immediate.isEmpty {
            store.stagedURLs = immediate
            return immediate
        }
        let finder = SelectionCapture.captureFromFinder()
        if !finder.isEmpty {
            store.stagedURLs = finder
            return finder
        }
        let picked = store.pickFiles(types: types, multiple: true)
        if !picked.isEmpty {
            store.stagedURLs = picked
        }
        return picked
    }

    private func triggerWedge(_ idx: Int, with urls: [URL]) {
        guard !urls.isEmpty else { return }
        store.stagedURLs = urls
        if idx == -1 {
            presentQuickConvertMenu(for: urls)
        } else if wedges.indices.contains(idx) {
            wedges[idx].action(urls)
        }
    }

    private func handleClick(_ pt: CGPoint) {
        switch hitTest(pt) {
        case .none:
            store.toggleWheel(false)
        case .center:
            let urls = resolveInputFiles(for: [.item])
            if !urls.isEmpty {
                presentQuickConvertMenu(for: urls)
            } else {
                store.onCheckAutoClose?()
            }
        case .wedge(let idx):
            guard wedges.indices.contains(idx) else { return }
            let w = wedges[idx]
            let picked = resolveInputFiles(for: w.types)
            if !picked.isEmpty {
                w.action(picked)
            } else {
                store.onCheckAutoClose?()
            }
        }
    }

    private func handleDrop(_ urls: [URL], at pt: CGPoint) {
        store.stagedURLs = urls
        switch hitTest(pt) {
        case .none, .center:
            presentQuickConvertMenu(for: urls)
        case .wedge(let idx):
            guard wedges.indices.contains(idx) else { return }
            wedges[idx].action(urls)
        }
    }

    var body: some View {
        ZStack {
            if let menu = store.activeMenu {
                // Morphs from Circular Wheel into a Spacious Rounded-Rectangle Clear Glass Card
                actionMenuCard(menu)
                    .frame(width: 396, height: 454)
                    .clearGlassRect(radius: 34)
                    .transition(.scale(scale: 0.90).combined(with: .opacity))
            } else {
                // Circular Clear Liquid Glass Radial Drop Wheel (WheelHitOverlay placed ABOVE glassEffect so drag & drop works natively!)
                ZStack {
                    ZStack {
                        Circle()
                            .fill(
                                RadialGradient(
                                    colors: [Color.white.opacity(0.08), Color.white.opacity(0.02)],
                                    center: .topLeading,
                                    startRadius: 8,
                                    endRadius: wheelSize * 0.85
                                )
                            )
                            .overlay(
                                Circle()
                                    .strokeBorder(
                                        LinearGradient(
                                            colors: [
                                                Color.white.opacity(0.75),
                                                Color.white.opacity(0.20),
                                                Color.white.opacity(0.48)
                                            ],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        ),
                                        lineWidth: 1.5
                                    )
                            )

                        // 8 Clear Glass Pie-Slice Wedges with Crisp Icons & Labels
                        ForEach(wedges) { w in
                            wedgeSlice(w)
                                .allowsHitTesting(false)
                        }

                        // Clear Glass Center Hub with Crisp Icon & Label
                        centerHub
                            .allowsHitTesting(false)
                    }
                    .frame(width: wheelSize + 18, height: wheelSize + 18)
                    .clearGlassCircle()
                    .allowsHitTesting(false)

                    // Top-level Polar Hit-Testing, Drag-to-Move & File Drop Overlay (outside glassEffect)
                    WheelHitOverlay(
                        onHoverPoint: { pt in updateHover(pt) },
                        onClickPoint: { pt in handleClick(pt) },
                        onDropURLs: { urls, pt in handleDrop(urls, at: pt) },
                        onWindowMoved: { origin in onWindowMoved(origin) }
                    )
                    .frame(width: wheelSize + 18, height: wheelSize + 18)
                }
                .frame(width: wheelSize + 18, height: wheelSize + 18)
                .transition(.scale(scale: 0.92).combined(with: .opacity))
            }
        }
        .shadow(color: .black.opacity(0.22), radius: 22, y: 8)
        .animation(.spring(response: 0.32, dampingFraction: 0.80), value: store.activeMenu?.id)
        .onAppear {
            store.onTriggerWedge = { idx, urls in
                triggerWedge(idx, with: urls)
            }
            store.onHoverWheelPoint = { pt in
                updateHover(pt)
            }
            store.onDropWheelURLs = { urls, pt in
                handleDrop(urls, at: pt)
            }
        }
    }

    // MARK: - Transformed Clear Glass Card for Contextual Action List
    @ViewBuilder
    private func actionMenuCard(_ menu: WheelActionMenu) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.10), Color.white.opacity(0.02)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 34, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.78),
                                    Color.white.opacity(0.20),
                                    Color.white.opacity(0.48)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.5
                        )
                )

            VStack(spacing: 14) {
                // Header Bar: Back to Wheel + Action Title + Close Button
                HStack(spacing: 10) {
                    Button {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.80)) {
                            store.activeMenu = nil
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 10.5, weight: .bold))
                            Text("Wheel")
                                .font(.system(size: 11.5, weight: .bold, design: .rounded))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.white.opacity(0.18)))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.48), lineWidth: 1))
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Text(menu.wedgeTitle.uppercased())
                        .font(.system(size: 12.5, weight: .heavy, design: .rounded))
                        .tracking(0.9)
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.45), radius: 2, y: 1)

                    Spacer()

                    Button {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                            store.activeMenu = nil
                        }
                        store.onCheckAutoClose?()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(Color.white.opacity(0.18)))
                            .overlay(Circle().strokeBorder(Color.white.opacity(0.48), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 22)
                .padding(.top, 22)

                // Auto-Detected File Type Badge Pill
                HStack(spacing: 8) {
                    Image(systemName: menu.detectedIcon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(menu.detectedBadge)
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.96))
                        .lineLimit(1)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity)
                .background(Capsule().fill(Color.white.opacity(0.16)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.45), lineWidth: 1))
                .shadow(color: .black.opacity(0.20), radius: 3, y: 1)
                .padding(.horizontal, 22)

                // Well-Padded Scrollable Options List
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 10) {
                        ForEach(menu.options) { opt in
                            let isRowHot = hoveredOptionID == opt.id
                            Button {
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                                    store.activeMenu = nil
                                }
                                opt.action()
                            } label: {
                                HStack(spacing: 14) {
                                    ZStack {
                                        Circle()
                                            .fill(Color.white.opacity(isRowHot ? 0.30 : 0.16))
                                            .frame(width: 36, height: 36)
                                            .overlay(Circle().strokeBorder(Color.white.opacity(0.48), lineWidth: 1))
                                        Image(systemName: opt.icon)
                                            .font(.system(size: 14.5, weight: .semibold))
                                            .foregroundStyle(.white)
                                    }

                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(opt.title)
                                            .font(.system(size: 13.5, weight: .bold, design: .rounded))
                                            .foregroundStyle(.white)
                                            .lineLimit(1)
                                        Text(opt.subtitle)
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundStyle(.white.opacity(0.86))
                                            .lineLimit(1)
                                    }

                                    Spacer(minLength: 8)

                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(.white.opacity(isRowHot ? 1.0 : 0.75))
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                                .background(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .fill(Color.white.opacity(isRowHot ? 0.26 : 0.12))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .strokeBorder(
                                            Color.white.opacity(isRowHot ? 0.82 : 0.40),
                                            lineWidth: isRowHot ? 1.5 : 1.0
                                        )
                                )
                                .scaleEffect(isRowHot ? 1.015 : 1.0)
                                .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
                            }
                            .buttonStyle(.plain)
                            .onHover { hovering in
                                withAnimation(.easeOut(duration: 0.14)) {
                                    if hovering {
                                        hoveredOptionID = opt.id
                                    } else if hoveredOptionID == opt.id {
                                        hoveredOptionID = nil
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 4)
                }
                .padding(.bottom, 18)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
    }

    @ViewBuilder
    private func wedgeSlice(_ w: WedgeSpec) -> some View {
        let count = Double(wedges.count)
        let step = 360.0 / count
        let centerDeg = Double(w.id) * step - 90.0
        let gap = 1.6
        let startDeg = centerDeg - step / 2.0 + gap
        let endDeg = centerDeg + step / 2.0 - gap
        let isHot = activeWedge == w.id
        let shape = AnnularWedgeShape(startDegrees: startDeg, endDegrees: endDeg, innerRadiusRatio: 0.32)

        let rad = centerDeg * .pi / 180.0
        let labelRadius = wheelSize * 0.335
        let lx = cos(rad) * labelRadius
        let ly = sin(rad) * labelRadius

        ZStack {
            shape
                .fill(
                    isHot
                        ? LinearGradient(
                            colors: [Color.white.opacity(0.38), Color.white.opacity(0.18)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        : LinearGradient(
                            colors: [Color.white.opacity(0.12), Color.white.opacity(0.04)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                )
                .overlay(
                    shape.stroke(
                        Color.white.opacity(isHot ? 0.92 : 0.36),
                        lineWidth: isHot ? 2.0 : 1.0
                    )
                )

            VStack(spacing: 2) {
                Image(systemName: w.icon)
                    .font(.system(size: isHot ? 18 : 15.5, weight: .semibold))
                    .foregroundStyle(.white)
                Text(w.label)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(w.subtitle)
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(isHot ? 0.96 : 0.80))
                    .lineLimit(1)
            }
            .shadow(color: .black.opacity(0.55), radius: 3, y: 1)
            .scaleEffect(isHot ? 1.10 : 1.0)
            .offset(x: lx, y: ly)
        }
        .frame(width: wheelSize, height: wheelSize)
        .animation(.spring(response: 0.18, dampingFraction: 0.75), value: isHot)
    }

    private var centerHub: some View {
        let current = activeWedge.flatMap { id in wedges.first(where: { $0.id == id }) }
        let hubDiameter = wheelSize * 0.30
        let hasStaged = !store.stagedURLs.isEmpty

        return ZStack {
            Circle()
                .fill(Color.white.opacity(centerTargeted ? 0.28 : (hasStaged ? 0.18 : 0.12)))
                .frame(width: hubDiameter, height: hubDiameter)
                .overlay(
                    Circle()
                        .strokeBorder(
                            Color.white.opacity(centerTargeted || current != nil || hasStaged ? 0.88 : 0.50),
                            lineWidth: centerTargeted ? 2.2 : 1.4
                        )
                )
                .shadow(color: .black.opacity(0.22), radius: 8)

            if store.wheelBusy {
                VStack(spacing: 5) {
                    ProgressView()
                        .controlSize(.small)
                    Text("WORKING")
                        .font(.system(size: 9, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                }
                .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
            } else if let current {
                VStack(spacing: 3) {
                    Image(systemName: current.icon)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(current.label.uppercased())
                        .font(.system(size: 9.5, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                    Text(hasStaged ? "Click or release ⇧+Z" : "Drop or Click")
                        .font(.system(size: 8.0, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.88))
                        .lineLimit(1)
                }
                .padding(8)
                .shadow(color: .black.opacity(0.55), radius: 3, y: 1)
            } else if hasStaged {
                let first = store.stagedURLs[0]
                let info = describeFiles(store.stagedURLs)
                VStack(spacing: 3) {
                    Image(systemName: centerTargeted ? "bolt.horizontal.circle.fill" : info.icon)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(store.stagedURLs.count == 1 ? first.lastPathComponent : "\(store.stagedURLs.count) FILES READY")
                        .font(.system(size: 9.0, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 10)
                    Text(centerTargeted ? "Quick Convert" : "Pick any wedge")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .shadow(color: .black.opacity(0.55), radius: 3, y: 1)
            } else {
                VStack(spacing: 3) {
                    Image(systemName: centerTargeted ? "arrow.down.circle.fill" : "bolt.horizontal.circle.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("QUICK CONVERT")
                        .font(.system(size: 9, weight: .heavy, design: .rounded))
                        .tracking(0.4)
                        .foregroundStyle(.white)
                    Text(centerTargeted ? "Release for menu" : "Drag to move")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.80))
                }
                .shadow(color: .black.opacity(0.55), radius: 3, y: 1)
            }
        }
        .scaleEffect(centerTargeted ? 1.08 : 1.0)
        .animation(.spring(duration: 0.18), value: centerTargeted)
        .animation(.easeOut(duration: 0.14), value: activeWedge)
    }

    // MARK: - Auto-Detection Helpers & Contextual Menus for Every Wedge
    private func describeFiles(_ urls: [URL]) -> (kind: FileKind, badge: String, icon: String) {
        let resolved = urls.map { Engine.resolveFileURL($0) }
        guard let first = resolved.first else {
            return (.other, "No file", "doc.fill")
        }
        let kind = FileKind.of(first)
        let ext = first.pathExtension.uppercased()
        let size = Engine.sizeString(resolved)
        let countStr = resolved.count == 1 ? first.lastPathComponent : "\(resolved.count) \(ext) files"

        switch kind {
        case .image:
            return (.image, "\(ext.isEmpty ? "Image" : ext) Image · \(countStr) (\(size))", "photo.fill")
        case .audio:
            return (.audio, "\(ext.isEmpty ? "Audio" : ext) Audio · \(countStr) (\(size))", "waveform")
        case .video:
            return (.video, "\(ext.isEmpty ? "Video" : ext) Video · \(countStr) (\(size))", "film.fill")
        case .pdf:
            return (.pdf, "PDF Document · \(countStr) (\(size))", "doc.richtext.fill")
        case .document:
            return (.document, "\(ext.isEmpty ? "Document" : ext) Document · \(countStr) (\(size))", "doc.text.fill")
        case .other:
            return (.other, "\(ext) File · \(countStr) (\(size))", "doc.fill")
        }
    }

    // 0. Quick Convert Menu (auto-detects Document / Image / Audio / Video / PDF and lists valid targets)
    private func presentQuickConvertMenu(for rawURLs: [URL]) {
        let urls = rawURLs.map { Engine.resolveFileURL($0) }
        let info = describeFiles(urls)
        let srcExt = urls.first?.pathExtension.lowercased() ?? ""
        var options: [WheelMenuOption] = []

        switch info.kind {
        case .document:
            if srcExt != "pdf" {
                options.append(WheelMenuOption(
                    title: "Convert to PDF (.pdf)",
                    subtitle: urls.count > 1 ? "Convert \(urls.count) documents to PDF" : "Paginated vector PDF document",
                    icon: "doc.richtext.fill"
                ) {
                    runBatchConvert(urls, to: .pdf)
                })
            }
            if srcExt != "docx" {
                options.append(WheelMenuOption(
                    title: "Convert to Word Document (.docx)",
                    subtitle: urls.count > 1 ? "Convert \(urls.count) files to editable Word format" : "Editable Microsoft Word document",
                    icon: "doc.text.fill"
                ) {
                    runBatchConvert(urls, to: .docx)
                })
            }
            if srcExt != "rtf" {
                options.append(WheelMenuOption(
                    title: "Convert to Rich Text (.rtf)",
                    subtitle: "Universal styled rich text document",
                    icon: "doc.richtext"
                ) {
                    runBatchConvert(urls, to: .rtf)
                })
            }
            if srcExt != "html" && srcExt != "htm" {
                options.append(WheelMenuOption(
                    title: "Convert to HTML (.html)",
                    subtitle: "Web document with responsive layout",
                    icon: "safari.fill"
                ) {
                    runBatchConvert(urls, to: .html)
                })
            }
            if srcExt != "txt" {
                options.append(WheelMenuOption(
                    title: "Convert to Plain Text (.txt)",
                    subtitle: "Clean unformatted text document",
                    icon: "doc.plaintext"
                ) {
                    runBatchConvert(urls, to: .txt)
                })
            }
            options.append(WheelMenuOption(
                title: "Convert Page 1 → PNG (.png)",
                subtitle: "Render first page as high-res PNG image",
                icon: "photo.badge.arrow.down"
            ) {
                runBatchConvert(urls, to: .png)
            })
            options.append(WheelMenuOption(
                title: "Convert Page 1 → JPEG (.jpg)",
                subtitle: "Render first page as JPEG photo",
                icon: "photo.fill"
            ) {
                runBatchConvert(urls, to: .jpeg)
            })
            options.append(WheelMenuOption(
                title: "Extract Text to Clipboard",
                subtitle: "Extract document body text and copy to clipboard",
                icon: "text.viewfinder"
            ) {
                runOCR(urls)
            })
            if urls.count >= 2 {
                options.append(WheelMenuOption(
                    title: "Convert & Merge \(urls.count) Documents into 1 PDF",
                    subtitle: "Render each document and combine pages in order",
                    icon: "square.stack.3d.up.fill"
                ) {
                    runTask {
                        var pdfs: [URL] = []
                        for u in urls {
                            pdfs.append(try Engine.convertDocumentToPDF(u, dir: store.outputDir))
                        }
                        return try Engine.mergePDFs(pdfs, dir: store.outputDir)
                    }
                })
            }

        case .image, .other:
            // 1. AI Super-Resolution Upscaling Options
            options.append(WheelMenuOption(
                title: "AI Super-Resolution 2× (200%)",
                subtitle: "Double dimensions with crisp edge reconstruction",
                icon: "sparkles"
            ) {
                runBatchUpscale(urls, scale: 2.0)
            })
            options.append(WheelMenuOption(
                title: "AI Super-Resolution 4× (400%)",
                subtitle: "Quadruple dimensions into crisp Ultra HD",
                icon: "wand.and.stars"
            ) {
                runBatchUpscale(urls, scale: 4.0)
            })
            options.append(WheelMenuOption(
                title: "Upscale to 4K Ultra HD (3840 px)",
                subtitle: "Boost image long edge to 4K resolution",
                icon: "tv.fill"
            ) {
                runBatchUpscale(urls, targetDimension: 3840)
            })

            let imageTargets: [(Target, String, String)] = [
                (.png, "PNG (.png)", "Lossless image with transparency"),
                (.jpeg, "JPEG (.jpg)", "Compact universal photo"),
                (.heic, "HEIC (.heic)", "Apple high-efficiency photo"),
                (.gif, "GIF (.gif)", "Web graphics format"),
                (.tiff, "TIFF (.tiff)", "Uncompressed print archival"),
                (.bmp, "BMP (.bmp)", "Uncompressed bitmap")
            ]
            // Sort so formats different from the source extension appear first
            let sorted = imageTargets.sorted { a, b in
                let aSame = (a.0.ext == srcExt || (a.0 == .jpeg && srcExt == "jpeg"))
                let bSame = (b.0.ext == srcExt || (b.0 == .jpeg && srcExt == "jpeg"))
                return !aSame && bSame
            }
            for (t, title, sub) in sorted {
                options.append(WheelMenuOption(title: "Convert to \(title)", subtitle: sub, icon: "photo.badge.arrow.down") {
                    runBatchConvert(urls, to: t)
                })
            }
            options.append(WheelMenuOption(
                title: "Extract Text to Clipboard (OCR)",
                subtitle: "Recognize and copy all visible text via Apple Vision",
                icon: "text.viewfinder"
            ) {
                runOCR(urls)
            })

            options.append(WheelMenuOption(
                title: "Convert to PDF (.pdf)",
                subtitle: urls.count > 1 ? "Combine \(urls.count) images into 1 PDF" : "Save image as PDF page",
                icon: "doc.richtext.fill"
            ) {
                runTask { try Engine.imagesToPDF(urls, dir: store.outputDir) }
            })

        case .audio:
            let audioTargets: [(Target, String, String)] = [
                (.m4a, "M4A (.m4a)", "Apple AAC compressed audio"),
                (.wav, "WAV (.wav)", "Uncompressed studio PCM"),
                (.flac, "FLAC (.flac)", "Lossless compressed audio"),
                (.aiff, "AIFF (.aiff)", "Apple lossless PCM")
            ]
            let sorted = audioTargets.sorted { ($0.0.ext == srcExt) && !($1.0.ext == srcExt) ? false : !($0.0.ext == srcExt) }
            for (t, title, sub) in sorted {
                options.append(WheelMenuOption(title: "Convert to \(title)", subtitle: sub, icon: "waveform.circle.fill") {
                    runBatchConvert(urls, to: t)
                })
            }

        case .video:
            options.append(WheelMenuOption(title: "Convert to MP4 (H.264)", subtitle: "Universal video container", icon: "film.fill") {
                runBatchConvert(urls, to: .mp4)
            })
            options.append(WheelMenuOption(title: "Convert to MOV (QuickTime)", subtitle: "Apple native QuickTime video", icon: "video.fill") {
                runBatchConvert(urls, to: .mov)
            })
            options.append(WheelMenuOption(title: "Convert to Animated GIF", subtitle: "Looping GIF animation from clip", icon: "sparkles.tv.fill") {
                runBatchConvert(urls, to: .gif)
            })
            options.append(WheelMenuOption(title: "Extract Audio → M4A", subtitle: "Save audio track as AAC (.m4a)", icon: "waveform") {
                runBatchConvert(urls, to: .m4a)
            })
            options.append(WheelMenuOption(title: "Extract Audio → WAV", subtitle: "Save audio track as lossless PCM", icon: "waveform.badge.plus") {
                runBatchConvert(urls, to: .wav)
            })
            options.append(WheelMenuOption(title: "Extract Audio → FLAC", subtitle: "Save audio track as lossless FLAC", icon: "waveform.circle") {
                runBatchConvert(urls, to: .flac)
            })

        case .pdf:
            options.append(WheelMenuOption(
                title: "Convert to Word Document (.docx)",
                subtitle: urls.count > 1 ? "Convert \(urls.count) PDFs to editable Word format" : "Editable Microsoft Word document (.docx)",
                icon: "doc.text.fill"
            ) {
                runBatchConvert(urls, to: .docx)
            })
            options.append(WheelMenuOption(
                title: "Convert to Rich Text (.rtf)",
                subtitle: "Universal styled rich text document (.rtf)",
                icon: "doc.richtext"
            ) {
                runBatchConvert(urls, to: .rtf)
            })
            options.append(WheelMenuOption(
                title: "Convert to HTML (.html)",
                subtitle: "Web document with responsive layout (.html)",
                icon: "safari.fill"
            ) {
                runBatchConvert(urls, to: .html)
            })
            options.append(WheelMenuOption(
                title: "Convert to Plain Text (.txt)",
                subtitle: "Clean unformatted text document (.txt)",
                icon: "doc.plaintext"
            ) {
                runBatchConvert(urls, to: .txt)
            })
            options.append(WheelMenuOption(title: "Export All Pages → PNG", subtitle: "High-res PNG image per page", icon: "photo.on.rectangle.angled") {
                runTask {
                    let imgs = try Engine.exportPNGs(urls[0], dir: store.outputDir)
                    guard let first = imgs.first else { throw KQError.msg("No pages exported") }
                    return first
                }
            })
            options.append(WheelMenuOption(title: "Convert Page 1 → JPEG", subtitle: "Render cover page as JPG photo", icon: "photo.fill") {
                runBatchConvert(urls, to: .jpeg)
            })
            options.append(WheelMenuOption(title: "Convert Page 1 → HEIC", subtitle: "Render cover page as HEIC", icon: "photo.badge.checkmark") {
                runBatchConvert(urls, to: .heic)
            })
            options.append(WheelMenuOption(title: "Flatten PDF (Rasterize)", subtitle: "Lock pages as non-editable images", icon: "square.3.layers.3d.down.right") {
                runTask { try Engine.flattenPDF(urls[0], dir: store.outputDir) }
            })
            options.append(WheelMenuOption(title: "Extract Text to Clipboard (OCR)", subtitle: "Extract all text from PDF document", icon: "text.viewfinder") {
                runOCR(urls)
            })
            if urls.count >= 2 {
                options.append(WheelMenuOption(title: "Merge \(urls.count) PDFs into One", subtitle: "Combine documents in order", icon: "square.stack.3d.up.fill") {
                    runTask { try Engine.mergePDFs(urls, dir: store.outputDir) }
                })
            }
        }

        store.activeMenu = WheelActionMenu(
            wedgeTitle: "Quick Convert",
            detectedBadge: info.badge,
            detectedIcon: info.icon,
            options: options
        )
    }

    // 1. Upscale & Resize Menu (auto-detects Document / Image / Video / PDF / Audio)
    private func presentCompressMenu(for rawURLs: [URL]) {
        let urls = rawURLs.map { Engine.resolveFileURL($0) }
        let info = describeFiles(urls)
        var options: [WheelMenuOption] = []

        switch info.kind {
        case .document:
            options.append(WheelMenuOption(title: "Convert Document to PDF (.pdf)", subtitle: "Generate formatted compact PDF", icon: "doc.richtext.fill") {
                runBatchConvert(urls, to: .pdf)
            })
            options.append(WheelMenuOption(title: "Extract Text to Clipboard", subtitle: "Extract all text without formatting", icon: "text.viewfinder") {
                runOCR(urls)
            })

        case .image, .other:
            options.append(WheelMenuOption(
                title: "Super-Resolution 2× (200%)",
                subtitle: "Double dimensions with Lanczos edge enhancement",
                icon: "arrow.up.left.and.arrow.down.right"
            ) {
                runBatchUpscale(urls, scale: 2.0)
            })
            options.append(WheelMenuOption(
                title: "Super-Resolution 4× (400%)",
                subtitle: "Quadruple dimensions with crisp micro-contrast",
                icon: "sparkles"
            ) {
                runBatchUpscale(urls, scale: 4.0)
            })
            options.append(WheelMenuOption(
                title: "Upscale to 4K Ultra HD (3840 px)",
                subtitle: "Boost long edge to 4K with super-res",
                icon: "tv.fill"
            ) {
                runBatchUpscale(urls, targetDimension: 3840)
            })
            options.append(WheelMenuOption(
                title: "Upscale to 8K Master (7680 px)",
                subtitle: "Massive print & archival super-resolution",
                icon: "crown.fill"
            ) {
                runBatchUpscale(urls, targetDimension: 7680)
            })
            options.append(WheelMenuOption(title: "Smart Compress (60% Quality)", subtitle: "Shrink file size while keeping detail", icon: "arrow.down.right.and.arrow.up.left") {
                runTask { try Engine.compressImage(urls[0], dir: store.outputDir) }
            })
            options.append(WheelMenuOption(title: "Resize to 1080p (1920 px)", subtitle: "Full HD web & sharing size", icon: "photo.tv") {
                runBatchConvert(urls, to: .jpeg, quality: 0.82, maxPixel: 1920)
            })
            options.append(WheelMenuOption(title: "Resize to 720p (1280 px)", subtitle: "Lightweight email & chat size", icon: "photo") {
                runBatchConvert(urls, to: .jpeg, quality: 0.78, maxPixel: 1280)
            })
            options.append(WheelMenuOption(title: "Thumbnail (640 px)", subtitle: "Smallest preview image", icon: "square.resize.down") {
                runBatchConvert(urls, to: .jpeg, quality: 0.75, maxPixel: 640)
            })

        case .video:
            options.append(WheelMenuOption(title: "Compress 1080p MP4", subtitle: "High quality H.264 1920×1080", icon: "film.fill") {
                runAsyncTask { try await Engine.compressVideo(urls[0], preset: AVAssetExportPreset1920x1080, dir: store.outputDir) }
            })
            options.append(WheelMenuOption(title: "Compress 720p MP4", subtitle: "Balanced web & Discord size", icon: "video.badge.checkmark") {
                runAsyncTask { try await Engine.compressVideo(urls[0], preset: AVAssetExportPreset1280x720, dir: store.outputDir) }
            })
            options.append(WheelMenuOption(title: "Compress 540p Small MP4", subtitle: "Maximum file size reduction", icon: "arrow.down.circle.fill") {
                runAsyncTask { try await Engine.compressVideo(urls[0], preset: AVAssetExportPreset960x540, dir: store.outputDir) }
            })

        case .pdf:
            options.append(WheelMenuOption(title: "Compress & Flatten PDF (1.5×)", subtitle: "Rasterize pages at compact DPI", icon: "doc.zipper") {
                runTask { try Engine.flattenPDF(urls[0], dir: store.outputDir, scale: 1.5) }
            })
            options.append(WheelMenuOption(title: "Flatten Hi-Res PDF (2.0×)", subtitle: "Crisp rasterized PDF", icon: "doc.richtext") {
                runTask { try Engine.flattenPDF(urls[0], dir: store.outputDir, scale: 2.0) }
            })

        case .audio:
            options.append(WheelMenuOption(title: "Compress to M4A (AAC)", subtitle: "Compact high-efficiency audio", icon: "waveform") {
                runBatchConvert(urls, to: .m4a)
            })
        }

        store.activeMenu = WheelActionMenu(
            wedgeTitle: "Upscale & Resize",
            detectedBadge: info.badge,
            detectedIcon: info.icon,
            options: options
        )
    }

    // 2. Photo Edit Menu
    private func presentPhotoEditMenu(for rawURLs: [URL]) {
        let urls = rawURLs.map { Engine.resolveFileURL($0) }
        guard let first = urls.first else { return }
        let info = describeFiles(urls)

        let options: [WheelMenuOption] = [
            WheelMenuOption(title: "AI Super-Resolution 2× Upscale", subtitle: "Double dimensions with zero blur", icon: "sparkles") {
                runBatchUpscale([first], scale: 2.0)
            },
            WheelMenuOption(title: "AI Super-Resolution 4× Upscale", subtitle: "Quadruple into crisp Ultra HD", icon: "wand.and.stars") {
                runBatchUpscale([first], scale: 4.0)
            },
            WheelMenuOption(title: "Adjust Exposure & Color…", subtitle: "Open studio sliders & presets", icon: "slider.horizontal.3") {
                store.handoff(url: first, tab: .photo, photoMode: .adjust, audioMode: nil)
            },
            WheelMenuOption(title: "Crop & Aspect Ratio…", subtitle: "1:1, 16:9, 4:5 or freeform crop", icon: "crop") {
                store.handoff(url: first, tab: .photo, photoMode: .crop, audioMode: nil)
            },
            WheelMenuOption(title: "Studio Frame & Backdrop…", subtitle: "Add rounded padding & gradient", icon: "rectangle.inset.filled") {
                store.handoff(url: first, tab: .photo, photoMode: .background, audioMode: nil)
            },
            WheelMenuOption(title: "Annotate & Arrows…", subtitle: "Draw callouts, boxes & highlights", icon: "pencil.tip.crop.circle") {
                store.handoff(url: first, tab: .photo, photoMode: .annotate, audioMode: nil)
            }
        ]

        store.activeMenu = WheelActionMenu(
            wedgeTitle: "Photo Edit",
            detectedBadge: info.badge,
            detectedIcon: info.icon,
            options: options
        )
    }

    // 3. Redact Menu
    private func presentRedactMenu(for rawURLs: [URL]) {
        let urls = rawURLs.map { Engine.resolveFileURL($0) }
        guard let first = urls.first else { return }
        let info = describeFiles(urls)
        var options: [WheelMenuOption] = []

        if info.kind == .pdf {
            options.append(WheelMenuOption(title: "Flatten PDF (Lock Text Layers)", subtitle: "Convert text to unselectable pixels", icon: "lock.doc.fill") {
                runTask { try Engine.flattenPDF(first, dir: store.outputDir) }
            })
        }
        options.append(WheelMenuOption(title: "Draw Blur / Pixelate / Blackout…", subtitle: "Interactive privacy redaction brush", icon: "eye.slash.fill") {
            store.handoff(url: first, tab: .photo, photoMode: .redact, audioMode: nil)
        })
        options.append(WheelMenuOption(title: "Scrub EXIF & Save Clean Copy", subtitle: "Strip hidden GPS & camera serials", icon: "shield.lefthalf.filled") {
            runStripMetadata(urls)
        })

        store.activeMenu = WheelActionMenu(
            wedgeTitle: "Redact & Privacy",
            detectedBadge: info.badge,
            detectedIcon: info.icon,
            options: options
        )
    }

    // 4. Strip EXIF Menu
    private func presentStripEXIFMenu(for rawURLs: [URL]) {
        let urls = rawURLs.map { Engine.resolveFileURL($0) }
        guard let first = urls.first else { return }
        let meta = Engine.readMetadata(first)
        let sensitiveCount = meta.map(\.0).filter(Engine.isSensitive).count
        let metaSummary = sensitiveCount > 0
            ? "\(sensitiveCount) Sensitive GPS/Device Tag(s) Found"
            : "\(meta.count) Metadata Tag(s) Detected"

        let options: [WheelMenuOption] = [
            WheelMenuOption(title: "Strip All EXIF & GPS Immediately", subtitle: "Save sanitized copy in original format", icon: "lock.shield.fill") {
                runStripMetadata(urls)
            },
            WheelMenuOption(title: "Strip EXIF + Convert to PNG", subtitle: "Clean lossless PNG with zero metadata", icon: "photo.badge.checkmark") {
                runBatchConvert(urls, to: .png)
            },
            WheelMenuOption(title: "Strip EXIF + Convert to JPG", subtitle: "Clean compact JPEG with zero metadata", icon: "photo.fill") {
                runBatchConvert(urls, to: .jpeg)
            },
            WheelMenuOption(title: "Inspect All Metadata Tags…", subtitle: "View full EXIF, GPS & camera table", icon: "magnifyingglass.circle.fill") {
                store.tab = .privacy
                store.onOpenStudio?(.privacy)
            }
        ]

        store.activeMenu = WheelActionMenu(
            wedgeTitle: "Strip EXIF",
            detectedBadge: metaSummary,
            detectedIcon: "lock.shield.fill",
            options: options
        )
    }

    // 5. PDF & Docs Menu
    private func presentPDFMenu(for rawURLs: [URL]) {
        let urls = rawURLs.map { Engine.resolveFileURL($0) }
        let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
        let docs = urls.filter { FileKind.of($0) == .document }
        let images = urls.filter { FileKind.of($0) == .image }
        let info = describeFiles(urls)
        var options: [WheelMenuOption] = []

        if !pdfs.isEmpty {
            options.append(WheelMenuOption(
                title: pdfs.count == 1 ? "Convert PDF → Word (.docx)" : "Convert \(pdfs.count) PDFs → Word (.docx)",
                subtitle: "Editable Microsoft Word document",
                icon: "doc.text.fill"
            ) {
                runBatchConvert(pdfs, to: .docx)
            })
            options.append(WheelMenuOption(
                title: pdfs.count == 1 ? "Convert PDF → Rich Text (.rtf)" : "Convert \(pdfs.count) PDFs → Rich Text",
                subtitle: "Universal styled rich text format",
                icon: "doc.richtext"
            ) {
                runBatchConvert(pdfs, to: .rtf)
            })
            options.append(WheelMenuOption(
                title: pdfs.count == 1 ? "Convert PDF → HTML (.html)" : "Convert \(pdfs.count) PDFs → HTML",
                subtitle: "Web document with responsive layout",
                icon: "safari.fill"
            ) {
                runBatchConvert(pdfs, to: .html)
            })
            options.append(WheelMenuOption(
                title: pdfs.count == 1 ? "Convert PDF → Plain Text (.txt)" : "Convert \(pdfs.count) PDFs → Plain Text",
                subtitle: "Clean unformatted body text",
                icon: "doc.plaintext"
            ) {
                runBatchConvert(pdfs, to: .txt)
            })
        }

        if !docs.isEmpty {
            options.append(WheelMenuOption(
                title: docs.count == 1 ? "Convert Document → PDF (.pdf)" : "Convert \(docs.count) Documents to PDF",
                subtitle: "Formatted paginated vector PDF",
                icon: "doc.richtext.fill"
            ) {
                runBatchConvert(docs, to: .pdf)
            })
            let nonDocx = docs.filter { $0.pathExtension.lowercased() != "docx" }
            if !nonDocx.isEmpty {
                options.append(WheelMenuOption(
                    title: nonDocx.count == 1 ? "Convert Document → Word (.docx)" : "Convert \(nonDocx.count) Documents → Word (.docx)",
                    subtitle: "Editable Microsoft Word document",
                    icon: "doc.text.fill"
                ) {
                    runBatchConvert(nonDocx, to: .docx)
                })
            }
            let nonRtf = docs.filter { $0.pathExtension.lowercased() != "rtf" }
            if !nonRtf.isEmpty {
                options.append(WheelMenuOption(
                    title: nonRtf.count == 1 ? "Convert Document → Rich Text (.rtf)" : "Convert \(nonRtf.count) Documents → Rich Text",
                    subtitle: "Universal styled rich text format",
                    icon: "doc.richtext"
                ) {
                    runBatchConvert(nonRtf, to: .rtf)
                })
            }
            if docs.count >= 2 || (!docs.isEmpty && !pdfs.isEmpty) {
                options.append(WheelMenuOption(
                    title: "Convert & Merge All into 1 PDF",
                    subtitle: "Render documents & combine with PDFs in order",
                    icon: "square.stack.3d.up.fill"
                ) {
                    runTask {
                        var allPDFs: [URL] = []
                        for u in urls {
                            if u.pathExtension.lowercased() == "pdf" {
                                allPDFs.append(u)
                            } else if FileKind.of(u) == .document {
                                allPDFs.append(try Engine.convertDocumentToPDF(u, dir: store.outputDir))
                            } else if FileKind.of(u) == .image {
                                allPDFs.append(try Engine.imagesToPDF([u], dir: store.outputDir))
                            }
                        }
                        return try Engine.mergePDFs(allPDFs, dir: store.outputDir)
                    }
                })
            }
        }

        if pdfs.count >= 2 {
            options.append(WheelMenuOption(title: "Merge \(pdfs.count) PDFs into One", subtitle: "Combine documents into a single PDF", icon: "square.stack.3d.up.fill") {
                runTask { try Engine.mergePDFs(pdfs, dir: store.outputDir) }
            })
        }
        if let firstPDF = pdfs.first {
            options.append(WheelMenuOption(title: "Export All Pages as PNG", subtitle: "Save every PDF page as a crisp PNG", icon: "photo.on.rectangle") {
                runTask {
                    let imgs = try Engine.exportPNGs(firstPDF, dir: store.outputDir)
                    guard let first = imgs.first else { throw KQError.msg("No pages exported") }
                    return first
                }
            })
            options.append(WheelMenuOption(title: "Flatten PDF (Rasterize)", subtitle: "Bake annotations & remove text layer", icon: "square.3.layers.3d.down.right") {
                runTask { try Engine.flattenPDF(firstPDF, dir: store.outputDir) }
            })
            options.append(WheelMenuOption(title: "Reorder, Rotate & Delete Pages…", subtitle: "Open interactive PDF page organizer", icon: "doc.on.doc.fill") {
                store.pdf.load(pdfs)
                store.tab = .pdf
                store.onOpenStudio?(.pdf)
            })
        }
        if !images.isEmpty {
            options.append(WheelMenuOption(title: "Combine \(images.count) Image(s) → PDF", subtitle: "Create PDF document from images", icon: "doc.badge.plus") {
                runTask { try Engine.imagesToPDF(images, dir: store.outputDir) }
            })
        }

        store.activeMenu = WheelActionMenu(
            wedgeTitle: "PDF & Docs",
            detectedBadge: info.badge,
            detectedIcon: info.icon,
            options: options
        )
    }

    // 6. Audio Tools Menu
    private func presentAudioMenu(for rawURLs: [URL]) {
        let urls = rawURLs.map { Engine.resolveFileURL($0) }
        guard let first = urls.first else { return }
        let info = describeFiles(urls)

        let options: [WheelMenuOption] = [
            WheelMenuOption(title: "Trim & Censor Bleep Studio…", subtitle: "Waveform editor with 1kHz censor bleep", icon: "waveform.and.magnifyingglass") {
                store.handoff(url: first, tab: .audio, photoMode: nil, audioMode: .trim)
            },
            WheelMenuOption(title: "Channel Mixer & Gain Studio…", subtitle: "Mono/Stereo conversion & L/R gain", icon: "slider.vertical.3") {
                store.handoff(url: first, tab: .audio, photoMode: nil, audioMode: .bleep)
            },
            WheelMenuOption(title: "Convert to M4A (AAC)", subtitle: "Compact Apple audio format", icon: "waveform.circle.fill") {
                runBatchConvert(urls, to: .m4a)
            },
            WheelMenuOption(title: "Convert to WAV (Lossless PCM)", subtitle: "Uncompressed studio waveform", icon: "waveform") {
                runBatchConvert(urls, to: .wav)
            },
            WheelMenuOption(title: "Convert to FLAC (Lossless)", subtitle: "Lossless archival audio", icon: "waveform.badge.plus") {
                runBatchConvert(urls, to: .flac)
            }
        ]

        store.activeMenu = WheelActionMenu(
            wedgeTitle: "Audio Tools",
            detectedBadge: info.badge,
            detectedIcon: info.icon,
            options: options
        )
    }

    // 7. Extract Text (Neural OCR) & Scan QR Menu
    private func presentTextAndQRMenu(for rawURLs: [URL]) {
        let urls = rawURLs.map { Engine.resolveFileURL($0) }
        let first = urls.first

        var options: [WheelMenuOption] = []

        if let u = first {
            options.append(WheelMenuOption(
                title: "Copy All Text (Neural OCR)",
                subtitle: "Extract all visible text from image to clipboard",
                icon: "text.badge.checkmark"
            ) {
                runOCR([u])
            })

            options.append(WheelMenuOption(
                title: "Copy Text as Single Line",
                subtitle: "Join lines with space (clean URL, key, or code)",
                icon: "text.quote"
            ) {
                store.wheelBusy = true
                Task {
                    do {
                        let text = try await Task.detached {
                            try Engine.extractText(from: u)
                        }.value
                        await MainActor.run {
                            store.wheelBusy = false
                            let single = text.components(separatedBy: .newlines)
                                .map { $0.trimmingCharacters(in: .whitespaces) }
                                .filter { !$0.isEmpty }
                                .joined(separator: " ")
                            if single.isEmpty {
                                store.say("No text detected in image")
                            } else {
                                let pb = NSPasteboard.general
                                pb.clearContents()
                                pb.setString(single, forType: .string)
                                store.say("Copied text to clipboard!")
                            }
                            store.onCheckAutoClose?()
                        }
                    } catch {
                        await MainActor.run {
                            store.wheelBusy = false
                            store.say("OCR Error: \(error.localizedDescription)")
                            store.onCheckAutoClose?()
                        }
                    }
                }
            })

            options.append(WheelMenuOption(
                title: "Save Recognized Text as .txt",
                subtitle: "Write recognized text to a file in output folder",
                icon: "doc.text.fill"
            ) {
                store.wheelBusy = true
                Task {
                    do {
                        let text = try await Task.detached {
                            try Engine.extractText(from: u)
                        }.value
                        await MainActor.run {
                            store.wheelBusy = false
                            if text.isEmpty {
                                store.say("No text detected in image")
                            } else {
                                let outURL = Engine.outURL(u, ext: "txt", suffix: "-ocr", dir: store.outputDir)
                                try? text.write(to: outURL, atomically: true, encoding: .utf8)
                                store.done(outURL)
                            }
                            store.onCheckAutoClose?()
                        }
                    } catch {
                        await MainActor.run {
                            store.wheelBusy = false
                            store.say("OCR Error: \(error.localizedDescription)")
                            store.onCheckAutoClose?()
                        }
                    }
                }
            })
        }

        let codes: [String] = {
            guard let u = first, let cg = try? Engine.loadCGImage(u) else { return [] }
            return (try? Engine.scanQR(cg)) ?? []
        }()

        for code in codes {
            options.append(WheelMenuOption(title: "Copy QR \"\(code)\"", subtitle: "Copy decoded QR text to clipboard", icon: "doc.on.doc.fill") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code, forType: .string)
                store.say("Copied QR: \(code)")
                store.onCheckAutoClose?()
            })
            if let u = URL(string: code), let scheme = u.scheme?.lowercased(), ["http", "https"].contains(scheme) {
                options.append(WheelMenuOption(title: "Open QR Link in Browser", subtitle: code, icon: "safari.fill") {
                    NSWorkspace.shared.open(u)
                    store.onCheckAutoClose?()
                })
            }
        }

        options.append(WheelMenuOption(title: "Extract Text from Clipboard Image", subtitle: "OCR screenshot or image copied to clipboard", icon: "doc.on.clipboard") {
            if let img = NSImage(pasteboard: .general),
               let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                store.wheelBusy = true
                Task {
                    do {
                        let text = try Engine.extractText(cg)
                        await MainActor.run {
                            store.wheelBusy = false
                            if text.isEmpty {
                                store.say("No text found in clipboard image")
                            } else {
                                let pb = NSPasteboard.general
                                pb.clearContents()
                                pb.setString(text, forType: .string)
                                let count = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
                                store.say("Copied \(count) line\(count == 1 ? "" : "s") from clipboard!")
                            }
                            store.onCheckAutoClose?()
                        }
                    } catch {
                        await MainActor.run {
                            store.wheelBusy = false
                            store.say("OCR Error: \(error.localizedDescription)")
                            store.onCheckAutoClose?()
                        }
                    }
                }
            } else {
                store.say("No image found on clipboard")
                store.onCheckAutoClose?()
            }
        })

        options.append(WheelMenuOption(title: "Scan QR Code from Clipboard", subtitle: "Decode QR code from copied screenshot", icon: "qrcode") {
            if let img = NSImage(pasteboard: .general),
               let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil),
               let found = (try? Engine.scanQR(cg))?.first {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(found, forType: .string)
                store.say("Copied QR: \(found)")
            } else {
                store.say("No QR code found on clipboard")
            }
            store.onCheckAutoClose?()
        })

        options.append(WheelMenuOption(title: "Open Full QR Scanner…", subtitle: "Inspect multiple QR payloads", icon: "qrcode.viewfinder") {
            store.tab = .qr
            store.onOpenStudio?(.qr)
        })

        let badge = !codes.isEmpty ? "\(codes.count) QR Code(s) + Neural OCR" : "Apple Vision Neural OCR"
        store.activeMenu = WheelActionMenu(
            wedgeTitle: "Extract Text",
            detectedBadge: badge,
            detectedIcon: "text.viewfinder",
            options: options
        )
    }

    private func runOCR(_ urls: [URL]) {
        guard let first = urls.first else { return }
        store.wheelBusy = true
        Task {
            do {
                let text = try await Task.detached {
                    try Engine.extractText(from: first)
                }.value

                await MainActor.run {
                    store.wheelBusy = false
                    if text.isEmpty {
                        store.say("No text detected in image")
                    } else {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(text, forType: .string)
                        let count = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
                        store.say("Copied \(count) line\(count == 1 ? "" : "s") to clipboard!")
                    }
                    store.onCheckAutoClose?()
                }
            } catch {
                await MainActor.run {
                    store.wheelBusy = false
                    store.say("OCR Error: \(error.localizedDescription)")
                    store.onCheckAutoClose?()
                }
            }
        }
    }

    // MARK: - Execution Helpers
    private func runBatchUpscale(_ urls: [URL], scale: Double? = nil, targetDimension: Int? = nil) {
        let targetDir = store.outputDir
        store.wheelBusy = true
        Task {
            var lastOut: URL?
            var count = 0
            for u in urls {
                do {
                    let out = try await Task.detached(priority: .userInitiated) {
                        try Engine.upscaleImage(u, scale: scale, targetDimension: targetDimension, dir: targetDir)
                    }.value
                    store.addRecent(out)
                    lastOut = out
                    count += 1
                } catch {
                    store.say("Upscale Error: \(error.localizedDescription)")
                }
            }
            store.wheelBusy = false
            if let lastOut {
                store.copyToClipboard(lastOut, announce: false)
                let tag = targetDimension != nil ? (targetDimension! >= 7000 ? "8K" : "4K") : "\(Int(scale ?? 2.0))×"
                store.say("Upscaled \(count) image\(count == 1 ? "" : "s") → \(tag) Super-Res!")
            }
            try? await Task.sleep(for: .seconds(0.9))
            store.onCheckAutoClose?()
        }
    }

    private func runBatchConvert(_ urls: [URL], to target: Target, quality: Double = 0.90, maxPixel: Int = 0) {
        store.wheelBusy = true
        Task {
            var lastOut: URL?
            var count = 0
            for u in urls {
                do {
                    let out = try await Engine.convert(u, to: target, quality: quality, maxPixel: maxPixel, dir: store.outputDir)
                    store.addRecent(out)
                    lastOut = out
                    count += 1
                } catch {
                    store.say("Error: \(error.localizedDescription)")
                }
            }
            store.wheelBusy = false
            if let lastOut {
                let actualExt = lastOut.pathExtension.uppercased()
                store.copyToClipboard(lastOut, announce: false)
                store.say("Converted \(count) file\(count == 1 ? "" : "s") → \(actualExt)")
            }
            try? await Task.sleep(for: .seconds(0.9))
            store.onCheckAutoClose?()
        }
    }

    private func runStripMetadata(_ urls: [URL]) {
        store.wheelBusy = true
        Task {
            var lastOut: URL?
            var count = 0
            for u in urls {
                do {
                    let out = try Engine.stripMetadata(u, dir: store.outputDir)
                    store.addRecent(out)
                    lastOut = out
                    count += 1
                } catch {
                    store.say("Error: \(error.localizedDescription)")
                }
            }
            store.wheelBusy = false
            if let lastOut {
                store.copyToClipboard(lastOut, announce: false)
                store.say("Stripped EXIF from \(count) file\(count == 1 ? "" : "s")")
            }
            try? await Task.sleep(for: .seconds(0.9))
            store.onCheckAutoClose?()
        }
    }

    private func runTask(_ block: @escaping () throws -> URL) {
        store.wheelBusy = true
        Task {
            do {
                let out = try block()
                store.done(out)
            } catch {
                store.say("Error: \(error.localizedDescription)")
            }
            store.wheelBusy = false
            try? await Task.sleep(for: .seconds(0.9))
            store.onCheckAutoClose?()
        }
    }

    private func runAsyncTask(_ block: @escaping () async throws -> URL) {
        store.wheelBusy = true
        Task {
            do {
                let out = try await block()
                store.done(out)
            } catch {
                store.say("Error: \(error.localizedDescription)")
            }
            store.wheelBusy = false
            try? await Task.sleep(for: .seconds(0.9))
            store.onCheckAutoClose?()
        }
    }
}

// MARK: - On-Demand Studio Container Window (for Photo Edit / Redact / Audio Trim / PDF Organize)
struct StudioContainerView: View {
    @EnvironmentObject var store: Store
    var onClose: () -> Void

    var body: some View {
        ZStack {
            AuroraBackground()

            VStack(spacing: 0) {
                HStack {
                    Button {
                        onClose()
                    } label: {
                        Label("Back to Drop Wheel (⇧)", systemImage: "circle.grid.cross.fill")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                    }
                    .buttonStyle(.soft)
                    .padding(.leading, 72)

                    Spacer()

                    HStack(spacing: 6) {
                        ForEach([Tab.photo, .audio, .pdf, .convert, .privacy, .qr]) { t in
                            Button {
                                store.tab = t
                            } label: {
                                Text(t.rawValue)
                                    .font(.system(size: 11.5, weight: store.tab == t ? .bold : .medium, design: .rounded))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .foregroundStyle(store.tab == t ? Color.black : Color.white.opacity(0.75))
                                    .background(
                                        Capsule().fill(store.tab == t ? Color.white.opacity(0.95) : Color.clear)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(4)
                    .background(Capsule().fill(Color.white.opacity(0.07)))

                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 6)

                Group {
                    switch store.tab {
                    case .home, .photo:
                        PhotoStudioView(m: store.photo)
                    case .audio:
                        AudioStudioView(m: store.audio)
                    case .pdf:
                        PDFToolsView()
                    case .convert:
                        ConvertView()
                    case .privacy:
                        PrivacyView()
                    case .qr:
                        QRView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            VStack {
                Spacer()
                ToastView()
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Convert View
struct ConvertItem: Identifiable {
    enum Status { case idle, working, done(URL), failed(String) }
    let id = UUID()
    let url: URL
    var status: Status = .idle
}

struct ConvertView: View {
    @EnvironmentObject var store: Store
    @State private var items: [ConvertItem] = []
    @State private var target: Target = .jpeg
    @State private var quality = 0.88
    @State private var maxPx = 0
    @State private var busy = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 20) {
                PageHeader(
                    title: "Universal Converter",
                    subtitle: "Convert images, audio and videos to standard formats with full quality control."
                )

                DropZone(
                    title: "Drop files to convert",
                    hint: "Images, Audio, or Videos · Batch processing supported",
                    symbol: "arrow.triangle.2.circlepath",
                    height: 160
                ) { urls in
                    items += urls.map { ConvertItem(url: $0) }
                }

                HStack(spacing: 16) {
                    Picker("Format", selection: $target) {
                        Section("Image") { ForEach(Target.allCases.filter { $0.kind == .image }) { Text($0.label).tag($0) } }
                        Section("Audio") { ForEach(Target.allCases.filter { $0.kind == .audio }) { Text($0.label).tag($0) } }
                        Section("Video") { ForEach(Target.allCases.filter { $0.kind == .video }) { Text($0.label).tag($0) } }
                    }
                    .frame(width: 180)

                    HStack {
                        Text("Quality")
                            .font(.system(size: 13, weight: .medium))
                        Slider(value: $quality, in: 0.4...1)
                            .frame(width: 100)
                        Text("\(Int(quality * 100))%")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .frame(width: 38)
                    }

                    if target.kind == .image {
                        Picker("Resize", selection: $maxPx) {
                            Text("Original").tag(0)
                            Text("4K (3840 px)").tag(3840)
                            Text("1080p (1920 px)").tag(1920)
                            Text("720p (1280 px)").tag(1280)
                            Text("Thumbnail (640 px)").tag(640)
                        }
                        .frame(width: 170)
                    }

                    Spacer()

                    if !items.isEmpty {
                        Button("Clear", systemImage: "trash") { items = [] }
                            .buttonStyle(.soft)
                            .disabled(busy)
                    }

                    Button(busy ? "Converting…" : "Convert All", systemImage: "bolt.fill") { run() }
                        .buttonStyle(.glow)
                        .disabled(items.isEmpty || busy)
                }
                .padding(14)
                .glass(16)

                if !items.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(items) { it in
                            HStack(spacing: 12) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: it.url.path))
                                    .resizable().frame(width: 28, height: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(it.url.lastPathComponent)
                                        .font(.system(size: 13, weight: .semibold))
                                        .lineLimit(1)
                                    Text(it.url.path)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.white.opacity(0.4))
                                        .lineLimit(1)
                                }
                                Spacer()
                                switch it.status {
                                case .idle:
                                    Text("Ready")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.5))
                                case .working:
                                    ProgressView().controlSize(.small)
                                case .done(let u):
                                    Button {
                                        store.reveal(u)
                                    } label: {
                                        Label("Show", systemImage: "checkmark.circle.fill")
                                            .foregroundStyle(Color.kqTeal)
                                    }
                                    .buttonStyle(.plain)
                                case .failed(let m):
                                    Text(m).font(.caption).foregroundStyle(.red).lineLimit(1)
                                }
                            }
                            .padding(12)
                            .glass(12)
                        }
                    }
                }
            }
            .padding(32)
        }
    }

    private func run() {
        busy = true
        Task {
            for i in items.indices {
                items[i].status = .working
                do {
                    let out = try await Engine.convert(items[i].url, to: target, quality: quality, maxPixel: maxPx, dir: store.outputDir)
                    items[i].status = .done(out)
                    store.addRecent(out)
                } catch {
                    items[i].status = .failed(error.localizedDescription)
                }
            }
            busy = false
            store.say("Conversion batch complete")
        }
    }
}

// MARK: - PDF Tools View
struct PDFToolsView: View {
    @EnvironmentObject var store: Store
    @ObservedObject var model = Store.shared.pdf

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 20) {
                PageHeader(
                    title: "PDF Tools",
                    subtitle: "Merge PDFs, reorder and rotate individual pages, flatten raster for privacy."
                )

                DropZone(
                    title: "Drop PDF documents",
                    hint: "Drop 1 PDF to inspect & reorder pages · Drop multiple to merge",
                    symbol: "doc.richtext.fill",
                    types: [.pdf],
                    height: 160
                ) { urls in
                    model.load(urls)
                }

                if !model.sources.isEmpty {
                    HStack(spacing: 12) {
                        Text("\(model.sources.count) document(s) loaded")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.7))
                        Spacer()

                        Button("Merge All", systemImage: "square.stack.3d.up") {
                            attempt { try Engine.mergePDFs(model.sources, dir: store.outputDir) }
                        }
                        .buttonStyle(.soft)
                        .disabled(model.sources.count < 2)

                        Button("Flatten", systemImage: "square.3.layers.3d.down.right") {
                            attempt { try Engine.flattenPDF(model.sources[0], dir: store.outputDir) }
                        }
                        .buttonStyle(.soft)
                        .disabled(model.sources.count != 1)

                        Button("Pages → PNG", systemImage: "photo.on.rectangle") {
                            attempt {
                                let imgs = try Engine.exportPNGs(model.sources[0], dir: store.outputDir)
                                return imgs.first ?? model.sources[0]
                            }
                        }
                        .buttonStyle(.soft)
                        .disabled(model.sources.count != 1)

                        Button("Save Reordered", systemImage: "square.and.arrow.down") {
                            attempt {
                                let ps = model.pages.map { it -> PDFPage in
                                    let c = it.page.copy() as! PDFPage
                                    c.rotation = (it.page.rotation + it.rotation) % 360
                                    return c
                                }
                                return try Engine.savePDF(pages: ps, source: model.sources[0], suffix: "-organized", dir: store.outputDir)
                            }
                        }
                        .buttonStyle(.glow)
                        .disabled(model.pages.isEmpty)
                    }
                    .padding(14)
                    .glass(16)

                    if !model.pages.isEmpty {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 16)], spacing: 16) {
                            ForEach(Array(model.pages.enumerated()), id: \.element.id) { i, p in
                                VStack(spacing: 8) {
                                    Image(nsImage: p.thumb)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(height: 160)
                                        .rotationEffect(.degrees(Double(p.rotation)))
                                        .animation(.spring(duration: 0.3), value: p.rotation)
                                        .shadow(color: .black.opacity(0.35), radius: 6)

                                    HStack(spacing: 6) {
                                        Button { move(i, -1) } label: { Image(systemName: "chevron.left") }
                                            .disabled(i == 0)
                                        Button { model.pages[i].rotation = (model.pages[i].rotation + 90) % 360 } label: { Image(systemName: "rotate.right") }
                                        Button { model.pages.remove(at: i) } label: { Image(systemName: "trash") }
                                            .tint(.red)
                                        Button { move(i, 1) } label: { Image(systemName: "chevron.right") }
                                            .disabled(i == model.pages.count - 1)
                                    }
                                    .buttonStyle(.soft)
                                    .controlSize(.small)

                                    Text("Page \(i + 1)")
                                        .font(.system(size: 11, weight: .bold, design: .rounded))
                                        .foregroundStyle(.white.opacity(0.5))
                                }
                                .padding(12)
                                .glass(14)
                            }
                        }
                    }
                }
            }
            .padding(32)
        }
    }

    private func move(_ i: Int, _ d: Int) {
        withAnimation { model.pages.swapAt(i, i + d) }
    }

    private func attempt(_ f: () throws -> URL) {
        do {
            let u = try f()
            store.done(u)
        } catch {
            store.say("Error: \(error.localizedDescription)")
        }
    }
}

// MARK: - Privacy View
struct PrivacyView: View {
    @EnvironmentObject var store: Store
    @State private var url: URL?
    @State private var rows: [(String, String)] = []

    var sensitive: [String] { rows.map(\.0).filter(Engine.isSensitive) }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 20) {
                PageHeader(
                    title: "EXIF & Privacy Guard",
                    subtitle: "Inspect hidden tracking metadata inside your photos and sanitize them before sharing."
                )

                DropZone(
                    title: "Drop a photo to inspect metadata",
                    hint: "Local on-device analysis · GPS location, device serials & camera metadata",
                    symbol: "eye.slash.fill",
                    types: [.image],
                    height: 160
                ) { urls in
                    url = urls[0]
                    rows = Engine.readMetadata(urls[0])
                }

                if let currentURL = url {
                    HStack {
                        if !sensitive.isEmpty {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.red)
                                Text("\(sensitive.count) sensitive field(s) detected (GPS location, camera, timestamps)")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.red)
                            }
                        } else {
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark.shield.fill")
                                    .foregroundStyle(.green)
                                Text(rows.isEmpty ? "No metadata found" : "Clean photo: No sensitive GPS/device leaks found")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.green)
                            }
                        }
                        Spacer()
                        Button("Sanitize & Save", systemImage: "wand.and.stars") {
                            do {
                                let o = try Engine.stripMetadata(currentURL, dir: store.outputDir)
                                store.done(o)
                            } catch {
                                store.say(error.localizedDescription)
                            }
                        }
                        .buttonStyle(.glow)
                    }
                    .padding(14)
                    .glass(16)

                    VStack(alignment: .leading, spacing: 10) {
                        Caption("Discovered Metadata Tags (\(rows.count))")
                        VStack(spacing: 4) {
                            ForEach(Array(rows.enumerated()), id: \.offset) { _, pair in
                                HStack {
                                    Text(pair.0)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(Engine.isSensitive(pair.0) ? .red : .white.opacity(0.7))
                                        .frame(width: 220, alignment: .leading)
                                    Text(pair.1)
                                        .font(.system(size: 12, weight: .regular))
                                        .foregroundStyle(.white.opacity(0.9))
                                        .textSelection(.enabled)
                                    Spacer()
                                }
                                .padding(.vertical, 6)
                                .padding(.horizontal, 10)
                                Divider().background(Color.white.opacity(0.06))
                            }
                        }
                        .padding(12)
                        .glass(14)
                    }
                }
            }
            .padding(32)
        }
    }
}

// MARK: - QR View
struct QRView: View {
    @EnvironmentObject var store: Store
    @State private var results: [String] = []
    @State private var preview: NSImage?
    @State private var scanned = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 20) {
                PageHeader(
                    title: "QR Code Scanner",
                    subtitle: "Scan QR codes instantly from images, screenshots, or paste directly with ⌘V."
                )

                HStack(spacing: 16) {
                    DropZone(
                        title: "Drop an image with a QR code",
                        hint: "Supports screenshots, photos, scans",
                        symbol: "qrcode.viewfinder",
                        types: [.image],
                        height: 160
                    ) { urls in
                        if let img = NSImage(contentsOf: urls[0]) { scan(img) }
                    }

                    Button {
                        if let img = NSImage(pasteboard: .general) {
                            scan(img)
                        } else {
                            store.say("No image found on clipboard")
                        }
                    } label: {
                        VStack(spacing: 10) {
                            Image(systemName: "doc.on.clipboard")
                                .font(.system(size: 28, weight: .medium))
                                .foregroundStyle(Color.kqOrange)
                            Text("Paste from Clipboard")
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                            Text("⌘V shortcut")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                        .frame(width: 200, height: 160)
                        .glass(22)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut("v")
                }

                if scanned {
                    HStack(alignment: .top, spacing: 20) {
                        if let preview {
                            Image(nsImage: preview)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: 240, maxHeight: 240)
                                .glass(14)
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            Caption("Detected QR Payloads")
                            if results.isEmpty {
                                Text("No QR codes detected in this image.")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.5))
                                    .padding(20)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .glass(14)
                            } else {
                                ForEach(results, id: \.self) { r in
                                    HStack {
                                        Text(r)
                                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                                            .textSelection(.enabled)
                                            .lineLimit(4)
                                        Spacer()
                                        if let u = URL(string: r), let scheme = u.scheme?.lowercased(), ["https", "http"].contains(scheme) {
                                            Button("Open Link", systemImage: "arrow.up.right.square") {
                                                NSWorkspace.shared.open(u)
                                            }
                                            .buttonStyle(.soft)
                                        }
                                        Button("Copy", systemImage: "doc.on.doc") {
                                            NSPasteboard.general.clearContents()
                                            NSPasteboard.general.setString(r, forType: .string)
                                            store.say("Copied payload")
                                        }
                                        .buttonStyle(.soft)
                                    }
                                    .padding(14)
                                    .glass(14)
                                }
                            }
                        }
                    }
                }
            }
            .padding(32)
        }
    }

    private func scan(_ img: NSImage) {
        preview = img
        scanned = true
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        results = (try? Engine.scanQR(cg)) ?? []
        if results.isEmpty {
            store.say("No QR codes found")
        } else {
            store.say("Found \(results.count) QR code(s)")
        }
    }
}
