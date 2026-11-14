import SwiftUI

@main struct MarginApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(MarginApplicationDelegate.self) private var applicationDelegate
    #endif
    @State private var store = LibraryStore()
    var body: some Scene {
        WindowGroup {
            LibraryView().environment(store)
                .safeAreaInset(edge: .bottom) {
                    if !store.narration.key.isEmpty { NarrationMiniPlayer(player: store.narration) }
                }
                .tint(Color.ink)
                .frame(minWidth: 320, minHeight: 500)
        }
        #if os(macOS)
        .defaultSize(width: 1180, height: 820)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Refresh Library") { Task { await store.refresh() } }.keyboardShortcut("r")
            }
        }
        #endif
    }
}

#if os(macOS)
final class MarginApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Development builds keep the same bundle URL; load the current icon
        // directly instead of relying on the launcher's cached representation.
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let icon = NSImage(contentsOf: url) else { return }
        NSApp.applicationIconImage = icon
    }
}
#endif

extension Color {
    static let surface = Color(light: 0xFFFFFF, dark: 0x242B26)
    static let line = Color(light: 0xE5E7DD, dark: 0x374139)
    static let forest = Color(hex: "#193E32")
    static let paper = Color(light: 0xFAF9F5, dark: 0x191D1B)
    static let ink = Color(light: 0x193E32, dark: 0xDCEBD1)
    static let leaf = Color(light: 0xE7EDDF, dark: 0x2C382E)
    init(hex: String) {
        let n = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0xDCE9C9
        self.init(.sRGB, red: Double((n >> 16) & 255)/255, green: Double((n >> 8) & 255)/255, blue: Double(n & 255)/255, opacity: 1)
    }
    init(light: UInt32, dark: UInt32) {
        #if os(macOS)
        self.init(nsColor: NSColor(name: nil) { appearance in
            let n = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((n >> 16) & 255)/255, green: Double((n >> 8) & 255)/255, blue: Double(n & 255)/255, alpha: 1)
        })
        #else
        self.init(uiColor: UIColor { traits in
            let n = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: Double((n >> 16) & 255)/255, green: Double((n >> 8) & 255)/255, blue: Double(n & 255)/255, alpha: 1)
        })
        #endif
    }
}
