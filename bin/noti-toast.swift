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
//   noti-toast pet
//       Shows a long-lived, non-activating floating companion. It watches
//       NOTI_PET_STATE_DIR for per-session state files written by the Python
//       hook adapter and reflects the most urgent state. It never becomes key.
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
//   NOTI_PET_STATE_DIR  directory of pet state JSON files, one per session
//   NOTI_PET_WAITING_TTL seconds before a waiting state decays when no hook
//                 clears it (default 120)
//   NOTI_PET_DONE_TTL seconds before done/failed decay to asleep (default 6)
//   NOTI_PET_PID_FILE pid file to remove on direct pet UI close (best-effort)
//   NOTI_PET_SNAPSHOT_DIR  write a PNG of the pet surface after each state
//                 change (snapshot/design aid; pairs with preview-toasts)
//   NOTI_PET_REDUCE_MOTION 1|0 — force the reduce-motion branch (snapshot
//                 determinism; live pets follow the system setting)
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
    FileHandle.standardError.write(Data("usage: noti-toast ask|summary|pet ...\n".utf8))
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

@Sendable func targetScreen() -> NSScreen {
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

// Where the pet's resting robot is (plus its screen), so an attached ask card can
// grow out of it while staying fully on-screen.
struct AttachSpec {
    let anchor: NSPoint      // the robot tile's screen origin (bottom-left of its 72pt tile)
    let vf: NSRect           // visible frame of the pet's screen — the box the card must fit in
}

// Resolve the live robot position for an attached prompt, or nil when the toast
// is not attached (NOTI_ATTACH unset). Prefers the `.anchor` file the pet
// republishes on every move — it survives drags and sidesteps any question of
// whether a bare CLI tool's UserDefaults domain is shared — then falls back to
// the persisted position, then the corner.
func attachSpec() -> AttachSpec? {
    guard env["NOTI_ATTACH"] == "1" else { return nil }
    let tile = NSSize(width: petTileSize, height: petTileSize)
    var origin: NSPoint?
    if let dir = env["NOTI_PET_STATE_DIR"], !dir.isEmpty {
        let url = URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent(".anchor")
        if let raw = try? String(contentsOf: url, encoding: .utf8) {
            let nums = raw.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
                          .compactMap { Double($0) }
            if nums.count == 2 { origin = NSPoint(x: nums[0], y: nums[1]) }
        }
    }
    let anchor = petClampedOrigin(origin ?? PetPositionStore.load(size: tile), size: tile)
    let vf = petScreen(for: anchor, size: tile)?.visibleFrame ?? targetScreen().visibleFrame
    return AttachSpec(anchor: anchor, vf: vf)
}

// Resolved geometry for an attached card of a specific size. The robot lands on
// the pet's anchor so it occludes the resting pet; the card grows into whichever
// side has the most room — horizontally (robotOnLeft) AND vertically (robotY: the
// robot tile's offset within the H-tall card, H-72 = robot at the card's top so it
// falls below, 0 = robot at the bottom so it rises above). A final clamp keeps the
// whole card on-screen even for a tall multi-option question or a narrow display:
// a few px of robot drift (a faint ghost of the pet) is the accepted cost of a
// fully-visible, answerable card — which matters far more than pixel occlusion.
struct AttachLayout {
    let robotOnLeft: Bool
    let robotY: CGFloat
    let origin: NSPoint
}

func attachLayout(_ spec: AttachSpec, cardW W: CGFloat, cardH H: CGFloat) -> AttachLayout {
    let tile = petTileSize
    let a = spec.anchor, vf = spec.vf
    // Horizontal: grow into the side that fits the whole card, else the roomier.
    let roomRight = vf.maxX - (a.x + tile)
    let roomLeft = a.x - vf.minX
    let robotOnLeft = (roomRight >= W) || (roomRight >= roomLeft)
    // Vertical: grow toward the side with more room, so a card taller than the
    // 72pt tile never overflows the way a symmetric centre would at a corner.
    let roomBelow = a.y - vf.minY
    let roomAbove = vf.maxY - (a.y + tile)
    let robotY: CGFloat = (roomBelow >= roomAbove) ? (H - tile) : 0
    var origin = NSPoint(x: robotOnLeft ? a.x : a.x - W, y: a.y - robotY)
    // Clamp the full card into the visible frame; the inner max() guards the
    // pathological card-bigger-than-screen case from inverting the bound.
    origin.x = min(max(origin.x, vf.minX), max(vf.minX, vf.maxX - (W + tile)))
    origin.y = min(max(origin.y, vf.minY), max(vf.minY, vf.maxY - H))
    return AttachLayout(robotOnLeft: robotOnLeft, robotY: robotY, origin: origin)
}

func makeCard(width: CGFloat, height: CGFloat, attach layout: AttachLayout? = nil) -> (NSPanel, HoverEffectView) {
    let robotW: CGFloat = layout != nil ? petTileSize : 0
    let panel = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: width + robotW, height: height),
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

    let vev = HoverEffectView(frame: NSRect(x: 0, y: 0, width: width + robotW, height: height))
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

    if let layout {
        // Attached mode: one frosted surface wide enough to wear the robot as its
        // leading icon, positioned (by attachLayout) so the robot tile lands on
        // the resting pet and the card grows into on-screen room. The card is at
        // least as big as the pet's 72pt tile in both dimensions, so it fully
        // occludes the pet underneath — the pet is revealed again, unchanged, the
        // instant this card retracts. No corner origin, no slot column: the pet's
        // spot is the position, and attached cards don't stack in the corner (a
        // second concurrent one overlaps here, top-answerable first — the
        // documented edge; the standing pet still counts them all).
        let robotX: CGFloat = layout.robotOnLeft ? 0 : width
        // An attached card is always a "needs you" summons; .waiting is the right
        // pose and — because the card occludes the pet — it is also the only robot
        // the user sees, so it can't clash with the pet's momentarily-stale pose.
        let robot = RobotIconView(frame: NSRect(x: robotX, y: layout.robotY,
                                              width: petTileSize, height: petTileSize))
        robot.mood = .waiting
        robot.cardSide = layout.robotOnLeft ? .right : .left   // arm toward the card body
        // Pin the robot to its own edge so the unfurl (a width-only frame
        // animation in present()) sweeps the card out from behind a robot that
        // never budges; height never animates, so the vertical margins just hold
        // it at robotY.
        robot.autoresizingMask = layout.robotOnLeft ? [.maxXMargin, .minYMargin, .maxYMargin]
                                                  : [.minXMargin, .minYMargin, .maxYMargin]
        vev.addSubview(robot)
        panel.setFrameOrigin(layout.origin)
        return (panel, vev)
    }

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
    if let onLeft = attachRobotOnLeft {
        // Unfurl out of the robot: start collapsed to just the robot tile, then
        // grow horizontally to full width. The card content is revealed by the
        // surface's clip as the width opens; the robot, pinned to its edge by
        // autoresizing, holds still — so the card reads as sweeping out from
        // behind the robot. Height/origin.y never change, so there is no vertical
        // lurch and the robot stays exactly over the pet it is occluding.
        panel.alphaValue = 0
        if reduce {                                   // reduce-motion: pure fade at full size
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                panel.animator().alphaValue = 1
            }
            return
        }
        var collapsed = target
        collapsed.size.width = petTileSize
        if !onLeft { collapsed.origin.x = target.maxX - petTileSize }   // robot-on-right: pin the right edge
        panel.setFrame(collapsed, display: true)
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = settleCurve
            panel.animator().alphaValue = 1
            panel.animator().setFrame(target, display: true)
        }
        return
    }
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
// Set when an ask card is attached to the pet (robot-on-left true/false, else
// nil). It flips present()/dismissThenExit() from the corner slide to a
// horizontal unfurl/retract out of / into the robot, so the interactive card
// reads as the pet growing a card rather than a second window arriving.
var attachRobotOnLeft: Bool?
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
            if let onLeft = attachRobotOnLeft {
                // retract the card back into the robot — the exact reverse of the
                // unfurl, so an answered prompt folds away and the pet (already
                // underneath, now in its post-answer mood) is what remains
                var f = panel.frame
                if !onLeft { f.origin.x = f.maxX - petTileSize }   // keep the robot's right edge fixed
                f.size.width = petTileSize
                panel.animator().setFrame(f, display: true)
            } else {
                var f = panel.frame
                f.origin.x += (env["NOTI_CORNER"] ?? "top-right").hasSuffix("left") ? -14 : 14
                panel.animator().setFrame(f, display: true)
            }
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
// Pet mode — a long-lived reader, never a hook path.
// ----------------------------------------------------------------------------

enum PetMood: String {
    case asleep, running, done, failed, waiting

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

struct PetSession {
    let id: String
    let mood: PetMood
    let project: String
}

final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// The pet is a single object that delivers its own notification: a robot tile
// that, on a summons, unfurls one frosted card ("Claude needs you · project")
// out of itself, and collapses back to just the robot when nothing is needed.
let petTileSize: CGFloat = 72     // the robot tile, resting footprint
let petCardWidth: CGFloat = 216   // the card that grows out of the robot

// Which side a presented card sits on, so the robot raises the arm on that
// side as a "here — look" gesture toward the message. `.none` while resting.
// Top-level (not nested in PetView) so the attached prompt card can wear the
// robot with the same arm-toward-the-card gesture the pet uses.
enum CardSide { case none, left, right }

// The robot is painted by a free renderer, not a PetView method, so two surfaces
// can draw the identical critter: the long-lived pet, and the interactive prompt
// card that unfurls out of it. The card wearing the same robot at the same screen
// point is what makes the toast read as the pet growing a card rather than a
// second window landing beside it.
private let petInk = NSColor(srgbRed: 0.16, green: 0.11, blue: 0.09, alpha: 1)

// chassis paints the head and body, accent tints the chest glyph, and beacon is
// the antenna ball — the one part that carries mood from across the room, so it
// stays a saturated dot in every state and only dims when the robot is asleep.
private func petPalette(_ mood: PetMood) -> (chassis: NSColor, accent: NSColor, beacon: NSColor) {
    switch mood {
    case .asleep:
        return (NSColor(srgbRed: 0.58, green: 0.56, blue: 0.53, alpha: 0.92),
                NSColor(srgbRed: 0.34, green: 0.34, blue: 0.34, alpha: 1),
                NSColor(srgbRed: 0.45, green: 0.43, blue: 0.40, alpha: 1))
    case .running: return (claude, .systemTeal, .systemTeal)
    case .done:    return (claude, .systemGreen, .systemGreen)
    case .failed:  return (.systemRed, .systemYellow, .systemYellow)
    case .waiting: return (claude, .systemYellow, .systemYellow)
    }
}

// The upright antenna ball's center for a robot drawn in `square` — one
// definition shared by the draw path and the breathing halo layer, so the
// render-server halo sits exactly on the drawn ball (head.maxY + the 6pt rise).
func petBeaconCenter(in square: NSRect) -> NSPoint {
    NSPoint(x: square.midX, y: square.minY + 64)
}

// Paint the robot into `square` (its own 72pt tile in the caller's coordinates).
// AppKit is y-up, so the antenna sits at high y and the legs at low y. The robot
// carries only its own state (eyes / a chest glyph / the beacon); every word
// lives in whatever card sits beside it, so a resting robot stays inert.
// beaconGlow scales the DRAWN halo discs (the ball always paints at full
// saturation); a caller whose halo lives on a CALayer passes 0 so the discs
// aren't painted twice. blinking briefly closes the lids of an awake robot;
// drawSleepZ: false lets a caller whose "z" floats on a CALayer keep the
// static one out of the same tile.
func drawRobot(in square: NSRect, mood: PetMood, cardSide: CardSide, beaconGlow: CGFloat = 1,
               blinking: Bool = false, drawSleepZ: Bool = true) {
    let (chassis, accent, beacon) = petPalette(mood)
    let ink = petInk
    let cx = square.midX
    let y0 = square.minY
    // Darker tone for outlines, legs, and stalk, so the chassis reads as one solid.
    let edge = chassis.shadow(withLevel: 0.28) ?? chassis

    // Big head, small body, stubby legs — the cuteness is in the proportion. The
    // whole stack fits inside the 72pt tile with room for the antenna's glow.
    let head = NSRect(x: cx - 17, y: y0 + 36, width: 34, height: 22)
    let body = NSRect(x: cx - 12, y: y0 + 16, width: 24, height: 17)

    // Legs sit behind the body.
    petLimb(NSRect(x: cx - 6, y: y0 + 6, width: 3.6, height: 11), color: edge)
    petLimb(NSRect(x: cx + 2.4, y: y0 + 6, width: 3.6, height: 11), color: edge)

    // The arm on the card side raises to point at the message it presents — the
    // robot's "here — look" gesture toward whatever card just unfurled beside it.
    petArm(shoulder: NSPoint(x: body.minX, y: body.midY + 2), dir: -1,
           raised: cardSide == .left, color: chassis)
    petArm(shoulder: NSPoint(x: body.maxX, y: body.midY + 2), dir: 1,
           raised: cardSide == .right, color: chassis)

    // Neck bridge, then body and head over it.
    chassis.setFill()
    NSBezierPath(rect: NSRect(x: cx - 3, y: y0 + 33, width: 6, height: 3)).fill()
    fillChassis(body, radius: 5, color: chassis, edge: edge)
    fillChassis(head, radius: 8, color: chassis, edge: edge)

    // The antenna beacon: a glowing dot that droops and dims only when asleep.
    // beaconGlow lets the caller breathe the halo in the attention states.
    petAntenna(headTop: NSPoint(x: cx, y: head.maxY), upright: petBeaconCenter(in: square),
               beacon: beacon, stalk: edge, drooped: mood == .asleep, glow: beaconGlow)

    if mood == .asleep {
        petClosedEyes(head: head, ink: ink, gaze: .none)
        if drawSleepZ {
            petText("z", in: NSRect(x: head.maxX - 4, y: head.maxY - 5, width: 12, height: 12),
                    size: 10, color: edge, bold: true)
        }
    } else {
        // The gaze rides the card side: a robot presenting a card looks at
        // what it's saying — half of what sells robot-plus-card as one object.
        if blinking {
            petClosedEyes(head: head, ink: ink, gaze: cardSide)
        } else {
            petEyes(head: head, ink: ink, gaze: cardSide)
        }
        petMouth(head: head, ink: ink)
    }

    // Terminal states ride a glyph on the chest.
    switch mood {
    case .done:
        petText("✓", in: NSRect(x: body.minX, y: body.midY - 11, width: body.width, height: 22),
                size: 16, color: accent, bold: true)
    case .failed:
        petText("!", in: NSRect(x: body.minX, y: body.midY - 11, width: body.width, height: 22),
                size: 17, color: accent, bold: true)
    default:
        break
    }
}

private func petText(_ text: String, in rect: NSRect, size: CGFloat, color: NSColor, bold: Bool) {
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
    (text as NSString).draw(in: rect, withAttributes: [
        .font: font,
        .foregroundColor: color,
        .paragraphStyle: style,
    ])
}

// A filled, rounded chassis panel (head or body) with a darker outline so the
// solid terracotta reads as a machined part rather than a flat blob.
private func fillChassis(_ rect: NSRect, radius: CGFloat, color: NSColor, edge: NSColor) {
    let p = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    color.setFill()
    p.fill()
    edge.setStroke()
    p.lineWidth = 1.5
    p.stroke()
}

// A capsule limb (leg). Width/2 corner radius makes the ends round.
private func petLimb(_ rect: NSRect, color: NSColor) {
    color.setFill()
    NSBezierPath(roundedRect: rect, xRadius: rect.width / 2, yRadius: rect.width / 2).fill()
}

// One arm. `dir` is -1 for the left arm, +1 for the right. A raised arm angles up
// and out toward a presented card; a resting arm hangs a touch below the shoulder.
private func petArm(shoulder: NSPoint, dir: CGFloat, raised: Bool, color: NSColor) {
    let tip = raised
        ? NSPoint(x: shoulder.x + dir * 8, y: shoulder.y + 9)
        : NSPoint(x: shoulder.x + dir * 7, y: shoulder.y - 2)
    let arm = NSBezierPath()
    arm.move(to: shoulder)
    arm.line(to: tip)
    arm.lineWidth = 4
    arm.lineCapStyle = .round
    color.setStroke()
    arm.stroke()
}

// The antenna: a short stalk topped by the beacon ball. When lit, two faint
// concentric rings fake a phosphor glow; asleep, the stalk leans and the ball
// dims with no glow.
private func petAntenna(headTop: NSPoint, upright: NSPoint, beacon: NSColor, stalk: NSColor, drooped: Bool, glow: CGFloat) {
    let ball = drooped
        ? NSPoint(x: headTop.x + 9, y: headTop.y + 4)
        : upright
    let stem = NSBezierPath()
    stem.move(to: headTop)
    stem.line(to: drooped ? NSPoint(x: headTop.x + 8, y: headTop.y + 4)
                          : NSPoint(x: headTop.x, y: headTop.y + 4))
    stem.lineWidth = 2
    stem.lineCapStyle = .round
    stalk.setStroke()
    stem.stroke()

    if !drooped {
        // Two faint rings fake a phosphor halo; both its size and alpha ride
        // `glow` (1 = full, lower = dimmer) so a breathing beacon just pulses light.
        for (r, a) in [(6.0, 0.16), (4.4, 0.30)] as [(CGFloat, CGFloat)] {
            let rr = r * (0.82 + 0.18 * glow)
            beacon.withAlphaComponent(a * glow).setFill()
            NSBezierPath(ovalIn: NSRect(x: ball.x - rr, y: ball.y - rr, width: rr * 2, height: rr * 2)).fill()
        }
    }
    let r: CGFloat = 3.6
    beacon.setFill()
    NSBezierPath(ovalIn: NSRect(x: ball.x - r, y: ball.y - r, width: r * 2, height: r * 2)).fill()
}

// How far the eyes slide toward a presented card. Small on purpose: a glance,
// not a stare — the head never turns.
private func petGazeShift(_ gaze: CardSide) -> CGFloat {
    switch gaze {
    case .left:  return -1.5
    case .right: return 1.5
    case .none:  return 0
    }
}

// Two open LED eyes in the upper face, glancing toward `gaze`.
private func petEyes(head: NSRect, ink: NSColor, gaze: CardSide) {
    ink.setFill()
    let dx = petGazeShift(gaze)
    for x in [head.midX - 9 + dx, head.midX + 4 + dx] {
        NSBezierPath(roundedRect: NSRect(x: x, y: head.midY - 1, width: 5, height: 7),
                     xRadius: 2, yRadius: 2).fill()
    }
}

// Lidded eyes — two short dashes — for the asleep pose and mid-blink. They
// keep the gaze shift so a blink doesn't snap the eyes back to center.
private func petClosedEyes(head: NSRect, ink: NSColor, gaze: CardSide) {
    ink.setFill()
    let dx = petGazeShift(gaze)
    for x in [head.midX - 9 + dx, head.midX + 4 + dx] {
        NSBezierPath(roundedRect: NSRect(x: x, y: head.midY + 2, width: 5, height: 2),
                     xRadius: 1, yRadius: 1).fill()
    }
}

// A neutral mouth line low on the face; faint so the eyes and beacon lead.
private func petMouth(head: NSRect, ink: NSColor) {
    ink.withAlphaComponent(0.5).setFill()
    NSBezierPath(roundedRect: NSRect(x: head.midX - 6, y: head.minY + 5, width: 12, height: 2),
                 xRadius: 1, yRadius: 1).fill()
}

// The beacon breathes only in states that want your eye: a slow "thinking"
// pulse while running, a faster, deeper one while it's actually summoning you.
// Everything else — asleep, done — holds a steady light. nil = steady.
func beaconBreathSpec(_ mood: PetMood) -> (period: CGFloat, floor: CGFloat)? {
    switch mood {
    case .running:          return (2.2, 0.62)
    case .waiting, .failed: return (1.1, 0.48)
    default:                return nil
    }
}

// Reduce-motion, with the spike's env override kept so the snapshot harness
// can force the static branch deterministically (NOTI_PET_REDUCE_MOTION=1/0).
func petReduceMotion() -> Bool {
    if let forced = env["NOTI_PET_REDUCE_MOTION"] { return forced != "0" }
    return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
}

// The breathing halo as a render-server animation: the two glow discs ride a
// repeating opacity+scale ease between full glow and the spec's floor. This
// replaces a 30fps timer redraw — the pet spike's checklist promised "no
// continuous animation", and a long-lived surface must keep it: the process
// sleeps while the beacon breathes. The solid ball stays in the draw path at
// full saturation; only the halo discs live here.
func makeBeaconHalo(center: NSPoint, mood: PetMood, period: CGFloat, floor: CGFloat) -> CALayer {
    let beacon = petPalette(mood).beacon
    let box = CALayer()
    box.frame = NSRect(x: center.x - 6, y: center.y - 6, width: 12, height: 12)
    for (r, a) in [(6.0, 0.16), (4.4, 0.30)] as [(CGFloat, CGFloat)] {
        let disc = CAShapeLayer()
        disc.path = CGPath(ellipseIn: CGRect(x: 6 - r, y: 6 - r, width: r * 2, height: r * 2),
                           transform: nil)
        disc.fillColor = beacon.withAlphaComponent(a).cgColor
        box.addSublayer(disc)
    }
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = 1.0
    fade.toValue = floor
    let swell = CABasicAnimation(keyPath: "transform.scale")
    swell.fromValue = 1.0
    swell.toValue = 0.82 + 0.18 * floor        // the drawn halo's radius ride
    let breath = CAAnimationGroup()
    breath.animations = [fade, swell]
    breath.duration = period / 2
    breath.autoreverses = true
    breath.repeatCount = .infinity
    breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    box.add(breath, forKey: "beacon-breath")
    return box
}

// (Re)build a view's breathing halo for `mood`. Returns nil when the light
// should hold steady (non-breathing mood, or reduce-motion) — the caller's
// draw path paints the static discs instead (beaconGlow 1 vs 0). cgColors
// freeze at creation, so callers rebuild on effective-appearance changes.
func rebuildHalo(_ old: CALayer?, on view: NSView, mood: PetMood) -> CALayer? {
    old?.removeFromSuperlayer()
    guard let spec = beaconBreathSpec(mood), !petReduceMotion() else { return nil }
    view.wantsLayer = true
    var built: CALayer?
    view.effectiveAppearance.performAsCurrentDrawingAppearance {
        let square = NSRect(x: 0, y: 0, width: petTileSize, height: petTileSize)
        let halo = makeBeaconHalo(center: petBeaconCenter(in: square), mood: mood,
                                  period: spec.period, floor: spec.floor)
        view.layer?.addSublayer(halo)
        built = halo
    }
    return built
}

// A blink is two redraws every few seconds, scheduled with one-shot timers —
// between blinks the process is fully idle, so the "no continuous animation"
// CPU bound the beacon fix restored keeps holding. The random interval is
// what reads as alive; a metronome blink reads as a cursor.
final class BlinkDriver {
    private var timer: Timer?
    private let setLids: (Bool) -> Void
    init(setLids: @escaping (Bool) -> Void) { self.setLids = setLids }
    var active = false {
        didSet {
            guard active != oldValue else { return }
            if active {
                schedule()
            } else {
                timer?.invalidate()
                timer = nil
                setLids(false)           // never park a stopped robot mid-blink
            }
        }
    }
    private func schedule() {
        let t = Timer(timeInterval: .random(in: 3.0...7.0), repeats: false) { [weak self] _ in
            guard let self, self.active else { return }
            self.setLids(true)
            let open = Timer(timeInterval: 0.12, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.setLids(false)
                if self.active { self.schedule() }
            }
            open.tolerance = 0.02
            RunLoop.main.add(open, forMode: .common)
            self.timer = open
        }
        t.tolerance = 0.5                // let the system coalesce our wakeups
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
    deinit { timer?.invalidate() }
}

// The sleeping "z": a slow float-and-fade above the head — the one ambient
// sign of life in the asleep pose. A repeating render-server animation, same
// zero-CPU class as the beacon breath; the cycle starts and ends transparent
// so the loop has no pop.
func makeSleepZ(for view: NSView) -> CALayer {
    let chassis = petPalette(.asleep).chassis
    let z = CATextLayer()
    z.string = "z"
    z.font = NSFont.boldSystemFont(ofSize: 10)
    z.fontSize = 10
    z.alignmentMode = .center
    z.foregroundColor = (chassis.shadow(withLevel: 0.28) ?? chassis).cgColor
    z.contentsScale = view.window?.backingScaleFactor ?? 2
    // The drawn z's tile (head.maxX - 4, head.maxY - 5) in the 72pt square.
    z.frame = NSRect(x: 49, y: 53, width: 12, height: 12)
    let rise = CABasicAnimation(keyPath: "transform.translation.y")
    rise.fromValue = 0
    rise.toValue = 7
    let fade = CAKeyframeAnimation(keyPath: "opacity")
    fade.values = [0, 1, 1, 0]
    fade.keyTimes = [0, 0.18, 0.55, 1]
    let drift = CAAnimationGroup()
    drift.animations = [rise, fade]
    drift.duration = 3.2
    drift.repeatCount = .infinity
    z.opacity = 0                        // the animation owns visibility
    z.add(drift, forKey: "sleep-z")
    return z
}

final class PetView: NSView {
    var mood: PetMood = .asleep { didSet { needsDisplay = true; if mood != oldValue { updateLife() } } }
    var cardSide: CardSide = .none { didSet { needsDisplay = true } }

    // The pet's idle life. Everything here is either a render-server layer
    // (halo, sleep-z) or a one-shot timer (blink) — never a repeating redraw.
    private var halo: CALayer?
    private var sleepZ: CALayer?
    private var lidsDown = false { didSet { needsDisplay = true } }
    private lazy var blink = BlinkDriver { [weak self] down in self?.lidsDown = down }
    private func updateLife() {
        halo = rebuildHalo(halo, on: self, mood: mood)
        blink.active = mood != .asleep && !petReduceMotion()
        sleepZ?.removeFromSuperlayer()
        sleepZ = nil
        if mood == .asleep && !petReduceMotion() {
            let z = makeSleepZ(for: self)
            layer?.addSublayer(z)
            sleepZ = z
        }
        needsDisplay = true
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLife()               // re-resolve the layers' frozen appearance colors
    }

    // The state-change reaction, in body language: done lands with a happy
    // bounce, failed startles, everything else keeps the settle pulse — and
    // falling asleep just... falls asleep. All transform animations on the
    // backing layer (anchor = bottom-left, so y-scales squash toward the
    // ground and the feet stay planted); nothing here re-enters draw().
    func react(to newMood: PetMood) {
        switch newMood {
        case .done:   bounce()
        case .failed: shake()
        case .asleep: break
        default:      pulse()
        }
    }

    private func pulse() {
        // Build the scale about the robot's own centre so the pulse settles
        // in place, not from the layer's bottom-left anchor.
        let cx = bounds.width / 2, cy = bounds.height / 2
        func scaleAboutCenter(_ s: CGFloat) -> CATransform3D {
            var t = CATransform3DMakeTranslation(cx, cy, 0)
            t = CATransform3DScale(t, s, s, 1)
            return CATransform3DTranslate(t, -cx, -cy, 0)
        }
        let a = CABasicAnimation(keyPath: "transform")
        a.fromValue = scaleAboutCenter(0.92)
        a.toValue = scaleAboutCenter(1.0)
        a.duration = 0.18
        a.timingFunction = settleCurve
        layer?.add(a, forKey: "pet-react")
    }

    private func bounce() {
        // Squash-and-rebound instead of a jump: the tile has only ~2pt of
        // headroom above the halo, so leaving the ground would clip the glow.
        let a = CAKeyframeAnimation(keyPath: "transform.scale.y")
        a.values = [1.0, 0.90, 1.02, 1.0]
        a.keyTimes = [0, 0.3, 0.7, 1]
        a.duration = 0.45
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer?.add(a, forKey: "pet-react")
    }

    private func shake() {
        let a = CAKeyframeAnimation(keyPath: "transform.translation.x")
        a.values = [0, -4, 4, -3, 3, -1, 0]
        a.duration = 0.4
        layer?.add(a, forKey: "pet-react")
    }

    var onClose: (() -> Void)?
    // Fired after a drag settles, so the driver re-anchors and re-lays-out.
    var onMoved: (() -> Void)?
    // Fired continuously during a drag so the driver can republish the live
    // anchor — a prompt that attaches mid-drag must land on the robot's CURRENT
    // spot, not the pre-drag one (otherwise: the two-robot split this avoids).
    var onDragMove: (() -> Void)?
    private var hovering = false { didSet { needsDisplay = true } }
    private var closeArmed = false { didSet { needsDisplay = true } }
    // A snapshot must capture the pose, not the cursor's accident: the driver
    // raises this around cacheDisplay so a pointer parked on the pet can't
    // bake the hover × into a design-review PNG.
    var suppressHoverChrome = false { didSet { needsDisplay = true } }
    private var trackingArea: NSTrackingArea?
    private var dragStartMouse = NSPoint.zero
    private var dragStartOrigin = NSPoint.zero
    private var dragged = false

    override var acceptsFirstResponder: Bool { false }

    private var closeButtonRect: NSRect {
        let size: CGFloat = 16
        return NSRect(x: 8, y: petTileSize - size - 8, width: size, height: size)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        closeArmed = false
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        // Baseline the drag origin up front, BEFORE the close-button branch, so a
        // fallthrough drag can never run off a stale (zero-init) baseline even if
        // closeArmed were cleared mid-gesture. mouseExited is not delivered during
        // a button-down drag (no .enabledDuringMouseDrag on the tracking area), so
        // this is belt-and-suspenders — but it costs nothing and removes the hazard.
        dragStartMouse = NSEvent.mouseLocation
        dragStartOrigin = window.frame.origin
        dragged = false
        let point = convert(event.locationInWindow, from: nil)
        if hovering && closeButtonRect.contains(point) {
            closeArmed = true       // press-in on the ×; mouseDragged/Up own the rest
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if closeArmed { return }
        guard let panel = window else { return }
        let now = NSEvent.mouseLocation
        if abs(now.x - dragStartMouse.x) + abs(now.y - dragStartMouse.y) > 3 { dragged = true }
        let proposed = NSPoint(x: dragStartOrigin.x + now.x - dragStartMouse.x,
                               y: dragStartOrigin.y + now.y - dragStartMouse.y)
        panel.setFrameOrigin(petClampedOrigin(proposed, size: panel.frame.size))
        onDragMove?()
    }

    override func mouseUp(with event: NSEvent) {
        if closeArmed {
            let point = convert(event.locationInWindow, from: nil)
            closeArmed = false
            if closeButtonRect.contains(point) {
                onClose?()
            }
            return
        }
        if dragged { onMoved?() }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let item = NSMenuItem(title: "Close pet", action: #selector(closePet(_:)), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func closePet(_ sender: Any?) {
        onClose?()
    }

    private func drawCloseButton() {
        let rect = closeButtonRect
        let circle = NSBezierPath(ovalIn: rect)
        NSColor.black.withAlphaComponent(closeArmed ? 0.30 : 0.20).setFill()
        circle.fill()
        NSColor.white.withAlphaComponent(0.45).setStroke()
        circle.lineWidth = 1
        circle.stroke()

        let inset: CGFloat = 5
        let glyph = NSBezierPath()
        glyph.move(to: NSPoint(x: rect.minX + inset, y: rect.minY + inset))
        glyph.line(to: NSPoint(x: rect.maxX - inset, y: rect.maxY - inset))
        glyph.move(to: NSPoint(x: rect.maxX - inset, y: rect.minY + inset))
        glyph.line(to: NSPoint(x: rect.minX + inset, y: rect.maxY - inset))
        glyph.lineWidth = 1.6
        glyph.lineCapStyle = .round
        glyph.lineJoinStyle = .round
        NSColor.white.withAlphaComponent(0.82).setStroke()
        glyph.stroke()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()
        drawRobot(in: NSRect(x: 0, y: 0, width: petTileSize, height: petTileSize),
                 mood: mood, cardSide: cardSide, beaconGlow: halo == nil ? 1 : 0,
                 blinking: lidsDown, drawSleepZ: sleepZ == nil)
        if hovering && !suppressHoverChrome {
            drawCloseButton()
        }
    }
}

// The robot an attached prompt card wears as its leading icon: the same critter,
// but with no drag or hit behavior — it is part of the interactive toast, not
// the movable pet. Click-through (hitTest -> nil) so it can never swallow a
// stray click meant for the card that surrounds it.
final class RobotIconView: NSView {
    var mood: PetMood = .waiting { didSet { needsDisplay = true; updateLife() } }
    var cardSide: CardSide = .none { didSet { needsDisplay = true } }
    // Same render-server breath and blink as the pet beneath, so the retract
    // handoff reveals a pet mid-breath instead of jumping from a frozen glow —
    // and the robot fronting a prompt is exactly as alive as the one resting.
    private var halo: CALayer?
    private var lidsDown = false { didSet { needsDisplay = true } }
    private lazy var blink = BlinkDriver { [weak self] down in self?.lidsDown = down }
    private func updateLife() {
        halo = rebuildHalo(halo, on: self, mood: mood)
        blink.active = mood != .asleep && !petReduceMotion()
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLife()
    }
    override func draw(_ dirtyRect: NSRect) {
        drawRobot(in: NSRect(x: 0, y: 0, width: petTileSize, height: petTileSize),
                 mood: mood, cardSide: cardSide, beaconGlow: halo == nil ? 1 : 0,
                 blinking: lidsDown)
    }
}

enum PetPositionStore {
    static let xKey = "noti.pet.x"
    static let yKey = "noti.pet.y"

    static func load(size: NSSize) -> NSPoint {
        let d = UserDefaults.standard
        if d.object(forKey: xKey) != nil, d.object(forKey: yKey) != nil {
            return petClampedOrigin(NSPoint(x: d.double(forKey: xKey), y: d.double(forKey: yKey)), size: size)
        }
        let vf = targetScreen().visibleFrame
        return petClampedOrigin(origin(in: vf, width: size.width, height: size.height, stack: 0), size: size)
    }

    static func save(_ origin: NSPoint) {
        UserDefaults.standard.set(Double(origin.x), forKey: xKey)
        UserDefaults.standard.set(Double(origin.y), forKey: yKey)
    }
}

@Sendable func petScreen(for origin: NSPoint, size: NSSize) -> NSScreen? {
    let rect = NSRect(origin: origin, size: size)
    let center = NSPoint(x: rect.midX, y: rect.midY)
    for screen in NSScreen.screens where screen.visibleFrame.contains(center) {
        return screen
    }
    // Nearest screen by center-distance; nil only when NSScreen.screens is
    // empty, which macOS can transiently report mid-undock / display-sleep.
    return NSScreen.screens.max { a, b in
        let adx = center.x - a.visibleFrame.midX
        let ady = center.y - a.visibleFrame.midY
        let bdx = center.x - b.visibleFrame.midX
        let bdy = center.y - b.visibleFrame.midY
        return (adx * adx + ady * ady) > (bdx * bdx + bdy * bdy)
    }
}

func petClampedOrigin(_ origin: NSPoint, size: NSSize) -> NSPoint {
    // The pet re-clamps from a long-lived didChangeScreenParametersNotification
    // observer — exactly when the display list churns and can momentarily be
    // empty. With no screen, leave the origin untouched (never force-index an
    // empty NSScreen.screens); the next screen-param event re-clamps.
    guard let screen = petScreen(for: origin, size: size) else { return origin }
    let vf = screen.visibleFrame.insetBy(dx: 4, dy: 4)
    return NSPoint(x: min(max(origin.x, vf.minX), vf.maxX - size.width),
                   y: min(max(origin.y, vf.minY), vf.maxY - size.height))
}

func petTimeout(_ name: String, default def: Double) -> Double {
    max(1, Double(env[name] ?? "") ?? def)
}

func petStateDir() -> URL {
    if let raw = env["NOTI_PET_STATE_DIR"], !raw.isEmpty {
        return URL(fileURLWithPath: raw, isDirectory: true)
    }
    let home = FileManager.default.homeDirectoryForCurrentUser
    return home.appendingPathComponent(".config/noti/pet", isDirectory: true)
}

func petParseSession(_ url: URL, now: Date, waitingTTL: Double, doneTTL: Double) -> PetSession? {
    let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
    let modified = (attrs?[.modificationDate] as? Date) ?? now
    let age = now.timeIntervalSince(modified)
    let data = try? Data(contentsOf: url)
    var mood: PetMood = .running
    var project = url.deletingPathExtension().lastPathComponent

    if let data,
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        if let s = obj["state"] as? String, let parsed = PetMood(rawValue: s) { mood = parsed }
        if let p = obj["project"] as? String, !p.isEmpty { project = p }
    } else if let data,
              let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty {
        let parts = raw.split(separator: " ", maxSplits: 1).map(String.init)
        if let parsed = PetMood(rawValue: parts[0]) { mood = parsed }
        if parts.count > 1 { project = parts[1] }
    }
    if mood == .waiting && age > waitingTTL { return nil }
    if (mood == .done || mood == .failed) && age > doneTTL { return nil }
    return PetSession(id: url.deletingPathExtension().lastPathComponent,
                      mood: mood, project: project)
}

func petReadSessions(waitingTTL: Double, doneTTL: Double) -> [PetSession] {
    let dir = petStateDir()
    guard let urls = try? FileManager.default.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles]
    ) else { return [] }
    let now = Date()
    return urls.compactMap { url in
        // The writer's contract is one `<sid>.json` per session (pet_session_path
        // in the Python). Ignore everything else so a mid-write atomic temp file
        // (`<sid>.json.tmp.<pid>`) or any stray drop-in can't be counted as a
        // phantom session — a torn tmp read would otherwise default to `running`
        // and never expire.
        guard url.pathExtension == "json" else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              !isDir.boolValue else { return nil }
        return petParseSession(url, now: now, waitingTTL: waitingTTL, doneTTL: doneTTL)
    }
}

func petSummary(_ sessions: [PetSession]) -> (PetMood, String) {
    guard let top = sessions.max(by: { $0.mood.urgency < $1.mood.urgency }) else {
        return (.asleep, "asleep")
    }
    // Charter carve-out: outside the summons the pet stays inert — no counts,
    // no project names, no lists. Only a summons mood (a human is actually
    // needed: `waiting`, or `failed` once StopFailure ships) may name who needs
    // you or count them; every other mood shows just its own state word. A calm
    // running/done robot must never read as "2 sessions".
    guard top.mood == .waiting || top.mood == .failed else {
        return (top.mood, top.mood.rawValue)
    }
    let matching = sessions.filter { $0.mood == top.mood }
    if matching.count == 1 {
        return (top.mood, matching[0].project)
    }
    return (top.mood, "\(matching.count) sessions")
}

struct PetChrome {
    let panel: PetPanel
    let surface: NSVisualEffectView
    let view: PetView
    let titleLabel: NSTextField
    let subtitleLabel: NSTextField
}

final class PetDriver {
    private let panel: PetPanel
    private let view: PetView
    private let titleLabel: NSTextField
    private let subtitleLabel: NSTextField
    private let waitingTTL: Double
    private let doneTTL: Double
    private var watcher: DispatchSourceFileSystemObject?
    private var pending = false
    private var lastSignature = ""
    // The robot's resting origin in screen space — the fixed point a presented
    // card unfurls from, and what PetPositionStore persists.
    private var anchor: NSPoint
    private var presenting = false

    init(chrome: PetChrome, waitingTTL: Double, doneTTL: Double) {
        self.panel = chrome.panel
        self.view = chrome.view
        self.titleLabel = chrome.titleLabel
        self.subtitleLabel = chrome.subtitleLabel
        self.waitingTTL = waitingTTL
        self.doneTTL = doneTTL
        self.anchor = chrome.panel.frame.origin
    }

    func start() {
        try? FileManager.default.createDirectory(at: petStateDir(), withIntermediateDirectories: true)
        let fd = open(petStateDir().path, O_EVTONLY)
        if fd >= 0 {
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                                                                eventMask: [.write, .delete, .rename],
                                                                queue: .main)
            src.setEventHandler { [weak self] in
                guard let self, !self.pending else { return }
                self.pending = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.pending = false
                    self.refresh()
                }
            }
            src.setCancelHandler { close(fd) }
            src.resume()
            watcher = src
        }
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        applyLayout(presenting: false, animated: false)
        writeAnchor()
        refresh()
    }

    // Republish the robot's resting origin so an attached prompt card grows out
    // of exactly where the pet sits — kept current across drags and re-clamps.
    // Best-effort: a failed write only means the next attached card falls back
    // to the persisted (possibly pre-drag) position, never a blocked anything.
    private var lastAnchorWrite = NSPoint(x: -1e9, y: -1e9)
    private func writeAnchor() {
        let url = petStateDir().appendingPathComponent(".anchor")
        try? "\(Int(anchor.x)) \(Int(anchor.y))".write(to: url, atomically: true, encoding: .utf8)
        lastAnchorWrite = anchor
    }

    // Live-drag republish, throttled to ~6pt of movement so a fast drag doesn't
    // hammer the file (each write also self-pings the pet's dir watcher). No
    // relayout here — the drag itself moves the window; we only keep .anchor
    // current so a prompt attaching mid-drag lands on the robot, not its origin.
    func petDragging() {
        let live = NSPoint(x: panel.frame.origin.x + view.frame.origin.x,
                           y: panel.frame.origin.y + view.frame.origin.y)
        guard abs(live.x - lastAnchorWrite.x) + abs(live.y - lastAnchorWrite.y) >= 6 else { return }
        anchor = live
        writeAnchor()
    }

    // A summons is the only thing that presents a card; everything else rests.
    private func isSummons(_ m: PetMood) -> Bool { m == .waiting || m == .failed }

    func refresh() {
        let sessions = petReadSessions(waitingTTL: waitingTTL, doneTTL: doneTTL)
            .sorted { $0.id < $1.id }
        let (mood, caption) = petSummary(sessions)
        let signature = sessions.map { "\($0.id):\($0.mood.rawValue):\($0.project)" }
            .joined(separator: "|") + "=>\(mood.rawValue):\(caption)"
        guard signature != lastSignature else { return }
        let old = view.mood
        lastSignature = signature
        view.mood = mood

        let wantPresenting = isSummons(mood)
        if wantPresenting {                             // the card carries the words
            titleLabel.stringValue = mood == .failed ? "A turn failed" : "Claude needs you"
            subtitleLabel.stringValue = caption
        }
        if wantPresenting != presenting {
            // The unfurl is motion, not meaning (the DEV.md reduce-motion
            // contract): under reduce-motion the card appears as a jump cut.
            applyLayout(presenting: wantPresenting, animated: !petReduceMotion())
        }
        if old != mood && !petReduceMotion() {
            view.react(to: mood)
        }
        scheduleSnapshot(mood: mood, caption: caption)
    }

    // Spike-parity snapshot hook: NOTI_PET_SNAPSHOT_DIR captures the whole
    // surface (robot AND any presented card) after each state change settles —
    // 0.35s covers the 0.2s unfurl — so a driver script can walk the moods and
    // review every pose headlessly. Same cacheDisplay path as NOTI_SNAPSHOT,
    // so no screen-recording permission; dev-only, unset in real installs.
    private let snapshotDir = env["NOTI_PET_SNAPSHOT_DIR"].map {
        URL(fileURLWithPath: $0, isDirectory: true)
    }
    private var snapshotCounter = 0
    private var snapshotTimer: Timer?
    private func scheduleSnapshot(mood: PetMood, caption: String) {
        guard let dir = snapshotDir else { return }
        snapshotTimer?.invalidate()
        snapshotTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            guard let self, let surface = self.panel.contentView,
                  let rep = surface.bitmapImageRepForCachingDisplay(in: surface.bounds) else { return }
            self.view.suppressHoverChrome = true
            surface.cacheDisplay(in: surface.bounds, to: rep)
            self.view.suppressHoverChrome = false
            guard let png = rep.representation(using: .png, properties: [:]) else { return }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.snapshotCounter += 1
            let safe = caption.replacingOccurrences(of: "/", with: "_")
                              .replacingOccurrences(of: " ", with: "_")
            let name = String(format: "%02d-%@-%@.png", self.snapshotCounter, mood.rawValue, safe)
            try? png.write(to: dir.appendingPathComponent(name))
        }
    }

    // The card unfurls into whichever side has room, so the robot never has to
    // move off its corner: robot-on-left when it rests on the left half.
    private func robotOnLeft() -> Bool {
        let tile = NSSize(width: petTileSize, height: petTileSize)
        guard let vf = petScreen(for: anchor, size: tile)?.visibleFrame else { return true }
        return (anchor.x + petTileSize / 2) < vf.midX
    }

    private func applyLayout(presenting: Bool, animated: Bool) {
        self.presenting = presenting
        let onLeft = robotOnLeft()
        let tile = petTileSize
        let panelW = presenting ? tile + petCardWidth : tile
        let originX = (presenting && !onLeft) ? anchor.x - petCardWidth : anchor.x
        var frame = NSRect(x: originX, y: anchor.y, width: panelW, height: tile)
        frame.origin = petClampedOrigin(frame.origin, size: frame.size)

        // Pin the robot to its side so an animated resize keeps it stationary
        // while the card grows out of the opposite edge.
        view.autoresizingMask = onLeft ? [.maxXMargin] : [.minXMargin]
        view.cardSide = presenting ? (onLeft ? .right : .left) : .none

        // Card text: on the far side from the robot, vertically centred.
        let pad: CGFloat = 14
        let cardX: CGFloat = onLeft ? tile : 0
        let textW = petCardWidth - 2 * pad
        let titleH = lineHeight(titleLabel.font ?? NSFont.systemFont(ofSize: 13))
        let subH = lineHeight(subtitleLabel.font ?? NSFont.systemFont(ofSize: 11))
        let gap: CGFloat = 2
        let blockY = (tile - (titleH + gap + subH)) / 2
        subtitleLabel.frame = NSRect(x: cardX + pad, y: blockY, width: textW, height: subH)
        titleLabel.frame = NSRect(x: cardX + pad, y: blockY + subH + gap, width: textW, height: titleH)
        // Labels are placed at their FINAL card coordinates before any resize,
        // so their mask must hold minX invariant through it — a flexible right
        // margin, on both sides. (A flexible LEFT margin shifts them by the
        // width delta: at a left-half pet the summons text landed off-panel.)
        titleLabel.autoresizingMask = [.maxXMargin]
        subtitleLabel.autoresizingMask = [.maxXMargin]

        if presenting {                                 // revealed as the card grows
            titleLabel.isHidden = false
            subtitleLabel.isHidden = false
        }

        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.2
                ctx.timingFunction = settleCurve
                self.panel.animator().setFrame(frame, display: true)
            }, completionHandler: {
                self.view.frame = NSRect(x: onLeft ? 0 : self.panel.frame.width - tile,
                                         y: 0, width: tile, height: tile)
                if !presenting {
                    self.titleLabel.isHidden = true
                    self.subtitleLabel.isHidden = true
                }
            })
        } else {
            // Order matters: setFrame first (autoresizing shifts subviews by the
            // width delta), THEN pin the robot at its exact final tile — the
            // reverse order leaves the pre-positioned robot shifted off-panel
            // after autoresizing re-applies the delta (a jump-cut unfurl under
            // reduce-motion is a real resize, unlike start()/petMoved()).
            panel.setFrame(frame, display: true)
            view.frame = NSRect(x: onLeft ? 0 : panelW - tile, y: 0, width: tile, height: tile)
            if !presenting {
                titleLabel.isHidden = true
                subtitleLabel.isHidden = true
            }
        }
    }

    // Re-anchor after a drag: the robot's screen origin becomes the new anchor,
    // and the card may flip to the now-roomier side.
    func petMoved() {
        anchor = NSPoint(x: panel.frame.origin.x + view.frame.origin.x,
                         y: panel.frame.origin.y + view.frame.origin.y)
        PetPositionStore.save(anchor)
        writeAnchor()
        applyLayout(presenting: presenting, animated: false)
    }

    // Screen params changed (undock / display sleep) — keep the robot on-screen.
    func reclamp() {
        anchor = petClampedOrigin(anchor, size: NSSize(width: petTileSize, height: petTileSize))
        PetPositionStore.save(anchor)
        writeAnchor()
        applyLayout(presenting: presenting, animated: false)
    }
}

func makePetPanel() -> PetChrome {
    let tile = NSSize(width: petTileSize, height: petTileSize)
    let panel = PetPanel(contentRect: NSRect(origin: .zero, size: tile),
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

    // One frosted surface with the toast's exact DNA (makeCard) — same .popover
    // vibrancy, 16pt continuous corner, hairline border — so the pet is a member
    // of the toast family, not a separate app icon. It IS the delivery surface:
    // it grows into a card on a summons. The robot draws transparently on top and
    // the surface's clip reveals the card as it unfurls.
    let surface = NSVisualEffectView(frame: NSRect(origin: .zero, size: tile))
    surface.autoresizingMask = [.width, .height]
    surface.material = .popover
    surface.state = .active
    surface.blendingMode = .behindWindow
    surface.wantsLayer = true
    surface.layer?.cornerRadius = 16
    surface.layer?.cornerCurve = .continuous
    surface.layer?.masksToBounds = true
    surface.layer?.borderWidth = 1
    surface.layer?.borderColor = hairline.cgColor
    panel.contentView = surface

    let pet = PetView(frame: NSRect(origin: .zero, size: tile))
    pet.wantsLayer = true                              // layer-backed for the state pulse
    surface.addSubview(pet)

    let titleLabel = label("", font: .systemFont(ofSize: 13, weight: .semibold),
                           color: .labelColor, frame: .zero)
    let subtitleLabel = label("", font: .systemFont(ofSize: 11),
                              color: .secondaryLabelColor, frame: .zero)
    titleLabel.isHidden = true
    subtitleLabel.isHidden = true
    surface.addSubview(titleLabel)
    surface.addSubview(subtitleLabel)

    panel.setFrameOrigin(PetPositionStore.load(size: tile))
    return PetChrome(panel: panel, surface: surface, view: pet,
                     titleLabel: titleLabel, subtitleLabel: subtitleLabel)
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

    let layout = attachSpec().map { attachLayout($0, cardW: W, cardH: H) }
    attachRobotOnLeft = layout.map { $0.robotOnLeft }
    let (panel, vev) = makeCard(width: W, height: H, attach: layout)
    activePanel = panel
    // Attached cards nest all content in a body view offset past the robot icon,
    // so the ask layout below keeps its own [0,W] coordinates — the robot is
    // prepended, not threaded through every frame. `content` is that body (or
    // the bare surface when unattached). Its far-edge autoresizing lets the
    // content ride the surface's growing edge during the unfurl (see present()).
    let content: NSView
    if let layout {
        let body = NSView(frame: NSRect(x: layout.robotOnLeft ? petTileSize : 0,
                                        y: 0, width: W, height: H))
        body.autoresizingMask = layout.robotOnLeft ? [.maxXMargin] : [.minXMargin]
        vev.addSubview(body)
        content = body
    } else {
        content = vev
    }
    let headerBottom = H - 14 - headerH
    content.addSubview(chipView(x: pad, y: headerBottom + (headerH - chip) / 2, size: chip, kind: kind))
    if eyeH > 0 {
        content.addSubview(label(project, font: eyebrowFont, color: .secondaryLabelColor,
                             frame: NSRect(x: headX, y: headerBottom + headerH - eyeH,
                                           width: headW, height: eyeH)))
        content.addSubview(label(title, font: titleFont, color: .labelColor,
                             frame: NSRect(x: headX, y: headerBottom, width: headW, height: titleH)))
    } else {
        content.addSubview(label(title, font: titleFont, color: .labelColor,
                             frame: NSRect(x: headX, y: headerBottom + (headerH - titleH) / 2,
                                           width: headW, height: titleH)))
    }
    if msgH > 0 {
        // full width below the header — command real estate beats strict
        // banner indentation; five mono lines at 11.5pt need every point
        content.addSubview(label(message, font: msgFont, color: msgColor,
                             frame: NSRect(x: pad, y: headerBottom - 9 - msgH,
                                           width: textW, height: msgH), maxLines: msgLines))
    }

    var choices: [NSControl & Choice] = []
    var footerLabel: NSTextField?      // swapped to the editing hint mid-edit
    if listMode {
        var yTop = (msgH > 0 ? headerBottom - 9 - msgH : headerBottom) - 12
        for r in rows {
            r.setFrameOrigin(NSPoint(x: pad, y: yTop - r.frame.height))
            content.addSubview(r)
            choices.append(r)
            yTop -= r.frame.height + 6
        }
        if footerH > 0 {
            // yTop sits one 6pt gap below the last row; the footer wants 8pt
            let fl = label(footer, font: footerFont, color: .tertiaryLabelColor,
                           frame: NSRect(x: pad, y: yTop + 6 - 8 - footerH,
                                         width: textW, height: footerH))
            content.addSubview(fl)
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
            content.addSubview(b)
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
        // On the surface layer (vev), offset to the card region when attached:
        // vev's layer geometry places the bar at the card's BOTTOM edge, where a
        // nested plain-NSView backing layer would flip it to the top.
        let drainX: CGFloat = attachRobotOnLeft == true ? petTileSize : 0
        drain.frame = CGRect(x: drainX, y: 0, width: W, height: 2)
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

case "pet":
    let chrome = makePetPanel()
    activePanel = chrome.panel
    let driver = PetDriver(chrome: chrome,
                           waitingTTL: petTimeout("NOTI_PET_WAITING_TTL", default: 120),
                           doneTTL: petTimeout("NOTI_PET_DONE_TTL", default: 6))
    chrome.view.onClose = {
        // A UI close is the same intent as `noti pet --stop`, and this is the only
        // place code runs at that moment (no Python babysits the pet), so mirror
        // stop_pet's teardown here. Clear the per-session state files so a later
        // re-summon starts clean instead of resurrecting a stale pose (running has
        // no TTL; a leftover `waiting` outlives the answer) — matches pet_clear.
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: petStateDir(), includingPropertiesForKeys: nil) {
            for url in entries where url.pathExtension == "json" {
                try? FileManager.default.removeItem(at: url)
            }
        }
        // Remove the pid file, but only if it still names THIS process — the same
        // pid-ownership check every Python teardown path makes, so a concurrent
        // relaunch that reclaimed the pid file is never orphaned by our close.
        if let pf = env["NOTI_PET_PID_FILE"], !pf.isEmpty,
           let owned = try? String(contentsOfFile: pf, encoding: .utf8),
           owned.trimmingCharacters(in: .whitespacesAndNewlines)
               == String(ProcessInfo.processInfo.processIdentifier) {
            try? FileManager.default.removeItem(atPath: pf)
        }
        exit(0)
    }
    chrome.view.onMoved = { [weak driver] in driver?.petMoved() }
    chrome.view.onDragMove = { [weak driver] in driver?.petDragging() }
    NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                           object: app, queue: .main) { [weak driver] _ in
        driver?.reclamp()
    }
    driver.start()
    chrome.panel.orderFrontRegardless()
    snapshotIfRequested(chrome.surface)            // capture the whole card, not just the robot
    _ = driver                                     // keep watcher alive
    app.run()

default:
    FileHandle.standardError.write(Data("unknown mode: \(mode)\n".utf8))
    exit(64)
}
