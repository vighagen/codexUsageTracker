#!/usr/bin/env python3
"""Render a deterministic hover demo from the production AppKit view.

Uses example usage (77%), never account data. Requires macOS graphics access.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile
import sys

root = Path(__file__).resolve().parent.parent
working_demo = '--working' in sys.argv
with tempfile.TemporaryDirectory(prefix='usage-tracker-preview-') as tmp:
    work = Path(tmp)
    bundle = work / 'Preview.app/Contents'
    (bundle / 'MacOS').mkdir(parents=True)
    (bundle / 'Resources').mkdir()
    shutil.copy(root / 'Assets/smoky-quartz.png', bundle / 'Resources')
    source = (root / 'main.swift').read_text().split('if CommandLine.arguments.contains("--self-test")')[0]
    source = source.replace('    var currentUsage: WeeklyUsage?', '''    func renderPreview(seconds: Double, hovered: Bool, shimmer: Bool, working: Bool = false, activitySeconds: Double = 0) {
        workingTasks = working ? 1 : 0
        activityTime = activitySeconds
        frameTime = seconds
        shimmerStarted = shimmer
        refreshFrame()
        for button in [chatButton, voiceButton] {
            button.isHidden = !hovered
            button.alphaValue = hovered ? 1 : 0
        }
    }
    var currentUsage: WeeklyUsage?''')
    source += r'''
import ImageIO
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let view = OrbView(frame: NSRect(x: 0, y: 0, width: 104, height: 104))
view.palette = .original
view.usage = WeeklyUsage(remaining: 77, resetsAt: nil, fetchedAt: Date())
view.layoutSubtreeIfNeeded()
let output = URL(fileURLWithPath: CommandLine.arguments[1])
let workingDemo = CommandLine.arguments.last == "working"
let frameCount = workingDemo ? 100 : 160
let destination = CGImageDestinationCreateWithURL(output as CFURL, "com.compuserve.gif" as CFString, frameCount, nil)!
CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
func text(_ value: String, x: CGFloat, y: CGFloat, size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular) {
    (value as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
}
for index in 0..<frameCount {
    let time = Double(index) / 10
    let hovering = !workingDemo && time >= 2 && time < 14
    let working = workingDemo && time >= 2 && time < 8
    let phaseTime = workingDemo ? 0 : min(12, max(0, time - 2))
    view.renderPreview(seconds: phaseTime, hovered: hovering, shimmer: !workingDemo && time >= 2, working: working, activitySeconds: max(0, time - 2))
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 420, pixelsHigh: 340,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let context = NSGraphicsContext.current!.cgContext
    NSColor(calibratedRed: 0.065, green: 0.070, blue: 0.082, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: 420, height: 340).fill()
    text("CODEX USAGE TRACKER", x: 24, y: 305, size: 13, color: .white, weight: .semibold)
    text(workingDemo ? (working ? "WORKING" : "IDLE") : (hovering ? "HOVER" : (time < 2 ? "IDLE" : "PAUSED")), x: 324, y: 305,
         size: 11, color: NSColor(calibratedWhite: 0.72, alpha: 1), weight: .medium)
    context.saveGState()
    context.translateBy(x: 106, y: 74)
    context.scaleBy(x: 2, y: 2)
    view.draw(view.bounds)
    if hovering {
        for button in view.subviews where !button.isHidden {
            context.saveGState()
            context.translateBy(x: button.frame.minX, y: button.frame.minY)
            button.draw(button.bounds)
            context.restoreGState()
        }
    }
    context.restoreGState()
    NSCursor.arrow.image.draw(at: NSPoint(x: hovering ? 295 : 360, y: hovering ? 169 : 73),
                              from: .zero, operation: .sourceOver, fraction: 1)
    let caption = workingDemo ? (working ? "AI working · floating orb + travelling light" : "Work finished or awaiting input · still") : hovering ? "Smoke + inner shimmer · 12-second cycle" : "Both effects pause outside hover"
    let width = (caption as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width
    text(caption, x: (420 - width) / 2, y: 43, size: 13, color: NSColor(calibratedWhite: 0.83, alpha: 1))
    text("Example usage · 77% remaining", x: 120, y: 20, size: 11, color: NSColor(calibratedWhite: 0.5, alpha: 1))
    NSGraphicsContext.restoreGraphicsState()
    CGImageDestinationAddImage(destination, rep.cgImage!, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
    if index == 50 {
        try! rep.representation(using: .png, properties: [:])!.write(to: output.deletingLastPathComponent().appendingPathComponent(workingDemo ? "orb-working.png" : "orb-hover.png"))
    }
}
precondition(CGImageDestinationFinalize(destination))
print(workingDemo ? "Rendered working-state preview" : "Rendered hover preview")
'''
    (work / 'main.swift').write_text(source)
    exe = bundle / 'MacOS/Preview'
    subprocess.run(['swiftc', '-swift-version', '5', '-O', '-module-cache-path', str(Path(tempfile.gettempdir()) / 'usage-tracker-swift-cache'),
                    '-framework', 'AppKit', '-framework', 'CoreImage', '-framework', 'QuartzCore',
                    '-framework', 'ApplicationServices', '-framework', 'ImageIO', '-lsqlite3',
                    str(root / 'WeeklyUsage.swift'), str(root / 'OrbInteraction.swift'), str(root / 'ActivityMonitor.swift'),
                    str(work / 'main.swift'), '-o', str(exe)], check=True)
    (root / 'docs').mkdir(exist_ok=True)
    subprocess.run([str(exe), str(root / ('docs/orb-working.gif' if working_demo else 'docs/orb-hover.gif')), 'working' if working_demo else 'hover'], check=True)
