import SwiftUI
import LibraryCore

/// Counts foreground reader time, pausing after two minutes without interaction.
@MainActor @Observable final class ReadingClock {
    var lastInteraction = Date()
    var seconds = 0
    var day = Date()
    var paused: Bool { Date().timeIntervalSince(lastInteraction) > 120 }
    func touch() { lastInteraction = Date() }
    func tick(store: LibraryStore, book: Book, location: ReadingLocation, active: Bool) {
        guard active else { return }
        if Habits.dayKey(day) != Habits.dayKey(Date()) { flush(store: store, book: book, location: location); day = Date() }
        guard !paused else { return }
        seconds += 1
        if seconds >= 60 { flush(store: store, book: book, location: location) }
    }
    func flush(store: LibraryStore, book: Book, location: ReadingLocation) {
        store.recordSession(book: book, location: location, seconds: seconds, day: day); seconds = 0; day = Date()
    }
}

struct ReadingTimerStatus: View {
    let clock: ReadingClock
    var body: some View {
        VStack(spacing: 4) {
            Text("This session: \(clock.seconds)s toward your daily goal").font(.caption2).foregroundStyle(.secondary)
            if clock.paused { Button("Reading timer paused — resume") { clock.touch() }.font(.caption) }
        }.padding(4)
    }
}
