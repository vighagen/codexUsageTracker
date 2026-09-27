import AppKit
import ApplicationServices
import CoreImage
import QuartzCore

enum OrbAction {
    case newChat, voice
    var symbol: String { self == .newChat ? "square.and.pencil" : "waveform" }
    var title: String { self == .newChat ? "New chat" : "Voice chat" }
}

enum OrbPalette: String, CaseIterable {
    case original = "Original", deepRed = "Deep red", mintGreen = "Mint green"
    case teal = "Teal", ivory = "Ivory", purple = "Purple"
    var rgb: (CGFloat, CGFloat, CGFloat) {
        switch self {
        case .original: return (0.68, 0.48, 0.32)
        case .deepRed: return (0.68, 0.08, 0.16)
        case .mintGreen: return (0.36, 0.86, 0.61)
        case .teal: return (0.05, 0.57, 0.59)
        case .ivory: return (0.91, 0.84, 0.65)
        case .purple: return (0.55, 0.25, 0.80)
        }
    }
    var accent: NSColor {
        let (r, g, b) = rgb
        return NSColor(calibratedRed: r, green: g, blue: b, alpha: 1)
    }
    static var saved: OrbPalette {
        OrbPalette(rawValue: UserDefaults.standard.string(forKey: "orbPalette") ?? "") ?? .original
    }
}

/// Time only advances while hovered. Exiting freezes the smoke at its current pose.
struct HoverClock {
    private(set) var elapsed: TimeInterval = 0
    private var startedAt: TimeInterval?
    var isActive: Bool { startedAt != nil }
    mutating func setActive(_ active: Bool, now: TimeInterval) {
        if active && startedAt == nil { startedAt = now }
        if !active, let start = startedAt { elapsed += max(0, now - start); startedAt = nil }
    }
    func phaseTime(at now: TimeInterval) -> TimeInterval {
        elapsed + (startedAt.map { max(0, now - $0) } ?? 0)
    }
}

final class SmokeRenderer {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var source: CIImage?
    private let extent = CGRect(x: 0, y: 0, width: 312, height: 312)
    private let kernel = CIWarpKernel(source: """
        kernel vec2 driftingSmoke(float phase) {
            vec2 p = destCoord();
            vec2 center = vec2(155.0, 151.0);
            // Leave the glass sphere and its rim completely unchanged.
            float smoke = smoothstep(91.0, 111.0, distance(p, center));
            float dx = 10.0 * (sin(p.y * 0.031 + phase) - sin(p.y * 0.031));
            float dy = 8.0 * (cos(p.x * 0.028 - phase) - cos(p.x * 0.028));
            return p + vec2(dx, dy) * smoke;
        }
        """)

    private let finish = CIColorKernel(source: """
        kernel vec4 crystalFinish(__sample pixel, vec3 tint, float recolor, float phase, float shimmer) {
            vec3 rgb = unpremultiply(pixel).rgb;
            float luminance = dot(rgb, vec3(0.2126, 0.7152, 0.0722));
            vec3 shade = mix(tint * 0.08, tint, smoothstep(0.0, 0.68, luminance));
            shade = mix(shade, vec3(1.0), smoothstep(0.60, 1.0, luminance));
            rgb = mix(rgb, shade, recolor);
            vec2 p = destCoord() - vec2(155.0, 151.0);
            float interior = 1.0 - smoothstep(70.0, 84.0, length(p));
            float sweep = (p.x * 0.85 + p.y * 0.40 - 64.0 * sin(phase)) / 22.0;
            float sheen = exp(-sweep * sweep) * interior * shimmer * 0.15;
            rgb = mix(rgb, vec3(1.0, 0.98, 0.94), sheen);
            return premultiply(vec4(rgb, pixel.a));
        }
        """)

    init(url: URL?) {
        guard let url, let original = CIImage(contentsOf: url) else { return }
        source = original.transformed(by: CGAffineTransform(scaleX: 312 / original.extent.width,
                                                            y: 312 / original.extent.height))
    }

    func frame(seconds: TimeInterval, palette: OrbPalette = .original, shimmer: Bool = false) -> CGImage? {
        guard let source else { return nil }
        let phase = seconds * .pi * 2 / 12 // One very slow 12-second smoke cycle.
        let warped = kernel?.apply(extent: extent, roiCallback: { _, rect in rect.insetBy(dx: -22, dy: -22) },
                                   image: source, arguments: [phase]) ?? source
        let (r, g, b) = palette.rgb
        let finished = finish?.apply(extent: extent, arguments: [warped, CIVector(x: r, y: g, z: b),
            palette == .original ? 0.0 : 1.0, phase, shimmer ? 1.0 : 0.0]) ?? warped
        return context.createCGImage(finished, from: extent, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
    }
}

final class OrbActionButton: NSButton {
    var onPress: (() -> Void)?
    var palette: OrbPalette = .original { didSet { needsDisplay = true } }
    private var pointerInside = false
    private var tracking: NSTrackingArea?

    init(action: OrbAction) {
        super.init(frame: NSRect(x: 0, y: 0, width: 27, height: 27))
        title = ""
        isBordered = false
        image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: action.title)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .medium))
        imagePosition = .imageOnly
        contentTintColor = NSColor(calibratedRed: 1, green: 0.93, blue: 0.82, alpha: 1)
        target = self
        self.action = #selector(pressed)
        setAccessibilityLabel(action.title)
        toolTip = action == .voice ? "Voice chat · uses Codex’s Control–Shift–V shortcut" : "Start a new Codex chat"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { pointerInside = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { pointerInside = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
        palette.accent.blended(withFraction: pointerInside ? 0.58 : 0.78, of: .black)!.withAlphaComponent(0.97).setFill()
        shape.fill()
        palette.accent.blended(withFraction: 0.42, of: .white)!.withAlphaComponent(pointerInside ? 0.95 : 0.55).setStroke()
        shape.lineWidth = 0.8; shape.stroke()
        super.draw(dirtyRect)
    }
    @objc private func pressed() { onPress?() }
}

final class CodexActions {
    private(set) var busy = false
    private let newChatURL = URL(string: "codex://threads/new")!

    func perform(_ action: OrbAction) {
        guard !busy else { return }
        if action == .voice && !AXIsProcessTrusted() {
            let alert = NSAlert()
            alert.messageText = "Enable one-click voice"
            alert.informativeText = "macOS requires Accessibility permission for Codex Usage Tracker to send Control–Shift–V to Codex. Enable Codex Usage Tracker in System Settings → Privacy & Security → Accessibility, then click the voice button again.\n\nYou can also open Codex and press Control–Shift–V yourself."
            alert.addButton(withTitle: "Open Accessibility Settings")
            alert.addButton(withTitle: "Open Codex")
            alert.addButton(withTitle: "Cancel")
            NSApplication.shared.activate(ignoringOtherApps: true)
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                // Only opens the pane. The user must explicitly grant permission there.
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            case .alertSecondButtonReturn: openNewChat(startVoice: false)
            default: break
            }
            return
        }
        openNewChat(startVoice: action == .voice)
    }

    private func openNewChat(startVoice: Bool) {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") else {
            showError("Codex could not be found. Open the ChatGPT desktop app and try again."); return
        }
        busy = true
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([newChatURL], withApplicationAt: appURL, configuration: configuration) { app, error in
            DispatchQueue.main.async {
                guard error == nil, let app, app.bundleIdentifier == "com.openai.codex" else {
                    self.busy = false; self.showError("Codex could not open a new chat."); return
                }
                guard startVoice else { self.busy = false; return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    defer { self.busy = false }
                    guard !app.isTerminated, app.isActive, AXIsProcessTrusted() else {
                        self.showError("Open Codex and press Control–Shift–V to start voice chat."); return
                    }
                    guard let source = CGEventSource(stateID: .privateState),
                          let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
                          let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return }
                    down.flags = [.maskControl, .maskShift]
                    up.flags = [.maskControl, .maskShift]
                    // Send only this documented shortcut, only to the verified Codex process.
                    down.postToPid(app.processIdentifier)
                    up.postToPid(app.processIdentifier)
                }
            }
        }
    }

    private func showError(_ text: String) {
        let alert = NSAlert(); alert.messageText = text; alert.addButton(withTitle: "OK")
        NSApplication.shared.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

func runInteractionTests() {
    var clock = HoverClock()
    precondition(clock.phaseTime(at: 100) == 0)
    clock.setActive(true, now: 100)
    precondition(clock.phaseTime(at: 103) == 3)
    clock.setActive(false, now: 104)
    precondition(clock.phaseTime(at: 900) == 4)
    clock.setActive(true, now: 900)
    precondition(clock.phaseTime(at: 902) == 6)
    clock.setActive(true, now: 903)
    precondition(clock.phaseTime(at: 904) == 8)
    clock.setActive(false, now: 905)
    precondition(clock.phaseTime(at: 1500) == 9)
    print("6 hover-clock checks passed")
    let renderer = SmokeRenderer(url: Bundle.main.url(forResource: "smoky-quartz", withExtension: "png"))
    guard let first = renderer.frame(seconds: 0), let next = renderer.frame(seconds: 6),
          let firstData = first.dataProvider?.data, let nextData = next.dataProvider?.data,
          let a = CFDataGetBytePtr(firstData), let b = CFDataGetBytePtr(nextData) else {
        preconditionFailure("Smoke artwork could not render")
    }
    var changedCenter = 0, changedSmoke = 0
    for y in 0..<312 { for x in 0..<312 {
        let i = y * first.bytesPerRow + x * 4
        let differs = (0..<4).contains { abs(Int(a[i + $0]) - Int(b[i + $0])) > 2 }
        if differs {
            if (105..<205).contains(x) && (105..<205).contains(y) { changedCenter += 1 }
            else { changedSmoke += 1 }
        }
    }}
    precondition(changedCenter == 0, "Glass center must remain still")
    precondition(changedSmoke > 100, "Smoke must visibly animate")
    print("Smoke rendering passed: center unchanged, \(changedSmoke) outer pixels animate")
    var fingerprints = Set<Data>()
    for palette in OrbPalette.allCases {
        let frame = renderer.frame(seconds: 0, palette: palette)!
        fingerprints.insert(frame.dataProvider!.data! as Data)
    }
    precondition(fingerprints.count == OrbPalette.allCases.count, "Colour schemes must differ")
    let plain = renderer.frame(seconds: 3)!
    let shimmer = renderer.frame(seconds: 3, shimmer: true)!
    let pd = plain.dataProvider!.data!, sd = shimmer.dataProvider!.data!
    let p = CFDataGetBytePtr(pd)!, q = CFDataGetBytePtr(sd)!
    var innerChanges = 0, outerChanges = 0
    for y in 0..<312 { for x in 0..<312 {
        let i = y * plain.bytesPerRow + x * 4
        precondition(p[i + 3] == q[i + 3], "Shimmer must preserve transparency")
        if (0..<3).contains(where: { abs(Int(p[i + $0]) - Int(q[i + $0])) > 2 }) {
            if (105..<205).contains(x) && (105..<205).contains(y) { innerChanges += 1 }
            if x < 65 || x > 245 || y < 65 || y > 245 { outerChanges += 1 }
        }
    }}
    precondition(innerChanges > 100 && outerChanges == 0, "Shimmer must stay inside the glass")
    print("6 colour schemes distinct; inner shimmer changes \(innerChanges) pixels without changing outer smoke or alpha")

}
