import SwiftUI
import LibraryCore

#if os(macOS)
import AppKit
typealias PlatformColor = NSColor
typealias PlatformFont = NSFont
#else
import UIKit
typealias PlatformColor = UIColor
typealias PlatformFont = UIFont
#endif

func readerAttributedText(_ text: String, size: Double, highlights: [ReaderRecord]) -> NSAttributedString {
    let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 9
    #if os(macOS)
    let font = NSFont(name: "Georgia", size: size) ?? NSFont.systemFont(ofSize: size)
    let foreground = NSColor.labelColor
    #else
    let font = UIFont(name: "Georgia", size: size) ?? UIFont.systemFont(ofSize: size)
    let foreground = UIColor.label
    #endif
    let result = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: foreground, .paragraphStyle: paragraph])
    let source = text as NSString
    for record in highlights where !record.quote.isEmpty {
        var range = NSRange(location: record.offset, length: record.length)
        if range.location + range.length > source.length || range.length == 0 || source.substring(with: range) != record.quote {
            range = source.range(of: record.quote)
        }
        if range.location != NSNotFound {
            let color: PlatformColor = record.color == "green" ? .systemGreen : record.color == "pink" ? .systemPink : .systemYellow
            result.addAttribute(.backgroundColor, value: color.withAlphaComponent(0.3), range: range)
        }
    }
    return result
}

#if os(macOS)
private final class HighlightTextView: NSTextView {
    var selectionAction: ((String, NSRange, Bool) -> Void)?
    override func scrollWheel(with event: NSEvent) {
        // The surrounding SwiftUI scroll view owns vertical scrolling.
        if let scrollView = enclosingScrollView { scrollView.scrollWheel(with: event) }
        else { super.scrollWheel(with: event) }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        if selectedRange().length > 0 {
            menu.addItem(.separator())
            for (title, action) in [("Highlight", #selector(highlight)), ("Highlight & add note", #selector(addNote))] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item)
            }
        }
        return menu
    }
    @objc private func highlight() { send(false) }
    @objc private func addNote() { send(true) }
    private func send(_ note: Bool) {
        let range = selectedRange()
        guard range.length > 0, range.location + range.length <= (string as NSString).length else { return }
        selectionAction?((string as NSString).substring(with: range), range, note)
    }
}

struct SelectionText: NSViewRepresentable {
    let text: String
    let fontSize: Double
    let highlights: [ReaderRecord]
    var pageHeight: CGFloat? = nil
    let onSelection: (String, NSRange, Bool) -> Void
    func makeNSView(context: Context) -> NSTextView {
        let view = HighlightTextView()
        view.isEditable = false; view.isSelectable = true; view.drawsBackground = false
        view.textContainerInset = .zero; view.textContainer?.lineFragmentPadding = 0
        view.isHorizontallyResizable = false; view.isVerticallyResizable = false
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.heightTracksTextView = false
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }
    func updateNSView(_ view: NSTextView, context: Context) {
        let value = readerAttributedText(text, size: fontSize, highlights: highlights)
        if view.attributedString() != value { let selection = view.selectedRange(); view.textStorage?.setAttributedString(value); if selection.location + selection.length <= value.length { view.setSelectedRange(selection) } }
        (view as? HighlightTextView)?.selectionAction = onSelection
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 600
        if let pageHeight { return CGSize(width: width, height: pageHeight) }
        return ReaderTextLayout.size(text: text, fontSize: fontSize, width: width)
    }
}
enum ReaderTextLayout {
    static func size(text: String, fontSize: Double, width: CGFloat) -> CGSize {
        let storage = NSTextStorage(attributedString: readerAttributedText(text, size: fontSize, highlights: []))
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: max(1, width), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        manager.ensureLayout(for: container)
        return CGSize(width: width, height: ceil(manager.usedRect(for: container).height) + 4)
    }
}
#else
struct SelectionText: UIViewRepresentable {
    let text: String
    let fontSize: Double
    let highlights: [ReaderRecord]
    var pageHeight: CGFloat? = nil
    let onSelection: (String, NSRange, Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(); view.isEditable = false; view.isSelectable = true; view.isScrollEnabled = false
        view.backgroundColor = .clear; view.textContainerInset = .zero; view.textContainer.lineFragmentPadding = 0
        view.delegate = context.coordinator; view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        let value = readerAttributedText(text, size: fontSize, highlights: highlights)
        if view.attributedText != value { let selection = view.selectedRange; view.attributedText = value; if selection.location + selection.length <= value.length { view.selectedRange = selection } }
        context.coordinator.action = onSelection
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        if let pageHeight { return CGSize(width: proposal.width ?? 320, height: pageHeight) }
        return uiView.sizeThatFits(CGSize(width: proposal.width ?? 320, height: .greatestFiniteMagnitude))
    }
    final class Coordinator: NSObject, UITextViewDelegate {
        var action: ((String, NSRange, Bool) -> Void)?
        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard range.length > 0 else { return nil }
            let quote = (textView.text as NSString).substring(with: range)
            return UIMenu(children: [
                UIAction(title: "Highlight", image: UIImage(systemName: "highlighter")) { [weak self] _ in self?.action?(quote, range, false) },
                UIAction(title: "Highlight & add note", image: UIImage(systemName: "note.text")) { [weak self] _ in self?.action?(quote, range, true) }
            ] + suggestedActions)
        }
    }
}
#endif
