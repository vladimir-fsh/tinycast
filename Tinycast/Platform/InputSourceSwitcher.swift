import AppKit
import Carbon.HIToolbox

/// Holds the keyboard input source at the palette's preferred one for the life of one summon.
@MainActor
final class InputSourceSwitcher {
    struct Option: Identifiable, Hashable {
        let id: String
        let title: String
    }

    static let sourcesDidChange = Notification.Name(
        kTISNotifyEnabledKeyboardInputSourcesChanged as String)

    /// The source to restore is kept as the object TIS vended, so hiding never re-reads the list.
    private struct Session {
        let id = UUID()
        let previousSource: TISInputSource
        let preferredInputSourceID: String
        var applied = false
        var confirmedAt: TimeInterval?
        var pendingLayout: PendingKeyboardLayout?
    }

    private var session: Session?
    private let readCurrentSource: @MainActor () -> TISInputSource?
    private let restoreSource: @MainActor (TISInputSource) -> Void
    private weak var pendingContext: NSTextInputContext?
    private var selectionTask: Task<Void, Never>?
    private var selectionObserver: NotificationToken?

    init(
        readCurrentSource: @escaping @MainActor () -> TISInputSource? = InputSourceSwitcher.currentSource,
        restoreSource: @escaping @MainActor (TISInputSource) -> Void = { TISSelectInputSource($0) }
    ) {
        self.readCurrentSource = readCurrentSource
        self.restoreSource = restoreSource
    }

    isolated deinit { selectionTask?.cancel() }

    func pendingCharacters(for event: NSEvent) -> String? {
        guard let session, let layout = session.pendingLayout,
            (session.confirmedAt.map({ event.timestamp <= $0 }) ?? true) || layout.hasDeadKey
        else { return nil }
        return layout.characters(for: event)
    }

    /// A `selected` source that is gone stays listed, so Settings keeps showing it.
    func options(selecting selected: String?) -> [Option] {
        var options = Self.enabledKeyboardSources().compactMap(Self.option(for:))
        if let selected, !options.contains(where: { $0.id == selected }) {
            options.append(Option(id: selected, title: selected))
        }
        return options
    }

    /// Records what to go back to; skipped when the preferred source is already the active one.
    func beginSession(preferredInputSourceID: String?) {
        guard session == nil, let preferredInputSourceID,
            let current = readCurrentSource(),
            Self.identifier(of: current) != preferredInputSourceID
        else { return }
        session = Session(
            previousSource: current, preferredInputSourceID: preferredInputSourceID,
            pendingLayout: preferredInputSourceID == "com.apple.keylayout.ABC"
                ? PendingKeyboardLayout(sourceID: preferredInputSourceID) : nil)
        guard let id = session?.id, session?.pendingLayout != nil else { return }
        let center = NotificationCenter.default
        let token = center.addObserver(
            forName: NSTextInputContext.keyboardSelectionDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.confirmSelection(sessionID: id, observedChange: true)
            }
        }
        selectionObserver = NotificationToken(token, center: center)
    }

    /// Goes through the field's own context, so the switch follows the palette's focus.
    func applySession(to inputContext: NSTextInputContext) {
        if pendingContext !== inputContext { session?.pendingLayout?.resetDeadKey() }
        pendingContext = inputContext
        guard let session, !session.applied else { return }
        if session.pendingLayout != nil {
            scheduleSelection(sessionID: session.id)
            return
        }
        inputContext.selectedKeyboardInputSource = session.preferredInputSourceID
        self.session?.applied = true
    }

    private func scheduleSelection(sessionID: UUID) {
        guard selectionTask == nil else { return }
        selectionTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self, self.session?.id == sessionID else { return }
            defer { self.selectionTask = nil }
            guard let context = self.pendingContext,
                let view = context.client as? NSView,
                view.window?.isKeyWindow == true, view.window?.isVisible == true,
                let preferredID = self.session?.preferredInputSourceID
            else { return }
            self.session?.applied = true
            context.selectedKeyboardInputSource = preferredID
            self.confirmSelection(sessionID: sessionID)
        }
    }

    private func confirmSelection(sessionID: UUID, observedChange: Bool = false) {
        guard let session, session.id == sessionID, session.applied,
            let current = readCurrentSource(), let currentID = Self.identifier(of: current)
        else { return }
        if currentID == session.preferredInputSourceID {
            if session.confirmedAt == nil {
                self.session?.confirmedAt = ProcessInfo.processInfo.systemUptime
            }
        } else if observedChange || session.confirmedAt != nil
            || currentID != Self.identifier(of: session.previousSource)
        {
            self.session?.pendingLayout = nil
        }
    }

    /// Undoes only our own switch: a source picked since, by the user or another app, stands.
    func endSession() {
        selectionTask?.cancel()
        selectionTask = nil
        selectionObserver = nil
        pendingContext = nil
        guard let session else { return }
        self.session = nil
        guard session.applied, let current = readCurrentSource(),
            Self.identifier(of: current) == session.preferredInputSourceID
        else { return }
        restoreSource(session.previousSource)
    }

    @MainActor
    private final class PendingKeyboardLayout {
        private let data: CFData
        private var deadKeyState: UInt32 = 0
        private(set) var hasDeadKey = false

        init?(sourceID: String) {
            guard let sources = TISCreateInputSourceList(
                [kTISPropertyInputSourceID as String: sourceID] as CFDictionary,
                false)?.takeRetainedValue(),
                let source = Self.firstSource(in: sources),
                let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
            else { return nil }
            data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
        }

        private static func firstSource(in sources: CFArray) -> TISInputSource? {
            for case let source as TISInputSource in sources as NSArray { return source }
            return nil
        }

        func resetDeadKey() {
            deadKeyState = 0
            hasDeadKey = false
        }

        func characters(for event: NSEvent) -> String? {
            guard event.type == .keyDown,
                event.modifierFlags.isDisjoint(with: [.command, .control])
            else { return nil }
            if Int(event.keyCode) == kVK_Delete, hasDeadKey {
                resetDeadKey()
                return ""
            }
            var modifiers: UInt32 = 0
            if event.modifierFlags.contains(.shift) { modifiers |= UInt32(shiftKey >> 8) }
            if event.modifierFlags.contains(.capsLock) { modifiers |= UInt32(alphaLock >> 8) }
            if event.modifierFlags.contains(.option) { modifiers |= UInt32(optionKey >> 8) }
            guard let text = translate(
                event.keyCode, modifiers: modifiers, state: &deadKeyState)
            else { return nil }
            // A nonzero opaque state may also describe a completed composition.
            var probeState = deadKeyState
            hasDeadKey = deadKeyState != 0
                && translate(UInt16(kVK_Space), modifiers: 0, state: &probeState) != " "
            guard !text.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0) || (0xF700...0xF8FF).contains($0.value)
            }) else {
                resetDeadKey()
                return nil
            }
            return text.isEmpty && !hasDeadKey ? nil : text
        }

        private func translate(_ code: UInt16, modifiers: UInt32, state: inout UInt32) -> String? {
            var length = 0
            var characters = [UniChar](repeating: 0, count: 16)
            let result = UCKeyTranslate(
                unsafeBitCast(CFDataGetBytePtr(data), to: UnsafePointer<UCKeyboardLayout>.self),
                code, UInt16(kUCKeyActionDown), modifiers, UInt32(LMGetKbdType()), 0,
                &state, characters.count, &length, &characters)
            guard result == noErr else { return nil }
            return String(utf16CodeUnits: characters, count: length)
        }
    }

    static func toggleCapsLockInputSource() {
        guard let current = currentSource() else { return }
        let isASCII: Bool = property(kTISPropertyInputSourceIsASCIICapable, of: current) ?? false
        let destination: TISInputSource?
        if isASCII {
            let candidates = enabledKeyboardSources().filter {
                property(kTISPropertyInputSourceIsASCIICapable, of: $0) == false
            }
            let history =
                UserDefaults.standard.persistentDomain(forName: "com.apple.HIToolbox")?[
                    "AppleInputSourceHistory"] as? [[String: Any]] ?? []
            destination =
                history.lazy.compactMap { entry in
                    candidates.first { source in
                        guard let id = identifier(of: source) else { return false }
                        let mode: String? = property(kTISPropertyInputModeID, of: source)
                        return entry["Input Mode"] as? String == id
                            || (mode != nil && entry["Input Mode"] as? String == mode)
                            || entry["Bundle ID"] as? String == id
                    }
                }.first ?? candidates.first
        } else {
            destination = TISCopyCurrentASCIICapableKeyboardInputSource()?.takeRetainedValue()
        }
        if let destination { TISSelectInputSource(destination) }
    }

    private static func currentSource() -> TISInputSource? {
        TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
    }

    private static func option(for source: TISInputSource) -> Option? {
        guard let id = identifier(of: source),
            let title: String = property(kTISPropertyLocalizedName, of: source)
        else { return nil }
        return Option(id: id, title: title)
    }

    private static func identifier(of source: TISInputSource) -> String? {
        property(kTISPropertyInputSourceID, of: source)
    }

    private static func enabledKeyboardSources() -> [TISInputSource] {
        guard let list = TISCreateInputSourceList(nil, false)?.takeRetainedValue() else { return [] }
        var sources: [TISInputSource] = []
        for case let source as TISInputSource in list as NSArray where isSelectableKeyboard(source) {
            sources.append(source)
        }
        return sources
    }

    private static func isSelectableKeyboard(_ source: TISInputSource) -> Bool {
        let category: String? = property(kTISPropertyInputSourceCategory, of: source)
        return category == kTISCategoryKeyboardInputSource as String
            && property(kTISPropertyInputSourceIsSelectCapable, of: source) == true
    }

    /// TIS vends untyped pointers, so an unexpected type reads as absent, not a trap.
    private static func property<Value>(_ key: CFString, of source: TISInputSource) -> Value? {
        guard let value = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(value).takeUnretainedValue() as? Value
    }
}
