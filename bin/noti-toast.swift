// noti-toast — a tiny, borderless, native macOS corner toast for the `noti` CLI.
//
// Two modes:
//
//   noti-toast ask "Title" "Message" "Yes" "Always" "No"
//       Blocks until a button is clicked. Prints the clicked button's label to
//       stdout and exits with that button's index (0, 1, 2, ...). If it times
//       out (NOTI_TIMEOUT) before a click, or Esc is pressed while armed, it
//       prints nothing and exits 124. With NOTI_OTHER=1 (list mode only) the
//       free-text row can submit instead: stdout = the typed answer, exit 10.
//
//   noti-toast summary "Title" "Body text\nsecond line"
//       Shows a non-blocking card that auto-dismisses after NOTI_TIMEOUT
//       seconds (default 6) and exits 0. Click anywhere to dismiss early.
//       Hovering holds the card open (you're reading it); leaving relights
//       a short fuse.
//
// Optional environment:
//   NOTI_TIMEOUT  seconds (ask: hard cap before exit 124; summary: dismiss delay)
//   NOTI_SLOT     integer stack index — offsets the toast so concurrent toasts
//                 don't overlap (slot 0 is the corner, 1 sits below it, ...)
//   NOTI_SLOT_DIR directory of slot files (one per live toast). When set, the
//                 toast publishes its height there, heartbeats it, and re-packs
//                 the column — within ~0.1s via a kqueue watch on the
//                 directory, each 0.4s as a backstop — stacking below the REAL
//                 cards and sliding up when a neighbour dismisses.
//   NOTI_CORNER   top-right (default) | bottom-right | top-left | bottom-left
//   NOTI_HOTKEYS  "0" disables hover-armed keyboard shortcuts (default on)
//   NOTI_KIND     run | edit | fetch | mcp | tool | note | question | plan —
//                 tints the icon chip and picks its glyph; run/edit/fetch/
//                 mcp/tool set the message in monospace (terminal text is
//                 the material), question/plan stay prose
//   NOTI_PROJECT  eyebrow line above the title (which session is asking)
//   NOTI_FOOTER   small monospaced footer line (summary: the tool tally;
//                 ask: rendered in list mode only — the esc hint)
//   NOTI_OPTIONS  full option labels, joined with the unit separator \u{1f} —
//                 2..4 non-empty fields flip the ask card into a vertical
//                 option list (question cards). argv still carries truncated
//                 fallback buttons, so an old binary renders the classic row.
//   NOTI_DESCS    per-option descriptions, \u{1f}-joined, same arity as
//                 NOTI_OPTIONS. An arity mismatch drops ALL descriptions — a
//                 description under the wrong option is worse than none.
//   NOTI_OTHER    "1" appends the free-text "Other…" row to a list-mode card
//                 (ignored without NOTI_OPTIONS — a permission prompt must
//                 never grow a text field). Click or digit N+1 swaps the row
//                 label for an inline single-line editor; Return submits:
//                 stdout = the typed answer, exit 10 (keep in sync with
//                 RC_OTHER in `noti`). Esc backs out one level, draft kept;
//                 the row is fixed-height so the card NEVER reflows.
//   NOTI_STATE    "other" auto-opens the Other editor ~0.1s after present —
//                 snapshot/design aid (pairs with NOTI_SNAPSHOT and the
//                 preview-toasts skill), works in both palettes.
//   NOTI_APPEARANCE  light | dark — force a palette (snapshot/design review
//                 aid; live toasts follow the system)
//
// Design notes (these are deliberate):
//   * .accessory activation policy  -> no Dock icon, no menu bar.
//   * .borderless + .nonactivatingPanel -> never steals focus from your editor.
//   * canJoinAllSpaces + .stationary -> appears on the *current* Space without
//     switching Spaces. Clicks still register on a non-activating panel.
//   * The panel is placed on the screen that currently contains the mouse, so it
//     shows up where you're looking on multi-monitor setups.
//   * The card follows macOS notification-banner anatomy — icon chip at the
//     leading edge, text block beside it, ~16pt continuous corners — so it
//     reads as a system surface, not a foreign dialog. The chip's tint is the
//     risk class; its glyph is the tool. Claude's terracotta is reserved for
//     identity moments (primary action, countdown, armed border, run/summary
//     chips): a glance says "Claude wants me", not "some app wants me".
//   * Cards are sized to their content — a one-line `ls` gets a compact card,
//     a long command gets room (capped at 5 lines). Text is measured with the
//     same NSTextField cell that renders it, and a clipped command always shows
//     a trailing ellipsis — approving a command you can only see part of, and
//     don't know is partial, is how mistakes happen.
//   * The ask card's bottom hairline drains over NOTI_TIMEOUT: when it empties,
//     the prompt falls back to the terminal. The deadline is never a surprise.
//   * Question cards (NOTI_OPTIONS set) render options as a VERTICAL NUMBERED
//     LIST — the same shape as Claude Code's terminal picker, so "press 1..4"
//     muscle memory transfers. Labels render in full (2-line wrap, real "…"),
//     each with its description beneath. No option is styled as the default
//     and Return is deliberately inert on these cards: options are semantic
//     peers, and an invisible default is how a reflexive keystroke submits an
//     answer the user never chose. Esc still hands off to the terminal.
//   * Hotkeys are HOVER-ARMED: the panel only grabs the keyboard after the mouse
//     *moves* over it. A toast appearing under a parked cursor, or while you're
//     typing in the terminal, can never swallow a keystroke — so an in-flight
//     "y" can't accidentally approve anything. Arming is visible (accent border,
//     keycaps brighten); moving the mouse off disarms and hands the keyboard back.
//   * Motion: cards arrive from the corner's screen edge (the direction a
//     system banner comes from) and EVERY exit — answer, Esc, timeout, click,
//     auto-dismiss — leaves through dismissThenExit()'s fade: a card that
//     blinks off mid-glance reads as a crash, not a completion. The stacked
//     column re-packs the moment a neighbour's slot file disappears, and
//     everything that moves shares one deceleration curve so concurrent cards
//     read as one surface. Reduce-motion keeps the fades, drops the slides.
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

// Snapshot/design aid: force a palette so both light and dark can be reviewed
// headlessly. Must happen before any view resolves a color.
if let forced = env["NOTI_APPEARANCE"] {
    app.appearance = NSAppearance(named: forced == "light" ? .aqua : .darkAqua)
}

// ----------------------------------------------------------------------------
// Geometry + text helpers
// ----------------------------------------------------------------------------

func targetScreen() -> NSScreen {
    let mouse = NSEvent.mouseLocation
    for s in NSScreen.screens where NSMouseInRect(mouse, s.frame, false) { return s }
    return NSScreen.main ?? NSScreen.screens[0]
}

// ----------------------------------------------------------------------------
// Slot stacking — concurrent toasts form one packed, self-healing column.
//
// Each slotted toast publishes its own pixel height into its slot file (the
// Python side creates the file EMPTY; only the binary ever writes a number)
// and heartbeats it every 0.4s so a killed toast goes stale fast. A toast's
// vertical offset is the sum of the LIVE heights below it — not
// slot-index × its own height, which overlaps a taller card and floats past a
// shorter one — and every tick it re-packs, sliding up smoothly when a
// neighbour dismisses.
// ----------------------------------------------------------------------------

let slotIndex = max(0, Int(env["NOTI_SLOT"] ?? "0") ?? 0)
let slotDir = env["NOTI_SLOT_DIR"]
let slotGap: CGFloat = 10
var slotFile: String?          // global: read by the capture-less atexit handler
var slotWatcher: DispatchSourceFileSystemObject?   // keep-alive for the dir watch
var repackPending = false      // leading-edge throttle for watcher-driven re-packs

func stackOffset(myHeight: CGFloat) -> CGFloat {
    guard let dir = slotDir else {
        return CGFloat(slotIndex) * (myHeight + slotGap)   // bare CLI use: no registry
    }
    var off: CGFloat = 0
    for j in 0..<slotIndex {
        let p = "\(dir)/slot-\(j)"
        guard FileManager.default.fileExists(atPath: p) else { continue }
        // an empty file is "claimed, height not yet published" — assume a card
        // like mine; the clamp keeps garbage from stacking the toast off-screen
        let h = (try? String(contentsOfFile: p, encoding: .utf8))
            .flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .flatMap { (40...800).contains($0) ? CGFloat($0) : nil }
        off += (h ?? myHeight) + slotGap
    }
    return off
}

func origin(in vf: NSRect, width: CGFloat, height: CGFloat, stack: CGFloat) -> NSPoint {
    let margin: CGFloat = 16
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

// Wrapped text is measured with a real NSTextFieldCell — the exact machinery
// that renders it. boundingRect() wraps slightly differently around quotes and
// backslashes, and a height that disagrees with layout means a command clipped
// with no visible ellipsis: the user approves text they can't see. Returns the
// height *and* the line count that fits, so the label's maximumNumberOfLines
// can be set to what actually renders (that's what makes the "…" appear).
func measure(_ s: String, font: NSFont, width: CGFloat, maxLines: Int) -> (height: CGFloat, lines: Int) {
    let t = NSTextField(labelWithString: s)
    t.font = font
    t.lineBreakMode = .byWordWrapping
    t.cell?.wraps = true
    t.maximumNumberOfLines = 0
    // per-line height must come from the cell too: NSLayoutManager says 13pt
    // where the cell renders 14pt lines, and a frame built on the smaller
    // number silently loses its last line ("Mg" probe = one cell line, immune
    // to embedded newlines in the measured string)
    let probe = NSTextField(labelWithString: "Mg")
    probe.font = font
    let lh = probe.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: 10_000, height: 10_000)).height
             ?? lineHeight(font)
    let full = t.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 100_000)).height ?? lh
    let lines = max(1, min(maxLines, Int((full / lh).rounded())))
    return (CGFloat(lines) * lh, lines)
}

// Claude's terracotta — the identity accent. Lifted a touch in dark mode so it
// keeps its warmth against the dark material instead of going muddy.
let claude = NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        ? NSColor(srgbRed: 0.898, green: 0.545, blue: 0.427, alpha: 1)   // ≈ #E58B6D
        : NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1)   // ≈ #D97757
}

// Semantic chip: tint is the action's risk class, readable before a single
// word. run and note wear Claude's terracotta — the everyday ask and the
// end-of-turn card are where "that's Claude" has to land from across the room.
func kindColor(_ kind: String) -> NSColor {
    switch kind {
    case "run":      return claude
    case "edit":     return .systemBlue
    case "fetch":    return .systemPurple
    case "mcp":      return .systemTeal
    case "note":     return claude
    case "question": return .systemIndigo
    case "plan":     return .systemGreen
    default:         return .systemGray
    }
}

func kindGlyph(_ kind: String) -> String {
    switch kind {
    case "run":      return "terminal.fill"
    case "edit":     return "pencil"
    case "fetch":    return "globe"
    case "mcp":      return "puzzlepiece.extension.fill"
    case "note":     return "sparkles"
    case "question": return "questionmark.bubble.fill"
    case "plan":     return "checklist"
    default:         return "questionmark"
    }
}

// Terminal-material kinds show their payload in monospace at full contrast —
// the command IS the content. Questions and plan previews are prose.
let monoKinds: Set<String> = ["run", "edit", "fetch", "mcp", "tool"]

let hairline = NSColor.separatorColor

// The one deceleration curve for everything that moves — the entrance slide,
// the column settling after a neighbour leaves. Fast start, long soft landing
// (an ease-out-quint, roughly how system banners arrive); the stock .easeOut
// stops too abruptly and reads mechanical next to real Notification Center
// motion. One curve everywhere is what makes concurrent cards move like one
// surface instead of a pile of independent windows.
let settleCurve = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)

// A borderless panel refuses key status by default; hotkeys need it. The panel
// still never *activates* the app (.nonactivatingPanel), so Spaces/focus stay put.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// Tracks the mouse so hotkeys arm only on deliberate movement over the card.
final class HoverEffectView: NSVisualEffectView {
    var onArm: (() -> Void)?
    var onLeave: (() -> Void)?
    // read by endEditing() to decide between staying armed (mouse still on
    // the card) and running the full leave routine (keyboard goes home)
    private(set) var inside = false
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
    vev.layer?.cornerRadius = 16                  // current banner geometry (Sonoma/Sequoia scale)
    vev.layer?.cornerCurve = .continuous          // Apple's squircle, not a pure round
    vev.layer?.masksToBounds = true
    vev.layer?.borderWidth = 1
    vev.layer?.borderColor = hairline.cgColor     // definition against busy backdrops
    panel.contentView = vev

    // screen resolved ONCE — the reflow tick below must re-pack the column,
    // not chase the mouse to another monitor mid-display
    let vf = targetScreen().visibleFrame
    panel.setFrameOrigin(origin(in: vf, width: width, height: height,
                                stack: stackOffset(myHeight: height)))

    if let dir = slotDir {
        let mine = "\(dir)/slot-\(slotIndex)"
        try? "\(Int(height))".write(toFile: mine, atomically: true, encoding: .utf8)
        slotFile = mine
        atexit { if let p = slotFile { try? FileManager.default.removeItem(atPath: p) } }
        let repack = { (duration: TimeInterval) in
            // the corner card never moves; a dying card holds still while it
            // fades — sliding a half-transparent card up the column reads as
            // a glitch, and its slot is only truly free once it exits
            guard slotIndex > 0, !dismissing else { return }
            let target = origin(in: vf, width: width, height: height,
                                stack: stackOffset(myHeight: height))
            guard abs(target.y - panel.frame.origin.y) > 0.5 else { return }
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                panel.setFrameOrigin(target)
            } else {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = duration
                    ctx.timingFunction = settleCurve
                    panel.animator().setFrameOrigin(target)
                }
            }
        }
        Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
            // heartbeat: mtime is the liveness signal for the Python stale
            // sweep. Runs to the very end — the slot is owned until exit.
            try? "\(Int(height))".write(toFile: mine, atomically: true, encoding: .utf8)
            repack(0.3)                                    // backstop re-pack
        }
        if slotIndex > 0 {
            // kqueue watch on the slot dir: a neighbour's exit deletes its
            // slot file and the column settles ~0.1s later, not at whatever
            // phase the 0.4s tick happens to be — the lurch after a dismissal
            // was the single most visible seam in the stacking illusion.
            // Leading-edge throttle, NOT cancel-and-reschedule debounce:
            // sibling heartbeats write the dir every 0.4s, so a debounce that
            // resets on every event could starve forever. The 0.1s pause also
            // rides out delete-then-recreate blips (a multi-question flow
            // re-claims its slot between cards) without a bounce. The fd is
            // deliberately never closed — it lives exactly as long as the
            // process. Failure at any step falls back to the 0.4s tick.
            let fd = open(dir, O_EVTONLY)
            if fd >= 0 {
                let watcher = DispatchSource.makeFileSystemObjectSource(
                    fileDescriptor: fd, eventMask: .write, queue: .main)
                watcher.setEventHandler {
                    guard !repackPending else { return }
                    repackPending = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        repackPending = false
                        repack(0.3)
                    }
                }
                watcher.resume()
                slotWatcher = watcher
            }
        }
    }
    return (panel, vev)
}

func label(_ s: String, font: NSFont, color: NSColor, frame: NSRect, maxLines: Int = 1) -> NSTextField {
    let t = NSTextField(labelWithString: s)
    t.frame = frame
    t.font = font
    t.textColor = color
    t.maximumNumberOfLines = maxLines
    if maxLines > 1 {
        // wrap + truncatesLastVisibleLine is the combo that renders a real "…"
        // on the last fitting line; .byTruncatingTail alone wraps but clips
        // silently when fewer lines fit than maximumNumberOfLines
        t.lineBreakMode = .byWordWrapping
        t.cell?.wraps = true
        t.cell?.truncatesLastVisibleLine = true
    } else {
        t.lineBreakMode = .byTruncatingTail
    }
    t.cell?.isScrollable = false
    return t
}

// The icon chip — a notification banner leads with the app icon; this card
// leads with the kind. Continuous-corner tinted square, white SF Symbol glyph.
func chipView(x: CGFloat, y: CGFloat, size: CGFloat, kind: String) -> NSView {
    let v = NSView(frame: NSRect(x: x, y: y, width: size, height: size))
    v.wantsLayer = true
    v.layer?.backgroundColor = kindColor(kind).cgColor
    v.layer?.cornerRadius = size * 0.3
    v.layer?.cornerCurve = .continuous
    let cfg = NSImage.SymbolConfiguration(pointSize: size * 0.5, weight: .semibold)
    if let img = (NSImage(systemSymbolName: kindGlyph(kind), accessibilityDescription: kind)
                  ?? NSImage(systemSymbolName: "circle.fill", accessibilityDescription: kind))?
        .withSymbolConfiguration(cfg) {
        let iv = NSImageView(image: img)
        iv.contentTintColor = .white
        iv.imageScaling = .scaleNone
        iv.frame = v.bounds
        v.addSubview(iv)
    }
    return v
}

func timeoutSeconds(default def: Double) -> Double {
    if let raw = env["NOTI_TIMEOUT"], let v = Double(raw) { return v }
    return def
}

// Banner entrance: fade + a short slide in from the corner's adjacent screen
// edge — the direction a system banner arrives from, so the card reads as
// "delivered to the corner", where the old vertical settle read as "dropped
// on it". 24pt is enough to give the motion a direction without the card
// visibly crossing content. Respects the system reduce-motion setting.
func present(_ panel: NSPanel) {
    let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    let target = panel.frame
    if !reduce {
        let dx: CGFloat = (env["NOTI_CORNER"] ?? "top-right").hasSuffix("left") ? -24 : 24
        panel.setFrameOrigin(NSPoint(x: target.origin.x + dx, y: target.origin.y))
    }
    panel.alphaValue = 0
    panel.orderFrontRegardless()
    NSAnimationContext.runAnimationGroup { ctx in
        ctx.duration = reduce ? 0.12 : 0.3
        ctx.timingFunction = settleCurve
        panel.animator().alphaValue = 1
        if !reduce { panel.animator().setFrame(target, display: true) }
    }
}

// ----------------------------------------------------------------------------
// Animated exit — every exit the user can see goes through here. A card that
// blinks off mid-glance reads as a crash, not a completion; the fade + short
// slide toward the edge it arrived from says "handled". The answer contract
// is untouched: stdout is written BEFORE the animation and the exit code
// lands ~0.15s later — imperceptible next to the human who just clicked.
// ----------------------------------------------------------------------------

var activePanel: NSPanel?      // set by each mode right after makeCard
var dismissing = false         // the first answer wins, forever
// noti's own belief about key status, maintained at the two makeKey() sites
// and the didResignKey observer. Deliberately NOT panel.isKeyWindow: that
// property is @MainActor-annotated in current SDKs and reading it from a
// global (Sendable) function is a Swift 6 error — and the belief is the
// truer test anyway ("did WE take the keyboard"), immune to a stray panel
// becoming key by some path noti never armed.
var panelHasKey = false

// The `dismissing` latch plus ignoresMouseEvents make a double-fire during
// the fade impossible (instant exit() used to get that for free); a dropped
// second call drops its output too, so stdout can never carry two answers.
// User-initiated exits are quick (0.15s — the user acted, get out of the
// way); timeouts and auto-dismissals may pass a gentler duration (nobody is
// waiting on those). Reduce-motion: short pure fade.
func dismissThenExit(code: Int32, output: String? = nil, duration: TimeInterval = 0.15) {
    guard !dismissing else { return }
    dismissing = true
    if let output { FileHandle.standardOutput.write(Data((output + "\n").utf8)) }
    guard let panel = activePanel else { exit(code) }   // fail-open: no panel, no ceremony
    // Mouse events keep landing ON the fading card (every handler is inert
    // behind the latch) — ignoresMouseEvents would pass clicks THROUGH a
    // still-visible card to whatever sits beneath it, which is worse.
    if panelHasKey {
        // the keyboard goes home the instant the answer commits, not when the
        // fade ends — orderOut + re-orderFront is the proven handoff (see
        // onLeave; resignKey alone leaves the keyboard in limbo). Deferred one
        // turn: the Other-submit path reaches here from INSIDE the field
        // editor's doCommandBy, and tearing down first-responder state
        // re-entrantly from that stack is how AppKit crashes are made.
        DispatchQueue.main.async {
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
    }
    let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    NSAnimationContext.runAnimationGroup({ ctx in
        ctx.duration = reduce ? 0.1 : duration
        ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
        panel.animator().alphaValue = 0
        if !reduce {
            var f = panel.frame
            f.origin.x += (env["NOTI_CORNER"] ?? "top-right").hasSuffix("left") ? -14 : 14
            panel.animator().setFrame(f, display: true)
        }
    }, completionHandler: { exit(code) })
}

// Debug aid: NOTI_SNAPSHOT=/path.png renders the card's own view hierarchy to
// a PNG shortly after presenting, then exits — no screen-recording permission
// needed. (The vibrancy blur can't be sampled this way; layout/type/color can.)
func snapshotIfRequested(_ vev: NSView) {
    guard let path = env["NOTI_SNAPSHOT"] else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        // a committed answer's code must win: this exit(0) landing mid-fade
        // would rewrite e.g. a clicked "No" (exit 2) into option 0's index
        guard !dismissing else { return }
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

// Anything the user can pick on an ask card. The horizontal ToastButton and
// the list-mode OptionRow share firing, arming, and the answer contract:
// stdout = label, exit code = tag = option index (the Python side maps the
// index back to the EXACT option string, so display text is never the answer).
protocol Choice: AnyObject {
    var label: String { get }
    var key: String { get }
    func fire()
    func setArmed(_ armed: Bool)
}

final class Handler: NSObject {
    @objc func tap(_ sender: Any?) {
        guard let b = sender as? (NSControl & Choice) else { exit(70) }
        // stdout = label, exit code == option index — via the animated exit
        dismissThenExit(code: Int32(b.tag), output: b.label)
    }
    @objc func dismiss(_ sender: Any?) {
        dismissThenExit(code: 0)               // summary: click anywhere to dismiss
    }
}

// ----------------------------------------------------------------------------
// ToastButton — flat, self-documenting button with its hotkey as a keycap chip.
// Stock NSButton bezels read as a generic system dialog; these are quiet,
// continuous-corner fills where the primary action carries Claude's terracotta
// (not the user's system accent — the answer button should look like it belongs
// to Claude, not to a random dialog) and the keycap answers "how do I press
// this" without a legend.
// ----------------------------------------------------------------------------

final class ToastButton: NSControl, Choice {
    let label: String
    let key: String                    // hotkey character ("" = none shown)
    private let primary: Bool
    private var capBox: NSView?
    private var fill: NSColor { primary ? claude
                                        : NSColor.labelColor.withAlphaComponent(0.08) }
    private var hoverFill: NSColor { primary ? claude.withAlphaComponent(0.85)
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
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)

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
// OptionRow — one full-width option in the list-mode ask card. The leading
// digit keycap doubles as the list numeral, so it stays visible even with
// hotkeys disabled (the ordinal is content, not just an affordance — it just
// never brightens, because no key monitor is installed). No terracotta, no
// "primary" row: an AskUserQuestion's options are semantic peers, and styling
// one as the default is how a reflexive keystroke picks the wrong answer.
// Labels wrap to 2 lines and descriptions clamp to 2, both through the same
// cell machinery as the message label, so any clip shows a real "…".
// ----------------------------------------------------------------------------

final class OptionRow: NSControl, Choice {
    let label: String                  // full display label — stdout on click
    let key: String                    // digit hotkey; always drawn as numeral
    private var capBox: NSView?
    private var fill: NSColor { NSColor.labelColor.withAlphaComponent(0.08) }
    private var hoverFill: NSColor { NSColor.labelColor.withAlphaComponent(0.14) }

    static let labelFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    static let descFont  = NSFont.systemFont(ofSize: 11)
    static let capSize: CGFloat = 18
    static let textX: CGFloat = 10 + capSize + 8      // keycap gutter

    init(title: String, desc: String, key: String, tag: Int, width: CGFloat,
         target: AnyObject?, action: Selector) {
        self.label = title
        self.key = key
        let textW = width - OptionRow.textX - 10
        let (labelH, labelLines) = measure(title, font: OptionRow.labelFont,
                                           width: textW, maxLines: 2)
        let (descH, descLines): (CGFloat, Int) = desc.isEmpty ? (0, 0)
            : measure(desc, font: OptionRow.descFont, width: textW, maxLines: 2)
        let h = max(30, 8 + labelH + (descH > 0 ? 2 + descH : 0) + 8)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: h))
        self.tag = tag
        self.target = target
        self.action = action
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = fill.cgColor
        setAccessibilityRole(.button)
        setAccessibilityLabel(desc.isEmpty ? title : "\(title), \(desc)")

        // mirrors the global label() helper's multiline branch — can't call it
        // here because the Choice `label` property shadows the function name
        func textField(_ s: String, font: NSFont, color: NSColor,
                       frame: NSRect, lines: Int) -> NSTextField {
            let t = NSTextField(labelWithString: s)
            t.frame = frame
            t.font = font
            t.textColor = color
            t.maximumNumberOfLines = lines
            t.lineBreakMode = .byWordWrapping
            t.cell?.wraps = true
            t.cell?.truncatesLastVisibleLine = true
            t.cell?.isScrollable = false
            return t
        }

        // keycap centers against the FIRST label line, not the row: a row with
        // a 2-line description must not divorce the numeral from its label
        let lineH = measure("Mg", font: OptionRow.labelFont, width: textW, maxLines: 1).height
        let cap = NSView(frame: NSRect(x: 10, y: h - 8 - lineH / 2 - OptionRow.capSize / 2,
                                       width: OptionRow.capSize, height: OptionRow.capSize))
        cap.wantsLayer = true
        cap.layer?.cornerRadius = 5
        cap.layer?.cornerCurve = .continuous
        cap.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.10).cgColor
        let k = NSTextField(labelWithString: key)
        k.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        k.textColor = .secondaryLabelColor
        k.alignment = .center
        k.frame = NSRect(x: 0, y: 2, width: OptionRow.capSize, height: 14)
        cap.addSubview(k)
        capBox = cap
        addSubview(cap)

        addSubview(textField(title, font: OptionRow.labelFont, color: .labelColor,
                             frame: NSRect(x: OptionRow.textX, y: h - 8 - labelH,
                                           width: textW, height: labelH),
                             lines: labelLines))
        if descH > 0 {
            addSubview(textField(desc, font: OptionRow.descFont, color: .secondaryLabelColor,
                                 frame: NSRect(x: OptionRow.textX,
                                               y: h - 8 - labelH - 2 - descH,
                                               width: textW, height: descH),
                                 lines: descLines))
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    // numerals brighten when the card arms — same "keyboard is live" signal
    // as ToastButton's keycaps
    func setArmed(_ armed: Bool) {
        capBox?.layer?.backgroundColor =
            NSColor.labelColor.withAlphaComponent(armed ? 0.20 : 0.10).cgColor
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
// OtherRow — the free-text escape hatch on a question card (NOTI_OTHER=1).
// GHOST register on purpose: no fill, hairline border — an escape hatch, not
// a fifth answer (options are semantic peers; this row is a different kind of
// thing and must read as one). FIXED 30pt height: the label swaps for the
// editor IN PLACE and long text scrolls in a single line, so the card never
// reflows and the published slot height stays truthful with zero work.
// `tag` is the display ordinal ONLY — fire() opens the editor; it must NEVER
// route through Handler.tap, whose stdout+exit(tag) contract would fabricate
// an option answer out of a UI affordance.
// ----------------------------------------------------------------------------

final class OtherRow: NSControl, Choice {
    let label = "Other…"
    let key: String                    // digit N+1 — the list ordinal continues
    var onFire: (() -> Void)?          // wired to beginEditing() by the ask case
    private(set) var active = false    // editor visible (editing state)
    let field: NSTextField             // pre-built, hidden until first edit
    private let rowLabel: NSTextField
    private var capBox: NSView!
    private var capLabel: NSTextField!
    static let height: CGFloat = 30    // the single-line minimum
    private var hoverFill: NSColor { NSColor.labelColor.withAlphaComponent(0.14) }
    private var ghostBorder: CGColor { NSColor.labelColor.withAlphaComponent(0.12).cgColor }

    init(key: String, tag: Int, width: CGFloat) {
        self.key = key
        let textW = width - OptionRow.textX - 10
        let lineH = measure("Mg", font: OptionRow.labelFont, width: textW, maxLines: 1).height
        // single-line editor: no wrap, long text scrolls horizontally —
        // what you see is what you send, and the height stays constant. No
        // focus ring: the terracotta row hairline is the capture signal.
        field = NSTextField(frame: NSRect(x: OptionRow.textX,
                                          y: (OtherRow.height - lineH - 4) / 2,
                                          width: textW, height: lineH + 4))
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.font = OptionRow.labelFont
        field.placeholderString = "Type your answer…"
        field.isHidden = true
        rowLabel = NSTextField(labelWithString: "Other…")
        rowLabel.font = OptionRow.labelFont
        rowLabel.textColor = .secondaryLabelColor
        rowLabel.lineBreakMode = .byTruncatingTail
        rowLabel.frame = NSRect(x: OptionRow.textX, y: (OtherRow.height - lineH) / 2,
                                width: textW, height: lineH)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: OtherRow.height))
        self.tag = tag
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.borderColor = ghostBorder
        setAccessibilityRole(.button)
        setAccessibilityLabel("Other: type your own answer")

        // keycap: same geometry as OptionRow's, centered on the fixed row
        let cap = NSView(frame: NSRect(x: 10, y: (OtherRow.height - OptionRow.capSize) / 2,
                                       width: OptionRow.capSize, height: OptionRow.capSize))
        cap.wantsLayer = true
        cap.layer?.cornerRadius = 5
        cap.layer?.cornerCurve = .continuous
        cap.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.10).cgColor
        let k = NSTextField(labelWithString: key)
        k.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        k.textColor = .secondaryLabelColor
        k.alignment = .center
        k.frame = NSRect(x: 0, y: 2, width: OptionRow.capSize, height: 14)
        cap.addSubview(k)
        capBox = cap
        capLabel = k
        addSubview(cap)
        addSubview(rowLabel)
        addSubview(field)
    }

    required init?(coder: NSCoder) { fatalError() }

    // editing-state visuals: the terracotta hairline says "the keyboard lives
    // HERE now"; the keycap becomes the submit hint
    func beginEdit() {
        active = true
        layer?.backgroundColor = nil
        rowLabel.isHidden = true
        field.isHidden = false
        layer?.borderColor = claude.cgColor
        capLabel.stringValue = "↩"
    }

    func endEdit() {
        active = false
        // a non-empty draft becomes the row label — re-entry visibly resumes
        let draft = field.stringValue
        rowLabel.stringValue =
            draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Other…" : draft
        field.isHidden = true
        rowLabel.isHidden = false
        layer?.borderColor = ghostBorder
        capLabel.stringValue = key
    }

    func setArmed(_ armed: Bool) {
        capBox.layer?.backgroundColor =
            NSColor.labelColor.withAlphaComponent(armed ? 0.20 : 0.10).cgColor
    }

    func fire() { onFire?() }          // NEVER Handler.tap — see class comment

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) {
        if !active { layer?.backgroundColor = hoverFill.cgColor }
    }
    override func mouseExited(with event: NSEvent) {
        if !active { layer?.backgroundColor = nil }
    }
    override func mouseDown(with event: NSEvent) { if !active { alphaValue = 0.7 } }
    override func mouseUp(with event: NSEvent) {
        alphaValue = 1
        guard !active else { return }  // while editing, clicks belong to the editor
        if bounds.contains(convert(event.locationInWindow, from: nil)) { fire() }
    }
}

// ----------------------------------------------------------------------------
// CommitDelegate — ALL editing key semantics via doCommandBy selectors, NEVER
// raw keycodes: during CJK composition the input context consumes Return/Esc,
// so only a real commit/cancel ever reaches this delegate — a keyCode check
// in the event monitor would kill the card mid-composition. Treat any future
// "simplification" back into keycodes as a regression.
// ----------------------------------------------------------------------------

final class CommitDelegate: NSObject, NSTextFieldDelegate {
    var onCancel: (() -> Void)?

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) {
            // single-line field: newlines only arrive by paste (if at all —
            // belt-and-suspenders), normalize each line break to ONE space so
            // what-you-see-is-what-you-send holds
            let flat = control.stringValue
                .replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
            // Return is inert on empty/whitespace-only text — the wire
            // invariant says the binary never exits 10 without an answer
            // (heir of the Return-inert list rule: Return only submits text
            // the user authored and can see)
            if flat.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
            dismissThenExit(code: 10, output: flat)   // keep 10 in sync with RC_OTHER in `noti`
            return true
        }
        if sel == #selector(NSResponder.cancelOperation(_:)) {
            onCancel?()                // back to list state, draft preserved
            return true
        }
        // nothing to tab to — swallowing keeps focus from stranding
        if sel == #selector(NSResponder.insertTab(_:))
            || sel == #selector(NSResponder.insertBacktab(_:)) { return true }
        return false
    }

    func controlTextDidChange(_ note: Notification) {
        guard let f = note.object as? NSTextField else { return }
        // never mutate mid-IME-composition: replacing stringValue would
        // destroy the marked text
        if let tv = f.currentEditor() as? NSTextView, tv.hasMarkedText() { return }
        // input-time cap, visibly — NEVER truncate at submit (silent
        // integrity break)
        if f.stringValue.count > 2000 { f.stringValue = String(f.stringValue.prefix(2000)) }
    }
}

// ----------------------------------------------------------------------------
// Modes
// ----------------------------------------------------------------------------

switch mode {

case "ask":   // noti-toast ask "Title" "Message" "Yes" "Always" "No"
    let title   = args.count > 1 ? args[1] : ""
    let message = args.count > 2 ? args[2] : ""
    // prefix(3) is deliberate: four fallback buttons overflow the 560pt cap.
    // 4-option cards always arrive via NOTI_OPTIONS (Python guarantees every
    // field non-empty, so a current binary never falls back for them); only a
    // pre-list binary caps a 4-option question at 3, with Esc -> terminal
    // still offering everything.
    let buttons = Array(args.dropFirst(3)).isEmpty ? ["OK"] : Array(args.dropFirst(3).prefix(3))
    let hotkeys = (env["NOTI_HOTKEYS"] ?? "1") != "0"
    let kind    = env["NOTI_KIND"] ?? ""
    let project = env["NOTI_PROJECT"] ?? ""
    let footer  = env["NOTI_FOOTER"] ?? ""

    // List mode: NOTI_OPTIONS carries the FULL option labels (\u{1f}-joined);
    // argv keeps truncated fallbacks so a stale binary renders the classic
    // card. Anything malformed — wrong arity, an empty label — falls back to
    // the horizontal row: fail-open lives in the UI too.
    func usFields(_ v: String?) -> [String] {
        guard let v, !v.isEmpty else { return [] }
        return v.components(separatedBy: "\u{1f}")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
    let optLabels = usFields(env["NOTI_OPTIONS"])
    let listMode = (2...4).contains(optLabels.count) && optLabels.allSatisfy { !$0.isEmpty }
    // Free-text "Other": opt-in via NOTI_OTHER=1, list mode ONLY — a stray
    // export must never bolt a text field onto a permission prompt. PURE UI:
    // never an extra NOTI_OPTIONS field, never an extra exit-code index.
    let allowOther = listMode && (env["NOTI_OTHER"] == "1")
    var optDescs = usFields(env["NOTI_DESCS"])
    if optDescs.count != optLabels.count {
        // never guess pairings: a description under the wrong option is an
        // answer-integrity bug, so an arity mismatch drops them all
        optDescs = Array(repeating: "", count: optLabels.count)
    }

    // hotkey per button = its first letter; duplicates keep first-wins and the
    // later button shows no keycap (still clickable). List mode uses digits
    // 1..N — the terminal picker's numbering, collision-proof by construction
    // (and drawn even with hotkeys off: the numeral is the list's ordinal)
    var seen = Set<String>()
    let keys: [String] = listMode
        ? (1...(optLabels.count + (allowOther ? 1 : 0))).map(String.init)
        : buttons.map {
            let k = String($0.lowercased().prefix(1))
            return (hotkeys && !k.isEmpty && seen.insert(k).inserted) ? k : ""
        }

    // measure buttons first: custom labels via the `noti ask` CLI may need a
    // wider card than the stock Yes/Always/No (which fits in 360)
    let btnWidths: [CGFloat] = listMode ? [] : zip(buttons, keys).map {
        ToastButton.width(title: $0, showKey: !$1.isEmpty)
    }
    let btnRowW = btnWidths.reduce(0, +) + CGFloat(max(0, buttons.count - 1)) * 8

    let pad: CGFloat = 16
    let chip: CGFloat = 26                     // banner anatomy: icon chip leads
    // list cards are fixed-width — rows wrap to the card, never the card to
    // the rows — sized between the 360 summary and the 560 ask cap
    let W: CGFloat = listMode ? 420 : min(560, max(360, btnRowW + 2 * pad))
    let textW = W - 2 * pad
    let headX = pad + chip + 10                // text block sits beside the chip
    let headW = W - headX - pad
    let eyebrowFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    let titleFont   = NSFont.systemFont(ofSize: 13, weight: .semibold)
    let mono = monoKinds.contains(kind)
    let msgFont: NSFont = mono ? .monospacedSystemFont(ofSize: 11.5, weight: .regular)
                               : .systemFont(ofSize: 12)
    let msgColor: NSColor = mono ? .labelColor : .secondaryLabelColor

    let eyeH: CGFloat = project.isEmpty ? 0 : lineHeight(eyebrowFont)
    let titleH = lineHeight(titleFont)
    let headerH = max(chip, eyeH + (eyeH > 0 ? 3 : 0) + titleH)
    // list mode trims the question to 4 lines: Python caps it at 220 chars
    // (≈3.6 lines at this width), so nothing real is lost and the option rows
    // get the room
    let (msgH, msgLines): (CGFloat, Int) =
        message.isEmpty ? (0, 0) : measure(message, font: msgFont, width: textW,
                                           maxLines: listMode ? 4 : 5)

    let handler = Handler()
    var rows: [NSControl & Choice] = []
    var otherRow: OtherRow?
    if listMode {
        for (i, lab) in optLabels.enumerated() {
            rows.append(OptionRow(title: lab, desc: optDescs[i], key: keys[i], tag: i,
                                  width: textW, target: handler,
                                  action: #selector(Handler.tap(_:))))
        }
        if allowOther {
            // joins rows/choices so layout, setArmed, and the digit-match
            // loop treat it uniformly; only its fire() differs (opens the
            // editor instead of routing to Handler.tap)
            let o = OtherRow(key: keys[optLabels.count], tag: optLabels.count, width: textW)
            otherRow = o
            rows.append(o)
        }
    }
    let rowsH = rows.reduce(0) { $0 + $1.frame.height } + CGFloat(max(0, rows.count - 1)) * 6
    let footerFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    let footerH: CGFloat = (listMode && !footer.isEmpty) ? lineHeight(footerFont) : 0

    var H: CGFloat = listMode ? 14 + headerH + 12 + rowsH + 14
                              : 14 + headerH + 12 + ToastButton.height + 14
    if msgH > 0 { H += 9 + msgH }
    if footerH > 0 { H += 8 + footerH }

    let (panel, vev) = makeCard(width: W, height: H)
    activePanel = panel
    let headerBottom = H - 14 - headerH
    vev.addSubview(chipView(x: pad, y: headerBottom + (headerH - chip) / 2, size: chip, kind: kind))
    if eyeH > 0 {
        vev.addSubview(label(project, font: eyebrowFont, color: .secondaryLabelColor,
                             frame: NSRect(x: headX, y: headerBottom + headerH - eyeH,
                                           width: headW, height: eyeH)))
        vev.addSubview(label(title, font: titleFont, color: .labelColor,
                             frame: NSRect(x: headX, y: headerBottom, width: headW, height: titleH)))
    } else {
        vev.addSubview(label(title, font: titleFont, color: .labelColor,
                             frame: NSRect(x: headX, y: headerBottom + (headerH - titleH) / 2,
                                           width: headW, height: titleH)))
    }
    if msgH > 0 {
        // full width below the header — command real estate beats strict
        // banner indentation; five mono lines at 11.5pt need every point
        vev.addSubview(label(message, font: msgFont, color: msgColor,
                             frame: NSRect(x: pad, y: headerBottom - 9 - msgH,
                                           width: textW, height: msgH), maxLines: msgLines))
    }

    var choices: [NSControl & Choice] = []
    var footerLabel: NSTextField?      // swapped to the editing hint mid-edit
    if listMode {
        var yTop = (msgH > 0 ? headerBottom - 9 - msgH : headerBottom) - 12
        for r in rows {
            r.setFrameOrigin(NSPoint(x: pad, y: yTop - r.frame.height))
            vev.addSubview(r)
            choices.append(r)
            yTop -= r.frame.height + 6
        }
        if footerH > 0 {
            // yTop sits one 6pt gap below the last row; the footer wants 8pt
            let fl = label(footer, font: footerFont, color: .tertiaryLabelColor,
                           frame: NSRect(x: pad, y: yTop + 6 - 8 - footerH,
                                         width: textW, height: footerH))
            vev.addSubview(fl)
            footerLabel = fl
        }
    } else {
        var x = W - pad
        for (i, name) in buttons.enumerated() {
            let b = ToastButton(title: name, key: keys[i], primary: i == 0,
                                tag: i, target: handler, action: #selector(Handler.tap(_:)))
            x -= btnWidths[i]
            b.setFrameOrigin(NSPoint(x: x, y: 14))
            x -= 8
            vev.addSubview(b)
            choices.append(b)
        }
    }

    // ------------------------------------------------------------------
    // Keyboard: hover-armed hotkeys + the Other editing mode. Editing IS
    // keyboard capture — always visible as the terracotta border — and it
    // PINS: onArm/onLeave are inert while editing, because a mouse drift
    // that disarmed mid-word would redirect the rest of a typed answer into
    // the live terminal (the exact keystroke-leak class noti exists to
    // prevent, inverted). The hover-arm rationale still holds: arming
    // prevents PASSIVE capture, and edit mode is unreachable passively —
    // entry needs a click or an armed digit press, two deliberate acts.
    // ------------------------------------------------------------------
    var armed = false
    var editing = false
    let commit = CommitDelegate()

    func disarmVisuals() {
        vev.layer?.borderColor = hairline.cgColor
        choices.forEach { $0.setArmed(false) }
    }

    func beginEditing() {
        // the one non-Handler re-entry path: a mouse-down held on the Other
        // row while the timeout fires still gets its mouse-up (the window
        // server latched it), and an unguarded beginEditing would makeKey()
        // a card that has already answered 124 and is fading out
        guard !dismissing, let o = otherRow, !editing else { return }
        // strict order: a click on a non-activating panel does NOT make it
        // key — makeKey FIRST (idempotent when hover-arming already did),
        // THEN the first-responder swap
        panel.makeKey()
        panelHasKey = true
        o.beginEdit()
        panel.makeFirstResponder(o.field)
        (o.field.currentEditor() as? NSTextView)?.insertionPointColor = claude
        editing = true
        // capture must be visible even when arming never happened (hotkeys
        // off / pure-click entry): editing forces the armed border on
        vev.layer?.borderColor = claude.withAlphaComponent(0.9).cgColor
        o.setArmed(true)
        // options recede but STAY clickable — clicking one mid-edit is
        // deliberate mouse rescue (it answers; the draft dies with the
        // process, which is what a rescue means)
        for r in rows where !(r is OtherRow) { r.alphaValue = 0.55; r.setArmed(false) }
        footerLabel?.stringValue = "return · submit   esc · back"
    }

    // keyLost = the panel already resigned key (user clicked away/Cmd-Tab):
    // restore list state WITHOUT touching key focus — never makeKey() or
    // orderOut/orderFront from that path, the keyboard is already home
    func endEditing(keyLost: Bool = false) {
        guard let o = otherRow, editing else { return }
        editing = false
        panel.makeFirstResponder(nil)  // commit the field editor into the field
        o.endEdit()
        for r in rows where !(r is OtherRow) { r.alphaValue = 1 }
        footerLabel?.stringValue = footer      // Python owns the list footer
        if !keyLost && hotkeys && vev.inside {
            // mouse still on the card: stay armed — the same capture contract
            // as hover-arming, and a second Esc (armed list state) exits 124:
            // consistent "Esc backs out one level"
            armed = true
            vev.layer?.borderColor = claude.withAlphaComponent(0.9).cgColor
            choices.forEach { $0.setArmed(true) }
        } else {
            armed = false
            disarmVisuals()
            if !keyLost {
                // today's full leave routine — the keyboard goes home the
                // instant the mode ends
                panel.orderOut(nil)
                panel.orderFrontRegardless()
            }
        }
    }

    commit.onCancel = { endEditing() }
    otherRow?.field.delegate = commit
    otherRow?.onFire = { beginEditing() }

    // Truthful-border guard: if the user clicks another app / Cmd-Tabs
    // mid-edit, the field editor is dead and keystrokes go elsewhere — the
    // UI must say so within a frame. (Also retires the latent stale-armed
    // border on click-away that predates this feature.)
    NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                                           object: panel, queue: .main) { _ in
        panelHasKey = false
        if editing {
            endEditing(keyLost: true)
        } else if armed {
            armed = false
            disarmVisuals()
        }
    }

    if hotkeys {
        vev.onArm = {
            guard !editing else { return }     // the pin: editing owns capture
            guard !armed else { return }
            armed = true
            panel.makeKey()
            panelHasKey = true
            // arming must be visible — the user needs to know the keyboard is live
            vev.layer?.borderColor = claude.withAlphaComponent(0.9).cgColor
            choices.forEach { $0.setArmed(true) }
        }
        vev.onLeave = {
            guard !editing else { return }     // the pin, leave side
            armed = false
            disarmVisuals()
            // orderOut + re-orderFront reliably hands key focus back to the
            // frontmost app; resignKey() alone leaves the keyboard in limbo
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
    }
    if hotkeys || allowOther {
        // with hotkeys off, arming never happens, so this monitor is a pure
        // pass-through EXCEPT while editing — "NOTI_HOTKEYS=0 = no
        // hover-armed hotkeys" holds while paste stays alive during explicit
        // editing. Editing keys (Return/Esc/Tab) are deliberately NOT here:
        // they live in CommitDelegate's doCommandBy selectors (IME safety —
        // see that class comment).
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { ev in
            // mid-fade the answer is already committed — swallow everything
            // (the panel can still be key for ~0.15s, so keys landing here
            // can't have been meant for the terminal)
            if dismissing { return nil }
            if editing {
                // .accessory app has no Edit menu -> shim the edit key
                // equivalents, routed down the KEY window's responder chain
                // (= the field editor)
                if ev.modifierFlags.contains(.command),
                   let ch = ev.charactersIgnoringModifiers?.lowercased() {
                    let map: [String: Selector] = ["v": #selector(NSText.paste(_:)),
                                                   "c": #selector(NSText.copy(_:)),
                                                   "x": #selector(NSText.cut(_:)),
                                                   "a": #selector(NSText.selectAll(_:))]
                    if let sel = map[ch] { NSApp.sendAction(sel, to: nil, from: nil); return nil }
                }
                return ev   // EVERYTHING else flows to the field editor / IME untouched
            }
            guard armed else { return ev }
            if ev.keyCode == 53 { dismissThenExit(code: 124); return nil }   // esc = no answer
            if ev.keyCode == 36 {
                // Return approves (Yes / Approve) on the classic row. A
                // question's options are peers: an invisible default is how
                // a reflexive Return submits an answer the user never chose,
                // so on list cards it's deliberately inert
                if !listMode { choices.first?.fire() }
                return nil
            }
            if ev.modifierFlags.intersection([.command, .control, .option]).isEmpty,
               let ch = ev.charactersIgnoringModifiers?.lowercased(), !ch.isEmpty {
                for c in choices where c.key == ch {
                    c.fire()
                    return nil
                }
            }
            return nil   // swallow unmapped keys while armed — never leak them
        }
    }

    let secs = timeoutSeconds(default: 120)   // safety net: never block forever if NOTI_TIMEOUT is unset
    if secs > 0 {
        Timer.scheduledTimer(withTimeInterval: secs, repeats: false) { _ in
            guard !dismissing else { return }      // an in-flight answer wins
            FileHandle.standardError.write(Data("timeout\n".utf8))
            // distinct: "no answer" — a touch slower than a click-exit; the
            // card expired, nobody is waiting on it
            dismissThenExit(code: 124, duration: 0.3)
        }
        // the deadline, made visible: a hairline that drains until the prompt
        // falls back to the terminal
        let drain = CALayer()
        drain.anchorPoint = CGPoint(x: 0, y: 0)
        drain.frame = CGRect(x: 0, y: 0, width: W, height: 2)
        drain.backgroundColor = claude.withAlphaComponent(0.5).cgColor
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
    // snapshot/design aid: NOTI_STATE=other opens the editor after present so
    // the editing state can be captured headlessly (NOTI_SNAPSHOT fires at
    // 0.5s, comfortably after)
    if allowOther && env["NOTI_STATE"] == "other" {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { beginEditing() }
    }
    present(panel)
    snapshotIfRequested(vev)
    _ = handler                                    // keep alive
    _ = commit                                     // field.delegate is weak
    app.run()

case "summary":   // noti-toast summary "Title" "Body\nlines"
    let title  = args.count > 1 ? args[1] : ""
    let body   = args.count > 2 ? args[2] : ""
    let kind   = env["NOTI_KIND"] ?? "note"
    let footer = env["NOTI_FOOTER"] ?? ""

    let W: CGFloat = 360, pad: CGFloat = 16, textW = W - 2 * pad
    let chip: CGFloat = 20
    let titleFont  = NSFont.systemFont(ofSize: 13, weight: .semibold)
    let bodyFont   = NSFont.systemFont(ofSize: 12)
    let footerFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)

    let titleH = lineHeight(titleFont)
    let rowH   = max(chip, titleH)
    let (bodyH, bodyLines): (CGFloat, Int) =
        body.isEmpty ? (0, 0) : measure(body, font: bodyFont, width: textW, maxLines: 3)
    let footerH: CGFloat = footer.isEmpty ? 0 : lineHeight(footerFont)

    var H: CGFloat = 12 + rowH + 12
    if bodyH > 0 { H += 6 + bodyH }
    if footerH > 0 { H += 6 + footerH }

    let (panel, vev) = makeCard(width: W, height: H)
    activePanel = panel
    let rowBottom = H - 12 - rowH
    vev.addSubview(chipView(x: pad, y: rowBottom + (rowH - chip) / 2, size: chip, kind: kind))
    vev.addSubview(label(title, font: titleFont, color: .labelColor,
                         frame: NSRect(x: pad + chip + 9, y: rowBottom + (rowH - titleH) / 2,
                                       width: textW - chip - 9, height: titleH)))
    var y = rowBottom
    if bodyH > 0 {
        y -= 6 + bodyH
        vev.addSubview(label(body, font: bodyFont, color: .secondaryLabelColor,
                             frame: NSRect(x: pad, y: y, width: textW, height: bodyH),
                             maxLines: bodyLines))
    }
    if footerH > 0 {
        y -= 6 + footerH
        vev.addSubview(label(footer, font: footerFont, color: .tertiaryLabelColor,
                             frame: NSRect(x: pad, y: y, width: textW, height: footerH)))
    }

    let handler = Handler()
    vev.addGestureRecognizer(NSClickGestureRecognizer(target: handler,
                                                      action: #selector(Handler.dismiss(_:))))

    // Native-banner behavior: the card holds while you're reading it (hover)
    // and relights a short fuse when you leave. Arming is movement-gated by
    // HoverEffectView, so a toast surfacing under a parked cursor still
    // dismisses on schedule — only deliberate attention pins it.
    var fuse: Timer?
    func scheduleDismiss(after t: TimeInterval) {
        fuse?.invalidate()
        fuse = Timer.scheduledTimer(withTimeInterval: t, repeats: false) { _ in
            dismissThenExit(code: 0, duration: 0.3)   // unhurried: nobody clicked
        }
    }
    let secs = timeoutSeconds(default: 6)
    scheduleDismiss(after: max(0.3, secs - 0.3))
    vev.onArm = { fuse?.invalidate(); fuse = nil }
    vev.onLeave = { scheduleDismiss(after: 1.2) }

    present(panel)
    snapshotIfRequested(vev)
    _ = handler                                    // keep alive
    app.run()

default:
    FileHandle.standardError.write(Data("unknown mode: \(mode)\n".utf8))
    exit(64)
}
