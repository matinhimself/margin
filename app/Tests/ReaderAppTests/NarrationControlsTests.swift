import XCTest
import SwiftUI
@testable import ReaderApp

@MainActor
final class NarrationControlsTests: XCTestCase {
    func testSpeedSelectionPreservesPausedPlaybackPosition() {
        let player = NarrationPlayer()
        player.position = 42
        player.duration = 120
        for rate in NarrationSpeedPicker.rates {
            player.setRate(rate)
            XCTAssertEqual(player.rate, rate)
            XCTAssertEqual(player.position, 42)
            XCTAssertFalse(player.playing)
        }
        player.stop()
    }

    #if os(macOS)
    func testNativeSpeedPickerOptionsRemainEnabledDuringProgressUpdates() throws {
        _ = NSApplication.shared
        let player = NarrationPlayer()
        player.duration = 120
        player.playing = true
        let host = NSHostingView(rootView: NarrationControls(player: player, start: {}, active: true))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 750, height: 160), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; player.stop() }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        let picker = try XCTUnwrap(popup(in: host))
        let progressTimer = Timer(timeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated {
                player.position += 0.05
                host.layoutSubtreeIfNeeded()
            }
        }
        RunLoop.main.add(progressTimer, forMode: .common)
        defer { progressTimer.invalidate() }
        for (index, rate) in NarrationSpeedPicker.rates.enumerated() {
            let initialPosition = player.position
            var titles: [String] = []
            var enabled = false
            let timer = Timer(timeInterval: 0.2, repeats: false) { _ in
                MainActor.assumeIsolated {
                    guard let menu = picker.menu else { return }
                    titles = menu.items.map(\.title)
                    if menu.items.indices.contains(index) {
                        enabled = menu.items[index].isEnabled
                        menu.performActionForItem(at: index)
                    }
                    menu.cancelTracking()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            picker.performClick(nil)
            timer.invalidate()
            XCTAssertEqual(titles, ["0.75×", "1×", "1.25×", "1.5×", "1.75×", "2×"])
            XCTAssertTrue(enabled)
            XCTAssertEqual(player.rate, rate)
            XCTAssertGreaterThan(player.position, initialPosition)
            XCTAssertTrue(player.playing)
        }
    }

    private func popup(in view: NSView) -> NSPopUpButton? {
        if let popup = view as? NSPopUpButton { return popup }
        return view.subviews.compactMap { popup(in: $0) }.first
    }
    #endif
}
