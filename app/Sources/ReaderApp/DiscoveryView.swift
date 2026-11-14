import SwiftUI
import LibraryCore

struct DiscoveryView: View {
    @Environment(LibraryStore.self) private var store
    let openActivity: () -> Void
    let connect: () -> Void
    @State private var query = ""
    @State private var topic = "Psychology"
    @State private var language = "english"
    @State private var lastLoadedIdentity = ""
    @State private var books: [ZLibraryBook] = []
    @State private var page = 0
    @State private var totalPages = 1
    @State private var loading = true
    @State private var loadingMore = false
    @State private var failure: String?
    @State private var selected: DiscoveryBook?
    private var effectiveQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? topic : query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var searchIdentity: String { store.server + "\n" + store.token + "\n" + effectiveQuery + "\n" + language }
    private var groups: [DiscoveryBook] { DiscoveryBook.grouped(books) }
    private var libraryMatches: [Book] { Array(store.books.filter { query.isEmpty || $0.matches(query) }.prefix(6)) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                introduction
                searchField
                if query.isEmpty { topics }
                if store.jobs.contains(where: \.isActive) { activityBanner }
                if !libraryMatches.isEmpty { readyReads }
                catalog
                Text("Books from Z-Library · Made into reads for your library")
                    .font(.caption2).foregroundStyle(.tertiary).frame(maxWidth: .infinity).padding(.vertical, 12)
            }.padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 24).frame(maxWidth: 1060).frame(maxWidth: .infinity)
        }
        .background(Color.paper)
        .refreshable { await store.refresh(); await loadMore(reset: true) }
        .task(id: searchIdentity) {
            let text = effectiveQuery; let identity = searchIdentity; let selectedLanguage = language
            if lastLoadedIdentity == identity && !books.isEmpty { loading = false; return }
            loading = true; failure = nil; books = []; page = 0
            guard !store.token.isEmpty else { loading = false; failure = "Connect to your library to explore new books and keep your reads together."; return }
            do {
                if !query.isEmpty { try await Task.sleep(for: .milliseconds(450)) }
                try Task.checkCancellation()
                let origin = store.server; let credential = store.token
                let response = try await LibraryAPI(server: origin, token: credential, proxy: store.proxy).searchZLibrary(query: text, language: selectedLanguage)
                try Task.checkCancellation()
                guard identity == searchIdentity && origin == store.server && credential == store.token else { return }
                lastLoadedIdentity = identity
                books = response.books; page = response.page; totalPages = response.totalPages; loading = false
            } catch is CancellationError { }
            catch { if !Task.isCancelled && text == effectiveQuery { failure = error.localizedDescription; loading = false } }
        }
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { break }
                if store.jobs.contains(where: \.isActive) {
                    await store.refreshProcessing()
                    if store.jobs.contains(where: { job in job.status == "complete" && !store.books.contains(where: { $0.id == job.bookID }) }) { await store.refresh() }
                }
            }
        }
        .sheet(item: $selected) { group in DiscoverySelectionView(group: group, openActivity: openActivity).environment(store) }
    }

    private var introduction: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 12) {
                Text("A LITTLE CURIOSITY GOES A LONG WAY").eyebrow()
                Text(query.isEmpty ? "Find your next\nperspective." : "Follow your\ncuriosity.")
                    .font(.system(size: 34, weight: .medium, design: .serif)).tracking(-1).foregroundStyle(Color.ink)
            }
            Spacer(minLength: 0)
            MarginMark().frame(width: 38, height: 38).padding(.top, 25).accessibilityHidden(true)
        }
    }
    private var searchField: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass").foregroundStyle(Color.ink)
            TextField("A book, an author, an idea…", text: $query).textFieldStyle(.plain).font(.body)
                .accessibilityIdentifier("discovery.search")
                #if os(iOS)
                .submitLabel(.search).autocorrectionDisabled()
                #endif
            if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.plain).accessibilityLabel("Clear search") }
        }.padding(17).background(Color.surface, in: RoundedRectangle(cornerRadius: 18))
            .overlay { RoundedRectangle(cornerRadius: 18).stroke(Color.line, lineWidth: 1) }
    }
    private var topics: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(["Psychology", "Habits", "Philosophy", "Creativity", "Business"], id: \.self) { value in
                    Button { topic = value } label: {
                        Text(value).font(.system(size: 13, weight: .medium)).padding(.horizontal, 15).padding(.vertical, 10)
                            .background(topic == value ? Color.ink : Color.leaf.opacity(0.6), in: Capsule())
                            .foregroundStyle(topic == value ? Color.paper : Color.ink)
                    }.buttonStyle(.plain)
                }
            }
        }.padding(.top, -10)
    }
    private var activityBanner: some View {
        Button(action: openActivity) {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Your next read is taking shape").font(.subheadline.weight(.medium))
                    Text("See what’s being prepared").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(); Image(systemName: "arrow.up.right").font(.caption)
            }.foregroundStyle(Color.ink).padding(16).background(Color.leaf, in: RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(.plain)
    }
    private var readyReads: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("Ready when you are").font(.system(.title3, design: .serif, weight: .semibold)); Spacer(); Text("IN YOUR LIBRARY").eyebrow() }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(libraryMatches) { book in
                        NavigationLink(value: book.id) {
                            HStack(spacing: 12) {
                                BookCover(book: book).frame(width: 46, height: 63)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(book.title).font(.system(.subheadline, design: .serif, weight: .semibold)).lineLimit(2)
                                    Text("\(book.minutes) min · Ready to read").font(.caption2).foregroundStyle(.secondary)
                                }.frame(width: 150, alignment: .leading)
                            }.padding(12).background(Color.surface, in: RoundedRectangle(cornerRadius: 15))
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
    }
    private var catalog: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text(query.isEmpty ? "Explore \(topic.lowercased())" : "Out there, waiting for you")
                    .font(.system(.title2, design: .serif, weight: .medium))
                Spacer()
                Menu {
                    Button("All languages") { language = "" }
                    Button("English") { language = "english" }
                    Button("فارسی") { language = "persian" }
                    Button("Español") { language = "spanish" }
                } label: { HStack(spacing: 4) { Text(language == "english" ? "English" : language == "persian" ? "فارسی" : language == "spanish" ? "Español" : "All languages"); Image(systemName: "chevron.down").font(.system(size: 9, weight: .medium)) }.font(.caption).foregroundStyle(.secondary) }
            }
            if let failure {
                VStack(alignment: .leading, spacing: 12) {
                    Label(store.token.isEmpty ? "Let’s open your library" : "Discovery is taking a moment", systemImage: store.token.isEmpty ? "books.vertical" : "wifi.exclamationmark").font(.headline)
                    Text(failure).font(.callout).foregroundStyle(.secondary)
                    if store.token.isEmpty { Button("Connect library", action: connect).buttonStyle(.bordered) }
                    else { Button("Try again") { Task { await loadMore(reset: true) } }.buttonStyle(.bordered) }
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(Color.surface, in: RoundedRectangle(cornerRadius: 18))
            }
            if loading { skeleton }
            else if groups.isEmpty && failure == nil { ContentUnavailableView("A different search might spark something", systemImage: "magnifyingglass", description: Text("Try a book title, an author, or a broader topic.")) }
            else if !groups.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 145, maximum: 220), spacing: 20)], alignment: .leading, spacing: 26) {
                    ForEach(groups) { group in
                        if let local = readyBook(group) {
                            NavigationLink(value: local.id) { catalogCard(group, status: "In your library", ready: true) }.buttonStyle(.plain)
                        } else {
                            Button { selected = group } label: { catalogCard(group, status: activeJob(group) == nil ? nil : "Being prepared", ready: false) }.buttonStyle(.plain)
                        }
                    }
                }
                if page < totalPages {
                    Button { Task { await loadMore() } } label: {
                        HStack { Spacer(); if loadingMore { ProgressView().controlSize(.small) } else { Text("A few more possibilities"); Image(systemName: "arrow.down") }; Spacer() }.font(.subheadline.weight(.medium)).padding(17)
                    }.buttonStyle(.plain).disabled(loadingMore).background(Color.leaf, in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }
    }
    private var skeleton: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 145, maximum: 220), spacing: 20)], spacing: 24) {
            ForEach(0..<4, id: \.self) { _ in VStack(alignment: .leading, spacing: 10) { RoundedRectangle(cornerRadius: 10).fill(Color.leaf).aspectRatio(0.74, contentMode: .fit); RoundedRectangle(cornerRadius: 3).fill(Color.leaf).frame(height: 13); RoundedRectangle(cornerRadius: 3).fill(Color.leaf.opacity(0.5)).frame(width: 85, height: 10) }.accessibilityHidden(true) }
        }.overlay(alignment: .topTrailing) { ProgressView().padding(12) }
    }
    private func catalogCard(_ group: DiscoveryBook, status: String?, ready: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            CatalogCover(title: group.book.title, author: group.book.authors.first ?? "", cover: group.book.cover)
                .overlay(alignment: .bottomLeading) {
                    if let status { Label(status, systemImage: ready ? "checkmark.circle.fill" : "clock").font(.system(size: 10, weight: .semibold)).padding(.horizontal, 9).padding(.vertical, 7).background(Color.paper.opacity(0.96), in: Capsule()).padding(8) }
                }
            Text(group.book.title).font(.system(size: 17, weight: .semibold, design: .serif)).lineLimit(2).multilineTextAlignment(.leading).foregroundStyle(Color.ink)
            Text(group.book.authors.joined(separator: ", ")).font(.caption).lineLimit(1).foregroundStyle(.secondary)
            Text(group.editions.count > 1 ? "\(group.editions.count) editions · Choose your read" : "Make it a 10 or 30 min read").font(.system(size: 10)).foregroundStyle(.secondary)
        }.frame(maxHeight: .infinity, alignment: .top).contentShape(Rectangle())
    }
    private func readyBook(_ group: DiscoveryBook) -> Book? {
        if let job = store.jobs.first(where: { job in group.editions.contains { $0.id == job.catalogID } && job.status == "complete" }), let book = store.books.first(where: { $0.id == job.bookID }) { return book }
        return store.books.first { local in
            let author = Set(DiscoveryBook.key(group.book.authors.first ?? "").split(separator: " "))
            return DiscoveryBook.key(local.title) == DiscoveryBook.key(group.book.title) && Set(DiscoveryBook.key(local.author).split(separator: " ")).isSuperset(of: author)
        }
    }
    private func activeJob(_ group: DiscoveryBook) -> ProcessingJob? { store.jobs.first { job in job.isActive && group.editions.contains { $0.id == job.catalogID } } }
    private func loadMore(reset: Bool = false) async {
        guard !loadingMore else { return }
        let text = effectiveQuery; let origin = store.server; let credential = store.token; let identity = searchIdentity; let selectedLanguage = language
        loadingMore = true
        if reset { loading = true; failure = nil }
        defer { loadingMore = false; if reset && identity == searchIdentity { loading = false } }
        do {
            let response = try await LibraryAPI(server: origin, token: credential, proxy: store.proxy).searchZLibrary(query: text, page: reset ? 1 : page + 1, language: selectedLanguage)
            guard identity == searchIdentity && origin == store.server && credential == store.token else { return }
            lastLoadedIdentity = identity
            books = reset ? response.books : books + response.books; page = response.page; totalPages = response.totalPages; failure = nil; loading = false
        } catch { if identity == searchIdentity { failure = error.localizedDescription } }
    }
}

struct CatalogCover: View {
    let title: String
    var author: String = ""
    var cover: String?
    private var palette: Color {
        let colors: [UInt32] = [0xD9E1CA, 0xE9DCC1, 0xD8DFE7, 0xE6CEC0, 0xDAD2E0]
        return Color(hex: String(format: "%06X", colors[title.unicodeScalars.reduce(0) { $0 + Int($1.value) } % colors.count]))
    }
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                palette
                VStack(alignment: .leading, spacing: 10) {
                    Text("M / LIBRARY").font(.system(size: max(7, geometry.size.width * 0.045), weight: .semibold)).tracking(2)
                    Rectangle().frame(width: 20, height: 1).padding(.top, 8)
                    Text(title).font(.system(size: geometry.size.width * 0.14, weight: .medium, design: .serif)).lineLimit(5).minimumScaleFactor(0.7)
                    Spacer(minLength: 0)
                    Text(author).font(.system(size: max(8, geometry.size.width * 0.06))).lineLimit(2)
                }.padding(geometry.size.width * 0.12).foregroundStyle(Color.forest).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                if let cover, let url = URL(string: cover), ["https", "http"].contains(url.scheme ?? "") {
                    let larger = URL(string: cover.replacingOccurrences(of: "/covers100/", with: "/covers400/")) ?? url
                    AsyncImage(url: larger) { phase in
                        if case .success(let image) = phase { artwork(image, size: geometry.size) }
                        else if case .failure = phase, larger != url {
                            AsyncImage(url: url) { original in if case .success(let image) = original { artwork(image, size: geometry.size) } }
                        }
                    }
                }
            }
        }.aspectRatio(0.74, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).stroke(.black.opacity(0.05), lineWidth: 1) }
            .shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: 4).accessibilityHidden(true)
    }
    private func artwork(_ image: Image, size: CGSize) -> some View {
        image.resizable().scaledToFill().frame(width: size.width, height: size.height).clipped()
    }

}

struct SummaryLengthPicker: View {
    @Binding var minutes: Int
    var body: some View {
        HStack(spacing: 12) {
            ForEach([10, 30], id: \.self) { value in
                Button { minutes = value } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Text("\(value) min").font(.system(.title2, design: .serif, weight: .medium)); Spacer(); Image(systemName: minutes == value ? "checkmark.circle.fill" : "circle").font(.subheadline) }
                        Text(value == 10 ? "The essentials" : "A deeper read").font(.caption).foregroundStyle(.secondary)
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(minutes == value ? Color.leaf : Color.surface, in: RoundedRectangle(cornerRadius: 15))
                        .overlay { RoundedRectangle(cornerRadius: 15).stroke(minutes == value ? Color.ink : Color.line, lineWidth: minutes == value ? 1.5 : 1) }
                }.buttonStyle(.plain).accessibilityAddTraits(minutes == value ? .isSelected : [])
            }
        }
    }
}

private struct DiscoverySelectionView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let group: DiscoveryBook
    let openActivity: () -> Void
    @State private var selectedID: String
    @State private var minutes = 10
    @State private var submitting = false
    @State private var submitted = false
    @State private var failure: String?
    init(group: DiscoveryBook, openActivity: @escaping () -> Void) {
        self.group = group; self.openActivity = openActivity
        _selectedID = State(initialValue: group.editions.first(where: { $0.language.lowercased().contains("english") })?.id ?? group.book.id)
    }
    private var edition: ZLibraryBook { group.editions.first(where: { $0.id == selectedID }) ?? group.book }
    private var existing: ProcessingJob? { store.jobs.first { job in job.catalogID == selectedID && (job.isActive || (job.status == "complete" && store.books.contains(where: { $0.id == job.bookID }))) } }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    HStack(alignment: .top, spacing: 20) {
                        CatalogCover(title: group.book.title, author: group.book.authors.first ?? "", cover: group.book.cover).frame(width: 100)
                        VStack(alignment: .leading, spacing: 10) {
                            Text("MAKE ROOM FOR A GOOD IDEA").eyebrow()
                            Text(group.book.title).font(.system(.title2, design: .serif, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                            Text(group.book.authors.joined(separator: ", ")).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    if submitted || existing != nil {
                        VStack(alignment: .leading, spacing: 12) {
                            Image(systemName: "checkmark.circle.fill").font(.largeTitle).foregroundStyle(Color.ink)
                            Text("Your next read is on its way.").font(.system(.title2, design: .serif))
                            Text("You’ll find it in Library when it’s ready. Follow its progress in Activity.").font(.callout).foregroundStyle(.secondary)
                        }.padding(22).frame(maxWidth: .infinity, alignment: .leading).background(Color.leaf, in: RoundedRectangle(cornerRadius: 20))
                    } else {
                        VStack(alignment: .leading, spacing: 14) { Text("How much time do you have?").font(.system(.title3, design: .serif)); SummaryLengthPicker(minutes: $minutes) }
                        VStack(alignment: .leading, spacing: 14) {
                            HStack { Text("Choose an edition").font(.system(.title3, design: .serif)); Spacer(); Text("\(group.editions.count) available").font(.caption).foregroundStyle(.secondary) }
                            VStack(spacing: 0) {
                                ForEach(group.editions) { item in
                                    Button { selectedID = item.id } label: {
                                        HStack(spacing: 12) {
                                            Image(systemName: selectedID == item.id ? "checkmark.circle.fill" : "circle").foregroundStyle(selectedID == item.id ? Color.ink : .secondary)
                                            VStack(alignment: .leading, spacing: 5) {
                                                Text([item.language.capitalized, item.year].filter { !$0.isEmpty }.joined(separator: " · ")).font(.subheadline.weight(.medium))
                                                Text([item.extension, item.size].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                    }.buttonStyle(.plain).disabled(submitting)
                                    if item.id != group.editions.last?.id { Divider().padding(.leading, 44) }
                                }
                            }.background(Color.surface, in: RoundedRectangle(cornerRadius: 16))
                        }
                        Text("We’ll turn this book into a focused read, with its key ideas and a readable full text.").font(.callout).foregroundStyle(.secondary)
                    }
                    if let failure { Label(failure, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red) }
                }.padding(24).frame(maxWidth: 620).frame(maxWidth: .infinity)
            }.background(Color.paper)
            .navigationTitle("Your next read").marginInlineTitle()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Image(systemName: "xmark").font(.subheadline.weight(.medium)) }.accessibilityLabel("Close").disabled(submitting) } }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    Button {
                        if submitted || existing != nil { dismiss(); openActivity() }
                        else {
                            submitting = true; failure = nil
                            Task {
                                do { try await store.submitZLibrary(book: edition, summaryMinutes: minutes); submitted = true }
                                catch { failure = error.localizedDescription }
                                submitting = false
                            }
                        }
                    } label: {
                        HStack(spacing: 10) {
                            if submitting { ProgressView().tint(Color.paper) }
                            Text(submitted || existing != nil ? "View in Activity" : submitting ? "Adding to your library…" : "Create my \(minutes)-minute read").font(.subheadline.weight(.semibold))
                            if !submitting { Image(systemName: "arrow.right") }
                        }.frame(maxWidth: .infinity).padding(18).foregroundStyle(Color.paper).background(Color.ink, in: RoundedRectangle(cornerRadius: 16))
                    }.buttonStyle(.plain).disabled(submitting)
                    if !submitted && existing == nil { Text("Your read will appear in Library when it’s ready.").font(.caption2).foregroundStyle(.secondary) }
                }.padding(20).background(Color.paper)
            }
        }.interactiveDismissDisabled(submitting)
    }
}
