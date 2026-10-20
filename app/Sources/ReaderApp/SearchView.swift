import SwiftUI
import LibraryCore

struct SearchView: View {
    @Environment(LibraryStore.self) private var store
    @State private var query = ""
    @State private var selected: BookMatch?
    private var matches: [BookMatch] { BookSearch.matches(books: store.books, records: store.records, query: query) }
    var body: some View {
        Group {
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView("Find an idea again", systemImage: "magnifyingglass", description: Text("Search across summaries, full-text chapters, highlights, and notes. Open a source PDF to search its text."))
            } else if matches.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                List(matches) { match in
                    Button { selected = match } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(match.bookTitle).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            HStack { Text(match.heading).font(.headline); Spacer(); Text(match.annotationID == nil ? match.location.label : "Notebook").font(.caption).foregroundStyle(.secondary) }
                            Text(match.excerpt).font(.body).lineLimit(4).foregroundStyle(.secondary)
                        }.padding(.vertical, 8).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }.listStyle(.plain)
            }
        }.background(Color.paper).navigationTitle("Search library")
            .searchable(text: $query, prompt: "Passages, chapters, and notes")
            .readerPresentation(item: $selected) { match in ReadingDestination(match: match).environment(store) }
    }
}
