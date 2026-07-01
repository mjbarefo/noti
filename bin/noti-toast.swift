// noti-toast — a tiny, borderless, native macOS corner toast for the `noti` CLI.
//
// Two modes:
//
//   noti-toast ask "Title" "Message" "Yes" "Always" "No"
//       Blocks until a button is clicked. Prints the clicked button's label to
//       stdout and exits with that button's index (0, 1, 2, ...). If it times
//       out (NOTI_TIMEOUT) before a click, or Esc is pressed while armed, it
//       prints nothing and exits 124.
//
//   noti-toast summary "Title" "Body text\nsecond line"
//       Shows a non-blocking card that auto-dismisses after NOTI_TIMEOUT
//       seconds (default 6) and exits 0. Click anywhere to dismiss early.
//
// Optional environment:
//   NOTI_TIMEOUT  seconds (ask: hard cap before exit 124; summary: dismiss delay)
//   NOTI_SLOT     integer stack index — offsets the toast so concurrent toasts
//                 don't overlap (slot 0 is the corner, 1 sits below it, ...)
//   NOTI_CORNER   top-right (default) | bottom-right | top-left | bottom-left
//   NOTI_HOTKEYS  "0" disables hover-armed keyboard shortcuts (default on)
//   NOTI_KIND     run | edit | fetch | mcp | note — colors the semantic dot and
//                 sets the message in monospace (terminal text is the material)
//   NOTI_PROJECT  eyebrow line above the title (which session is asking)
//   NOTI_FOOTER   small monospaced footer line (summary: the tool tally)
//
// Design notes (these are deliberate):
//   * .accessory activation policy  -> no Dock icon, no menu bar.
//   * .borderless + .nonactivatingPanel -> never steals focus from your editor.
//   * canJoinAllSpaces + .stationary -> appears on the *current* Space without
//     switching Spaces. Clicks still register on a non-activating panel.
//   * The panel is placed on the screen that currently contains the mouse, so it
//     shows up where you're looking on multi-monitor setups.
//   * Cards are sized to their content — a one-line `ls` gets a compact card,
//     a long command gets room (capped at 5 lines).
//   * The ask card's bottom hairline drains over NOTI_TIMEOUT: when it empties,
//     the prompt falls back to the terminal. The deadline is never a surprise.
//   * Hotkeys are HOVER-ARMED: the panel only grabs the keyboard after the mouse
//     *moves* over it. A toast appearing under a parked cursor, or while you're
//     typing in the terminal, can never swallow a keystroke — so an in-flight
//     "y" can't accidentally approve anything. Arming is visible (accent border,
//     keycaps brighten); moving the mouse off disarms and hands the keyboard back.
//
// Build: swiftc -O noti-toast.swift -o noti-toast   (zero third-party deps)

import AppKit

let env = ProcessInfo.processInfo.environment
let args = Array(CommandLine.arguments.dropFirst())

guard let mode = args.first else {
    FileHandle.standardError.write(Data("usage: noti-toast ask|summary ...\n".utf8))
    exit(64)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)            // no Dock icon, no menu bar

// ----------------------------------------------------------------------------
// Geometry + text helpers
// ----------------------------------------------------------------------------

func targetScreen() -> NSScreen {
    let mouse = NSEvent.mouseLocation
    for s in NSScreen.screens where NSMouseInRect(mouse, s.frame, false) { return s }
    return NSScreen.main ?? NSScreen.screens.first ?? NSScreen.screens[0]
}

func toastOrigin(width: CGFloat, height: CGFloat) -> NSPoint {
    let vf = targetScreen().visibleFrame
    let margin: CGFloat = 16, gap: CGFloat = 10
    let slot = CGFloat(Int(env["NOTI_SLOT"] ?? "0") ?? 0)
    let stack = slot * (height + gap)
    switch env["NOTI_CORNER"] ?? "top-right" {
    case "top-left":     return NSPoint(x: vf.minX + margin,          y: vf.maxY - height - margin - stack)
    case "bottom-left":  return NSPoint(x: vf.minX + margin,          y: vf.minY + margin + stack)
    case "bottom-right": return NSPoint(x: vf.maxX - width - margin,  y: vf.minY + margin + stack)
    default:             return NSPoint(x: vf.maxX - width - margin,  y: vf.maxY - height - margin - stack)
    }
}

func lineHeight(_ font: NSFont) -> CGFloat {
    ceil(NSLayoutManager().defaultLineHeight(for: font))
}

func textHeight(_ s: String, font: NSFont, width: CGFloat, maxLines: Int) -> CGFloat {
    let rect = (s as NSString).boundingRect(
        with: NSSize(width: width, height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading],
        attributes: [.font: font])
    return min(ceil(rect.height), CGFloat(maxLines) * lineHeight(font))
}

// Semantic dot: the action's risk class, readable before a single word.
func dotColor(_ kind: String) -> NSColor {
    switch kind {
    case "run":   return .systemOrange
    case "edit":  return .systemBlue
    case "fetch": return .systemPurple
    case "mcp":   return .systemTeal
    case "note":  return .systemGreen
    default:      return .tertiaryLabelColor
    }
}

let hairline = NSColor.separatorColor

// A borderless panel refuses key status by default; hotkeys need it. The panel
// still never *activates* the app (.nonactivatingPanel), so Spaces/focus stay put.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// Tracks the mouse so hotkeys arm only on deliberate movement over the card.
final class HoverEffectView: NSVisualEffectView {
    var onArm: (() -> Void)?
    var onLeave: (() -> Void)?
    private var inside = false
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
                                       owner: self, userInfo: nil))
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { inside = true }
    // arm on movement, not entry: a toast that appears under a parked cursor
    // must not start capturing keystrokes meant for the terminal
    override func mouseMoved(with event: NSEvent) { if inside { onArm?() } }
    override func mouseExited(with event: NSEvent) { inside = false; onLeave?() }
}

func makeCard(width: CGFloat, height: CGFloat) -> (NSPanel, HoverEffectView) {
    let panel = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
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

    let vev = HoverEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
    vev.material = .popover                       // system-notification depth, not HUD smoke
    vev.state = .active
    vev.blendingMode = .behindWindow
    vev.wantsLayer = true
    vev.layer?.cornerRadius = 12
    vev.layer?.cornerCurve = .continuous          // Apple's squircle, not a pure round
    vev.layer?.masksToBounds = true
    vev.layer?.borderWidth = 1
    vev.layer?.borderColor = hairline.cgColor     // definition against busy backdrops
    panel.contentView = vev

    panel.setFrameOrigin(toastOrigin(width: width, height: height))
    return (panel, vev)
}

func label(_ s: String, font: NSFont, color: NSColor, frame: NSRect, maxLines: Int = 1) -> NSTextField {
    let t = NSTextField(labelWithString: s)
    t.frame = frame
    t.font = font
    t.textColor = color
    t.lineBreakMode = .byTruncatingTail
    t.maximumNumberOfLines = maxLines
    t.cell?.wraps = maxLines > 1
    t.cell?.isScrollable = false
    return t
}

func dotView(x: CGFloat, y: CGFloat, kind: String) -> NSView {
    let v = NSView(frame: NSRect(x: x, y: y, width: 7, height: 7))
    v.wantsLayer = true
    v.layer?.backgroundColor = dotColor(kind).cgColor
    v.layer?.cornerRadius = 3.5
    return v
}

func timeoutSeconds(default def: Double) -> Double {
    if let raw = env["NOTI_TIMEOUT"], let v = Double(raw) { return v }
    return def
}

// Fade + a short settle toward the corner (slides down from a top corner, up
// from a bottom one). Respects the system reduce-motion setting.
func present(_ panel: NSPanel) {
    let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    let target = panel.frame
    if !reduce {
        let fromTop = (env["NOTI_CORNER"] ?? "top-right").hasPrefix("top")
        panel.setFrameOrigin(NSPoint(x: target.origin.x,
                                     y: target.origin.y + (fromTop ? 8 : -8)))
    }
    panel.alphaValue = 0
    panel.orderFrontRegardless()
    NSAnimationContext.runAnimationGroup { ctx in
        ctx.duration = reduce ? 0.12 : 0.22
        ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
        panel.animator().alphaValue = 1
        if !reduce { panel.animator().setFrame(target, display: true) }
    }
}

// Debug aid: NOTI_SNAPSHOT=/path.png renders the card's own view hierarchy to
// a PNG shortly after presenting, then exits — no screen-recording permission
// needed. (The vibrancy blur can't be sampled this way; layout/type/color can.)
func snapshotIfRequested(_ vev: NSView) {
    guard let path = env["NOTI_SNAPSHOT"] else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        if let rep = vev.bitmapImageRepForCachingDisplay(in: vev.bounds) {
            vev.cacheDisplay(in: vev.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path))
            }
        }
        exit(0)
    }
}

// ----------------------------------------------------------------------------
// Click handlers
// ----------------------------------------------------------------------------

final class Handler: NSObject {
    @objc func tap(_ sender: Any?) {
        guard let b = sender as? ToastButton else { exit(70) }
        FileHandle.standardOutput.write(Data((b.label + "\n").utf8))
        exit(Int32(b.tag))                     // exit code == button index
    }
    @objc func dismiss(_ sender: Any?) {
        exit(0)                                // summary: click anywhere to dismiss
    }
}

// ----------------------------------------------------------------------------
// ToastButton — flat, self-documenting button with its hotkey as a keycap chip.
// Stock NSButton bezels read as a generic system dialog; these are quiet,
// continuous-corner fills where the primary action carries the accent and the
// keycap answers "how do I press this" without a legend.
// ----------------------------------------------------------------------------

final class ToastButton: NSControl {
    let label: String
    let key: String                    // hotkey character ("" = none shown)
    private let primary: Bool
    private var capBox: NSView?
    private var fill: NSColor { primary ? .controlAccentColor
                                        : NSColor.labelColor.withAlphaComponent(0.08) }
    private var hoverFill: NSColor { primary ? NSColor.controlAccentColor.withAlphaComponent(0.85)
                                             : NSColor.labelColor.withAlphaComponent(0.14) }

    static let titleFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    static let keyFont   = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .medium)
    static let height: CGFloat = 28

    static func width(title: String, showKey: Bool) -> CGFloat {
        let tw = ceil((title as NSString).size(withAttributes: [.font: titleFont]).width)
        return max(64, tw + (showKey ? 16 + 6 : 0) + 24)
    }

    init(title: String, key: String, primary: Bool, tag: Int, target: AnyObject?, action: Selector) {
        self.label = title
        self.key = key
        self.primary = primary
        let w = ToastButton.width(title: title, showKey: !key.isEmpty)
        super.init(frame: NSRect(x: 0, y: 0, width: w, height: ToastButton.height))
        self.tag = tag
        self.target = target
        self.action = action
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = fill.cgColor

        let titleColor: NSColor = primary ? .white : .labelColor
        let t = NSTextField(labelWithString: title)
        t.font = ToastButton.titleFont
        t.textColor = titleColor
        t.sizeToFit()
        let contentW = t.frame.width + (key.isEmpty ? 0 : 6 + 16)
        let tx = (w - contentW) / 2
        t.frame.origin = NSPoint(x: tx, y: (ToastButton.height - t.frame.height) / 2)
        addSubview(t)

        if !key.isEmpty {
            let cap = NSView(frame: NSRect(x: tx + t.frame.width + 6,
                                           y: (ToastButton.height - 16) / 2, width: 16, height: 16))
            cap.wantsLayer = true
            cap.layer?.cornerRadius = 4
            cap.layer?.cornerCurve = .continuous
            cap.layer?.backgroundColor = (primary ? NSColor.white.withAlphaComponent(0.22)
                                                  : NSColor.labelColor.withAlphaComponent(0.10)).cgColor
            let k = NSTextField(labelWithString: key)
            k.font = ToastButton.keyFont
            k.textColor = primary ? NSColor.white.withAlphaComponent(0.9) : .secondaryLabelColor
            k.alignment = .center
            k.frame = NSRect(x: 0, y: 1.5, width: 16, height: 13)
            cap.addSubview(k)
            capBox = cap
            addSubview(cap)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    // keycaps light up when the card arms — "the keyboard is live now"
    func setArmed(_ armed: Bool) {
        capBox?.layer?.backgroundColor = (primary
            ? NSColor.white.withAlphaComponent(armed ? 0.35 : 0.22)
            : NSColor.labelColor.withAlphaComponent(armed ? 0.20 : 0.10)).cgColor
    }

    func fire() {
        if let action { NSApp.sendAction(action, to: target, from: self) }
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { layer?.backgroundColor = hoverFill.cgColor }
    override func mouseExited(with event: NSEvent)  { layer?.backgroundColor = fill.cgColor }
    override func mouseDown(with event: NSEvent)    { alphaValue = 0.7 }
    override func mouseUp(with event: NSEvent) {
        alphaValue = 1
        if bounds.contains(convert(event.locationInWindow, from: nil)) { fire() }
    }
}

// ----------------------------------------------------------------------------
// Modes
// ----------------------------------------------------------------------------

switch mode {

case "ask":   // noti-toast ask "Title" "Message" "Yes" "Always" "No"
    let title   = args.count > 1 ? args[1] : ""
    let message = args.count > 2 ? args[2] : ""
    let buttons = Array(args.dropFirst(3)).isEmpty ? ["OK"] : Array(args.dropFirst(3).prefix(3))
    let hotkeys = (env["NOTI_HOTKEYS"] ?? "1") != "0"
    let kind    = env["NOTI_KIND"] ?? ""
    let project = env["NOTI_PROJECT"] ?? ""

    // hotkey per button = its first letter; duplicates keep first-wins and the
    // later button shows no keycap (still clickable)
    var seen = Set<String>()
    let keys: [String] = buttons.map {
        let k = String($0.lowercased().prefix(1))
        return (hotkeys && !k.isEmpty && seen.insert(k).inserted) ? k : ""
    }

    // measure buttons first: custom labels via the `noti ask` CLI may need a
    // wider card than the stock Yes/Always/No (which fits in 360)
    let btnWidths: [CGFloat] = zip(buttons, keys).map {
        ToastButton.width(title: $0, showKey: !$1.isEmpty)
    }
    let btnRowW = btnWidths.reduce(0, +) + CGFloat(max(0, buttons.count - 1)) * 8

    let pad: CGFloat = 16
    let W: CGFloat = min(560, max(360, btnRowW + 2 * pad))
    let textW = W - 2 * pad
    let eyebrowFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    let titleFont   = NSFont.systemFont(ofSize: 13, weight: .semibold)
    // the command IS the content — terminal material, full label color
    let msgFont: NSFont = kind.isEmpty ? .systemFont(ofSize: 12)
                                       : .monospacedSystemFont(ofSize: 11.5, weight: .regular)
    let msgColor: NSColor = kind.isEmpty ? .secondaryLabelColor : .labelColor

    let eyeH: CGFloat = project.isEmpty ? 0 : lineHeight(eyebrowFont)
    let titleH = lineHeight(titleFont)
    let msgH: CGFloat = message.isEmpty ? 0 : textHeight(message, font: msgFont, width: textW, maxLines: 5)

    var H: CGFloat = 14 + titleH + 12 + ToastButton.height + 14 // padding + title + buttons row
    if eyeH > 0 { H += eyeH + 5 }
    if msgH > 0 { H += 6 + msgH }

    let (panel, vev) = makeCard(width: W, height: H)
    var y = H - 14
    if eyeH > 0 {
        y -= eyeH
        vev.addSubview(dotView(x: pad, y: y + (eyeH - 7) / 2, kind: kind))
        vev.addSubview(label(project, font: eyebrowFont, color: .secondaryLabelColor,
                             frame: NSRect(x: pad + 13, y: y, width: textW - 13, height: eyeH)))
        y -= 5
    }
    y -= titleH
    vev.addSubview(label(title, font: titleFont, color: .labelColor,
                         frame: NSRect(x: pad, y: y, width: textW, height: titleH)))
    if msgH > 0 {
        y -= 6 + msgH
        vev.addSubview(label(message, font: msgFont, color: msgColor,
                             frame: NSRect(x: pad, y: y, width: textW, height: msgH), maxLines: 5))
    }

    let handler = Handler()
    var buttonViews: [ToastButton] = []
    var x = W - pad
    for (i, name) in buttons.enumerated() {
        let b = ToastButton(title: name, key: keys[i], primary: i == 0,
                            tag: i, target: handler, action: #selector(Handler.tap(_:)))
        x -= btnWidths[i]
        b.setFrameOrigin(NSPoint(x: x, y: 14))
        x -= 8
        vev.addSubview(b)
        buttonViews.append(b)
    }

    if hotkeys {
        var armed = false
        vev.onArm = {
            guard !armed else { return }
            armed = true
            panel.makeKey()
            // arming must be visible — the user needs to know the keyboard is live
            vev.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.8).cgColor
            buttonViews.forEach { $0.setArmed(true) }
        }
        vev.onLeave = {
            armed = false
            vev.layer?.borderColor = hairline.cgColor
            buttonViews.forEach { $0.setArmed(false) }
            // orderOut + re-orderFront reliably hands key focus back to the
            // frontmost app; resignKey() alone leaves the keyboard in limbo
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { ev in
            guard armed else { return ev }
            if ev.keyCode == 53 { exit(124) }                            // esc = no answer
            if ev.keyCode == 36 { buttonViews.first?.fire(); return nil }  // return
            if ev.modifierFlags.intersection([.command, .control, .option]).isEmpty,
               let ch = ev.charactersIgnoringModifiers?.lowercased(), !ch.isEmpty {
                for b in buttonViews where b.key == ch {
                    b.fire()
                    return nil
                }
            }
            return nil   // swallow unmapped keys while armed — never leak them
        }
    }

    let secs = timeoutSeconds(default: 120)   // safety net: never block forever if NOTI_TIMEOUT is unset
    if secs > 0 {
        Timer.scheduledTimer(withTimeInterval: secs, repeats: false) { _ in
            FileHandle.standardError.write(Data("timeout\n".utf8))
            exit(124)                              // distinct: "no answer"
        }
        // the deadline, made visible: a hairline that drains until the prompt
        // falls back to the terminal
        let drain = CALayer()
        drain.anchorPoint = CGPoint(x: 0, y: 0)
        drain.frame = CGRect(x: 0, y: 0, width: W, height: 2)
        drain.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.35).cgColor
        vev.layer?.addSublayer(drain)
        let a = CABasicAnimation(keyPath: "bounds.size.width")
        a.fromValue = W
        a.toValue = 0
        a.duration = secs
        a.timingFunction = CAMediaTimingFunction(name: .linear)
        a.fillMode = .forwards
        a.isRemovedOnCompletion = false
        drain.add(a, forKey: "drain")
    }
    present(panel)
    snapshotIfRequested(vev)
    _ = handler                                    // keep alive
    app.run()

case "summary":   // noti-toast summary "Title" "Body\nlines"
    let title  = args.count > 1 ? args[1] : ""
    let body   = args.count > 2 ? args[2] : ""
    let kind   = env["NOTI_KIND"] ?? "note"
    let footer = env["NOTI_FOOTER"] ?? ""

    let W: CGFloat = 360, pad: CGFloat = 16, textW = W - 2 * pad
    let titleFont  = NSFont.systemFont(ofSize: 12, weight: .semibold)
    let bodyFont   = NSFont.systemFont(ofSize: 12)
    let footerFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)

    let titleH  = lineHeight(titleFont)
    let bodyH: CGFloat   = body.isEmpty ? 0 : textHeight(body, font: bodyFont, width: textW, maxLines: 3)
    let footerH: CGFloat = footer.isEmpty ? 0 : lineHeight(footerFont)

    var H: CGFloat = 12 + titleH + 12
    if bodyH > 0 { H += 4 + bodyH }
    if footerH > 0 { H += 6 + footerH }

    let (panel, vev) = makeCard(width: W, height: H)
    var y = H - 12 - titleH
    vev.addSubview(dotView(x: pad, y: y + (titleH - 7) / 2, kind: kind))
    vev.addSubview(label(title, font: titleFont, color: .labelColor,
                         frame: NSRect(x: pad + 13, y: y, width: textW - 13, height: titleH)))
    if bodyH > 0 {
        y -= 4 + bodyH
        vev.addSubview(label(body, font: bodyFont, color: .secondaryLabelColor,
                             frame: NSRect(x: pad, y: y, width: textW, height: bodyH), maxLines: 3))
    }
    if footerH > 0 {
        y -= 6 + footerH
        vev.addSubview(label(footer, font: footerFont, color: .tertiaryLabelColor,
                             frame: NSRect(x: pad, y: y, width: textW, height: footerH)))
    }

    let handler = Handler()
    vev.addGestureRecognizer(NSClickGestureRecognizer(target: handler,
                                                      action: #selector(Handler.dismiss(_:))))

    let secs = timeoutSeconds(default: 6)
    Timer.scheduledTimer(withTimeInterval: max(0.3, secs - 0.3), repeats: false) { _ in
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            panel.animator().alphaValue = 0
        }, completionHandler: { exit(0) })
    }
    present(panel)
    snapshotIfRequested(vev)
    _ = handler                                    // keep alive
    app.run()

default:
    FileHandle.standardError.write(Data("unknown mode: \(mode)\n".utf8))
    exit(64)
}
