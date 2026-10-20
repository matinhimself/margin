import SwiftUI
import LibraryCore

struct HabitView: View {
    @Environment(LibraryStore.self) private var store
    @State private var now = Date()
    private var days: [HabitDay] { Habits.days(records: store.sessions, now: now) }
    private var today: Int { days.last?.seconds ?? 0 }
    private var streak: Int { Habits.streak(days: Habits.days(records: store.sessions, now: now, count: 3660), goal: store.goalSeconds) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Text("A little, every day.").font(.system(.largeTitle, design: .serif, weight: .medium)).foregroundStyle(Color.ink)
                Text("Time spent reading, with room to build a rhythm.").foregroundStyle(.secondary)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 18) { todayCard; streakCard }
                    VStack(spacing: 18) { todayCard; streakCard }
                }
                Stepper("Daily goal: \(store.goalSeconds / 60) minutes", value: Binding(get: { store.goalSeconds / 60 }, set: { store.setGoal(minutes: $0) }), in: 1...240).padding().background(Color.leaf, in: RoundedRectangle(cornerRadius: 14))
                Text("Last 30 days").font(.title2.bold())
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 14) {
                    ForEach(days) { day in
                        VStack(spacing: 6) {
                            Text(day.date.formatted(.dateTime.day())).font(.caption)
                            Circle().fill(day.seconds >= store.goalSeconds ? Color.ink : day.seconds > 0 ? Color.ink.opacity(0.35) : Color.leaf).frame(width: 28, height: 28)
                            Text("\(day.seconds / 60)m").font(.caption2).foregroundStyle(.secondary)
                        }.accessibilityElement(children: .ignore).accessibilityLabel("\(day.date.formatted(date: .abbreviated, time: .omitted)), \(day.seconds) seconds, \(day.seconds >= store.goalSeconds ? "goal reached" : "goal not reached")")
                    }
                }
                Text("Recent reading history").font(.title2.bold())
                if store.sessions.isEmpty { Text("Open a summary, chapter, or source PDF to start tracking. Your reading sessions appear here automatically.").foregroundStyle(.secondary) }
                ForEach(Array(store.sessions.prefix(50))) { session in
                    HStack(alignment: .top) {
                        Image(systemName: session.location == "pdf" ? "doc.richtext" : "book").foregroundStyle(Color.ink)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(session.bookTitle).font(.headline)
                            Text("\(session.day) · \(ReadingLocation(rawValue: session.location)?.label ?? "Reading")").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(session.seconds >= 60 ? "\(session.seconds / 60)m \(session.seconds % 60)s" : "\(session.seconds)s").font(.subheadline.monospacedDigit())
                    }.padding(.vertical, 6)
                    Divider()
                }
                Text("Time counts while a reader is visible in the foreground. It pauses after two minutes without interaction; scroll, tap, or use Resume to continue. Sessions save every minute and when you leave. Your goal and history sync to your other devices. Reading on two devices at the same time counts both sessions.").font(.caption).foregroundStyle(.secondary)
            }.padding(28).frame(maxWidth: 850).frame(maxWidth: .infinity)
        }.background(Color.paper).navigationTitle("Reading habits")
            .task { while !Task.isCancelled { now = Date(); do { try await Task.sleep(for: .seconds(15)) } catch { break } } }
    }
    private var todayCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("TODAY").font(.caption.weight(.semibold)).tracking(2)
            Text("\(today / 60) min \(today % 60) sec").font(.system(.title, design: .rounded, weight: .semibold))
            ProgressView(value: min(Double(today) / Double(store.goalSeconds), 1)).tint(Color.ink)
            Text(today >= store.goalSeconds ? "Daily goal reached" : "\(max(0, store.goalSeconds - today) / 60)m \(max(0, store.goalSeconds - today) % 60)s to your goal").font(.caption)
        }.padding(24).frame(maxWidth: .infinity, alignment: .leading).background(Color.leaf, in: RoundedRectangle(cornerRadius: 20))
    }
    private var streakCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("CURRENT STREAK", systemImage: "flame").font(.caption.weight(.semibold))
            Text("\(streak) \(streak == 1 ? "day" : "days")").font(.system(.title, design: .rounded, weight: .semibold))
            Text("Reach your daily goal to keep it growing. Today stays open until midnight.").font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(maxWidth: .infinity, alignment: .leading).background(Color.leaf, in: RoundedRectangle(cornerRadius: 20))
    }
}
