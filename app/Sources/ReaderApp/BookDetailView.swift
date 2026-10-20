import SwiftUI
import LibraryCore
import UniformTypeIdentifiers

struct BookDetailView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let book: Book
    @State private var reading = false
    @State private var showSource = false
    @State private var showChapters = false
    @State private var showNotebook = false
    @State private var importing = false
    @State private var uploading = false
    @State private var editing = false
    @State private var confirmingDelete = false
    @State private var deleting = false
    @State private var failure: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 40) { cover; introduction }
                    VStack(alignment: .leading, spacing: 24) { cover.frame(maxWidth: .infinity); introduction }
                }
                HStack {
                    if book.source != nil { Button("Read source PDF", systemImage: "doc.richtext") { showSource = true } }
                    if !(book.chapters ?? []).isEmpty { Button("Read full book", systemImage: "book.pages") { showChapters = true } }
                    Button("Notes & highlights", systemImage: "note.text") { showNotebook = true }
                }.buttonStyle(.bordered)
                Button(uploading ? "Uploading PDF…" : book.source == nil ? "Attach source PDF" : "Replace source PDF", systemImage: "paperclip") { importing = true }.disabled(uploading)
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text("What’s inside").font(.system(.title2, design: .serif, weight: .semibold))
                    Text(book.synopsis).font(.body).lineSpacing(6).textSelection(.enabled)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text("The ideas").font(.system(.title2, design: .serif, weight: .semibold)).padding(.bottom, 14)
                    ForEach(Array(book.sections.enumerated()), id: \.offset) { i, section in
                        Button {
                            store.update(book) { $0.section = i; $0.completed = false }
                            reading = true
                        } label: {
                            HStack(spacing: 16) {
                                Text(String(format: "%02d", i+1)).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                                Text(section.title).font(.body.weight(.medium)).multilineTextAlignment(.leading)
                                Spacer()
                                if store.state(book).bookmarks.contains(i) { Image(systemName: "bookmark.fill") }
                                Image(systemName: "arrow.right").font(.caption)
                            }.padding(.vertical, 16).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Divider()
                    }
                }
                Text("Manually curated · \(book.sections.count) key ideas").font(.caption).foregroundStyle(.secondary)
                if let failure { Text(failure).font(.callout).foregroundStyle(.red) }
            }.padding(28).frame(maxWidth: 850).frame(maxWidth: .infinity)
        }
        .background(Color.paper)
        .navigationTitle(book.title)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Edit", systemImage: "pencil") { editing = true }
                Button("Delete", systemImage: "trash", role: .destructive) { confirmingDelete = true }.disabled(deleting)
            }
        }
        .readerPresentation(isPresented: $reading) { ReaderView(book: book).environment(store) }
        .readerPresentation(isPresented: $showSource) { SourceReader(book: book).environment(store) }
        .readerPresentation(isPresented: $showChapters) { ReaderView(book: book, location: .chapter).environment(store) }
        .sheet(isPresented: $showNotebook) { NavigationStack { NotebookView(bookID: book.id).toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { showNotebook = false } } } }.environment(store) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf]) { result in
            switch result {
            case .success(let url): uploading = true; Task { do { try await store.uploadPDF(book: book, url: url) } catch { failure = error.localizedDescription }; uploading = false }
            case .failure(let error): failure = error.localizedDescription
            }
        }
        .sheet(isPresented: $editing) { BookEditor(book: book).environment(store) }
        .confirmationDialog("Delete “\(book.title)” from the server?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete book", role: .destructive) {
                deleting = true
                Task {
                    do { try await store.delete(book); dismiss() }
                    catch { failure = error.localizedDescription }
                    deleting = false
                }
            }
        } message: { Text("This removes the book for every device when it next refreshes. This cannot be undone.") }
    }
    private var cover: some View { BookCover(book: book).frame(width: 200).shadow(color: .black.opacity(0.08), radius: 12, y: 8) }
    private var introduction: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text(book.category.uppercased()).font(.caption.weight(.semibold)).tracking(2).foregroundStyle(.secondary)
            Text(book.title).font(.system(size: 36, weight: .semibold, design: .serif)).foregroundStyle(Color.ink)
            Text(book.subtitle).font(.title3).foregroundStyle(.secondary)
            Text("By \(book.author)").font(.subheadline)
            Label("\(book.minutes) min · \(book.sections.count) ideas", systemImage: "clock").font(.subheadline).foregroundStyle(.secondary)
            if store.state(book).completed { Label("Finished", systemImage: "checkmark.circle.fill").foregroundStyle(Color.ink) }
            HStack {
                Button {
                    if store.state(book).completed { store.update(book) { $0.section = 0; $0.completed = false } }
                    reading = true
                } label: { Label(store.state(book).completed ? "Read again" : store.state(book).lastReadAt != nil ? "Continue reading" : "Start reading", systemImage: "book") }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                Button {
                    store.update(book) { $0.saved.toggle() }
                } label: { Image(systemName: store.state(book).saved ? "bookmark.fill" : "bookmark") }
                    .buttonStyle(.bordered).controlSize(.large)
                    .accessibilityLabel(store.state(book).saved ? "Remove from my library" : "Save to my library")
            }.padding(.top, 6)
        }.frame(minWidth: 220, maxWidth: .infinity, alignment: .leading)
    }
}

struct ReaderView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.closeReader) private var closeReader
    @Environment(\.toggleReaderFullScreen) private var toggleFullScreen
    @AppStorage("readerFontSize") private var fontSize: Double = 21
    @AppStorage("readerTheme") private var theme = "System"
    @AppStorage("readerWidePage") private var widePage = false
    @AppStorage("readerTwoPages") private var twoPages = false
    let book: Book
    var location: ReadingLocation = .summary
    var initialSection: Int? = nil
    @Environment(\.scenePhase) private var scenePhase
    @State private var editingAnnotation: ReaderRecord?
    @State private var showNotebook = false
    @State private var showSource = false
    @State private var contentsQuery = ""
    @State private var clock = ReadingClock()
    private var sections: [LibraryCore.Section] { location == .chapter ? book.chapters ?? [] : book.sections }
    private var state: ReadingState { store.state(book, location: location) }
    @State private var showContents = false
    @State private var showAppearance = false
    @State private var controlsVisible = true
    private var index: Int { min(max(state.section, 0), max(sections.count-1, 0)) }
    private var scheme: ColorScheme? { (theme == "Light" || theme == "Sepia") ? .light : theme == "Dark" ? .dark : nil }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if controlsVisible {
                    HStack(spacing: 18) {
                        Text(location == .chapter ? "FULL BOOK" : "KEY IDEAS").font(.caption2.weight(.semibold)).tracking(1).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Menu {
                            Button("Contents & search", systemImage: "magnifyingglass") { showContents = true }
                            Button("Notes & highlights", systemImage: "note.text") { showNotebook = true }
                            if book.source != nil { Button("Open source PDF", systemImage: "doc.richtext") { showSource = true } }
                        } label: { Image(systemName: "list.bullet") }.accessibilityLabel("Contents, search, and notebook")
                        Button("Add note", systemImage: "note.text.badge.plus") { annotate(quote: "", range: NSRange(location: 0, length: 0), withNote: true) }
                        Button("Appearance", systemImage: "textformat.size") { showAppearance = true }
                        Button {
                            store.update(book, location: location) { if $0.bookmarks.contains(index) { $0.bookmarks.remove(index) } else { $0.bookmarks.insert(index) } }
                        } label: { Image(systemName: state.bookmarks.contains(index) ? "bookmark.fill" : "bookmark") }
                            .accessibilityLabel(state.bookmarks.contains(index) ? "Remove section bookmark" : "Bookmark this section")
                    }.labelStyle(.iconOnly).buttonStyle(.borderless).padding(.horizontal, 24).padding(.vertical, 15)
                    ProgressView(value: state.progress(sectionCount: sections.count)).tint(Color.ink).accessibilityLabel("Reading progress")
                }
                GeometryReader { geometry in
                    if sections.indices.contains(index) {
                        if twoPages && geometry.size.width >= 700 {
                            VStack(alignment: .leading, spacing: 20) {
                                Text("\(location == .chapter ? "CHAPTER" : "IDEA") \(index+1) OF \(sections.count)").font(.caption.weight(.semibold)).tracking(2).foregroundStyle(.secondary)
                                Text(sections[index].title).font(.system(size: 28, weight: .medium, design: .serif)).foregroundStyle(Color.ink)
                                TwoPageText(text: sections[index].body, fontSize: min(max(fontSize, 16), 32), highlights: store.annotations(bookID: book.id, location: location, section: index)) { quote, range, note in
                                    annotate(quote: quote, range: range, withNote: note)
                                }.id(index)
                                if book.source != nil, let page = sections[index].sourcePage, page > 0 {
                                    Button("Read the source · page \(page)", systemImage: "doc.richtext") { showSource = true }
                                }
                            }.padding(.horizontal, 28).padding(.top, 20).padding(.bottom, 8)
                                .frame(maxWidth: widePage ? 1500 : 1200).frame(maxWidth: .infinity)
                        } else {
                            ScrollViewReader { proxy in
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 24) {
                                        Color.clear.frame(height: 1).id("top")
                                        Text("\(location == .chapter ? "CHAPTER" : "IDEA") \(index+1) OF \(sections.count)").font(.caption.weight(.semibold)).tracking(2).foregroundStyle(.secondary)
                                        Text(sections[index].title).font(.system(size: 34, weight: .medium, design: .serif)).foregroundStyle(Color.ink)
                                        SelectionText(text: sections[index].body, fontSize: min(max(fontSize, 16), 32), highlights: store.annotations(bookID: book.id, location: location, section: index)) { quote, range, note in
                                            annotate(quote: quote, range: range, withNote: note)
                                        }
                                        if book.source != nil, let page = sections[index].sourcePage, page > 0 {
                                            Button("Read the source · page \(page)", systemImage: "doc.richtext") { showSource = true }.buttonStyle(.bordered)
                                        }
                                        let annotations = store.annotations(bookID: book.id, location: location, section: index)
                                        if controlsVisible && !annotations.isEmpty {
                                            VStack(alignment: .leading, spacing: 12) {
                                                Text("Your annotations").font(.headline)
                                                ForEach(annotations) { record in
                                                    Button { editingAnnotation = record } label: {
                                                        VStack(alignment: .leading, spacing: 5) {
                                                            if !record.quote.isEmpty { Label(record.quote, systemImage: "highlighter").lineLimit(2) }
                                                            if !record.text.isEmpty { Text(record.text).lineLimit(3) }
                                                        }.font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding(12).background(Color.leaf, in: RoundedRectangle(cornerRadius: 10))
                                                    }.buttonStyle(.plain)
                                                }
                                            }
                                        }
                                        if state.completed {
                                            VStack(alignment: .leading, spacing: 10) {
                                                Label("An idea to take with you", systemImage: "checkmark.circle.fill").font(.headline)
                                                Text("You’ve finished this read. What’s one small thing you’ll try today?")
                                            }.padding(24).frame(maxWidth: .infinity, alignment: .leading).background(Color.leaf, in: RoundedRectangle(cornerRadius: 16))
                                        }
                                    }.padding(.horizontal, 28).padding(.bottom, 40).frame(maxWidth: widePage ? 900 : 690).frame(maxWidth: .infinity)
                                }.frame(width: geometry.size.width, height: geometry.size.height)
                                    .onChange(of: index) { _, _ in proxy.scrollTo("top", anchor: .top) }
                            }
                        }
                    } else { ContentUnavailableView("No reading sections", systemImage: "book.closed") }
                }
                if controlsVisible { ReadingTimerStatus(clock: clock) }
                Divider()
                HStack {
                    Button { move(-1) } label: { Label(twoPages ? "Previous section" : "Previous", systemImage: "arrow.left") }.disabled(index == 0)
                    Spacer()
                    Text(sections.isEmpty ? "0 / 0" : "\(index + 1) / \(sections.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        if index == sections.count - 1 {
                            if state.completed { close() }
                            else { store.update(book, location: location) { $0.completed = true } }
                        } else { move(1) }
                    } label: { Label(index == sections.count - 1 ? (state.completed ? "Done" : "Finish") : (twoPages ? "Next section" : "Next"), systemImage: "arrow.right") }
                    .buttonStyle(.borderedProminent).disabled(sections.isEmpty)
                }.padding(.horizontal, 24).padding(.vertical, controlsVisible ? 20 : 10).frame(maxWidth: 750)
            }
            .background(theme == "Sepia" ? Color(hex: "F4ECD8") : Color.paper)
            .navigationTitle(controlsVisible ? book.title : "")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button(controlsVisible ? "Hide reading controls" : "Show reading controls", systemImage: controlsVisible ? "eye.slash" : "eye") {
                        withAnimation(.easeInOut(duration: 0.2)) { controlsVisible.toggle() }
                    }
                    #if os(macOS)
                    Button("Toggle full screen", systemImage: "arrow.up.left.and.arrow.down.right") { toggleFullScreen?() }
                        .keyboardShortcut("f", modifiers: [.command, .control])
                    #endif
                }
                ToolbarItem(placement: .cancellationAction) { Button("Close", systemImage: "xmark") { close() }
                    .keyboardShortcut("w", modifiers: .command) }
            }
            .sheet(isPresented: $showContents) {
                NavigationStack {
                    List(Array(sections.enumerated()).filter { contentsQuery.isEmpty || ($0.element.title + " " + $0.element.body).localizedCaseInsensitiveContains(contentsQuery) }, id: \.offset) { i, section in
                        Button { store.update(book, location: location) { $0.section = i; $0.completed = false }; showContents = false } label: {
                            HStack { Text("\(i+1). \(section.title)"); Spacer(); if state.bookmarks.contains(i) { Image(systemName: "bookmark.fill") }; if i == index { Image(systemName: "checkmark") } }
                        }
                    }.navigationTitle("Contents & search").searchable(text: $contentsQuery, prompt: "Search this book")
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showContents = false } } }
                }.frame(minWidth: 300, minHeight: 350)
            }
            .sheet(item: $editingAnnotation) { record in AnnotationEditor(record: record).environment(store) }
            .sheet(isPresented: $showNotebook) { NavigationStack { NotebookView(bookID: book.id).toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { showNotebook = false } } } }.environment(store) }
            .readerPresentation(isPresented: $showSource) { SourceReader(book: book, initialPage: sections.indices.contains(index) ? sections[index].sourcePage.map { $0 - 1 } : nil).environment(store) }
            .popover(isPresented: $showAppearance) {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Reading appearance").font(.headline)
                    Picker("Page layout", selection: $twoPages) {
                        Text("Single page").tag(false)
                        Text("Two pages").tag(true)
                    }.pickerStyle(.segmented)
                    if twoPages { Text("Two pages appear side by side in a wide window or landscape iPad. Narrow screens use a single page.").font(.caption).foregroundStyle(.secondary) }
                    Toggle("Wide reading page", isOn: $widePage)
                    Slider(value: $fontSize, in: 16...32, step: 1) { Text("Text size") }
                    Text("Text size: \(Int(fontSize))").font(.caption)
                    Picker("Theme", selection: $theme) { Text("System").tag("System"); Text("Light").tag("Light"); Text("Sepia").tag("Sepia"); Text("Dark").tag("Dark") }.pickerStyle(.segmented)
                }.padding(24).frame(width: 290).presentationCompactAdaptation(.popover)
            }
        }
        #if os(iOS)
        .statusBarHidden(!controlsVisible)
        #endif
        .preferredColorScheme(scheme)
        .frame(minWidth: 320, idealWidth: 780, idealHeight: 800)
        #if os(macOS)
        .frame(minWidth: 640, minHeight: 600)
        #endif
        .onAppear { store.update(book, location: location) { if let initialSection { $0.section = initialSection }; $0.lastReadAt = Date() } }
        .simultaneousGesture(TapGesture().onEnded { clock.touch() })
        .simultaneousGesture(DragGesture(minimumDistance: 1).onChanged { _ in clock.touch() })
        .onChange(of: index) { _, _ in clock.touch() }
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
                clock.tick(store: store, book: book, location: location, active: scenePhase == .active && editingAnnotation == nil && !showNotebook && !showSource && !showContents)
            }
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { clock.flush(store: store, book: book, location: location) } }
        .onDisappear { clock.flush(store: store, book: book, location: location) }
    }
    private func close() { if let closeReader { closeReader() } else { dismiss() } }
    private func annotate(quote: String, range: NSRange, withNote: Bool) {
        guard withNote || !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var record = ReaderRecord(id: "annotation:" + UUID().uuidString.lowercased(), kind: "annotation", bookID: book.id, bookTitle: book.title)
        record.location = location.rawValue; record.section = index; record.quote = quote; record.offset = range.location; record.length = range.length
        if withNote { editingAnnotation = record } else { store.put(record) }
        clock.touch()
    }
    private func move(_ delta: Int) { store.update(book, location: location) { $0.section = min(max(index + delta, 0), sections.count - 1); $0.completed = false } }
}
