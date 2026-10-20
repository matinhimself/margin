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
                                Button("Restore") { var restored = record; restored.deleted = false; store.put(restored) }
                            } else if store.books.contains(where: { $0.id == record.bookID }) {
                                Button("Open") { reading = BookMatch(bookID: record.bookID, bookTitle: record.bookTitle, location: ReadingLocation(rawValue: record.location) ?? .summary, section: record.section, heading: "Annotation", excerpt: record.quote) }
                            } else { Text("Book removed").font(.caption).foregroundStyle(.secondary) }
                            if !record.deleted { Button("Edit") { editing = record } }
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
