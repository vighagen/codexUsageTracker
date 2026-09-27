import AppKit
import Foundation
import QuartzCore

// This usage client only reads usage. It never starts a model turn or consumes a reset.
final class UsageClient {
    var onUpdate: ((WeeklyUsage?, String?) -> Void)?
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var readBuffer = Data()
    private var initialized = false
    private var generation = 0
    private var nextID = 10
    private var pendingID: Int?
    private var timeout: DispatchWorkItem?
    private var timer: Timer?

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                         object: nil, queue: .main) { [weak self] _ in self?.refresh() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        disconnect()
    }

    private func disconnect() {
        generation += 1
        timeout?.cancel()
        timeout = nil
        pendingID = nil
        initialized = false
        output?.readabilityHandler = nil
        try? input?.close()
        if let process, process.isRunning { process.terminate() }
        process = nil
        input = nil
        output = nil
        readBuffer = Data()
    }

    func refresh() {
        guard pendingID == nil else { return }
        if initialized, process?.isRunning == true { requestUsage(); return }
        connect()
    }

    private func connect() {
        disconnect()
        let candidates = ["/Applications/ChatGPT.app/Contents/Resources/codex",
                          "/Applications/Codex.app/Contents/Resources/codex",
                          "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            onUpdate?(nil, "Codex was not found. Open Codex, then refresh."); return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = ["app-server", "--stdio"]
        p.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
        let stdinPipe = Pipe(), stdoutPipe = Pipe()
        p.standardInput = stdinPipe
        p.standardOutput = stdoutPipe
        p.standardError = FileHandle.nullDevice
        let connection = generation
        output = stdoutPipe.fileHandleForReading
        output?.readabilityHandler = { [weak self] file in
            let bytes = file.availableData
            DispatchQueue.main.async {
                guard let self, self.generation == connection else { return }
                if bytes.isEmpty { self.failed("Codex connection closed. Retrying shortly."); return }
                self.readBuffer.append(bytes)
                while let end = self.readBuffer.firstIndex(of: 10) {
                    let line = self.readBuffer.prefix(upTo: end)
                    self.readBuffer.removeSubrange(...end)
                    if let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                        self.receive(message)
                    }
                }
            }
        }
        do {
            try p.run()
            process = p
            input = stdinPipe.fileHandleForWriting
            armTimeout()
            send(["id": 1, "method": "initialize", "params": ["clientInfo": [
                "name": "codex_usage_tracker", "title": "Codex Usage Tracker", "version": "1.0.0"]]])
        } catch { failed("Could not open Codex. Open Codex, then refresh.") }
    }

    private func send(_ message: [String: Any]) {
        guard let input, var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(10)
        do { try input.write(contentsOf: data) }
        catch { failed("Codex connection unavailable. Retrying shortly.") }
    }

    private func requestUsage() {
        nextID += 1
        pendingID = nextID
        armTimeout()
        send(["id": nextID, "method": "account/rateLimits/read"])
    }

    private func armTimeout() {
        timeout?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.failed("Usage refresh timed out. Retrying shortly.") }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: work)
    }

    private func receive(_ message: [String: Any]) {
        if (message["id"] as? Int) == 1 {
            guard message["result"] != nil else { failed("Codex initialization failed."); return }
            initialized = true
            timeout?.cancel()
            send(["method": "initialized"])
            requestUsage()
        } else if let id = message["id"] as? Int, id == pendingID {
            pendingID = nil
            timeout?.cancel()
            if let result = message["result"] as? [String: Any] { publish(result) }
            else { onUpdate?(nil, "Usage unavailable. Check your Codex sign-in, then refresh.") }
        } else if (message["method"] as? String) == "account/rateLimits/updated",
                  let result = message["params"] as? [String: Any] { publish(result) }
        else if message["id"] != nil, message["method"] != nil {
            // No login, token, or other server-initiated actions are delegated to this widget.
            send(["id": message["id"]!, "error": ["code": -32601, "message": "Unsupported by usage-only client"]])
        }
    }

    private func publish(_ result: [String: Any]) {
        if let usage = WeeklyUsage.parse(result), usage.isCurrent() { onUpdate?(usage, nil) }
        else { onUpdate?(nil, "Weekly usage unavailable. Check your Codex account.") }
    }

    private func failed(_ reason: String) {
        disconnect()
        onUpdate?(nil, reason)
    }
}

final class OrbView: NSView {
    var usage: WeeklyUsage? { didSet { updateAccessibility(); needsDisplay = true } }
    var issue: String? { didSet { updateAccessibility(); needsDisplay = true } }
    var showMenu: ((NSEvent) -> Void)?
    var savePosition: (() -> Void)?
    var onAction: ((OrbAction) -> Void)?
    private var dragOrigin: NSPoint?
    private var mouseOrigin: NSPoint?
    private var tracking: NSTrackingArea?
    private var hoverClock = HoverClock()
    private var motionTimer: Timer?
    private var hoverPresenceTimer: Timer?
    private var frameTime: TimeInterval = 0
    private var shimmerStarted = false
    var palette: OrbPalette = .saved {
        didSet {
            chatButton.palette = palette; voiceButton.palette = palette
            refreshFrame()
        }
    }
    private func refreshFrame() {
        smokeFrame = smokeRenderer.frame(seconds: frameTime, palette: palette, shimmer: shimmerStarted)
        needsDisplay = true
    }
    private var smokeFrame: CGImage?
    private var isHovered = false
    private lazy var smokeRenderer = SmokeRenderer(url: Bundle.main.url(forResource: "smoky-quartz", withExtension: "png"))
    private let chatButton = OrbActionButton(action: .newChat)
    private let voiceButton = OrbActionButton(action: .voice)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for button in [chatButton, voiceButton] {
            button.isHidden = true; button.alphaValue = 0; button.palette = palette
            addSubview(button)
        }
        chatButton.onPress = { [weak self] in self?.onAction?(.newChat) }
        voiceButton.onPress = { [weak self] in self?.onAction?(.voice) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hoverPresenceTimer?.invalidate(); hoverPresenceTimer = nil
        guard let window else { setHovered(false); return }
        window.acceptsMouseMovedEvents = true
        // Also recognize an already-hovering pointer when a nonactivating panel opens.
        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            guard let self, let window = self.window else { return }
            let point = self.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            self.setHovered(window.isVisible && self.bounds.contains(point))
        }
        timer.tolerance = 0.03
        RunLoop.main.add(timer, forMode: .common)
        hoverPresenceTimer = timer
    }

    override func layout() {
        super.layout()
        chatButton.frame = NSRect(x: bounds.midX - 30, y: 1, width: 27, height: 27)
        voiceButton.frame = NSRect(x: bounds.midX + 3, y: 1, width: 27, height: 27)
    }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }
    private func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        let animate = hovered && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        hoverClock.setActive(animate, now: CACurrentMediaTime())
        motionTimer?.invalidate(); motionTimer = nil
        if animate {
            shimmerStarted = true
            let timer = Timer(timeInterval: 1 / 20, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.frameTime = self.hoverClock.phaseTime(at: CACurrentMediaTime())
                self.refreshFrame()
            }
            timer.tolerance = 0.01
            RunLoop.main.add(timer, forMode: .common)
            motionTimer = timer
        }
        if hovered { chatButton.isHidden = false; voiceButton.isHidden = false }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            chatButton.animator().alphaValue = hovered ? 1 : 0
            voiceButton.animator().alphaValue = hovered ? 1 : 0
        } completionHandler: { [weak self] in
            guard let self, !self.isHovered else { return }
            self.chatButton.isHidden = true; self.voiceButton.isHidden = true
        }
        needsDisplay = true
    }
    var currentUsage: WeeklyUsage? { issue == nil && usage?.isCurrent() == true ? usage : nil }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    private func updateAccessibility() {
        let text = currentUsage.map { "\($0.display) weekly limit remaining" } ?? "Weekly usage unavailable"
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Codex Usage Tracker. \(text).")
        toolTip = issue ?? "\(text)\nHover for chat and voice · Drag to move\nUpdates every minute"
    }

    private let artwork: NSImage? = Bundle.main.url(forResource: "smoky-quartz", withExtension: "png")
        .flatMap { NSImage(contentsOf: $0) }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.scaleBy(x: bounds.width / 104, y: bounds.height / 104)
        let available = currentUsage != nil
        // Preserve the supplied artwork's alpha; leave padding for the smoky silhouette.
        NSGraphicsContext.current?.imageInterpolation = .high
        if smokeFrame == nil { refreshFrame() }
        let rendered = smokeFrame.map { NSImage(cgImage: $0, size: NSSize(width: 312, height: 312)) } ?? artwork
        if let rendered {
            rendered.draw(in: NSRect(x: 3, y: 3, width: 98, height: 98),
                         from: .zero, operation: .sourceOver,
                         fraction: available ? 1 : 0.62, respectFlipped: true, hints: nil)
        } else {
            NSColor(calibratedRed: 0.18, green: 0.14, blue: 0.13, alpha: 0.97).setFill()
            NSBezierPath(ovalIn: NSRect(x: 23, y: 21, width: 58, height: 58)).fill()
        }
        // The glass sphere is slightly below the center of the full smoky asset.
        let center = NSPoint(x: 51.5, y: 49.5)
        let text = currentUsage?.display ?? "—"
        let fontSize: CGFloat = text == "100%" ? 18 : 20
        let font = NSFont(name: "Baskerville-SemiBold", size: fontSize)
            ?? NSFont.monospacedDigitSystemFont(ofSize: fontSize - 2, weight: .semibold)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(calibratedRed: 0.07, green: 0.035, blue: 0.02, alpha: 0.95)
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowBlurRadius = 3
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .kern: -0.4,
            .foregroundColor: NSColor(calibratedRed: 1, green: 0.94, blue: 0.84, alpha: 1),
            .shadow: shadow]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: NSPoint(x: center.x - size.width / 2,
                                           y: center.y - size.height / 2 + 1),
                               withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { showMenu?(event); return }
        dragOrigin = window?.frame.origin
        mouseOrigin = NSEvent.mouseLocation
    }
    override func mouseDragged(with event: NSEvent) {
        guard let dragOrigin, let mouseOrigin else { return }
        let point = NSEvent.mouseLocation
        window?.setFrameOrigin(NSPoint(x: dragOrigin.x + point.x - mouseOrigin.x,
                                       y: dragOrigin.y + point.y - mouseOrigin.y))
    }
    override func mouseUp(with event: NSEvent) { savePosition?() }
    override func rightMouseDown(with event: NSEvent) { showMenu?(event) }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NSPanel!
    private var orb: OrbView!
    private let client = UsageClient()
    private let codexActions = CodexActions()
    private var statusItem: NSStatusItem!
    private var redrawTimer: Timer?
    private var statusMenu: NSMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let defaults = UserDefaults.standard
        let saved = defaults.double(forKey: "orbSize")
        let size = [88.0, 104.0, 128.0].contains(saved) ? saved : 104
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        var origin = NSPoint(x: screen.maxX - size - 150, y: screen.minY + 48)
        if defaults.object(forKey: "orbX") != nil {
            let candidate = NSRect(x: defaults.double(forKey: "orbX"), y: defaults.double(forKey: "orbY"), width: size, height: size)
            if NSScreen.screens.contains(where: { $0.visibleFrame.contains(candidate) }) { origin = candidate.origin }
        }
        panel = NSPanel(contentRect: NSRect(origin: origin, size: NSSize(width: size, height: size)),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Codex Usage Tracker"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        orb = OrbView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        orb.autoresizingMask = [.width, .height]
        orb.issue = "Reading weekly usage…"
        orb.showMenu = { [weak self] event in
            guard let self else { return }
            NSMenu.popUpContextMenu(self.makeMenu(), with: event, for: self.orb)
        }
        orb.savePosition = { [weak self] in self?.savePosition() }
        orb.onAction = { [weak self] action in self?.codexActions.perform(action) }
        panel.contentView = orb
        panel.orderFrontRegardless()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "circle.dotted.circle.fill", accessibilityDescription: "Codex Usage Tracker")
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusClicked)
        statusItem.button?.toolTip = "Weekly Codex usage"
        client.onUpdate = { [weak self] usage, issue in
            guard let self else { return }
            self.orb.issue = issue
            self.orb.usage = usage
            self.statusItem.button?.toolTip = usage.map { "Codex Usage Tracker · \($0.display) weekly remaining" } ?? issue
        }
        client.start()
        redrawTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            guard let self else { return }
            if let usage = self.orb.usage, !usage.isCurrent() { self.orb.issue = "Refreshing weekly usage…" }
            self.orb.needsDisplay = true
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel?.orderFrontRegardless(); client.refresh(); return true
    }
    func applicationWillTerminate(_ notification: Notification) { client.stop(); savePosition() }
    private func savePosition() {
        guard let panel else { return }
        UserDefaults.standard.set(panel.frame.origin.x, forKey: "orbX")
        UserDefaults.standard.set(panel.frame.origin.y, forKey: "orbY")
    }
    private func makeMenu() -> NSMenu {
        let menu = NSMenu(title: "Codex Usage Tracker")
        let label = orb.currentUsage.map { "Weekly remaining: \($0.display)" } ?? "Weekly usage unavailable"
        menu.addItem(withTitle: label, action: nil, keyEquivalent: "")
        if let issue = orb.issue {
            menu.addItem(withTitle: issue, action: nil, keyEquivalent: "")
        } else if let usage = orb.usage {
            let updated = DateFormatter.localizedString(from: usage.fetchedAt, dateStyle: .none, timeStyle: .short)
            menu.addItem(withTitle: "Updated \(updated) · every minute", action: nil, keyEquivalent: "")
            if let reset = usage.resetsAt {
                let text = DateFormatter.localizedString(from: reset, dateStyle: .medium, timeStyle: .short)
                menu.addItem(withTitle: "Resets \(text)", action: nil, keyEquivalent: "")
            }
        }
        menu.addItem(.separator())
        let refresh = menu.addItem(withTitle: "Refresh now", action: #selector(refresh), keyEquivalent: "r"); refresh.target = self
        let reposition = menu.addItem(withTitle: "Bring orb into view", action: #selector(reposition), keyEquivalent: ""); reposition.target = self
        let sizeMenu = NSMenu(title: "Size")
        for (name, value) in [("Small", 88), ("Medium", 104), ("Large", 128)] {
            let item = sizeMenu.addItem(withTitle: name, action: #selector(resize(_:)), keyEquivalent: "")
            item.target = self; item.tag = value; item.state = Int(panel.frame.width) == value ? .on : .off
        }
        let colourMenu = NSMenu(title: "Colour scheme")
        for (index, palette) in OrbPalette.allCases.enumerated() {
            let item = colourMenu.addItem(withTitle: palette.rawValue, action: #selector(changePalette(_:)), keyEquivalent: "")
            item.target = self; item.tag = index
            item.state = orb.palette == palette ? .on : .off
        }
        let colours = menu.addItem(withTitle: "Colour scheme", action: nil, keyEquivalent: "")
        colours.submenu = colourMenu
        let sizes = menu.addItem(withTitle: "Size", action: nil, keyEquivalent: ""); sizes.submenu = sizeMenu
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Quit Codex Usage Tracker", action: #selector(quit), keyEquivalent: "q"); quit.target = self
        return menu
    }
    @objc private func statusClicked() {
        statusMenu = makeMenu()
        guard let button = statusItem.button else { return }
        statusMenu?.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
    }
    @objc private func changePalette(_ sender: NSMenuItem) {
        guard OrbPalette.allCases.indices.contains(sender.tag) else { return }
        orb.palette = OrbPalette.allCases[sender.tag]
        UserDefaults.standard.set(orb.palette.rawValue, forKey: "orbPalette")
    }
    @objc private func refresh() { client.refresh() }
    @objc private func quit() { NSApplication.shared.terminate(nil) }
    @objc private func resize(_ sender: NSMenuItem) {
        var frame = panel.frame
        frame.origin.x += (frame.width - CGFloat(sender.tag)) / 2
        frame.origin.y += (frame.height - CGFloat(sender.tag)) / 2
        frame.size = NSSize(width: sender.tag, height: sender.tag)
        panel.setFrame(frame, display: true)
        UserDefaults.standard.set(sender.tag, forKey: "orbSize")
        savePosition()
    }
    @objc private func reposition() {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: screen.maxX - panel.frame.width - 150, y: screen.minY + 48))
        panel.orderFrontRegardless()
        savePosition()
    }
}

if CommandLine.arguments.contains("--self-test") {
    runUsageTests()
    runInteractionTests()
} else {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
