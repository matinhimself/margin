import SwiftUI
import LibraryCore

struct AnnotationEditor: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var record: ReaderRecord
    var body: some View {
        NavigationStack {
            Form {
                SwiftUI.Section(record.bookTitle) {
                    Text("\(ReadingLocation(rawValue: record.location)?.label ?? "Reading") · \(record.location == "pdf" ? "Page" : "Section") \(record.section + 1)").font(.caption).foregroundStyle(.secondary)
                    if !record.quote.isEmpty { Text(record.quote).textSelection(.enabled).padding(.vertical, 8) }
                    Picker("Highlight color", selection: $record.color) { Text("Yellow").tag("yellow"); Text("Green").tag("green"); Text("Pink").tag("pink") }
                }
                SwiftUI.Section("Your note") {
                    TextEditor(text: $record.text).frame(minHeight: 180).accessibilityLabel("Note text")
                }
                if store.cache.records[record.id] != nil {
                    SwiftUI.Section {
                        Button("Delete annotation", role: .destructive) { store.remove(record); dismiss() }
                        Text("Deletion syncs to your other devices.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.formStyle(.grouped).navigationTitle(record.quote.isEmpty ? "Note" : "Highlight & note")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Save") { store.put(record); dismiss() }.disabled((record.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && record.quote.isEmpty) || record.text.utf8.count > 100000 || record.quote.utf8.count > 100000) }
                }
        }.frame(minWidth: 320, idealWidth: 560, minHeight: 420, idealHeight: 620)
    }
}

struct NotebookView: View {
    @Environment(LibraryStore.self) private var store
    var bookID: String? = nil
    @State private var query = ""
    @State private var filter = "All"
    @State private var editing: ReaderRecord?
    @State private var reading: BookMatch?
    private var entries: [ReaderRecord] {
        store.records.filter { $0.kind == "annotation" && (filter == "Deleted" ? $0.deleted : !$0.deleted) && (bookID == nil || $0.bookID == bookID) && (filter != "Highlights" || !$0.quote.isEmpty) && (filter != "Notes" || !$0.text.isEmpty) && (query.isEmpty || ($0.bookTitle + " " + $0.quote + " " + $0.text).localizedCaseInsensitiveContains(query)) }.sorted { $0.updatedAt == $1.updatedAt ? $0.id > $1.id : $0.updatedAt > $1.updatedAt }
    }
    var body: some View {
        VStack(spacing: 0) {
            Picker("Show", selection: $filter) { ForEach(["All", "Highlights", "Notes", "Deleted"], id: \.self) { Text($0) } }.pickerStyle(.segmented).padding()
            if entries.isEmpty {
                ContentUnavailableView("Your notebook is waiting", systemImage: "note.text", description: Text("Select text while reading to highlight it, or use Add note. Your annotations are saved offline and sync across devices."))
            } else {
                List(entries) { record in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(record.bookTitle).font(.headline)
                            Spacer()
                            Text(record.date, style: .date).font(.caption).foregroundStyle(.secondary)
                        }
                        if !record.quote.isEmpty { Text(record.quote).lineLimit(5).padding(10).background(highlightColor(record).opacity(0.18), in: RoundedRectangle(cornerRadius: 8)) }
                        if !record.text.isEmpty { Text(record.text).lineLimit(6).textSelection(.enabled) }
                        HStack {
                            Text("\(ReadingLocation(rawValue: record.location)?.label ?? "Reading") · \(record.location == "pdf" ? "Page" : "Section") \(record.section + 1)").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            if record.deleted {
                                Button("Restore") { var restored = record; restored.deleted = false; store.put(restored) }.fixedSize()
                            } else if store.books.contains(where: { $0.id == record.bookID }) {
                                Button("Open") { reading = BookMatch(bookID: record.bookID, bookTitle: record.bookTitle, location: ReadingLocation(rawValue: record.location) ?? .summary, section: record.section, heading: "Annotation", excerpt: record.quote) }
                            } else { Text("Book removed").font(.caption).foregroundStyle(.secondary) }
                            if !record.deleted { Button("Edit") { editing = record }.fixedSize() }
                        }.buttonStyle(.borderless)
                        if record.location == "pdf", !record.sourceHash.isEmpty, let book = store.books.first(where: { $0.id == record.bookID }), book.source?.sha256 != record.sourceHash {
                            Text("Saved from an earlier source PDF. The original quotation and note are preserved.").font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 10)
                }.listStyle(.plain)
            }
        }.background(Color.paper).navigationTitle("Notes & highlights")
            .searchable(text: $query, prompt: "Search your notebook")
            .sheet(item: $editing) { record in AnnotationEditor(record: record).environment(store) }
            .readerPresentation(item: $reading) { match in ReadingDestination(match: match).environment(store) }
    }
    private func highlightColor(_ record: ReaderRecord) -> Color { record.color == "green" ? .green : record.color == "pink" ? .pink : .yellow }
}

struct ReadingDestination: View {
    @Environment(LibraryStore.self) private var store
    let match: BookMatch
    var body: some View {
        if let book = store.books.first(where: { $0.id == match.bookID }) {
            if match.location == .pdf { SourceReader(book: book, initialPage: match.section) }
            else { ReaderView(book: book, location: match.location, initialSection: match.section) }
        } else { ContentUnavailableView("Book unavailable", systemImage: "book.closed") }
    }
}

struct HighlightSelectionMenu: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let record: ReaderRecord
    let onEdit: (ReaderRecord) -> Void
    private var currentRecord: ReaderRecord { store.cache.records[record.id] ?? record }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Highlight", systemImage: "highlighter").font(.subheadline.weight(.semibold))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary).frame(width: 28, height: 28)
                        .background(Color.primary.opacity(0.05), in: Circle())
                }.accessibilityLabel("Close highlight menu")
            }
            Text(record.quote)
                .font(.system(size: 14, design: .serif)).lineSpacing(4).lineLimit(3)
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .leading) { Capsule().fill(swatch(currentRecord.color)).frame(width: 3) }
            HStack(spacing: 12) {
                Text("Color").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                ForEach(["yellow", "green", "pink"], id: \.self) { color in
                    Button { recolor(color) } label: {
                        Circle().fill(swatch(color))
                            .overlay {
                                if currentRecord.color == color {
                                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Color.black.opacity(0.7))
                                }
                            }
                            .padding(4)
                            .overlay { Circle().strokeBorder(currentRecord.color == color ? Color.ink.opacity(0.65) : .clear, lineWidth: 1.5) }
                            .frame(width: 36, height: 36)
                    }
                    .accessibilityLabel("\(color.capitalized) highlight")
                    .accessibilityAddTraits(currentRecord.color == color ? .isSelected : [])
                }
            }
            Divider()
            VStack(spacing: 4) {
                menuAction(currentRecord.text.isEmpty ? "Add note" : "Edit note", icon: "square.and.pencil") {
                    let updated = currentRecord
                    dismiss()
                    onEdit(updated)
                }
                menuAction("Copy text", icon: "doc.on.doc") {
                    #if os(macOS)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(record.quote, forType: .string)
                    #else
                    UIPasteboard.general.string = record.quote
                    #endif
                    dismiss()
                }
                menuAction("Delete highlight", icon: "trash", destructive: true) {
                    store.remove(currentRecord)
                    dismiss()
                }
            }
        }
        .buttonStyle(.plain)
        .padding(20).frame(width: 300)
        .foregroundStyle(Color.ink).background(Color.paper)
        .presentationCompactAdaptation(.popover)
    }
    private func menuAction(_ title: String, icon: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(role: destructive ? .destructive : nil, action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 13, weight: .medium))
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                .padding(.horizontal, 10)
                .foregroundStyle(destructive ? Color.red : Color.ink)
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(HighlightMenuButtonStyle())
    }
    private func swatch(_ color: String) -> Color {
        switch color {
        case "green": Color(red: 0.60, green: 0.79, blue: 0.59)
        case "pink": Color(red: 0.92, green: 0.65, blue: 0.71)
        default: Color(red: 0.94, green: 0.80, blue: 0.37)
        }
    }
    private func recolor(_ color: String) {
        var updated = currentRecord
        updated.color = color
        store.put(updated)
    }
}

private struct HighlightMenuButtonStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.ink.opacity(configuration.isPressed ? 0.12 : hovering ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 8))
            .onHover { hovering = $0 }
    }
}
