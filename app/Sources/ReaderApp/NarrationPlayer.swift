import SwiftUI
import AVFoundation
import MediaPlayer
import LibraryCore

@MainActor @Observable final class NarrationPlayer: NSObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    var key = ""
    var title = ""
    var provider = "Apple · device voice"
    var playing = false
    var loading = false
    var position: Double = 0
    var duration: Double = 0
    var spokenRange: NSRange?
    var failure: String?
    var follow = true
    var rate: Double = 1
    @ObservationIgnored private var audio: AVAudioPlayer?
    @ObservationIgnored private let speech = AVSpeechSynthesizer()
    @ObservationIgnored private var utterance: AVSpeechUtterance?
    @ObservationIgnored private var speechOffset = 0
    @ObservationIgnored private var text = ""
    @ObservationIgnored private var alignment: Narration?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var loadID = UUID()
    @ObservationIgnored private var remoteTargets: [Any] = []
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    override init() {
        super.init(); speech.delegate = self
        #if os(iOS)
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notice in
            guard let type = notice.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt, type == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor in self?.pause() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] notice in
            guard let reason = notice.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt, reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
            Task { @MainActor in self?.pause() }
        })
        #endif
        let commands = MPRemoteCommandCenter.shared()
        remoteTargets.append(commands.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.resume() }; return .success })
        remoteTargets.append(commands.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pause() }; return .success })
        commands.skipBackwardCommand.preferredIntervals = [15]
        commands.skipForwardCommand.preferredIntervals = [15]
        remoteTargets.append(commands.skipBackwardCommand.addTarget { [weak self] _ in Task { @MainActor in guard let self else { return }; self.seek(self.position - 15) }; return .success })
        remoteTargets.append(commands.skipForwardCommand.addTarget { [weak self] _ in Task { @MainActor in guard let self else { return }; self.seek(self.position + 15) }; return .success })
    }
    static func identifier(book: Book, section: Int, location: ReadingLocation) -> String { "\(book.id):\(location.rawValue):\(section)" }
    func start(book: Book, section: Int, location: ReadingLocation, store: LibraryStore) async {
        stop(); let id = UUID(); loadID = id
        let sections = location == .chapter ? book.chapters ?? [] : book.sections
        guard sections.indices.contains(section) else { return }
        key = Self.identifier(book: book, section: section, location: location)
        let part = sections[section]; title = part.title; text = part.body
        alignment = part.narration; follow = true; failure = nil
        do {
            #if os(iOS)
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            #endif
            if part.narration != nil && location == .summary {
                loading = true
                let url = try await store.narrationURL(book: book, section: section)
                guard loadID == id else { return }
                let player = try AVAudioPlayer(contentsOf: url)
                audio = player; player.delegate = self; player.enableRate = true; player.rate = Float(rate)
                duration = player.duration; provider = "\(part.narration!.provider) · \(part.narration!.voice)"
                player.prepareToPlay(); player.play(); playing = true
                timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
            } else {
                provider = "Apple · device voice"
                duration = Double(text.split(whereSeparator: { $0.isWhitespace }).count) / 2.7
                speak(from: 0)
            }
            loading = false; nowPlaying()
        } catch { guard loadID == id else { return }; loading = false; failure = error.localizedDescription }
    }
    func stop() {
        loadID = UUID(); audio?.stop(); audio = nil; utterance = nil; speech.stopSpeaking(at: .immediate)
        timer?.invalidate(); timer = nil; playing = false; loading = false; position = 0; duration = 0; spokenRange = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
    func pause() { audio?.pause(); if speech.isSpeaking { speech.pauseSpeaking(at: .immediate) }; playing = false; nowPlaying() }
    func resume() {
        if let audio { if audio.currentTime >= audio.duration { audio.currentTime = 0 }; audio.play() }
        else if speech.isPaused { speech.continueSpeaking() }
        else { speak(from: spokenRange?.location ?? 0) }
        playing = true; nowPlaying()
    }
    func seek(_ time: Double) {
        let wasPlaying = playing
        position = min(max(time, 0), duration)
        if let audio { audio.currentTime = position; spokenRange = alignment?.word(at: position)?.range }
        else {
            let total = (text as NSString).length
            let raw = Int(position / max(1, duration) * Double(total))
            let source = text as NSString
            var offset = min(raw, total)
            while offset > 0 && offset < total && !CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(source.character(at: offset - 1)) ?? " ") { offset -= 1 }
            speak(from: offset)
            if !wasPlaying { pause() }
        }
        nowPlaying()
    }
    func setRate(_ value: Double) {
        rate = value
        if let audio { audio.rate = Float(value) }
        else if utterance != nil { let wasPlaying = playing; speak(from: spokenRange?.location ?? speechOffset); if !wasPlaying { pause() } }
        nowPlaying()
    }
    private func speak(from offset: Int) {
        utterance = nil; speech.stopSpeaking(at: .immediate)
        let source = text as NSString
        speechOffset = min(max(0, offset), source.length)
        guard speechOffset < source.length else { playing = false; return }
        let next = AVSpeechUtterance(string: source.substring(from: speechOffset))
        next.voice = AVSpeechSynthesisVoice(language: "en-US")
        next.rate = min(AVSpeechUtteranceMaximumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * Float(rate))
        utterance = next; playing = true; speech.speak(next)
    }
    private func tick() {
        guard let audio else { return }
        position = audio.currentTime; spokenRange = alignment?.word(at: position)?.range
        // Keep lock-screen progress current without publishing every cursor frame.
        if Int(position * 20) % 20 == 0 { nowPlaying() }
    }
    private func nowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyTitle: title, MPMediaItemPropertyArtist: provider,
            MPMediaItemPropertyPlaybackDuration: duration, MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? rate : 0]
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString range: NSRange, utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard self.utterance === utterance else { return }
            self.spokenRange = NSRange(location: self.speechOffset + range.location, length: range.length)
            self.position = Double(self.speechOffset + range.location) / Double(max(1, (self.text as NSString).length)) * self.duration
            self.nowPlaying()
        }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in guard self.utterance === utterance else { return }; self.playing = false; self.position = self.duration; self.spokenRange = nil; self.nowPlaying() }
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in guard self.audio === player else { return }; self.playing = false; self.position = self.duration; self.spokenRange = nil; self.nowPlaying() }
    }
}

struct NarrationControls: View {
    @Bindable var player: NarrationPlayer
    let start: () -> Void
    let active: Bool
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 16) {
                Button { player.seek(player.position - 15) } label: { Image(systemName: "gobackward.15") }.disabled(!active)
                Button { if !active || player.failure != nil { start() } else if player.playing { player.pause() } else { player.resume() } } label: {
                    Label(player.loading && active ? "Loading…" : player.playing && active ? "Pause" : "Listen", systemImage: player.playing && active ? "pause.fill" : "play.fill")
                }.disabled(player.loading && active)
                Button { player.seek(player.position + 15) } label: { Image(systemName: "goforward.15") }.disabled(!active)
                Spacer()
                NarrationSpeedPicker(player: player)
                if active { Toggle("Follow", isOn: $player.follow).toggleStyle(.button).help("Follow the spoken word and scroll automatically") }
            }
            if active {
                NarrationProgress(player: player)
            }
        }.buttonStyle(.borderless).padding(.horizontal, 24).padding(.vertical, 10)
    }
}

struct NarrationSpeedPicker: View {
    static let rates: [Double] = [0.75, 1, 1.25, 1.5, 1.75, 2]
    @Bindable var player: NarrationPlayer
    var body: some View {
        Picker("Playback speed", selection: Binding(get: { player.rate }, set: { player.setRate($0) })) {
            ForEach(Self.rates, id: \.self) { rate in
                Text(rate.formatted(.number.precision(.fractionLength(0...2))) + "×").tag(rate)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel("Playback speed")
    }
}

private struct NarrationProgress: View {
    @Bindable var player: NarrationPlayer
    var body: some View {
        VStack(spacing: 8) {
            Slider(value: Binding(get: { player.position }, set: { player.seek($0) }), in: 0...max(1, player.duration)).accessibilityLabel("Narration position")
            HStack { Text(player.provider + (player.provider.hasPrefix("Apple") ? " · time estimated" : "")).lineLimit(1); Spacer(); Text("\(clock(player.position)) / \(clock(player.duration))").monospacedDigit() }.font(.caption).foregroundStyle(.secondary)
            if let failure = player.failure { Text(failure).font(.caption).foregroundStyle(.red) }
        }
    }
    private func clock(_ value: Double) -> String { String(format: "%d:%02d", Int(value) / 60, Int(value) % 60) }
}

struct NarrationMiniPlayer: View {
    @Bindable var player: NarrationPlayer
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "headphones")
            VStack(alignment: .leading, spacing: 3) {
                Text(player.title).font(.callout.weight(.medium)).lineLimit(1)
                Text(player.provider).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button { player.seek(player.position - 15) } label: { Image(systemName: "gobackward.15") }.accessibilityLabel("Back 15 seconds")
            Button { if player.playing { player.pause() } else { player.resume() } } label: { Image(systemName: player.playing ? "pause.fill" : "play.fill") }.accessibilityLabel(player.playing ? "Pause narration" : "Resume narration")
            Button { player.stop(); player.key = "" } label: { Image(systemName: "xmark") }.accessibilityLabel("Close narration")
        }.buttonStyle(.borderless).padding(14).background(.regularMaterial)
    }
}
