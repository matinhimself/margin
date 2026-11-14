import SwiftUI
import PDFKit
import LibraryCore

struct SourceReader: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.closeReader) private var closeReader
    @Environment(\.toggleReaderFullScreen) private var toggleFullScreen
    @Environment(\.scenePhase) private var scenePhase
    let book: Book
    var initialPage: Int? = nil
    @State private var document: PDFDocument?
    @State private var page = 0
    @State private var selection: PDFSelection?
    @State private var failure: String?
    @State private var query = ""
    @State private var results: [PDFSelection] = []
    @State private var resultIndex = 0
    @State private var editing: ReaderRecord?
    @State private var selectedHighlight: ReaderRecord?
    @State private var clock = ReadingClock()
    @State private var showNotebook = false
    @State private var controlsVisible = true
    @AppStorage("pdfContinuousReading") private var continuous = false
    @AppStorage("pdfTwoPages") private var twoPages = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let document {
                    if controlsVisible { controls(document) }
                    PDFCanvas(document: document, continuous: continuous, twoPages: twoPages, page: $page, selection: $selection, annotations: store.annotations(bookID: book.id, location: .pdf).filter { $0.sourceHash.isEmpty || $0.sourceHash == book.source?.sha256 }, onHighlightTap: { selectedHighlight = $0 })
                        .simultaneousGesture(TapGesture().onEnded { clock.touch() })
                        .simultaneousGesture(DragGesture(minimumDistance: 1).onChanged { _ in clock.touch() })
                    HStack {
                        Button("Previous", systemImage: "arrow.left") { page = max(0, twoPages ? (page / 2) * 2 - 2 : page - 1) }.disabled(twoPages ? page < 2 : page == 0)
                        Spacer()
                        Text(twoPages ? "Pages \((page / 2) * 2 + 1)–\(min((page / 2) * 2 + 2, document.pageCount)) of \(document.pageCount)" : "Page \(page + 1) of \(document.pageCount)").font(.caption.monospacedDigit())
                        Spacer()
                        Button("Next", systemImage: "arrow.right") { page = min(document.pageCount-1, twoPages ? (page / 2) * 2 + 2 : page + 1) }.disabled(twoPages ? (page / 2) * 2 + 2 >= document.pageCount : page >= document.pageCount-1)
                    }.padding()
                } else if let failure {
                    ContentUnavailableView("Cannot open the source", systemImage: "doc", description: Text(failure))
                    Button("Try again") { Task { await load() } }.padding()
                } else { ProgressView("Opening source PDF…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
            .background(Color.paper).navigationTitle(controlsVisible ? book.title : "")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { if let closeReader { closeReader() } else { dismiss() } }
                        .keyboardShortcut("w", modifiers: .command)
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button(controlsVisible ? "Hide reading controls" : "Show reading controls", systemImage: controlsVisible ? "eye.slash" : "eye") { controlsVisible.toggle() }
                    Menu("Page layout", systemImage: "book.pages") {
                        Picker("Pages", selection: $twoPages) {
                            Text("Single page").tag(false)
                            Text("Two pages").tag(true)
                        }
                        Picker("Scrolling", selection: $continuous) {
                            Text("Page by page").tag(false)
                            Text("Continuous scroll").tag(true)
                        }
                    }
                    #if os(macOS)
                    Button("Toggle full screen", systemImage: "arrow.up.left.and.arrow.down.right") { toggleFullScreen?() }
                        .keyboardShortcut("f", modifiers: [.command, .control])
                    #endif
                }
            }
            .searchable(text: $query, prompt: "Search this PDF")
            .task { await load() }
            .task(id: query) {
                do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
                results = query.isEmpty ? [] : document?.findString(query, withOptions: .caseInsensitive) ?? []
                resultIndex = 0; if !results.isEmpty { showResult() }
            }
            .sheet(item: $editing) { record in AnnotationEditor(record: record).environment(store) }
            .popover(item: $selectedHighlight) { record in
                HighlightSelectionMenu(record: record) { editing = $0 }
                    .environment(store)
            }
            .sheet(isPresented: $showNotebook) { NavigationStack { NotebookView(bookID: book.id).toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { showNotebook = false } } } }.environment(store) }
        }
        #if os(iOS)
        .statusBarHidden(!controlsVisible)
        #endif
        .frame(minWidth: 320, idealWidth: 900, idealHeight: 800)
        #if os(macOS)
        .frame(minWidth: 650, minHeight: 600)
        #endif
        .onChange(of: page) { _, _ in
            clock.touch(); store.update(book, location: .pdf) { $0.section = page; $0.lastReadAt = Date() }
        }
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
                clock.tick(store: store, book: book, location: .pdf, active: scenePhase == .active && document != nil && editing == nil && !showNotebook)
            }
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { clock.flush(store: store, book: book, location: .pdf) } }
        .onDisappear { clock.flush(store: store, book: book, location: .pdf) }
    }
    private func controls(_ document: PDFDocument) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 16) {
                Button("Highlight selection", systemImage: "highlighter") { annotate(withNote: false) }.disabled(selection?.string?.isEmpty != false)
                Button("Add note", systemImage: "note.text.badge.plus") { annotate(withNote: true) }
                Button("Notebook", systemImage: "note.text") { showNotebook = true }
                Spacer()
                Button {
                    store.update(book, location: .pdf) { if $0.bookmarks.contains(page) { $0.bookmarks.remove(page) } else { $0.bookmarks.insert(page) } }
                } label: { Image(systemName: store.state(book, location: .pdf).bookmarks.contains(page) ? "bookmark.fill" : "bookmark") }.accessibilityLabel("Bookmark source page")
                Menu("Bookmarks", systemImage: "list.bullet") {
                    ForEach(store.state(book, location: .pdf).bookmarks.sorted(), id: \.self) { index in Button("Page \(index+1)") { page = min(index, document.pageCount-1) } }
                }
            }.labelStyle(.iconOnly)
            if !query.isEmpty {
                HStack {
                    Text(results.isEmpty ? "No matches (scanned PDFs may need OCR)" : "Match \(resultIndex+1) of \(results.count)").font(.caption)
                    Spacer()
                    Button("Previous match", systemImage: "chevron.up") { resultIndex = (resultIndex + results.count - 1) % results.count; showResult() }.disabled(results.isEmpty)
                    Button("Next match", systemImage: "chevron.down") { resultIndex = (resultIndex+1) % results.count; showResult() }.disabled(results.isEmpty)
                }
            }
            ReadingTimerStatus(clock: clock)
        }.padding(.horizontal).padding(.vertical, 10)
    }
    private func load() async {
        failure = nil
        do {
            let url = try await store.sourceURL(book: book)
            guard let doc = PDFDocument(url: url), !doc.isLocked, doc.pageCount > 0 else { throw APIError.response(422, "This PDF is unreadable or password protected") }
            document = doc; page = min(max(initialPage ?? store.state(book, location: .pdf).section, 0), doc.pageCount-1)
            store.update(book, location: .pdf) { $0.section = page; $0.lastReadAt = Date() }
        } catch { failure = error.localizedDescription }
    }
    private func showResult() {
        guard results.indices.contains(resultIndex), let document, let first = results[resultIndex].pages.first else { return }
        page = document.index(for: first); selection = results[resultIndex]; clock.touch()
    }
    private func annotate(withNote: Bool) {
        var record = ReaderRecord(id: "annotation:" + UUID().uuidString.lowercased(), kind: "annotation", bookID: book.id, bookTitle: book.title)
        record.location = "pdf"; record.section = page
        record.sourceHash = book.source?.sha256 ?? ""
        if let selectedPage = selection?.pages.first, let document { record.section = document.index(for: selectedPage) }
        record.quote = selection?.string ?? ""; record.length = (record.quote as NSString).length
        if withNote { editing = record } else if !record.quote.isEmpty { store.put(record) }
        clock.touch()
    }
}

private final class PDFCoordinator: NSObject {
    var highlightTapped: ((ReaderRecord) -> Void)?
    var pageChanged: ((Int) -> Void)?
    var selectionChanged: ((PDFSelection?) -> Void)?
    var observers: [NSObjectProtocol] = []
    var renderedAnnotations: [ReaderRecord] = []
    weak var renderedDocument: PDFDocument?
    func needsRedraw(document: PDFDocument, annotations: [ReaderRecord]) -> Bool {
        guard renderedDocument !== document || renderedAnnotations != annotations else { return false }
        renderedDocument = document; renderedAnnotations = annotations; return true
    }
    func attach(_ view: PDFView) {
        #if os(macOS)
        view.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(tapHighlight(_:))))
        #else
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapHighlight(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        view.addGestureRecognizer(tap)
        #endif
        observers.append(NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak self, weak view] _ in
            guard let view, let document = view.document, let page = view.currentPage else { return }
            self?.pageChanged?(document.index(for: page))
        })
        observers.append(NotificationCenter.default.addObserver(forName: .PDFViewSelectionChanged, object: view, queue: .main) { [weak self, weak view] _ in self?.selectionChanged?(view?.currentSelection) })
    }
    private func openHighlight(at point: CGPoint, in view: PDFView) {
        guard let page = view.page(for: point, nearest: false) else { return }
        let location = view.convert(point, to: page)
        guard let annotation = page.annotations.reversed().first(where: {
            $0.userName == "Margin" && $0.bounds.contains(location)
        }), let id = annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "MarginRecordID")) as? String,
              let record = renderedAnnotations.first(where: { $0.id == id }) else { return }
        highlightTapped?(record)
    }
    #if os(macOS)
    @objc private func tapHighlight(_ gesture: NSClickGestureRecognizer) {
        guard let view = gesture.view as? PDFView else { return }
        openHighlight(at: gesture.location(in: view), in: view)
    }
    #else
    @objc private func tapHighlight(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, let view = gesture.view as? PDFView else { return }
        openHighlight(at: gesture.location(in: view), in: view)
    }
    #endif
    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }
}

private func updatePDF(_ view: PDFView, document: PDFDocument, page: Int, selection: PDFSelection?, annotations: [ReaderRecord], redraw: Bool) {
    if view.document !== document { view.document = document }
    if let target = document.page(at: page), view.currentPage !== target { view.go(to: target) }
    if let selection, let selectedPage = selection.pages.first {
        let current = view.currentSelection
        if current?.string != selection.string || current?.pages.first !== selectedPage || current?.bounds(for: selectedPage) != selection.bounds(for: selectedPage) {
            view.setCurrentSelection(selection, animate: false)
        }
    }
    guard redraw else { return }
    // Recreate only Margin's overlays, leaving the original document untouched on disk.
    for index in 0..<document.pageCount {
        guard let pdfPage = document.page(at: index) else { continue }
        for annotation in pdfPage.annotations where annotation.userName == "Margin" { pdfPage.removeAnnotation(annotation) }
        for record in annotations where record.section == index && !record.quote.isEmpty {
            let range = ((pdfPage.string ?? "") as NSString).range(of: record.quote)
            guard range.location != NSNotFound, let selection = pdfPage.selection(for: range) else { continue }
            for line in selection.selectionsByLine() {
                let annotation = PDFAnnotation(bounds: line.bounds(for: pdfPage), forType: .highlight, withProperties: nil)
                annotation.userName = "Margin"; annotation.contents = record.text
                annotation.setValue(record.id, forAnnotationKey: PDFAnnotationKey(rawValue: "MarginRecordID"))
                annotation.color = (record.color == "green" ? PlatformColor.systemGreen : record.color == "pink" ? PlatformColor.systemPink : PlatformColor.systemYellow).withAlphaComponent(0.35)
                pdfPage.addAnnotation(annotation)
            }
        }
    }
}

#if os(macOS)
private struct PDFCanvas: NSViewRepresentable {
    let document: PDFDocument
    let continuous: Bool
    let twoPages: Bool
    @Binding var page: Int
    @Binding var selection: PDFSelection?
    let annotations: [ReaderRecord]
    let onHighlightTap: (ReaderRecord) -> Void
    func makeCoordinator() -> PDFCoordinator { PDFCoordinator() }
    func makeNSView(context: Context) -> PDFView { let view = PDFView(); view.autoScales = true; view.displayMode = .singlePageContinuous; context.coordinator.attach(view); return view }
    func updateNSView(_ view: PDFView, context: Context) {
        let displayMode: PDFDisplayMode = twoPages ? (continuous ? .twoUpContinuous : .twoUp) : (continuous ? .singlePageContinuous : .singlePage)
        view.displaysAsBook = false
        if view.displayMode != displayMode { view.displayMode = displayMode; view.autoScales = true }
        context.coordinator.highlightTapped = onHighlightTap
        context.coordinator.pageChanged = { value in if page != value { DispatchQueue.main.async { page = value } } }
        context.coordinator.selectionChanged = { value in DispatchQueue.main.async { selection = value } }
        updatePDF(view, document: document, page: page, selection: selection, annotations: annotations, redraw: context.coordinator.needsRedraw(document: document, annotations: annotations))
    }
}
#else
private struct PDFCanvas: UIViewRepresentable {
    let document: PDFDocument
    let continuous: Bool
    let twoPages: Bool
    @Binding var page: Int
    @Binding var selection: PDFSelection?
    let annotations: [ReaderRecord]
    let onHighlightTap: (ReaderRecord) -> Void
    func makeCoordinator() -> PDFCoordinator { PDFCoordinator() }
    func makeUIView(context: Context) -> PDFView { let view = PDFView(); view.autoScales = true; view.displayMode = .singlePageContinuous; context.coordinator.attach(view); return view }
    func updateUIView(_ view: PDFView, context: Context) {
        let displayMode: PDFDisplayMode = twoPages ? (continuous ? .twoUpContinuous : .twoUp) : (continuous ? .singlePageContinuous : .singlePage)
        view.displaysAsBook = false
        if view.displayMode != displayMode { view.displayMode = displayMode; view.autoScales = true }
        context.coordinator.highlightTapped = onHighlightTap
        context.coordinator.pageChanged = { value in if page != value { DispatchQueue.main.async { page = value } } }
        context.coordinator.selectionChanged = { value in DispatchQueue.main.async { selection = value } }
        updatePDF(view, document: document, page: page, selection: selection, annotations: annotations, redraw: context.coordinator.needsRedraw(document: document, annotations: annotations))
    }
}
#endif

#if os(iOS)
extension PDFCoordinator: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
}
#endif
