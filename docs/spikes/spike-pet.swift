// spike-pet.swift — Spike: prove a non-capturing, always-on-top pet surface can
// reflect per-session state files without touching noti's real hooks.
//
// Build: swiftc docs/spikes/spike-pet.swift -o /tmp/noti-pet-spike
// Run:   rm -rf /tmp/noti-pet-state && mkdir -p /tmp/noti-pet-state
//        /tmp/noti-pet-spike /tmp/noti-pet-state
//
// Drive it by hand from another terminal:
//   echo "running noti" > /tmp/noti-pet-state/session-a
//   echo "waiting noti" > /tmp/noti-pet-state/session-a
//   echo "waiting /same/cwd" > /tmp/noti-pet-state/session-a
//   echo "waiting /same/cwd" > /tmp/noti-pet-state/session-b
//   echo "done noti" > /tmp/noti-pet-state/session-a
//   rm /tmp/noti-pet-state/session-*
//
// Optional spike knobs:
//   NOTI_PET_WAITING_TTL=5      waiting files older than N seconds are ignored
//   NOTI_PET_DONE_TTL=3         done/failed files older than N seconds decay away
//   NOTI_PET_REDUCE_MOTION=1    force the reduce-motion branch for this process
//   NOTI_PET_SNAPSHOT_DIR=/tmp/pet-shots
//                               write a PNG of each rendered state change
//   NOTI_PET_SELFTEST=1         shove the panel off-screen and post
//                               didChangeScreenParametersNotification after 2s
//
// Checklist (pass = all of these):
//   1. The panel is a small .accessory, .borderless + .nonactivatingPanel,
//      canJoinAllSpaces + stationary + fullScreenAuxiliary surface.
//   2. It never becomes key. No "FAIL became key" line appears after clicks,
//      drags, state changes, or typing into another app.
//   3. It never captures a keystroke. Click the pet, then type in Terminal;
//      the text lands in Terminal and no panel "FAIL captured key" line appears.
//   4. State files drive the pose: empty/touch = running; "running", "waiting",
//      and deleting all files produce visually distinct running, waiting, and
//      asleep static poses.
//   5. Multiple waiting files keep one pet but log all waiting sessions; two
//      files with the same cwd demonstrate that cwd alone is not a focus target.
//   6. Drag the pet; it follows the pointer and logs drag-end while still not
//      key. With NOTI_PET_SELFTEST=1 it re-clamps after
//      didChangeScreenParametersNotification.
//   7. Reduce motion removes the state-change pulse, not the state meaning:
//      run once normally, then once with NOTI_PET_REDUCE_MOTION=1 and repeat
//      waiting/running/asleep.
//   8. CPU stays idle-ish while shown: there is no continuous animation; only a
//      directory watcher plus a 0.5s scan backstop.

import AppKit
import Darwin

let args = Array(CommandLine.arguments.dropFirst())
let env = ProcessInfo.processInfo.environment
let stateDirPath = args.first ?? "/tmp/noti-pet-state"
let stateDir = URL(fileURLWithPath: stateDirPath, isDirectory: true)
let snapshotDir = env["NOTI_PET_SNAPSHOT_DIR"].map {
    URL(fileURLWithPath: $0, isDirectory: true)
}
let waitingTTL = max(1, Double(env["NOTI_PET_WAITING_TTL"] ?? "120") ?? 120)
let doneTTL = max(1, Double(env["NOTI_PET_DONE_TTL"] ?? "4") ?? 4)
var snapshotCounter = 0

func log(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
}

func reduceMotion() -> Bool {
    if let forced = env["NOTI_PET_REDUCE_MOTION"] {
        return forced != "0"
    }
    return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
}

enum Mood: String, CaseIterable {
    case asleep
    case running
    case done
    case failed
    case waiting

    var urgency: Int {
        switch self {
        case .asleep: return 0
        case .running: return 1
        case .done: return 2
        case .failed: return 3
        case .waiting: return 4
        }
    }
}

struct SessionState {
    let id: String
    let mood: Mood
    let label: String
    let modified: Date
}

final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func keyDown(with event: NSEvent) {
        log("FAIL captured key in panel: \(event.charactersIgnoringModifiers ?? "?")")
    }
}

final class PetView: NSView {
    var mood: Mood = .asleep {
        didSet { needsDisplay = true }
    }
    var label: String = "asleep" {
        didSet { needsDisplay = true }
    }
    var sessions: [SessionState] = []
    private var dragStartMouse = NSPoint.zero
    private var dragStartOrigin = NSPoint.zero

    override var acceptsFirstResponder: Bool { false }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        dragStartMouse = NSEvent.mouseLocation
        dragStartOrigin = window.frame.origin
        log("mouse-down mood=\(mood.rawValue) key=\(window.isKeyWindow)")
    }

    override func mouseDragged(with event: NSEvent) {
        guard let panel = window else { return }
        let now = NSEvent.mouseLocation
        let proposed = NSPoint(x: dragStartOrigin.x + now.x - dragStartMouse.x,
                               y: dragStartOrigin.y + now.y - dragStartMouse.y)
        panel.setFrameOrigin(clampedOrigin(proposed, size: panel.frame.size))
    }

    override func mouseUp(with event: NSEvent) {
        guard let panel = window else { return }
        panel.setFrameOrigin(clampedOrigin(panel.frame.origin, size: panel.frame.size))
        let waiting = sessions.filter { $0.mood == .waiting }
        if waiting.count > 1 {
            let groups = Dictionary(grouping: waiting, by: { $0.label })
            let ambiguous = groups.filter { $0.value.count > 1 }
            if !ambiguous.isEmpty {
                let detail = ambiguous.map { label, states in
                    "\(label)=\(states.map { $0.id }.joined(separator: ","))"
                }.joined(separator: " ")
                log("click: ambiguous focus target from cwd-only data: " + detail)
            }
        }
        log("drag-end origin=\(Int(panel.frame.origin.x)),\(Int(panel.frame.origin.y)) key=\(panel.isKeyWindow)")
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()

        let base = bounds.insetBy(dx: 5, dy: 5)
        let shell = NSRect(x: base.minX + 8, y: base.minY + 11, width: base.width - 16, height: base.height - 23)
        let terracotta = NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1)
        let ink = NSColor(srgbRed: 0.18, green: 0.12, blue: 0.10, alpha: 1)
        let shellColor: NSColor
        let accent: NSColor
        switch mood {
        case .asleep:
            shellColor = NSColor(srgbRed: 0.58, green: 0.56, blue: 0.53, alpha: 0.92)
            accent = NSColor(srgbRed: 0.34, green: 0.34, blue: 0.34, alpha: 1)
        case .running:
            shellColor = terracotta
            accent = NSColor.systemTeal
        case .done:
            shellColor = terracotta
            accent = NSColor.systemGreen
        case .failed:
            shellColor = NSColor.systemRed
            accent = NSColor.systemYellow
        case .waiting:
            shellColor = terracotta
            accent = NSColor.systemYellow
        }

        drawLegs(shell: shell, color: shellColor.shadow(withLevel: 0.18) ?? shellColor)

        if mood == .waiting {
            let sign = NSBezierPath(roundedRect: NSRect(x: base.midX + 9, y: base.maxY - 24, width: 22, height: 18),
                                    xRadius: 3, yRadius: 3)
            NSColor.white.setFill()
            sign.fill()
            accent.setStroke()
            sign.lineWidth = 2
            sign.stroke()
            drawText("!", in: NSRect(x: base.midX + 9, y: base.maxY - 23, width: 22, height: 16),
                     size: 15, color: ink, bold: true)
            let arm = NSBezierPath()
            arm.move(to: NSPoint(x: shell.maxX - 4, y: shell.maxY - 5))
            arm.line(to: NSPoint(x: base.midX + 11, y: base.maxY - 11))
            shellColor.setStroke()
            arm.lineWidth = 4
            arm.lineCapStyle = .round
            arm.stroke()
        } else {
            drawClaw(center: NSPoint(x: shell.minX - 2, y: shell.midY + 4), flip: false, color: shellColor)
            drawClaw(center: NSPoint(x: shell.maxX + 2, y: shell.midY + 4), flip: true, color: shellColor)
        }

        let body = NSBezierPath(ovalIn: shell)
        shellColor.setFill()
        body.fill()
        (shellColor.shadow(withLevel: 0.25) ?? shellColor).setStroke()
        body.lineWidth = 1.5
        body.stroke()

        switch mood {
        case .asleep:
            drawClosedEyes(shell: shell, ink: ink)
            drawText("z", in: NSRect(x: shell.maxX - 5, y: shell.maxY - 2, width: 13, height: 13),
                     size: 11, color: NSColor.white.withAlphaComponent(0.9), bold: true)
        case .running:
            drawEyes(shell: shell, ink: ink)
            drawText("...", in: NSRect(x: shell.minX, y: shell.midY - 11, width: shell.width, height: 16),
                     size: 10, color: NSColor.white, bold: true)
        case .done:
            drawEyes(shell: shell, ink: ink)
            drawText("✓", in: NSRect(x: shell.minX, y: shell.midY - 14, width: shell.width, height: 24),
                     size: 21, color: accent, bold: true)
        case .failed:
            drawEyes(shell: shell, ink: ink)
            drawText("!", in: NSRect(x: shell.minX, y: shell.midY - 14, width: shell.width, height: 24),
                     size: 22, color: accent, bold: true)
        case .waiting:
            drawEyes(shell: shell, ink: ink)
            drawText("need", in: NSRect(x: shell.minX, y: shell.midY - 12, width: shell.width, height: 16),
                     size: 8, color: NSColor.white, bold: true)
        }

        let footer = shortLabel(label)
        drawText(footer, in: NSRect(x: 3, y: 2, width: bounds.width - 6, height: 10),
                 size: 7, color: NSColor.labelColor.withAlphaComponent(0.75), bold: false)
    }

    private func shortLabel(_ s: String) -> String {
        if s.count <= 12 { return s }
        return String(s.prefix(11)) + "…"
    }

    private func drawText(_ text: String, in rect: NSRect, size: CGFloat, color: NSColor, bold: Bool) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
        (text as NSString).draw(in: rect, withAttributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: style,
        ])
    }

    private func drawEyes(shell: NSRect, ink: NSColor) {
        ink.setFill()
        NSBezierPath(ovalIn: NSRect(x: shell.midX - 12, y: shell.midY + 5, width: 5, height: 7)).fill()
        NSBezierPath(ovalIn: NSRect(x: shell.midX + 7, y: shell.midY + 5, width: 5, height: 7)).fill()
    }

    private func drawClosedEyes(shell: NSRect, ink: NSColor) {
        ink.setStroke()
        for x in [shell.midX - 12, shell.midX + 7] {
            let eye = NSBezierPath()
            eye.move(to: NSPoint(x: x, y: shell.midY + 8))
            eye.curve(to: NSPoint(x: x + 6, y: shell.midY + 8),
                      controlPoint1: NSPoint(x: x + 2, y: shell.midY + 5),
                      controlPoint2: NSPoint(x: x + 4, y: shell.midY + 5))
            eye.lineWidth = 1.4
            eye.stroke()
        }
    }

    private func drawLegs(shell: NSRect, color: NSColor) {
        color.setStroke()
        for yOff in [6.0, 16.0, 26.0] {
            let left = NSBezierPath()
            left.move(to: NSPoint(x: shell.minX + 8, y: shell.minY + yOff))
            left.line(to: NSPoint(x: shell.minX - 2, y: shell.minY + yOff - 4))
            left.lineWidth = 2
            left.lineCapStyle = .round
            left.stroke()
            let right = NSBezierPath()
            right.move(to: NSPoint(x: shell.maxX - 8, y: shell.minY + yOff))
            right.line(to: NSPoint(x: shell.maxX + 2, y: shell.minY + yOff - 4))
            right.lineWidth = 2
            right.lineCapStyle = .round
            right.stroke()
        }
    }

    private func drawClaw(center: NSPoint, flip: Bool, color: NSColor) {
        color.setStroke()
        let dir: CGFloat = flip ? 1 : -1
        let arm = NSBezierPath()
        arm.move(to: center)
        arm.line(to: NSPoint(x: center.x + dir * 11, y: center.y + 5))
        arm.lineWidth = 3
        arm.lineCapStyle = .round
        arm.stroke()
        let claw = NSBezierPath()
        claw.appendOval(in: NSRect(x: center.x + dir * 10 - 5, y: center.y + 1, width: 10, height: 10))
        color.setFill()
        claw.fill()
    }
}

func containingScreen(for origin: NSPoint, size: NSSize) -> NSScreen {
    let rect = NSRect(origin: origin, size: size)
    let center = NSPoint(x: rect.midX, y: rect.midY)
    for screen in NSScreen.screens where screen.visibleFrame.contains(center) {
        return screen
    }
    return NSScreen.screens.max { a, b in
        distance(from: center, to: a.visibleFrame.center) > distance(from: center, to: b.visibleFrame.center)
    } ?? NSScreen.main ?? NSScreen.screens[0]
}

func distance(from a: NSPoint, to b: NSPoint) -> CGFloat {
    let dx = a.x - b.x
    let dy = a.y - b.y
    return sqrt(dx * dx + dy * dy)
}

extension NSRect {
    var center: NSPoint { NSPoint(x: midX, y: midY) }
}

func clampedOrigin(_ origin: NSPoint, size: NSSize) -> NSPoint {
    let screen = containingScreen(for: origin, size: size)
    let vf = screen.visibleFrame.insetBy(dx: 4, dy: 4)
    return NSPoint(x: min(max(origin.x, vf.minX), vf.maxX - size.width),
                   y: min(max(origin.y, vf.minY), vf.maxY - size.height))
}

func readSessions() -> [SessionState] {
    let fm = FileManager.default
    guard let urls = try? fm.contentsOfDirectory(at: stateDir,
                                                 includingPropertiesForKeys: [.contentModificationDateKey],
                                                 options: [.skipsHiddenFiles]) else {
        return []
    }
    let now = Date()
    return urls.compactMap { url in
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { return nil }
        let attrs = try? fm.attributesOfItem(atPath: url.path)
        let modified = (attrs?[.modificationDate] as? Date) ?? now
        let age = now.timeIntervalSince(modified)
        let raw = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let fields = raw.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
        let mood = fields.first.flatMap { Mood(rawValue: String($0).lowercased()) } ?? .running
        if mood == .waiting, age > waitingTTL { return nil }
        if (mood == .done || mood == .failed), age > doneTTL { return nil }
        let label = fields.dropFirst().map(String.init).joined(separator: " ")
        return SessionState(id: url.lastPathComponent,
                            mood: mood,
                            label: label.isEmpty ? url.lastPathComponent : label,
                            modified: modified)
    }
}

func summarize(_ sessions: [SessionState]) -> (Mood, String) {
    guard let top = sessions.max(by: { $0.mood.urgency < $1.mood.urgency }) else {
        return (.asleep, "asleep")
    }
    let matching = sessions.filter { $0.mood == top.mood }
    if matching.count == 1 {
        return (top.mood, matching[0].label)
    }
    return (top.mood, "\(matching.count) sessions")
}

func snapshot(_ view: NSView, mood: Mood, label: String) {
    guard let dir = snapshotDir,
          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    view.display()
    view.cacheDisplay(in: view.bounds, to: rep)
    guard let data = rep.representation(using: .png, properties: [:]) else { return }
    snapshotCounter += 1
    let safe = label.replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: " ", with: "_")
    let url = dir.appendingPathComponent(String(format: "%02d-%@-%@.png",
                                                snapshotCounter, mood.rawValue, safe))
    do {
        try data.write(to: url)
        log("snapshot wrote \(url.path)")
    } catch {
        log("WARN snapshot failed \(url.path): \(error)")
    }
}

func makePanel() -> (PetPanel, PetView) {
    let size = NSSize(width: 72, height: 72)
    let panel = PetPanel(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
    panel.level = .floating
    panel.isFloatingPanel = true
    panel.hidesOnDeactivate = false
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
    panel.acceptsMouseMovedEvents = true
    panel.ignoresMouseEvents = false

    let view = PetView(frame: NSRect(origin: .zero, size: size))
    view.wantsLayer = true
    view.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.86).cgColor
    view.layer?.cornerRadius = 16
    view.layer?.cornerCurve = .continuous
    view.layer?.borderWidth = 1
    view.layer?.borderColor = NSColor.separatorColor.cgColor
    view.layer?.masksToBounds = true
    panel.contentView = view

    let vf = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
    let origin = NSPoint(x: vf.maxX - size.width - 24, y: vf.minY + 90)
    panel.setFrameOrigin(clampedOrigin(origin, size: size))
    return (panel, view)
}

final class StateDriver {
    private let panel: NSPanel
    private let view: PetView
    private var watcher: DispatchSourceFileSystemObject?
    private var repackPending = false
    private var lastSignature = ""

    init(panel: NSPanel, view: PetView) {
        self.panel = panel
        self.view = view
    }

    func start() {
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let fd = open(stateDir.path, O_EVTONLY)
        if fd >= 0 {
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                                                                eventMask: [.write, .delete, .rename],
                                                                queue: .main)
            src.setEventHandler { [weak self] in
                guard let self, !self.repackPending else { return }
                self.repackPending = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.repackPending = false
                    self.refresh(reason: "kqueue")
                }
            }
            src.setCancelHandler { close(fd) }
            src.resume()
            watcher = src
            log("watching \(stateDir.path) with kqueue + 0.5s backstop")
        } else {
            log("WARN could not kqueue-watch \(stateDir.path); using 0.5s backstop only")
        }
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refresh(reason: "timer")
        }
        refresh(reason: "initial")
    }

    func refresh(reason: String) {
        let sessions = readSessions().sorted { $0.id < $1.id }
        let (mood, label) = summarize(sessions)
        let signature = sessions.map { "\($0.id):\($0.mood.rawValue):\($0.label)" }.joined(separator: "|")
            + "=>\(mood.rawValue):\(label)"
        guard signature != lastSignature else { return }
        lastSignature = signature
        view.sessions = sessions
        let old = view.mood
        view.mood = mood
        view.label = label
        let detail = sessions.map { "\($0.id)=\($0.mood.rawValue)(\($0.label))" }.joined(separator: ",")
        log("state[\(reason)] \(mood.rawValue) label=\(label) sessions=[\(detail)] key=\(panel.isKeyWindow)")
        snapshot(view, mood: mood, label: label)
        if old != mood && !reduceMotion() {
            pulse()
        }
    }

    private func pulse() {
        guard let layer = view.layer else { return }
        let animation = CABasicAnimation(keyPath: "transform.scale")
        animation.fromValue = 0.92
        animation.toValue = 1.0
        animation.duration = 0.18
        animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
        layer.add(animation, forKey: "state-pulse")
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let (panel, petView) = makePanel()
let driver = StateDriver(panel: panel, view: petView)

NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
                                       object: panel, queue: .main) { _ in
    log("FAIL became key")
}
NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                       object: app, queue: .main) { _ in
    let before = panel.frame.origin
    let target = clampedOrigin(before, size: panel.frame.size)
    panel.setFrameOrigin(target)
    log("screen-change reclamp \(Int(before.x)),\(Int(before.y)) -> \(Int(target.x)),\(Int(target.y)) key=\(panel.isKeyWindow)")
}

log("panel style=.borderless+.nonactivatingPanel accessory=true collection=canJoinAllSpaces,stationary,fullScreenAuxiliary size=72x72")
log("reduceMotion=\(reduceMotion()) waitingTTL=\(waitingTTL)s doneTTL=\(doneTTL)s")
driver.start()
panel.orderFrontRegardless()

if env["NOTI_PET_SELFTEST"] == "1" {
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
        let bad = NSPoint(x: panel.frame.origin.x + 100_000, y: panel.frame.origin.y + 100_000)
        panel.setFrameOrigin(bad)
        log("selftest moved off-screen to \(Int(bad.x)),\(Int(bad.y)); posting screen-parameters notification")
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: app)
    }
}

app.run()
