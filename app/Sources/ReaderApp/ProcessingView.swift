import SwiftUI
import LibraryCore
import UniformTypeIdentifiers

struct ProcessingView: View {
    @Environment(LibraryStore.self) private var store
    @State private var showUpload = false
    @State private var failure: String?
    private var active: [ProcessingJob] { store.jobs.filter(\.isActive) }
    private var recent: [ProcessingJob] { store.jobs.filter { !$0.isActive } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("A PLACE FOR WHAT’S NEXT").eyebrow()
                    Text("Good reads\nin the making.").font(.system(size: 36, weight: .medium, design: .serif)).foregroundStyle(Color.ink)
                    Text("From a little curiosity to your next favourite read.").font(.callout).foregroundStyle(.secondary)
                }
                Button { showUpload = true } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "doc.badge.plus").font(.title2).frame(width: 42, height: 48).background(Color.leaf, in: RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 4) { Text("Bring your own book").font(.subheadline.weight(.semibold)); Text("Add a PDF or EPUB from Files").font(.caption).foregroundStyle(.secondary) }
                        Spacer(); Image(systemName: "plus").font(.body)
                    }.padding(16).background(Color.surface, in: RoundedRectangle(cornerRadius: 18))
                }.buttonStyle(.plain)
                if let failure { Text(failure).font(.callout).foregroundStyle(.red) }
                if let error = store.processingError { Label(error, systemImage: "wifi.exclamationmark").font(.caption).foregroundStyle(.secondary) }
                if !active.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        sectionTitle("Taking shape", count: active.count)
                        ForEach(active) { job in jobCard(job) }
                    }
                }
                if !recent.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        sectionTitle("Recently added", count: recent.count)
                        ForEach(recent.prefix(30)) { job in jobCard(job) }
                    }
                }
                if store.jobs.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "book.closed").font(.system(size: 36, weight: .ultraLight)).foregroundStyle(Color.ink)
                        Text("Nothing in the making. Yet.").font(.system(.title2, design: .serif))
                        Text("Choose a book in Discover, or bring one of your own. We’ll take it from there.").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.frame(maxWidth: .infinity).padding(.vertical, 48)
                }
            }.padding(20).frame(maxWidth: 760).frame(maxWidth: .infinity)
        }.background(Color.paper)
        .sheet(isPresented: $showUpload) { BookUploadView().environment(store) }
        .task {
            await store.refreshProcessing()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { break }
                let wasActive = store.jobs.contains(where: \.isActive)
                await store.refreshProcessing()
                if wasActive { await store.refresh() }
            }
        }
    }
    private func sectionTitle(_ title: String, count: Int) -> some View {
        HStack { Text(title).font(.system(.title2, design: .serif, weight: .medium)); Spacer(); Text("\(count)").font(.caption).foregroundStyle(.secondary) }
    }
    private func title(_ job: ProcessingJob) -> String {
        if job.kind == "narration" { return store.books.first(where: { $0.id == job.bookID })?.title ?? "Book narration" }
        return store.books.first(where: { $0.id == job.bookID })?.title ?? job.displayTitle
    }
    private func jobCard(_ job: ProcessingJob) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                CatalogCover(title: title(job), author: job.author ?? "", cover: job.cover).frame(width: 56)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title(job)).font(.system(.headline, design: .serif)).lineLimit(3)
                    if let author = job.author, !author.isEmpty { Text(author).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    Text(job.kind == "narration" ? "Audio narration" : "\(job.summaryMinutes ?? 10)-minute read").font(.caption).foregroundStyle(.secondary)
                    Label(job.status == "complete" ? "Ready to read" : job.statusLabel, systemImage: job.status == "complete" ? "checkmark.circle.fill" : job.status == "failed" ? "exclamationmark.circle" : "clock").font(.caption.weight(.medium)).foregroundStyle(job.status == "failed" ? Color.red : Color.ink)
                }
                Spacer(minLength: 0)
            }
            if job.isActive {
                HStack(spacing: 5) {
                    ForEach(0..<3, id: \.self) { step in Capsule().fill(step <= (job.status == "summarizing" ? 2 : job.status == "extracting" ? 1 : 0) ? Color.ink : Color.leaf).frame(height: 3) }
                }
                if !job.progress.isEmpty { Text(job.progress).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
            }
            if !job.error.isEmpty { Text(job.error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Text(Date(timeIntervalSince1970: Double(job.createdAt)), style: .date).font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                if job.status == "complete", store.books.contains(where: { $0.id == job.bookID }) {
                    NavigationLink(value: job.bookID) { Label("Open read", systemImage: "arrow.up.right").font(.caption.weight(.semibold)) }
                }
                if job.status == "failed", job.kind != "narration" || store.isAdmin {
                    Button("Try again") { Task { do { try await store.retryJob(job) } catch { failure = error.localizedDescription } } }.font(.caption.weight(.medium))
                }
            }
        }.padding(18).background(Color.surface, in: RoundedRectangle(cornerRadius: 18))
            .overlay { RoundedRectangle(cornerRadius: 18).stroke(Color.line.opacity(0.6), lineWidth: 1) }
    }
}

private struct BookUploadView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var minutes = 10
    @State private var importing = false
    @State private var uploading = false
    @State private var failure: String?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Image(systemName: "doc.richtext").font(.system(size: 42, weight: .ultraLight)).foregroundStyle(Color.ink).padding(.top, 12)
                    Text("Your book.\nA little more distilled.").font(.system(size: 34, weight: .medium, design: .serif))
                    Text("Choose a PDF or EPUB, and we’ll make a focused read from its key ideas.").font(.callout).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 14) { Text("Make time for it").font(.system(.title3, design: .serif)); SummaryLengthPicker(minutes: $minutes) }
                    if let failure { Text(failure).font(.callout).foregroundStyle(.red) }
                }.padding(24).frame(maxWidth: 540).frame(maxWidth: .infinity)
            }.background(Color.paper)
            .navigationTitle("Add a book").marginInlineTitle()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(uploading) } }
            .safeAreaInset(edge: .bottom) {
                Button { importing = true } label: { HStack { if uploading { ProgressView().tint(Color.paper) }; Text(uploading ? "Adding your book…" : "Choose from Files"); Image(systemName: "arrow.up.right") }.font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).padding(18).foregroundStyle(Color.paper).background(Color.ink, in: RoundedRectangle(cornerRadius: 16)) }.buttonStyle(.plain).disabled(uploading).padding(20).background(Color.paper)
            }
        }.interactiveDismissDisabled(uploading)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf, UTType(filenameExtension: "epub") ?? UTType(importedAs: "org.idpf.epub-container")]) { result in
            switch result {
            case .success(let url):
                uploading = true; failure = nil
                Task { do { try await store.submitUpload(url: url, summaryMinutes: minutes); dismiss() } catch { failure = error.localizedDescription }; uploading = false }
            case .failure(let error): failure = error.localizedDescription
            }
        }
    }
}
