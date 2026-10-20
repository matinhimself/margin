import SwiftUI
import LibraryCore

struct BookEditor: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var book: Book
    @State private var saving = false
    @State private var failure: String?
    @State private var confirmCancel = false
    @State private var original: Book?
    @State private var contentMode = "Summary"
    private var content: Binding<[LibraryCore.Section]> {
        contentMode == "Summary" ? $book.sections : Binding(get: { book.chapters ?? [] }, set: { book.chapters = $0.isEmpty ? nil : $0 })
    }
    private let colors = ["#DCE9C9", "#F0D5B8", "#CBDCE8", "#E7CFD4", "#E8DFB8", "#CDCDE5"]
    var body: some View {
        NavigationStack {
            Form {
                SwiftUI.Section("The book") {
                    TextField("Title", text: $book.title)
                    TextField("Author", text: $book.author)
                    TextField("Subtitle", text: $book.subtitle)
                    TextField("Topic", text: $book.category)
                    Stepper("\(book.minutes) minute read", value: $book.minutes, in: 1...999)
                    Picker("Cover color", selection: $book.color) {
                        ForEach(Array(colors.enumerated()), id: \.element) { i, color in Text(["Sage", "Apricot", "Sky", "Rose", "Sand", "Lavender"][i]).tag(color) }
                        if !colors.contains(book.color) { Text("Custom").tag(book.color) }
                    }
                }
                SwiftUI.Section("What will the reader learn?") {
                    TextEditor(text: $book.synopsis).frame(minHeight: 90).accessibilityLabel("Synopsis")
                }
                SwiftUI.Section("Reading content") {
                    Picker("Content", selection: $contentMode) { Text("Summary ideas").tag("Summary"); Text("Full-book chapters").tag("Full book") }.pickerStyle(.segmented)
                    Text("Full-book chapters are optional and are kept alongside the summary. Attach a source PDF from the book details screen.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(content.wrappedValue.indices, id: \.self) { i in
                    SwiftUI.Section {
                        TextField("Idea title", text: content[i].title)
                        TextEditor(text: content[i].body).frame(minHeight: 180).accessibilityLabel("Body for idea \(i+1)")
                        TextField("Source PDF page (optional)", text: Binding(get: { content.wrappedValue[i].sourcePage.map(String.init) ?? "" }, set: { content.wrappedValue[i].sourcePage = Int($0).flatMap { $0 > 0 ? $0 : nil } }))
                        HStack {
                            Button("Move up", systemImage: "arrow.up") { content.wrappedValue.swapAt(i, i-1) }.disabled(i == 0)
                            Button("Move down", systemImage: "arrow.down") { content.wrappedValue.swapAt(i, i+1) }.disabled(i == content.wrappedValue.count-1)
                            Spacer()
                            Button("Remove", role: .destructive) { content.wrappedValue.remove(at: i) }.disabled(contentMode == "Summary" && content.wrappedValue.count == 1)
                        }.buttonStyle(.borderless)
                    } header: { Text("\(contentMode == "Summary" ? "Idea" : "Chapter") \(i+1)") }
                }
                SwiftUI.Section {
                    Button(contentMode == "Summary" ? "Add an idea" : "Add a chapter", systemImage: "plus") { content.wrappedValue.append(LibraryCore.Section()) }.disabled(content.wrappedValue.count >= (contentMode == "Summary" ? 100 : 1000))
                    Text("Write each idea by hand. Plain text paragraphs are supported. Publishing makes the book available to every connected device.").font(.caption).foregroundStyle(.secondary)
                    if let failure { Text(failure).foregroundStyle(.red) }
                }
            }.formStyle(.grouped)
                .navigationTitle(original?.title.isEmpty == false ? "Edit book" : "New book")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { if original != book { confirmCancel = true } else { dismiss() } }.disabled(saving)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(saving ? "Publishing…" : "Publish") {
                            saving = true; failure = nil
                            Task {
                                do { try await store.save(book); dismiss() }
                                catch { failure = error.localizedDescription }
                                saving = false
                            }
                        }.disabled(saving || !book.isValid)
                    }
                }
                .disabled(saving)
        }
        .frame(minWidth: 320, idealWidth: 680, minHeight: 500, idealHeight: 780)
        .onAppear { if original == nil { original = book } }
        .interactiveDismissDisabled(original != book)
        .confirmationDialog("Discard your changes?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Discard changes", role: .destructive) { dismiss() }
        }
    }
}
