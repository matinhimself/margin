import SwiftUI
import LibraryCore

private enum Shelf: String, CaseIterable, Identifiable {
    case discover = "Discover", saved = "My library", reading = "Continue reading", finished = "Finished", notebook = "Notes & highlights", habits = "Reading habits", search = "Search library"
    var id: String { rawValue }
    var icon: String {
        switch self { case .discover: "square.grid.2x2"; case .saved: "books.vertical"; case .reading: "book"; case .finished: "checkmark.circle"; case .notebook: "note.text"; case .habits: "chart.bar"; case .search: "magnifyingglass" }
    }
}

struct LibraryView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @State private var shelf: Shelf? = .discover
    @State private var search = ""
    @State private var category = "All topics"
    @State private var showSettings = false
    @State private var showEditor = false
    @State private var path: [String] = []

    private var filtered: [Book] {
        store.books.filter { book in
            let state = store.state(book)
            let inShelf: Bool = switch shelf ?? .discover {
            case .discover: true
            case .saved: state.saved
            case .reading: !state.completed && state.lastReadAt != nil
            case .finished: state.completed
            case .notebook, .habits, .search: true
            }
            return inShelf && (book.matches(search) || store.annotations(bookID: book.id).contains { ($0.text + " " + $0.quote).localizedCaseInsensitiveContains(search) }) && (category == "All topics" || category == book.category)
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $shelf) {
                Section {
                    ForEach(Shelf.allCases) { item in Label(item.rawValue, systemImage: item.icon).tag(item) }
                } header: {
                    HStack(spacing: 8) {
                        MarginMark().frame(width: 36, height: 36)
                        Text("margin").font(.system(size: 28, weight: .bold, design: .serif))
                    }.foregroundStyle(Color.ink).padding(.vertical, 24).textCase(nil)
                }
                Section("Sync") {
                    Label(store.isSyncing ? "Syncing…" : store.cache.pending.isEmpty ? "Up to date" : "\(store.cache.pending.count) changes pending", systemImage: store.cache.pending.isEmpty ? "checkmark.icloud" : "icloud.and.arrow.up")
                        .font(.caption).foregroundStyle(.secondary)
                    if let error = store.syncError { Text("Offline: \(error)").font(.caption).foregroundStyle(.secondary) }
                    Button("Sync now") { Task { await store.sync() } }.disabled(store.isSyncing)
                }
                Section("Your space to grow") {
                    Text("Big ideas.\nA little every day.")
                        .font(.system(.title3, design: .serif)).foregroundStyle(.secondary).padding(.vertical, 8)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
            .toolbar { ToolbarItem(placement: .automatic) { Button("Connection", systemImage: "gearshape") { showSettings = true } } }
        } detail: {
            NavigationStack(path: $path) {
                Group {
                if shelf == .notebook { NotebookView() }
                else if shelf == .habits { HabitView() }
                else if shelf == .search { SearchView() }
                else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        header
                        connectionStatus
                        if store.books.isEmpty && store.isLoading {
                            ProgressView("Opening your library…").frame(maxWidth: .infinity).padding(60)
                        } else if filtered.isEmpty {
                            ContentUnavailableView {
                                Label(store.books.isEmpty ? "Your next idea starts here" : "No books here yet", systemImage: "books.vertical")
                            } description: {
                                Text(store.books.isEmpty ? "Connect to your library server, then add your first manually written summary." : "Try another topic or search, or save a book from Discover.")
                            } actions: {
                                if store.books.isEmpty {
                                    Button("Add a book") { showEditor = true }.buttonStyle(.borderedProminent)
                                    Button("Connection settings") { showSettings = true }
                                } else { Button("Show all books") { shelf = .discover; search = ""; category = "All topics" } }
                            }.padding(.vertical, 40)
                        } else {
                            if shelf == .discover && search.isEmpty && category == "All topics", let book = filtered.first {
                                featured(book)
                            }
                            HStack {
                                Text(search.isEmpty ? "Explore the bookshelf" : "Search results")
                                    .font(.system(.title2, design: .serif, weight: .semibold))
                                Spacer()
                                Text("\(filtered.count) books").font(.subheadline).foregroundStyle(.secondary)
                            }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 165, maximum: 230), spacing: 22)], alignment: .leading, spacing: 28) {
                                ForEach(filtered) { book in
                                    NavigationLink(value: book.id) { BookCard(book: book) }.buttonStyle(.plain)
                                }
                            }
                        }
                    }.padding(28).frame(maxWidth: 1160).frame(maxWidth: .infinity)
                }
                .background(Color.paper)
                .navigationTitle(shelf?.rawValue ?? "Discover")
                .searchable(text: $search, prompt: "Books, passages, and notes")
                }
                }
                .refreshable { await store.refresh() }
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button("Refresh", systemImage: "arrow.clockwise") { Task { await store.refresh() } }.disabled(store.isLoading)
                        Button("Add book", systemImage: "plus") { showEditor = true }
                        Button("Connection", systemImage: "slider.horizontal.3") { showSettings = true }
                    }
                }
                .navigationDestination(for: String.self) { id in
                    if let book = store.books.first(where: { $0.id == id }) { BookDetailView(book: book) }
                    else { ContentUnavailableView("Book unavailable", systemImage: "book.closed", description: Text("This book was removed from the library.")) }
                }
            }
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
        .onChange(of: shelf) { _, _ in category = "All topics"; path = [] }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("A LITTLE WISER, EVERY DAY").font(.caption.weight(.semibold)).tracking(2).foregroundStyle(.secondary)
            Text(shelf == .discover ? "Make room for a new idea." : shelf?.rawValue ?? "Your library")
                .font(.system(size: 36, weight: .medium, design: .serif)).foregroundStyle(Color.ink)
            Text("Thoughtful reads for a curious mind.").foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(["All topics"] + Set(store.books.map(\.category)).sorted(), id: \.self) { item in
                        Button { category = item } label: {
                            Text(item).font(.subheadline.weight(.medium)).padding(.horizontal, 16).padding(.vertical, 9)
                                .background(category == item ? Color.ink : Color.leaf, in: Capsule())
                                .foregroundStyle(category == item ? Color.paper : Color.ink)
                        }.buttonStyle(.plain)
                    }
                }
            }.padding(.top, 8)
        }
    }
    @ViewBuilder private var connectionStatus: some View {
        if let error = store.error {
            HStack(alignment: .top) {
                Image(systemName: "wifi.slash")
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.books.isEmpty ? "Cannot reach your library" : "Reading from your offline library").font(.subheadline.bold())
                    Text(error).font(.caption)
                    if let date = store.cache.refreshedAt { Text("Last refreshed \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption) }
                }
                Spacer()
                Button("Connect") { showSettings = true }
            }.foregroundStyle(.secondary).padding().background(Color.leaf, in: RoundedRectangle(cornerRadius: 14))
        }
        if let notice = store.notice { Label(notice, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
    }
    private func featured(_ book: Book) -> some View {
        NavigationLink(value: book.id) {
            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("TODAY’S LITTLE DISCOVERY").font(.caption2.weight(.bold)).tracking(1.5)
                    Text(book.title).font(.system(.largeTitle, design: .serif, weight: .semibold))
                    Text(book.subtitle).font(.subheadline).lineLimit(2)
                    Label("Take \(book.minutes) minutes for yourself", systemImage: "arrow.up.right").font(.subheadline.weight(.semibold)).padding(.top, 8)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "sparkle").font(.system(size: 56, weight: .ultraLight)).accessibilityHidden(true)
            }.foregroundStyle(Color.ink).padding(28).background(Color.leaf, in: RoundedRectangle(cornerRadius: 22))
        }.buttonStyle(.plain)
    }
}

struct BookCover: View {
    let book: Book
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(hex: book.color)
            GeometryReader { geo in
                Circle().stroke(.black.opacity(0.12), lineWidth: 1).frame(width: geo.size.width * 0.9).offset(x: geo.size.width * 0.3, y: geo.size.height * 0.43)
                Circle().fill(.white.opacity(0.25)).frame(width: geo.size.width * 0.65).offset(x: -geo.size.width * 0.2, y: geo.size.height * 0.6)
            }.clipped()
            VStack(alignment: .leading, spacing: 12) {
                Text("M / FIELDNOTES").font(.system(size: 9, weight: .bold)).tracking(2)
                Rectangle().frame(width: 26, height: 2).padding(.top, 8)
                Text(book.title).font(.system(size: 24, weight: .semibold, design: .serif)).minimumScaleFactor(0.6).lineLimit(4)
                Spacer(minLength: 12)
                Text(book.author.uppercased()).font(.system(size: 10, weight: .medium)).tracking(1).lineLimit(2)
            }.padding(20).foregroundStyle(Color(hex: "#183C32"))
        }.aspectRatio(0.73, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(alignment: .leading) { Rectangle().fill(.black.opacity(0.06)).frame(width: 6).padding(.vertical, 5) }
            .accessibilityElement(children: .ignore).accessibilityLabel("Cover of \(book.title)")
    }
}

private struct BookCard: View {
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
