import Foundation
import AVFoundation
import SwiftUI
import UIKit

// MARK: - Musi-style stream resolution
//
// Musi could equalize any YouTube stream because it never used YouTube's
// player: it resolved the video's streams itself and played them in its own
// AVPlayer, where an audio tap is a first-class citizen. TrapTube's native
// player does the same thing in miniature: ask YouTube's InnerTube player
// endpoint (the same public interface the web and mobile clients use) for
// the stream list, pick a directly playable format, and hand it to an
// AVPlayer we own - so TrapTubeAudioHook's MTAudioProcessingTap attaches
// exactly the way it was designed to.

enum TrapTubePlayerError: LocalizedError {
    case invalidVideoID
    case unplayable(String)
    case cipherProtected
    case noPlayableFormat
    case network(String)

    var errorDescription: String? {
        switch self {
        case .invalidVideoID:
            return "That link or ID doesn't look like a YouTube video."
        case .unplayable(let reason):
            return "YouTube says this video can't be played: \(reason)"
        case .cipherProtected:
            return "YouTube served this video's streams signature-protected to every client profile, so there's no directly playable URL. Try another video."
        case .noPlayableFormat:
            return "YouTube returned no format this player can use for this video."
        case .network(let detail):
            return "Couldn't reach YouTube: \(detail)"
        }
    }
}

struct TrapTubeResolvedPlayback {
    let title: String
    let author: String
    let makeItem: @Sendable () async throws -> AVPlayerItem
}

enum TrapTubeStreamResolver {
    private static let apiKey = "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8"

    private struct ClientProfile {
        let name: String
        let userAgent: String
        let context: [String: Any]
    }

    private static let profiles: [ClientProfile] = [
        ClientProfile(
            name: "IOS",
            userAgent: "com.google.ios.youtube/19.45.4 (iPhone16,2; U; CPU iOS 18_1_0 like Mac OS X)",
            context: ["clientName": "IOS", "clientVersion": "19.45.4",
                      "deviceMake": "Apple", "deviceModel": "iPhone16,2",
                      "osName": "iPhone", "osVersion": "18.1.0", "hl": "en", "gl": "US"]),
        ClientProfile(
            name: "ANDROID",
            userAgent: "com.google.android.youtube/19.44.38 (Linux; U; Android 14; en_US; Pixel 8) gzip",
            context: ["clientName": "ANDROID", "clientVersion": "19.44.38",
                      "androidSdkVersion": 34, "osName": "Android", "osVersion": "14",
                      "hl": "en", "gl": "US"]),
        ClientProfile(
            name: "WEB_EMBEDDED_PLAYER",
            userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15",
            context: ["clientName": "WEB_EMBEDDED_PLAYER", "clientVersion": "1.20241110.01.00",
                      "hl": "en", "gl": "US"]),
    ]

    static func extractVideoID(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let idCharacterSet = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
        if trimmed.count == 11, trimmed.unicodeScalars.allSatisfy({ idCharacterSet.contains($0) }) {
            return trimmed
        }
        let patterns = [#"youtu\.be/([A-Za-z0-9_-]{11})"#,
                        #"[?&]v=([A-Za-z0-9_-]{11})"#,
                        #"/shorts/([A-Za-z0-9_-]{11})"#,
                        #"/live/([A-Za-z0-9_-]{11})"#,
                        #"/embed/([A-Za-z0-9_-]{11})"#]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
               let range = Range(match.range(at: 1), in: trimmed) {
                return String(trimmed[range])
            }
        }
        return nil
    }

    static func resolve(videoID: String) async throws -> TrapTubeResolvedPlayback {
        var sawCipher = false
        var lastPlayability: String?
        for profile in profiles {
            let json = try await fetchPlayerResponse(videoID: videoID, profile: profile)
            if let playability = json["playabilityStatus"] as? [String: Any],
               let status = playability["status"] as? String, status != "OK" {
                lastPlayability = (playability["reason"] as? String) ?? status
                continue
            }
            guard let streaming = json["streamingData"] as? [String: Any] else {
                continue
            }
            let details = json["videoDetails"] as? [String: Any]
            let title = (details?["title"] as? String) ?? "YouTube video"
            let author = (details?["author"] as? String) ?? ""

            let muxed = formatList(streaming["formats"])
            let adaptive = formatList(streaming["adaptiveFormats"])
            if muxed.isEmpty && adaptive.isEmpty { continue }
            if muxed.allSatisfy({ $0.url == nil }) && adaptive.allSatisfy({ $0.url == nil }) {
                sawCipher = true
                continue
            }

            // 1) A muxed MP4 (itag 22/18 style) is the simplest playable item.
            let playableMuxed = muxed
                .filter { $0.url != nil && $0.hasVideo && $0.hasAudio && $0.mime.contains("mp4") }
                .sorted { $0.height > $1.height }
            if let best = playableMuxed.first, let urlString = best.url, let url = URL(string: urlString) {
                return TrapTubeResolvedPlayback(title: title, author: author) {
                    AVPlayerItem(asset: AVURLAsset(url: url))
                }
            }

            // 2) Otherwise combine the best MP4 video-only and audio-only
            //    adaptive formats into one composition; the composed audio
            //    track accepts the EQ tap like any other track.
            let videos = adaptive
                .filter { $0.url != nil && $0.hasVideo && !$0.hasAudio && $0.mime.contains("mp4") && $0.mime.contains("avc1") }
                .sorted { $0.height != $1.height ? $0.height > $1.height : $0.bitrate > $1.bitrate }
            let audios = adaptive
                .filter { $0.url != nil && $0.hasAudio && !$0.hasVideo && $0.mime.contains("mp4") }
                .sorted { $0.bitrate > $1.bitrate }
            if let video = videos.first(where: { $0.height <= 720 }) ?? videos.first,
               let audio = audios.first,
               let videoURL = URL(string: video.url ?? ""), let audioURL = URL(string: audio.url ?? "") {
                return TrapTubeResolvedPlayback(title: title, author: author) {
                    let videoAsset = AVURLAsset(url: videoURL)
                    let audioAsset = AVURLAsset(url: audioURL)
                    guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first,
                          let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first else {
                        throw TrapTubePlayerError.noPlayableFormat
                    }
                    let composition = AVMutableComposition()
                    let duration = try await videoAsset.load(.duration)
                    let range = CMTimeRange(start: .zero, duration: duration)
                    let compVideo = composition.addMutableTrack(withMediaType: .video,
                                                                preferredTrackID: kCMPersistentTrackID_Invalid)
                    try compVideo?.insertTimeRange(range, of: videoTrack, at: .zero)
                    let compAudio = composition.addMutableTrack(withMediaType: .audio,
                                                                preferredTrackID: kCMPersistentTrackID_Invalid)
                    try compAudio?.insertTimeRange(range, of: audioTrack, at: .zero)
                    return AVPlayerItem(asset: composition)
                }
            }
        }
        if sawCipher { throw TrapTubePlayerError.cipherProtected }
        if let reason = lastPlayability { throw TrapTubePlayerError.unplayable(reason) }
        throw TrapTubePlayerError.noPlayableFormat
    }

    private struct FormatEntry {
        let url: String?
        let mime: String
        let height: Int
        let bitrate: Int
        let hasVideo: Bool
        let hasAudio: Bool
    }

    private static func formatList(_ raw: Any?) -> [FormatEntry] {
        guard let list = raw as? [[String: Any]] else { return [] }
        return list.map { entry in
            let mime = (entry["mimeType"] as? String) ?? ""
            let codecs = mime.lowercased()
            return FormatEntry(
                url: entry["url"] as? String,
                mime: mime,
                height: (entry["height"] as? Int) ?? 0,
                bitrate: (entry["bitrate"] as? Int) ?? 0,
                hasVideo: codecs.contains("avc1") || codecs.contains("av01") || codecs.contains("vp9") || codecs.contains("vp09"),
                hasAudio: codecs.contains("mp4a") || codecs.contains("opus"))
        }
    }

    private static func fetchPlayerResponse(videoID: String, profile: ClientProfile) async throws -> [String: Any] {
        guard let endpoint = URL(string: "https://www.youtube.com/youtubei/v1/player?key=\(apiKey)&prettyPrint=false") else {
            throw TrapTubePlayerError.network("bad endpoint")
        }
        var body: [String: Any] = [
            "context": ["client": profile.context],
            "videoId": videoID,
            "racyCheckOk": true,
            "contentCheckOk": true,
        ]
        if profile.name == "WEB_EMBEDDED_PLAYER" {
            body["context"] = ["client": profile.context,
                               "thirdParty": ["embedUrl": "https://www.youtube.com/embed/\(videoID)"]]
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(profile.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw TrapTubePlayerError.network("unexpected response")
            }
            return json
        } catch let error as TrapTubePlayerError {
            throw error
        } catch {
            throw TrapTubePlayerError.network(error.localizedDescription)
        }
    }
}

// MARK: - Current-video detection (best effort)
//
// Walks the app's own view-controller tree looking for a player controller
// that answers one of the well-known video-ID accessors. Everything is
// probed with responds(to:) first, so a miss just means the button hides.

enum TrapTubeCurrentVideo {
    static func detectVideoID() -> String? {
        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive })
                ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController
                ?? scene.windows.first?.rootViewController else { return nil }
        var stack: [UIViewController] = [root]
        var visited = 0
        let keyCandidates = ["videoID", "currentVideoID", "contentVideoID", "videoId"]
        while let controller = stack.popLast(), visited < 400 {
            visited += 1
            for key in keyCandidates {
                let selector = NSSelectorFromString(key)
                if controller.responds(to: selector),
                   let value = controller.value(forKey: key) as? String,
                   TrapTubeStreamResolver.extractVideoID(from: value) == value {
                    return value
                }
            }
            if let presented = controller.presentedViewController { stack.append(presented) }
            stack.append(contentsOf: controller.children)
            if let navigation = controller as? UINavigationController {
                stack.append(contentsOf: navigation.viewControllers)
            }
            if let tab = controller as? UITabBarController {
                stack.append(contentsOf: tab.viewControllers ?? [])
            }
        }
        return nil
    }
}

// MARK: - Player controller

@MainActor
final class TrapTubePlayerController: ObservableObject {
    let player = AVPlayer()
    private let hook = TrapTubeAudioHook()
    private var timeObserver: Any?
    private var loadTask: Task<Void, Never>?

    @Published var title = ""
    @Published var author = ""
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var rate: Float = 1.0

    init() {
        hook.install(on: player)
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main) { [weak self] time in
                guard let self else { return }
                self.currentTime = time.seconds.isFinite ? time.seconds : 0
                if let itemDuration = self.player.currentItem?.duration.seconds,
                   itemDuration.isFinite {
                    self.duration = itemDuration
                }
                self.isPlaying = self.player.timeControlStatus == .playing
            }
    }

    func load(videoID: String) {
        loadTask?.cancel()
        isLoading = true
        errorMessage = nil
        title = ""
        author = ""
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let resolved = try await TrapTubeStreamResolver.resolve(videoID: videoID)
                let item = try await resolved.makeItem()
                guard !Task.isCancelled else { return }
                self.title = resolved.title
                self.author = resolved.author
                self.player.replaceCurrentItem(with: item)
                self.isLoading = false
                self.player.play()
            } catch {
                guard !Task.isCancelled else { return }
                self.isLoading = false
                self.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    func togglePlayPause() {
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            player.rate = rate
        }
        isPlaying = player.timeControlStatus == .playing
    }

    func skip(by seconds: Double) {
        let target = max(0, currentTime + seconds)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func setRate(_ newRate: Float) {
        rate = newRate
        if player.timeControlStatus == .playing { player.rate = newRate }
    }

    func stop() {
        loadTask?.cancel()
        player.pause()
        hook.invalidate()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
    }
}

// MARK: - Player layer

private struct TrapTubePlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    final class LayerView: UIView {
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        override class var layerClass: AnyClass { AVPlayerLayer.self }
    }

    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: LayerView, context: Context) {
        uiView.playerLayer.player = player
    }
}

// MARK: - Native player screen

struct TrapTubePlayerRequest: Identifiable {
    let videoID: String
    let stamp = UUID()
    var id: String { stamp.uuidString }
}

struct TrapTubeNativePlayerView: View {
    let request: TrapTubePlayerRequest
    @StateObject private var controller = TrapTubePlayerController()
    @State private var streamStatus = "Not attached yet"
    @State private var scrubbing = false
    @State private var scrubTime: Double = 0
    @State private var showEQ = false
    @Environment(\.dismiss) private var dismiss

    private var accent: Color {
        let hex = UserDefaults.standard.string(forKey: "TrapTube.AccentHex") ?? "D1091F"
        let clean = hex.replacingOccurrences(of: "#", with: "")
        let value = UInt64(clean, radix: 16) ?? 0xD1091F
        return Color(.sRGB, red: Double((value >> 16) & 255) / 255,
                     green: Double((value >> 8) & 255) / 255,
                     blue: Double(value & 255) / 255, opacity: 1)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                videoArea
                controls
                Spacer(minLength: 0)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            streamStatus = TrapTubeEQManager.shared.attachmentStatus
            controller.load(videoID: request.videoID)
        }
        .onDisappear { controller.stop() }
        .onReceive(NotificationCenter.default.publisher(
            for: Notification.Name("TrapTubeEQAttachmentStatusChanged"))) { note in
            if let status = note.userInfo?["status"] as? String { streamStatus = status }
        }
        .sheet(isPresented: $showEQ) {
            TrapTubeEqualizerPanel()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(controller.title.isEmpty ? "TrapTube Player" : controller.title)
                    .font(.headline.weight(.bold)).foregroundStyle(.white)
                    .lineLimit(2)
                if !controller.author.isEmpty {
                    Text(controller.author)
                        .font(.subheadline).foregroundStyle(Color.white.opacity(0.6))
                        .lineLimit(1)
                }
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var videoArea: some View {
        ZStack {
            TrapTubePlayerLayerView(player: controller.player)
            if controller.isLoading {
                ProgressView().tint(.white).scaleEffect(1.3)
            }
            if let message = controller.errorMessage {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title2).foregroundStyle(accent)
                    Text(message)
                        .font(.subheadline).foregroundStyle(Color.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .background(Color.black)
    }

    private var controls: some View {
        VStack(spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: "waveform")
                Text("EQ stream status")
                Spacer()
                Text(streamStatus)
                    .foregroundStyle(accent)
                    .multilineTextAlignment(.trailing)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.white.opacity(0.65))

            VStack(spacing: 4) {
                Slider(value: Binding(
                        get: { scrubbing ? scrubTime : controller.currentTime },
                        set: { newValue in if scrubbing { scrubTime = newValue } }),
                       in: 0...max(controller.duration, 1)) { editing in
                    if editing {
                        scrubbing = true
                        scrubTime = controller.currentTime
                    } else {
                        controller.seek(to: scrubTime)
                        scrubbing = false
                    }
                }
                .tint(accent)
                HStack {
                    Text(timeLabel(scrubbing ? scrubTime : controller.currentTime))
                    Spacer()
                    Text(timeLabel(controller.duration))
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Color.white.opacity(0.55))
            }

            HStack {
                Menu {
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { speed in
                        Button("\(speed, specifier: "%g")x") { controller.setRate(Float(speed)) }
                    }
                } label: {
                    Text("\(controller.rate, specifier: "%g")x")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 40)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                Spacer()
                Button { controller.skip(by: -10) } label: {
                    Image(systemName: "gobackward.10")
                        .font(.system(size: 24))
                        .foregroundStyle(.white)
                }
                Button { controller.togglePlayPause() } label: {
                    Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.white)
                        .frame(width: 64, height: 64)
                        .background(accent, in: Circle())
                }
                Button { controller.skip(by: 10) } label: {
                    Image(systemName: "goforward.10")
                        .font(.system(size: 24))
                        .foregroundStyle(.white)
                }
                Spacer()
                Button { showEQ = true } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 40)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
            }

            Text("This is TrapTube's own player, so the equalizer tap attaches to its audio. Adjust bands on the Equalizer tab - changes apply live. Pause the video in YouTube's own player first if it's also playing.")
                .font(.caption)
                .foregroundStyle(Color.white.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .ttGlassCard(cornerRadius: 20)
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }

    private func timeLabel(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Equalizer panel (presented from the player)
//
// The EQ controls used to be their own Stem Studio tab. They now live with
// the player they actually affect: one tap on the player's EQ button opens
// this panel, and every change applies live to the playing item through the
// shared manager.

struct TrapTubeEqualizerPanel: View {
    @State private var streamStatus = "Not attached yet"
    @Environment(\.dismiss) private var dismiss

    private var manager: TrapTubeEQManager { TrapTubeEQManager.shared }

    private var accent: Color {
        let hex = UserDefaults.standard.string(forKey: "TrapTube.AccentHex") ?? "D1091F"
        let clean = hex.replacingOccurrences(of: "#", with: "")
        let value = UInt64(clean, radix: 16) ?? 0xD1091F
        return Color(.sRGB, red: Double((value >> 16) & 255) / 255,
                     green: Double((value >> 8) & 255) / 255,
                     blue: Double(value & 255) / 255, opacity: 1)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Equalizer").font(.headline.weight(.bold)).foregroundStyle(.white)
                Spacer()
                Button("Done") { dismiss() }
                    .font(.subheadline.weight(.bold)).foregroundStyle(accent)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Equalizer enabled", isOn: Binding(
                            get: { manager.isEQEnabled },
                            set: { manager.setEQEnabled($0) }
                        ))
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                        .tint(accent)
                        HStack {
                            Text("Stream status").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                            Spacer()
                            Text(streamStatus)
                                .font(.caption.weight(.bold)).foregroundStyle(accent)
                        }
                        .onAppear { streamStatus = manager.attachmentStatus }
                        .onReceive(NotificationCenter.default.publisher(
                            for: Notification.Name("TrapTubeEQAttachmentStatusChanged"))) { note in
                            if let status = note.userInfo?["status"] as? String { streamStatus = status }
                        }
                        Button("Reset EQ to flat") { manager.resetAll() }
                            .font(.subheadline.weight(.bold)).foregroundStyle(accent)
                    }
                    .padding(16)
                    .ttGlassCard(cornerRadius: 18)

                    VStack(alignment: .leading, spacing: 16) {
                        TrapTubeEQSliderRow(title: "Bass boost", value: manager.bassBoostDecibels,
                                            range: 0...20, suffix: " dB") { manager.setBassBoost($0) }
                        TrapTubeEQSliderRow(title: "Master gain", value: manager.masterGainPercent,
                                            range: 0...200, suffix: "%") { manager.setMasterGainPercent($0) }
                    }
                    .padding(16)
                    .ttGlassCard(cornerRadius: 18)

                    VStack(alignment: .leading, spacing: 14) {
                        Text("16-BAND EQUALIZER").font(.caption.weight(.black))
                            .tracking(1.5).foregroundStyle(accent)
                        ForEach(Array(TrapTubeEQManager.frequencies.enumerated()), id: \.offset) { index, frequency in
                            let label = frequency >= 1000
                                ? (frequency.truncatingRemainder(dividingBy: 1000) == 0
                                   ? "\(Int(frequency / 1000)) kHz"
                                   : String(format: "%.1f kHz", frequency / 1000))
                                : "\(Int(frequency)) Hz"
                            TrapTubeEQSliderRow(title: label, value: manager.bandGain(at: index),
                                                range: -12...12, suffix: " dB") {
                                manager.setBandGain($0, at: index)
                            }
                        }
                    }
                    .padding(16)
                    .ttGlassCard(cornerRadius: 18)

                    Text("EQ applies to the TrapTube Player and to TrapTube-owned audio. YouTube's own player renders through its private pipeline and doesn't expose its audio.")
                        .font(.caption).foregroundStyle(Color.white.opacity(0.45))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(18)
            }
        }
        .background {
            LinearGradient(colors: [Color(red: 0.055, green: 0.04, blue: 0.075),
                                    Color(red: 0.015, green: 0.015, blue: 0.028)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Feed (Stem Studio Player tab)
//
// A YouTube-style home feed and search, backed by the same InnerTube
// interface the resolver uses: browse (FEwhat_to_watch) for the
// recommendation grid and search for queries. Signed out, recommendations
// are YouTube's public picks; every row plays in the native player.

struct TrapTubeFeedItem: Identifiable {
    let videoID: String
    let title: String
    let channel: String
    let duration: String?
    let meta: String
    let thumbnailURL: URL?
    var id: String { videoID }
}

@MainActor
final class TrapTubeFeedModel: ObservableObject {
    @Published var items: [TrapTubeFeedItem] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var isSearching = false

    private var continuation: String?
    private var currentQuery: String?
    private var generation = 0

    func loadHome() async {
        currentQuery = nil
        isSearching = false
        await load(reset: true) { token in
            token == nil
                ? ["browseId": "FEwhat_to_watch"]
                : ["continuation": token as Any]
        }
    }

    func search(_ query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { await loadHome(); return }
        currentQuery = trimmed
        isSearching = true
        await load(reset: true) { token in
            token == nil
                ? ["query": trimmed, "params": "EgIQAQ%3D%3D"]
                : ["query": trimmed, "continuation": token as Any]
        }
    }

    func loadMore() async {
        guard continuation != nil, !isLoading else { return }
        if let query = currentQuery {
            await load(reset: false) { token in
                ["query": query, "continuation": token as Any]
            }
        } else {
            await load(reset: false) { token in
                ["continuation": token as Any]
            }
        }
    }

    private func load(reset: Bool, body: (String?) -> [String: Any]) async {
        generation += 1
        let run = generation
        if reset {
            continuation = nil
            items = []
            errorMessage = nil
        }
        isLoading = true
        defer { if run == generation { isLoading = false } }
        do {
            let endpoint = (currentQuery != nil)
                ? "https://www.youtube.com/youtubei/v1/search"
                : "https://www.youtube.com/youtubei/v1/browse"
            let json = try await TrapTubeInnerTube.post(endpoint: endpoint,
                                                        body: body(continuation))
            guard run == generation else { return }
            var seen = Set(items.map { $0.videoID })
            var found: [TrapTubeFeedItem] = []
            var token: String?
            Self.collect(node: json, items: &found, seen: &seen, continuation: &token)
            if reset { items = found } else { items.append(contentsOf: found) }
            continuation = token
            if items.isEmpty && reset {
                errorMessage = "YouTube returned no videos for this view."
            }
        } catch {
            guard run == generation else { return }
            if reset { errorMessage = "Couldn't load the feed: \(error.localizedDescription)" }
        }
    }

    private static func collect(node: Any, items: inout [TrapTubeFeedItem],
                                seen: inout Set<String>, continuation: inout String?) {
        if let dict = node as? [String: Any] {
            if let renderer = dict["videoRenderer"] as? [String: Any],
               let item = parse(renderer), !seen.contains(item.videoID) {
                seen.insert(item.videoID)
                items.append(item)
            }
            if let renderer = dict["continuationItemRenderer"] as? [String: Any],
               let endpoint = renderer["continuationEndpoint"] as? [String: Any],
               let command = endpoint["continuationCommand"] as? [String: Any],
               let token = command["token"] as? String {
                continuation = token
            }
            for value in dict.values {
                collect(node: value, items: &items, seen: &seen, continuation: &continuation)
            }
        } else if let array = node as? [Any] {
            for value in array {
                collect(node: value, items: &items, seen: &seen, continuation: &continuation)
            }
        }
    }

    private static func parse(_ renderer: [String: Any]) -> TrapTubeFeedItem? {
        guard let videoID = renderer["videoId"] as? String else { return nil }
        func text(_ key: String) -> String? {
            guard let node = renderer[key] as? [String: Any] else { return nil }
            if let simple = node["simpleText"] as? String { return simple }
            if let runs = node["runs"] as? [[String: Any]] {
                return runs.compactMap { $0["text"] as? String }.joined()
            }
            return nil
        }
        let title = text("title") ?? "Untitled video"
        let channel = text("longBylineText") ?? text("ownerText") ?? ""
        let duration = text("lengthText")
        var metaParts: [String] = []
        if let views = text("viewCountText") ?? text("shortViewCountText") { metaParts.append(views) }
        if let age = text("publishedTimeText") { metaParts.append(age) }
        var thumbnailURL: URL?
        if let thumb = renderer["thumbnail"] as? [String: Any],
           let variants = thumb["thumbnails"] as? [[String: Any]],
           let best = variants.last, var urlString = best["url"] as? String {
            if urlString.hasPrefix("//") { urlString = "https:" + urlString }
            thumbnailURL = URL(string: urlString)
        }
        return TrapTubeFeedItem(videoID: videoID, title: title, channel: channel,
                                duration: duration, meta: metaParts.joined(separator: " · "),
                                thumbnailURL: thumbnailURL)
    }
}

enum TrapTubeInnerTube {
    static func post(endpoint: String, body: [String: Any]) async throws -> [String: Any] {
        guard let url = URL(string: "\(endpoint)?key=AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8&prettyPrint=false") else {
            throw TrapTubePlayerError.network("bad endpoint")
        }
        var fullBody = body
        fullBody["context"] = ["client": ["clientName": "IOS", "clientVersion": "19.45.4",
                                          "deviceMake": "Apple", "deviceModel": "iPhone16,2",
                                          "osName": "iPhone", "osVersion": "18.1.0",
                                          "hl": "en", "gl": "US"]]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("com.google.ios.youtube/19.45.4 (iPhone16,2; U; CPU iOS 18_1_0 like Mac OS X)",
                         forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: fullBody)
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TrapTubePlayerError.network("unexpected response")
        }
        return json
    }
}

struct TrapTubePlayerHomeView: View {
    @StateObject private var feed = TrapTubeFeedModel()
    @State private var searchText = ""
    @State private var request: TrapTubePlayerRequest?
    @State private var detectedID: String?

    private var accent: Color {
        let hex = UserDefaults.standard.string(forKey: "TrapTube.AccentHex") ?? "D1091F"
        let clean = hex.replacingOccurrences(of: "#", with: "")
        let value = UInt64(clean, radix: 16) ?? 0xD1091F
        return Color(.sRGB, red: Double((value >> 16) & 255) / 255,
                     green: Double((value >> 8) & 255) / 255,
                     blue: Double(value & 255) / 255, opacity: 1)
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            if let detectedID {
                detectedButton(detectedID)
            }
            content
        }
        .task {
            if feed.items.isEmpty { await feed.loadHome() }
            detectedID = TrapTubeCurrentVideo.detectVideoID()
        }
        .fullScreenCover(item: $request) { request in
            TrapTubeNativePlayerView(request: request)
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.white.opacity(0.5))
            TextField("Search YouTube", text: $searchText)
                .foregroundStyle(.white)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .onSubmit { Task { await feed.search(searchText) } }
            if feed.isSearching {
                Button {
                    searchText = ""
                    Task { await feed.loadHome() }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
        }
        .font(.subheadline)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func detectedButton(_ videoID: String) -> some View {
        Button {
            request = TrapTubePlayerRequest(videoID: videoID)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "play.circle.fill").foregroundStyle(accent)
                Text("Play the video open in YouTube")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold)).foregroundStyle(Color.white.opacity(0.4))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var content: some View {
        if feed.items.isEmpty {
            VStack(spacing: 12) {
                Spacer()
                if feed.isLoading {
                    ProgressView().tint(.white)
                    Text("Loading your feed…")
                        .font(.subheadline).foregroundStyle(Color.white.opacity(0.6))
                } else if let message = feed.errorMessage {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.title2).foregroundStyle(accent)
                    Text(message)
                        .font(.subheadline).foregroundStyle(Color.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    Button("Try again") {
                        Task {
                            if feed.isSearching { await feed.search(searchText) }
                            else { await feed.loadHome() }
                        }
                    }
                    .font(.subheadline.weight(.bold)).foregroundStyle(accent)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 6) {
                    Text(feed.isSearching ? "Results" : "Recommended")
                        .font(.caption.weight(.black)).tracking(1.5)
                        .foregroundStyle(accent)
                        .padding(.horizontal, 16)
                        .padding(.top, 6)
                        .padding(.bottom, 4)
                    ForEach(feed.items) { item in
                        row(item)
                            .onAppear {
                                if item.videoID == feed.items.last?.videoID {
                                    Task { await feed.loadMore() }
                                }
                            }
                    }
                    if feed.isLoading {
                        HStack { Spacer(); ProgressView().tint(.white); Spacer() }
                            .padding(.vertical, 14)
                    }
                }
                .padding(.bottom, 16)
            }
        }
    }

    private func row(_ item: TrapTubeFeedItem) -> some View {
        Button {
            request = TrapTubePlayerRequest(videoID: item.videoID)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                ZStack(alignment: .bottomTrailing) {
                    AsyncImage(url: item.thumbnailURL) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().aspectRatio(contentMode: .fill)
                        default:
                            Color.white.opacity(0.08)
                        }
                    }
                    .frame(width: 132, height: 74)
                    .clipped()
                    if let duration = item.duration {
                        Text(duration)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 4))
                            .padding(4)
                    }
                }
                .frame(width: 132, height: 74)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                .clipShape(RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if !item.channel.isEmpty {
                        Text(item.channel)
                            .font(.caption).foregroundStyle(Color.white.opacity(0.6))
                            .lineLimit(1)
                    }
                    if !item.meta.isEmpty {
                        Text(item.meta)
                            .font(.caption).foregroundStyle(Color.white.opacity(0.45))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
