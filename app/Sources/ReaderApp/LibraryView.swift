import SwiftUI
import LibraryCore

private enum Shelf: String, CaseIterable, Identifiable {
    case discover = "Discover", library = "Library", notebook = "Notebook", uploads = "Activity", habits = "Reading habits", search = "Search passages"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .discover: "sparkle.magnifyingglass"
        case .library: "books.vertical"
        case .notebook: "note.text"
        case .uploads: "circle.dotted.circle"
        case .habits: "chart.bar"
        case .search: "text.magnifyingglass"
        }
    }
}

struct LibraryView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @State private var shelf: Shelf = .discover
    @State private var showSettings = false
    @State private var showEditor = false

    var body: some View {
        Group {
            #if os(iOS)
            TabView(selection: $shelf) {
                destination(.discover).tabItem { Label("Discover", systemImage: Shelf.discover.icon) }.tag(Shelf.discover)
                destination(.library).tabItem { Label("Library", systemImage: Shelf.library.icon) }.tag(Shelf.library)
                destination(.notebook).tabItem { Label("Notebook", systemImage: Shelf.notebook.icon) }.tag(Shelf.notebook)
                destination(.uploads).tabItem { Label("Activity", systemImage: Shelf.uploads.icon) }.tag(Shelf.uploads)
                    .badge(store.jobs.filter(\.isActive).count)
            }
            #else
            NavigationSplitView {
                List(selection: $shelf) {
                    HStack(spacing: 10) { MarginMark().frame(width: 32, height: 32); Text("margin").font(.system(size: 28, weight: .medium, design: .serif)) }.padding(.vertical, 24)
                    ForEach(Shelf.allCases) { item in Label(item.rawValue, systemImage: item.icon).tag(item) }
                }.navigationSplitViewColumnWidth(min: 190, ideal: 220)
            } detail: { destination(shelf) }
            #endif
        }
        .task {
            await store.refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { break }
                if scenePhase == .active { await store.refresh() }
            }
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await store.refresh() } } }
        .sheet(isPresented: $showSettings) { ConnectionView().environment(store) }
        .sheet(isPresented: $showEditor) { BookEditor(book: Book()).environment(store) }
    }

    private func destination(_ item: Shelf) -> some View {
        NavigationStack {
            Group {
                switch item {
                case .discover: DiscoveryView(openActivity: { shelf = .uploads }, connect: { showSettings = true })
                case .library: LibraryShelfView()
                case .notebook: NotebookView()
                case .uploads: ProcessingView()
                case .habits: HabitView()
                case .search: SearchView()
                }
            }
            .background(Color.paper)
            .navigationTitle(item.rawValue)
            .marginInlineTitle()
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Connection settings", systemImage: "slider.horizontal.3") { showSettings = true }
                        Button("Refresh library", systemImage: "arrow.clockwise") { Task { await store.refresh() } }
                        if store.isAdmin { Button("Write a book", systemImage: "square.and.pencil") { showEditor = true } }
                    } label: { Image(systemName: "ellipsis.circle").font(.body).accessibilityLabel("Library options") }
                }
            }
            .navigationDestination(for: String.self) { id in
                if let book = store.books.first(where: { $0.id == id }) { BookDetailView(book: book) }
                else { ContentUnavailableView("Book unavailable", systemImage: "book.closed") }
            }
            .refreshable { await store.refresh() }
        }
    }
}

private struct LibraryShelfView: View {
    @Environment(LibraryStore.self) private var store
    @State private var filter = "All"
    @State private var query = ""
    private var books: [Book] {
        store.books.filter { book in
            let state = store.state(book)
            return book.matches(query) && (filter == "All" || (filter == "Saved" && state.saved) || (filter == "Reading" && !state.completed && state.lastReadAt != nil) || (filter == "Finished" && state.completed))
        }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("YOUR OWN LITTLE BOOKSHELF").eyebrow()
                    Text("Good ideas,\nkept close.").font(.system(size: 36, weight: .medium, design: .serif))
                }
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Find a read in your library", text: $query).textFieldStyle(.plain)
                }.padding(16).background(Color.surface, in: RoundedRectangle(cornerRadius: 16))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(["All", "Saved", "Reading", "Finished"], id: \.self) { value in
                            Button { filter = value } label: { Text(value).font(.subheadline.weight(.medium)).padding(.horizontal, 18).padding(.vertical, 10).background(filter == value ? Color.ink : Color.leaf, in: Capsule()).foregroundStyle(filter == value ? Color.paper : Color.ink) }.buttonStyle(.plain)
                        }
                    }
                }
                if let error = store.error { Label(error, systemImage: "wifi.slash").font(.caption).foregroundStyle(.secondary) }
                if store.isLoading && store.books.isEmpty { ProgressView().frame(maxWidth: .infinity).padding(40) }
                else if books.isEmpty { ContentUnavailableView("A little space for your next read", systemImage: "books.vertical", description: Text("Books you add from Discover will appear here when they’re ready.")) }
                else {
                    HStack { Text("\(books.count) reads").font(.subheadline).foregroundStyle(.secondary); Spacer(); NavigationLink { HabitView() } label: { Label("Reading habit", systemImage: "chart.bar").font(.caption) } }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 145, maximum: 220), spacing: 20)], alignment: .leading, spacing: 26) {
                        ForEach(books) { book in NavigationLink(value: book.id) { BookCard(book: book) }.buttonStyle(.plain) }
                    }
                }
                NavigationLink { SearchView() } label: { Label("Search passages & notes", systemImage: "text.magnifyingglass").font(.subheadline) }.padding(.top, 12)
            }.padding(20).frame(maxWidth: 1060).frame(maxWidth: .infinity)
        }.background(Color.paper)
    }
}

extension View {
    func marginInlineTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline).toolbarBackground(Color.paper, for: .navigationBar)
        #else
        self
        #endif
    }
    func eyebrow() -> some View { self.font(.system(size: 10, weight: .semibold)).tracking(2).foregroundStyle(.secondary) }
}
struct BookCover: View {
    let book: Book
    var body: some View {
        CatalogCover(title: book.title, author: book.author, cover: book.coverURL)
    }
}

struct BookCard: View {
    @Environment(LibraryStore.self) private var store
    let book: Book
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            BookCover(book: book)
            Text(book.category.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
            Text(book.title).font(.headline).lineLimit(2)
            Text(book.author).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            HStack {
                Label("\(book.minutes) min", systemImage: "text.book.closed").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if store.state(book).saved { Image(systemName: "bookmark.fill").font(.caption).foregroundStyle(Color.ink) }
                if store.state(book).completed { Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(Color.ink) }
            }
        }.frame(maxHeight: .infinity, alignment: .top).contentShape(Rectangle())
    }
}
