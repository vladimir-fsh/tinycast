import AppKit
import Carbon.HIToolbox
import SwiftUI
import Synchronization

@MainActor
final class PaletteState {
    var menuOpen = false { didSet { onMenuOpenChanged?(menuOpen) } }
    var onMenuOpenChanged: ((Bool) -> Void)?
    var isComposing = false
    var searchFieldFrame = CGRect.zero
    var mode = PaletteMode.launcher
    func notePointerMoved(to: CGPoint) {}
    func disarmHoverHighlight(pointerAt: CGPoint) {}
    func noteCommandHeld(_ held: Bool) {}
}

enum PaletteMode {
    case launcher
    var isNativeEditor: Bool { false }
}

@MainActor
enum ASCIIKeyboardLayout {
    static func character(for event: NSEvent) -> String? { nil }
}

@MainActor
private final class PendingContext: NSTextInputContext {
    nonisolated private let selectionHistory = Mutex<[String]>([])
    var selections: [String] { selectionHistory.withLock { $0 } }
    override var selectedKeyboardInputSource: String? {
        get { selectionHistory.withLock { $0.last } }
        set { if let newValue { selectionHistory.withLock { $0.append(newValue) } } }
    }
    override func activate() {}
    override func deactivate() {}
}

@MainActor
private final class PendingEditor: NSTextView {
    lazy var pendingContext = PendingContext(client: self)
    var nativeKeyDowns = 0
    var nativeDelay: TimeInterval = 0.2
    override var inputContext: NSTextInputContext? { pendingContext }
    override func keyDown(with event: NSEvent) {
        nativeKeyDowns += 1
        Thread.sleep(forTimeInterval: nativeDelay)
        insertText(event.characters ?? "", replacementRange: NSRange(location: NSNotFound, length: 0))
    }
}

@main
@MainActor
struct InputSourceTests {
    private static var failures = 0
    private static var checks = 0
    private static func check(_ condition: Bool, _ message: String) {
        checks += 1
        if !condition { failures += 1; print("FAIL: \(message)") }
    }

    static func main() {
        _ = NSApplication.shared
        immediateTyping()
        confirmationAndRestoration()
        cancelledSelection()
        deadKeysAcrossConfirmation()
        inputPolicies()
        inactivePreferences()
        print("Input source tests: \(checks) checks, \(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }

    @MainActor
    private final class Fixture {
        let other = InputSourceTests.source("com.apple.keylayout.Russian")
        let abc = InputSourceTests.source("com.apple.keylayout.ABC")
        var current: TISInputSource
        var restored: [String] = []
        lazy var switcher = InputSourceSwitcher(
            readCurrentSource: { [unowned self] in current },
            restoreSource: { [unowned self] in restored.append(InputSourceTests.identifier($0)) })
        let panel = PalettePanel(rootView: Color.clear)
        let state = PaletteState()
        let editor = PendingEditor(frame: NSRect(x: 0, y: 0, width: 400, height: 80))

        init() {
            current = other
            panel.contentView = editor
            panel.paletteState = state
            panel.setFrameOrigin(NSPoint(x: -10000, y: -10000))
            panel.orderFront(nil)
            panel.becomeKey()
            _ = panel.makeFirstResponder(editor)
            panel.onPendingTextInput = { [unowned self] in switcher.pendingCharacters(for: $0) }
        }

        func begin() {
            switcher.beginSession(preferredInputSourceID: "com.apple.keylayout.ABC")
            switcher.applySession(to: editor.pendingContext)
        }

        func confirm() {
            current = abc
            NotificationCenter.default.post(
                name: NSTextInputContext.keyboardSelectionDidChangeNotification, object: nil)
            InputSourceTests.pump()
        }

        func close() {
            switcher.endSession()
            panel.onPendingTextInput = nil
            panel.orderOut(nil)
        }

        func key(
            _ code: Int = kVK_ANSI_A, text: String = "ф",
            modifiers: NSEvent.ModifierFlags = [], repeatKey: Bool = false
        ) -> NSEvent {
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                context: nil, characters: text, charactersIgnoringModifiers: text,
                isARepeat: repeatKey, keyCode: UInt16(code))!
        }
    }

    private static func immediateTyping() {
        let fixture = Fixture()
        defer { fixture.close() }
        fixture.begin()
        check(fixture.editor.pendingContext.selections.isEmpty, "selection is deferred past focus setup")
        let start = ContinuousClock.now
        fixture.panel.sendEvent(fixture.key())
        let elapsed = start.duration(to: .now)
        check(fixture.editor.string == "a", "the first key uses ABC while the source switch is pending")
        check(fixture.editor.nativeKeyDowns == 0, "pending typing bypasses the waiting native input path")
        check(elapsed < .milliseconds(50), "pending typing does not wait for the 200 ms input method")
        fixture.switcher.applySession(to: fixture.editor.pendingContext)
        pump()
        check(fixture.editor.pendingContext.selections == ["com.apple.keylayout.ABC"], "one summon requests one switch")
        fixture.panel.sendEvent(fixture.key(kVK_ANSI_B, text: "И", modifiers: .shift))
        fixture.panel.sendEvent(fixture.key(kVK_ANSI_1, text: "1", modifiers: .shift))
        fixture.panel.sendEvent(fixture.key(repeatKey: true))
        check(fixture.editor.string == "aB!a", "Shift, punctuation and held keys use the ABC layout")
        check(fixture.restored.isEmpty, "pending selection does not restore or mutate the system source")
    }

    private static func confirmationAndRestoration() {
        let fixture = Fixture()
        defer { fixture.close() }
        fixture.begin()
        pump()
        let queued = fixture.key()
        fixture.confirm()
        fixture.panel.sendEvent(queued)
        check(fixture.editor.string == "a", "an old queued key is translated after confirmation")
        fixture.editor.nativeDelay = 0
        fixture.panel.sendEvent(fixture.key(kVK_ANSI_B, text: "b"))
        check(fixture.editor.string == "ab" && fixture.editor.nativeKeyDowns == 1, "new keys return to native input exactly once")
        fixture.switcher.endSession()
        check(fixture.restored == ["com.apple.keylayout.Russian"], "closing restores only the source we changed")
        fixture.switcher.endSession()
        check(fixture.restored.count == 1, "closing twice cannot restore twice")

        fixture.current = fixture.other
        fixture.begin()
        pump()
        fixture.confirm()
        fixture.current = fixture.other
        NotificationCenter.default.post(name: NSTextInputContext.keyboardSelectionDidChangeNotification, object: nil)
        pump()
        check(fixture.switcher.pendingCharacters(for: queued) == nil, "a later user switch ends all translation")
        fixture.switcher.endSession()
        check(fixture.restored.count == 1, "a later user source choice survives closing")
    }

    private static func cancelledSelection() {
        let fixture = Fixture()
        defer { fixture.close() }
        fixture.begin()
        fixture.switcher.endSession()
        pump()
        check(fixture.editor.pendingContext.selections.isEmpty, "closing before the deferred request cancels it")
        check(fixture.restored.isEmpty, "an unapplied switch has nothing to restore")
        fixture.begin()
        pump()
        check(fixture.editor.pendingContext.selections.count == 1, "a cancelled old summon cannot cancel the new one")
        fixture.switcher.endSession()
        fixture.begin()
        fixture.panel.orderOut(nil)
        pump()
        check(fixture.editor.pendingContext.selections.count == 1, "a hidden editor cannot receive a stale request")
    }

    private static func deadKeysAcrossConfirmation() {
        let fixture = Fixture()
        defer { fixture.close() }
        fixture.begin()
        fixture.panel.sendEvent(fixture.key(kVK_ANSI_E, text: "у", modifiers: .option))
        check(fixture.editor.string.isEmpty, "an ABC dead key waits for its composed character")
        pump()
        fixture.confirm()
        fixture.panel.sendEvent(fixture.key(kVK_ANSI_E, text: "e"))
        check(fixture.editor.string == "é" && fixture.editor.nativeKeyDowns == 0, "a dead key finishes across handoff")
        fixture.editor.nativeDelay = 0
        fixture.panel.sendEvent(fixture.key(text: "a"))
        check(fixture.editor.string == "éa" && fixture.editor.nativeKeyDowns == 1,
              "native input resumes after composition")
    }

    private static func inputPolicies() {
        let fixture = Fixture()
        defer { fixture.close() }
        fixture.begin()
        for modifiers: NSEvent.ModifierFlags in [.command, .control, [.command, .shift]] {
            check(
                fixture.switcher.pendingCharacters(for: fixture.key(modifiers: modifiers)) == nil,
                "shortcuts are never inserted as text")
        }
        for code in [kVK_LeftArrow, kVK_Return, kVK_Tab, kVK_Delete, kVK_Escape] {
            check(
                fixture.switcher.pendingCharacters(for: fixture.key(code)) == nil,
                "navigation and editing keys keep native routing")
        }
        fixture.panel.sendEvent(fixture.key(modifiers: .capsLock))
        check(fixture.editor.string == "A", "Caps Lock is respected")
        fixture.editor.setSelectedRange(NSRange(location: 0, length: 1))
        fixture.panel.sendEvent(fixture.key(kVK_ANSI_B, text: "и"))
        check(fixture.editor.string == "b", "direct insertion replaces the selection through AppKit")
        fixture.state.menuOpen = true
        fixture.panel.sendEvent(fixture.key())
        check(fixture.editor.string == "b", "an open menu retains its input freeze")
        fixture.state.menuOpen = false
        fixture.editor.nativeDelay = 0
        fixture.editor.setMarkedText(
            "あ", selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: 0, length: 1))
        fixture.panel.sendEvent(fixture.key(text: "x"))
        check(fixture.editor.nativeKeyDowns == 1, "existing marked text stays on the native composition path")
    }

    private static func inactivePreferences() {
        let fixture = Fixture()
        defer { fixture.close() }
        fixture.switcher.beginSession(preferredInputSourceID: nil)
        fixture.switcher.applySession(to: fixture.editor.pendingContext)
        check(fixture.switcher.pendingCharacters(for: fixture.key()) == nil, "None leaves typing untouched")
        check(fixture.editor.pendingContext.selections.isEmpty, "None requests no switch")
        fixture.current = fixture.abc
        fixture.begin()
        check(fixture.switcher.pendingCharacters(for: fixture.key()) == nil, "an already active ABC source needs no bridge")
        check(fixture.editor.pendingContext.selections.isEmpty, "an already active ABC source needs no switch")
    }

    private static func pump() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
    }

    private static func identifier(_ source: TISInputSource) -> String {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return "" }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    private static func source(_ id: String) -> TISInputSource {
        let sources = TISCreateInputSourceList(
            [kTISPropertyInputSourceID as String: id] as CFDictionary, true).takeRetainedValue()
        for case let source as TISInputSource in sources as NSArray { return source }
        fatalError("Missing built-in keyboard layout \(id)")
    }
}
