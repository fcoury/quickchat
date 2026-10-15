import AppKit
import SwiftUI

struct ComposerEditor: NSViewRepresentable {
    @Binding var text: String
    var focus: UUID
    var fontSize: CGFloat
    var onSend: () -> Void
    var onImage: (NSImage) -> Void
    var onPasteError: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let editor = PasteTextView()
        editor.delegate = context.coordinator
        editor.isRichText = false; editor.drawsBackground = false; editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false; editor.isAutomaticSpellingCorrectionEnabled = false
        editor.font = .systemFont(ofSize: fontSize); editor.textColor = .white; editor.insertionPointColor = .white
        editor.textContainerInset = NSSize(width: 0, height: 4)
        editor.textContainer?.lineFragmentPadding = 0
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        editor.minSize = NSSize(width: 0, height: 48); editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.setAccessibilityLabel("Message")
        scroll.documentView = editor
        editor.onSend = onSend; editor.onImage = onImage; editor.onPasteError = onPasteError
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? PasteTextView else { return }
        context.coordinator.parent = self
        if editor.string != text { editor.string = text }
        if editor.font?.pointSize != fontSize { editor.font = .systemFont(ofSize: fontSize) }
        editor.onSend = onSend; editor.onImage = onImage; editor.onPasteError = onPasteError
        if context.coordinator.lastFocus != focus {
            context.coordinator.lastFocus = focus
            DispatchQueue.main.async { editor.window?.makeFirstResponder(editor) }
        }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerEditor
        var lastFocus: UUID?
        init(_ parent: ComposerEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            if let editor = notification.object as? NSTextView { parent.text = editor.string }
        }
    }
}

final class PasteTextView: NSTextView {
    var imagePasteboard = NSPasteboard.general
    var onSend: (() -> Void)?
    var onImage: ((NSImage) -> Void)?
    var onPasteError: ((String) -> Void)?
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)) || item.action == #selector(pasteAsPlainText(_:)) {
            let types = imagePasteboard.types ?? []
            if types.contains(.png) || types.contains(.tiff) || types.contains(.fileURL) { return true }
        }
        return super.validateUserInterfaceItem(item)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "v" {
            paste(nil); return true
        }
        return super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 && !event.modifierFlags.contains(.shift) && !hasMarkedText() { onSend?(); return }
        super.keyDown(with: event)
    }
    override func paste(_ sender: Any?) {
        if pasteImages() { return }
        super.pasteAsPlainText(sender)
    }
    override func pasteAsPlainText(_ sender: Any?) {
        if pasteImages() { return }
        super.pasteAsPlainText(sender)
    }
    private func pasteImages() -> Bool {
        let board = imagePasteboard
        // Screenshots expose PNG/TIFF representations. Read those directly before
        // asking AppKit to infer an object type from the pasteboard.
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = board.data(forType: type), let image = NSImage(data: data) {
                onImage?(image); return true
            }
        }
        if let images = board.readObjects(forClasses: [NSImage.self]) as? [NSImage], !images.isEmpty {
            images.prefix(4).forEach { onImage?($0) }; return true
        }
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            let images = urls.filter { ["png", "jpg", "jpeg", "tiff", "tif", "webp", "gif"].contains($0.pathExtension.lowercased()) }.compactMap(NSImage.init(contentsOf:))
            if !images.isEmpty { images.prefix(4).forEach { onImage?($0) }; return true }
        }
        if board.string(forType: .string) == nil {
            onPasteError?("The clipboard does not contain readable text or an image. Copy the screenshot again and try pasting.")
            return true
        }
        return false
    }
}
