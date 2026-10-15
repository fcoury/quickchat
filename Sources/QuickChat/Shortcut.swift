import AppKit
import Carbon
import SwiftUI

struct Shortcut: Codable, Equatable {
    var key: UInt32
    var modifiers: UInt32
    var label: String
    static let initial = Shortcut(key: 49, modifiers: UInt32(controlKey | optionKey), label: "⌃⌥Space")
    static func from(_ event: NSEvent) -> Shortcut? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) || flags.contains(.option) || flags.contains(.control), ![54, 55, 56, 58, 59, 60, 61, 62, 63].contains(Int(event.keyCode)) else { return nil }
        var modifiers: UInt32 = 0; var prefix = ""
        if flags.contains(.control) { modifiers |= UInt32(controlKey); prefix += "⌃" }
        if flags.contains(.option) { modifiers |= UInt32(optionKey); prefix += "⌥" }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey); prefix += "⇧" }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey); prefix += "⌘" }
        let name = [49: "Space", 36: "Return", 48: "Tab", 51: "Delete", 123: "←", 124: "→", 125: "↓", 126: "↑"][Int(event.keyCode)] ?? event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)"
        return Shortcut(key: UInt32(event.keyCode), modifiers: modifiers, label: prefix + name)
    }
}

@MainActor final class GlobalShortcut: ObservableObject {
    @Published private(set) var shortcut: Shortcut
    @Published var error: String?
    var action: (() -> Void)?
    private var hotkey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    init() {
        shortcut = UserDefaults.standard.data(forKey: "shortcut").flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) } ?? .initial
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<GlobalShortcut>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in owner.action?() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        register(shortcut, persist: false)
    }
    func register(_ new: Shortcut, persist: Bool = true) {
        if let hotkey { UnregisterEventHotKey(hotkey); self.hotkey = nil }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(new.key, new.modifiers, EventHotKeyID(signature: 0x51434854, id: 1), GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else {
            error = "That shortcut could not be registered. It may already be in use. Choose another combination."
            if new != shortcut { register(shortcut, persist: false) }
            return
        }
        hotkey = ref; shortcut = new
        if persist { error = nil; UserDefaults.standard.set(try? JSONEncoder().encode(new), forKey: "shortcut") }
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    @ObservedObject var hotkey: GlobalShortcut
    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton(); button.bezelStyle = .rounded
        button.shortcutLabel = hotkey.shortcut.label; button.title = button.shortcutLabel
        button.onRecord = { hotkey.register($0) }; return button
    }
    func updateNSView(_ button: RecorderButton, context: Context) {
        button.shortcutLabel = hotkey.shortcut.label
        if !button.recording { button.title = button.shortcutLabel }
    }
}
final class RecorderButton: NSButton {
    var onRecord: ((Shortcut) -> Void)?
    var shortcutLabel = ""
    var recording = false
    override var acceptsFirstResponder: Bool { true }
    override init(frame: NSRect) { super.init(frame: frame); target = self; action = #selector(record); setAccessibilityLabel("Record global shortcut") }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func record() { recording = true; title = "Press shortcut…"; window?.makeFirstResponder(self) }
    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == 53 { recording = false; title = shortcutLabel; return }
        if let shortcut = Shortcut.from(event) { recording = false; onRecord?(shortcut); title = shortcut.label }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if recording { keyDown(with: event); return true }; return super.performKeyEquivalent(with: event)
    }
    override func resignFirstResponder() -> Bool { recording = false; title = shortcutLabel; return super.resignFirstResponder() }
}
