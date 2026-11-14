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

let readerHighlightID = NSAttributedString.Key("MarginHighlightID")

func readerAttributedText(_ text: String, size: Double, highlights: [ReaderRecord], lineSpacing: Double = 9) -> NSAttributedString {
    let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = lineSpacing
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
        if range.location < 0 || range.location > source.length || range.length <= 0 || range.length > source.length - range.location || source.substring(with: range) != record.quote {
            range = source.range(of: record.quote)
        }
        if range.location != NSNotFound {
            let color: PlatformColor = record.color == "green" ? .systemGreen : record.color == "pink" ? .systemPink : .systemYellow
            result.addAttribute(.backgroundColor, value: color.withAlphaComponent(0.3), range: range)
            result.addAttribute(readerHighlightID, value: record.id, range: range)
        }
    }
    return result
}

#if os(macOS)
private final class HighlightTextView: NSTextView {
    var selectionAction: ((String, NSRange, Bool) -> Void)?
    var highlightAction: ((String) -> Void)?
    var manualScroll: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let manager = layoutManager, let container = textContainer {
            let location = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
            let glyph = manager.glyphIndex(for: location, in: container)
            if glyph < manager.numberOfGlyphs,
               manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(location) {
                let index = manager.characterIndexForGlyph(at: glyph)
                if let id = textStorage?.attribute(readerHighlightID, at: index, effectiveRange: nil) as? String {
                    highlightAction?(id)
                    return
                }
            }
        }
        super.mouseDown(with: event)
    }
    override func scrollWheel(with event: NSEvent) {
        manualScroll?()
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
    var spokenRange: NSRange? = nil
    var followNarration = false
    var narrationPosition: Double = 0.5
    var onManualScroll: (() -> Void)? = nil
    var pageHeight: CGFloat? = nil
    var lineSpacing: Double = 9
    var onHighlightTap: ((ReaderRecord) -> Void)? = nil
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
        let value = NSMutableAttributedString(attributedString: readerAttributedText(text, size: fontSize, highlights: highlights, lineSpacing: lineSpacing))
        if let range = spokenRange, range.location >= 0, range.length > 0, NSMaxRange(range) <= value.length {
            value.addAttribute(.backgroundColor, value: PlatformColor.systemOrange.withAlphaComponent(0.55), range: range)
        }
        if view.attributedString() != value { let selection = view.selectedRange(); view.textStorage?.setAttributedString(value); if selection.location + selection.length <= value.length { view.setSelectedRange(selection) } }
        if followNarration, let range = spokenRange, NSMaxRange(range) <= value.length, let manager = view.layoutManager, let container = view.textContainer {
            manager.ensureLayout(for: container)
            var rect = manager.boundingRect(forGlyphRange: manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
            rect.origin.x += view.textContainerOrigin.x; rect.origin.y += view.textContainerOrigin.y
            let target = narrationPosition
            DispatchQueue.main.async {
                // The text's visibleRect shrinks near its end. Use the outer
                // viewport and document (including trailing paper) instead.
                guard let scroll = view.enclosingScrollView, let document = scroll.documentView else { return }
                let clip = scroll.contentView
                let word = view.convert(rect, to: document)
                let center = clip.bounds.minY + clip.bounds.height * target
                if abs(word.midY - center) > clip.bounds.height * 0.04 {
                    let y = word.midY - clip.bounds.height * target
                    let proposed = NSRect(origin: NSPoint(x: clip.bounds.minX, y: y), size: clip.bounds.size)
                    clip.scroll(to: clip.constrainBoundsRect(proposed).origin)
                    scroll.reflectScrolledClipView(clip)
                }
            }
        }
        (view as? HighlightTextView)?.manualScroll = onManualScroll
        (view as? HighlightTextView)?.selectionAction = onSelection
        (view as? HighlightTextView)?.highlightAction = { id in
            if let record = highlights.first(where: { $0.id == id }) { onHighlightTap?(record) }
        }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 600
        if let pageHeight { return CGSize(width: width, height: pageHeight) }
        return ReaderTextLayout.size(text: text, fontSize: fontSize, width: width, lineSpacing: lineSpacing)
    }
}
enum ReaderTextLayout {
    static func size(text: String, fontSize: Double, width: CGFloat, lineSpacing: Double = 9) -> CGSize {
        let storage = NSTextStorage(attributedString: readerAttributedText(text, size: fontSize, highlights: [], lineSpacing: lineSpacing))
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
    var spokenRange: NSRange? = nil
    var followNarration = false
    var narrationPosition: Double = 0.5
    var onManualScroll: (() -> Void)? = nil
    var pageHeight: CGFloat? = nil
    var lineSpacing: Double = 9
    var onHighlightTap: ((ReaderRecord) -> Void)? = nil
    let onSelection: (String, NSRange, Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(); view.isEditable = false; view.isSelectable = true; view.isScrollEnabled = false
        view.backgroundColor = .clear; view.textContainerInset = .zero; view.textContainer.lineFragmentPadding = 0
        view.delegate = context.coordinator
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapHighlight(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        view.addGestureRecognizer(tap)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        let value = NSMutableAttributedString(attributedString: readerAttributedText(text, size: fontSize, highlights: highlights, lineSpacing: lineSpacing))
        if let range = spokenRange, range.location >= 0, range.length > 0, NSMaxRange(range) <= value.length {
            value.addAttribute(.backgroundColor, value: PlatformColor.systemOrange.withAlphaComponent(0.55), range: range)
        }
        if view.attributedText != value { let selection = view.selectedRange; view.attributedText = value; if selection.location + selection.length <= value.length { view.selectedRange = selection } }
        if followNarration, let range = spokenRange, NSMaxRange(range) <= value.length {
            view.layoutManager.ensureLayout(for: view.textContainer)
            var rect = view.layoutManager.boundingRect(forGlyphRange: view.layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: view.textContainer)
            rect.origin.y += view.textContainerInset.top
            let target = narrationPosition
            DispatchQueue.main.async {
                var ancestor = view.superview
                while let candidate = ancestor {
                    if let scroll = candidate as? UIScrollView, scroll.isScrollEnabled {
                        var converted = view.convert(rect, to: scroll)
                        let center = scroll.contentOffset.y + scroll.bounds.height * target
                        if abs(converted.midY - center) > scroll.bounds.height * 0.04 {
                            converted.origin.y = converted.midY - scroll.bounds.height * target
                            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: min(max(0, converted.minY), max(0, scroll.contentSize.height - scroll.bounds.height))), animated: true)
                        }
                        break
                    }
                    ancestor = candidate.superview
                }
            }
        }
        context.coordinator.action = onSelection
        context.coordinator.highlightAction = { id in
            if let record = highlights.first(where: { $0.id == id }) { onHighlightTap?(record) }
        }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        if let pageHeight { return CGSize(width: proposal.width ?? 320, height: pageHeight) }
        return uiView.sizeThatFits(CGSize(width: proposal.width ?? 320, height: .greatestFiniteMagnitude))
    }
    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        var highlightAction: ((String) -> Void)?
        private func highlightID(at point: CGPoint, in view: UITextView) -> String? {
            let location = CGPoint(x: point.x - view.textContainerInset.left + view.contentOffset.x,
                                   y: point.y - view.textContainerInset.top + view.contentOffset.y)
            let manager = view.layoutManager
            let glyph = manager.glyphIndex(for: location, in: view.textContainer)
            guard glyph < manager.numberOfGlyphs,
                  manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: view.textContainer).contains(location) else { return nil }
            let index = manager.characterIndexForGlyph(at: glyph)
            guard index < view.attributedText.length else { return nil }
            return view.attributedText.attribute(readerHighlightID, at: index, effectiveRange: nil) as? String
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let view = gestureRecognizer.view as? UITextView, view.selectedRange.length == 0 else { return false }
            return highlightID(at: touch.location(in: view), in: view) != nil
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
        @objc func tapHighlight(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended, let view = gesture.view as? UITextView,
                  let id = highlightID(at: gesture.location(in: view), in: view) else { return }
            highlightAction?(id)
        }
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
