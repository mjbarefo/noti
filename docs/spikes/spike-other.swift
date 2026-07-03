// spike-other.swift — Spike 0: prove single-line text entry works in a
// borderless, NON-ACTIVATING panel while the owning app stays inactive.
//
// Run:   swift spike-other.swift      (or: swiftc spike-other.swift -o s && ./s)
// Then, WITHIN 3 SECONDS, click into some other app (this terminal is fine)
// and type a few characters there. At the 3s mark the panel grabs the
// keyboard: an insertion point must appear in the field and typing must land
// there WITHOUT the menu bar / active app changing.
//
// Checklist (pass = all of these):
//   1. Before 3s: keystrokes stay in the other app.
//   2. At 3s: insertion point blinks in the panel; menu bar still shows the
//      OTHER app's name (we never activated).
//   3. Typing lands in the field. Option+e then e -> é (dead keys).
//   4. Optional: switch to a CJK input source; composition underline shows;
//      first Return commits the composition (does NOT exit); second Return
//      exits with the composed text.
//   5. Cmd+V pastes (the shim below). Paste multi-line text once and check
//      what stdout shows — this tells us how a single-line field treats \n.
//   6. Return: shell prints the EXACT text; `echo $?` == 10.
//   7. After exit, keyboard focus is back in the previous app, no clicks.
//   8. Rerun, press Esc -> exit 124, keyboard returns.

import AppKit

final class KeyablePanel: NSPanel { override var canBecomeKey: Bool { true } }

final class Delegate: NSObject, NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) {
            FileHandle.standardOutput.write(Data((control.stringValue + "\n").utf8))
            exit(10)
        }
        if sel == #selector(NSResponder.cancelOperation(_:)) { exit(124) }
        return false
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let panel = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 56),
                         styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
panel.level = .floating
panel.isFloatingPanel = true
panel.hidesOnDeactivate = false
panel.backgroundColor = .windowBackgroundColor

let field = NSTextField(frame: NSRect(x: 12, y: 16, width: 316, height: 24))
field.placeholderString = "type here — app stays inactive"
field.usesSingleLineMode = true
field.cell?.wraps = false
field.cell?.isScrollable = true
let del = Delegate()
field.delegate = del
panel.contentView?.addSubview(field)

if let s = NSScreen.main {
    let vf = s.visibleFrame
    panel.setFrameOrigin(NSPoint(x: vf.maxX - 356, y: vf.maxY - 72))
}
panel.orderFrontRegardless()

// Cmd-key shim: an .accessory app has no menu bar, so Cmd+V/C/X/A do nothing
// unless routed down the key window's responder chain by hand.
NSEvent.addLocalMonitorForEvents(matching: .keyDown) { ev in
    guard ev.modifierFlags.contains(.command),
          let ch = ev.charactersIgnoringModifiers?.lowercased() else { return ev }
    let map: [String: Selector] = ["v": #selector(NSText.paste(_:)),
                                   "c": #selector(NSText.copy(_:)),
                                   "x": #selector(NSText.cut(_:)),
                                   "a": #selector(NSText.selectAll(_:))]
    if let sel = map[ch] { NSApp.sendAction(sel, to: nil, from: nil); return nil }
    return ev
}

// Grab the keyboard 3s in — enough time to click another app first, which is
// the whole point: prove makeKey + field editor work while we are inactive.
DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
    panel.makeKey()
    panel.makeFirstResponder(field)
}
_ = del
app.run()
