import SwiftUI

private struct CloseReaderKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}
private struct ToggleReaderFullScreenKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}
extension EnvironmentValues {
    var closeReader: (() -> Void)? {
        get { self[CloseReaderKey.self] }
        set { self[CloseReaderKey.self] = newValue }
    }
    var toggleReaderFullScreen: (() -> Void)? {
        get { self[ToggleReaderFullScreenKey.self] }
        set { self[ToggleReaderFullScreenKey.self] = newValue }
    }
}

extension View {
    func readerPresentation<Content: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) -> some View {
        #if os(macOS)
        background(ReaderWindow(isPresented: isPresented, content: content).frame(width: 0, height: 0))
        #else
        fullScreenCover(isPresented: isPresented, content: content)
        #endif
    }

    func readerPresentation<Item: Identifiable, Content: View>(item: Binding<Item?>, @ViewBuilder content: @escaping (Item) -> Content) -> some View {
        readerPresentation(isPresented: Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })) {
            if let value = item.wrappedValue { content(value) }
        }
    }
}

#if os(macOS)
import AppKit

// A reader owns its window so library navigation stays available, and the native
// green window button / Control-Command-F can enter a separate full-screen space.
private struct ReaderWindow<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    let content: () -> Content

    func makeCoordinator() -> Coordinator { Coordinator(isPresented: $isPresented) }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.isPresented = $isPresented
        let presented = isPresented
        // Present after SwiftUI finishes updating the originating navigation view.
        DispatchQueue.main.async {
            guard !coordinator.dismantled, presented == coordinator.isPresented.wrappedValue else { return }
            if presented {
                guard coordinator.window == nil else { return }
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
                window.title = "Margin — Reader"
                window.minSize = NSSize(width: 650, height: 600)
                window.collectionBehavior.insert(.fullScreenPrimary)
                window.isReleasedWhenClosed = false
                window.delegate = coordinator
                window.contentViewController = NSHostingController(rootView: ReaderWindowContent(window: window, content: content())
                    .environment(\.closeReader, { [weak window] in window?.performClose(nil) })
                    .environment(\.toggleReaderFullScreen, { [weak window] in window?.toggleFullScreen(nil) }))
                coordinator.window = window
                window.center()
                window.makeKeyAndOrderFront(nil)
            } else if let window = coordinator.window {
                window.delegate = nil
                window.close()
                coordinator.window = nil
            }
        }
    }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.dismantled = true
        coordinator.window?.delegate = nil
        coordinator.window?.close()
        coordinator.window = nil
    }
    final class Coordinator: NSObject, NSWindowDelegate {
        var isPresented: Binding<Bool>
        var window: NSWindow?
        var dismantled = false
        init(isPresented: Binding<Bool>) { self.isPresented = isPresented }
        func windowWillClose(_ notification: Notification) {
            window = nil
            isPresented.wrappedValue = false
        }
    }
}

private struct ReaderWindowContent<Content: View>: View {
    weak var window: NSWindow?
    let content: Content
    @State private var active = true

    var body: some View {
        content
            .environment(\.scenePhase, active ? .active : .inactive)
            .onAppear { updateActivity() }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in updateActivity() }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in updateActivity() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in updateActivity() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in updateActivity() }
    }

    private func updateActivity() { active = NSApp.isActive && window?.isKeyWindow == true }
}
#endif
