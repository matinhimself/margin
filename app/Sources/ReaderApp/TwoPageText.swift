import SwiftUI
import LibraryCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// Both pagination and selectable page text use the same TextKit font and spacing.
struct TwoPageText: View {
    let text: String
    let fontSize: Double
    let highlights: [ReaderRecord]
    var lineSpacing: Double = 9
    var onHighlightTap: ((ReaderRecord) -> Void)? = nil
    let onSelection: (String, NSRange, Bool) -> Void
    @State private var pages: [NSRange] = []
    @State private var anchor = 0

    private struct Layout: Equatable {
        let text: String
        let fontSize: Double
        let lineSpacing: Double
        let width: CGFloat
        let height: CGFloat
    }

    private var first: Int { pages.firstIndex { NSLocationInRange(anchor, $0) } ?? 0 }

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, (geometry.size.width - 65) / 2)
            let height = max(1, geometry.size.height - 52)
            let layout = Layout(text: text, fontSize: fontSize, lineSpacing: lineSpacing, width: width, height: height)
            VStack(spacing: 12) {
                HStack(alignment: .top, spacing: 32) {
                    page(first, width: width, height: height)
                    Rectangle().fill(.secondary.opacity(0.18)).frame(width: 1)
                    page(first + 1, width: width, height: height)
                }.frame(height: height)
                HStack {
                    Button("Previous pages", systemImage: "chevron.left") { turn(-2) }.disabled(first == 0)
                    Spacer()
                    Text(pages.isEmpty ? "Laying out pages…" : "Pages \(first + 1)–\(min(first + 2, pages.count)) of \(pages.count)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    Button("Next pages", systemImage: "chevron.right") { turn(2) }.disabled(first + 2 >= pages.count)
                }.buttonStyle(.borderless)
            }
            .onChange(of: layout, initial: true) { old, new in
                if old.text != new.text { anchor = 0 }
                pages = TextPageLayout.ranges(text: new.text, fontSize: new.fontSize, size: CGSize(width: new.width, height: new.height), lineSpacing: new.lineSpacing)
                anchor = min(anchor, max((text as NSString).length - 1, 0))
            }
        }
    }

    @ViewBuilder private func page(_ index: Int, width: CGFloat, height: CGFloat) -> some View {
        if pages.indices.contains(index) {
            let range = pages[index]
            SelectionText(text: (text as NSString).substring(with: range), fontSize: fontSize, highlights: pageHighlights(range), pageHeight: height, lineSpacing: lineSpacing, onHighlightTap: { record in
                if let original = highlights.first(where: { $0.id == record.id }) { onHighlightTap?(original) }
            }) { quote, selected, note in
                onSelection(quote, NSRange(location: range.location + selected.location, length: selected.length), note)
            }
            .frame(width: width, height: height, alignment: .topLeading)
            .clipped()
            .accessibilityLabel("Reading page \(index + 1)")
        } else {
            Color.clear.frame(width: width, height: height).accessibilityHidden(true)
        }
    }

    private func turn(_ delta: Int) {
        let target = min(max(first + delta, 0), max(pages.count - 1, 0))
        if pages.indices.contains(target) { anchor = pages[target].location }
    }

    private func pageHighlights(_ page: NSRange) -> [ReaderRecord] {
        let source = text as NSString
        return highlights.compactMap { record in
            guard !record.quote.isEmpty else { return nil }
            var range = NSRange(location: record.offset, length: record.length)
            if range.location < 0 || range.length <= 0 || NSMaxRange(range) > source.length || source.substring(with: range) != record.quote {
                range = source.range(of: record.quote)
            }
            guard range.location != NSNotFound else { return nil }
            let overlap = NSIntersectionRange(page, range)
            guard overlap.length > 0 else { return nil }
            var result = record
            result.offset = overlap.location - page.location
            result.length = overlap.length
            result.quote = source.substring(with: overlap)
            return result
        }
    }

}

enum TextPageLayout {
    static func ranges(text: String, fontSize: Double, size: CGSize, lineSpacing: Double = 9) -> [NSRange] {
        let storage = NSTextStorage(attributedString: readerAttributedText(text, size: fontSize, highlights: [], lineSpacing: lineSpacing))
        let manager = NSLayoutManager()
        storage.addLayoutManager(manager)
        var result: [NSRange] = []
        var end = 0
        while end < storage.length {
            let container = NSTextContainer(size: CGSize(width: max(1, size.width), height: max(1, size.height - 4)))
            container.lineFragmentPadding = 0
            manager.addTextContainer(container)
            manager.ensureLayout(for: container)
            let glyphs = manager.glyphRange(for: container)
            let range = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            guard range.length > 0, NSMaxRange(range) > end else { break }
            result.append(range)
            end = NSMaxRange(range)
        }
        return result
    }
}
