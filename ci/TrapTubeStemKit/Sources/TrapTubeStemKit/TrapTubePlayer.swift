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
                Image(systemName: "hifispeaker.fill")
                    .foregroundStyle(Color.white.opacity(0.0))
                    .frame(width: 52, height: 40)
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

// MARK: - Launcher (Stem Studio Player tab)

struct TrapTubePlayerHomeView: View {
    @State private var input = ""
    @State private var request: TrapTubePlayerRequest?
    @State private var inputError: String?
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
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Text("TRAPTUBE PLAYER").font(.caption.weight(.black))
                    .tracking(1.5).foregroundStyle(accent)
                Text("Watch with the equalizer")
                    .font(.title2.weight(.black)).foregroundStyle(.white)
                Text("YouTube's own player never hands its audio to the EQ. This player resolves the same video's stream and plays it natively - the way Musi did - so the EQ tap attaches and every band works.")
                    .font(.subheadline).foregroundStyle(Color.white.opacity(0.64))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .ttGlassCard(cornerRadius: 18)

            VStack(alignment: .leading, spacing: 12) {
                Text("Open a video")
                    .font(.subheadline.weight(.bold)).foregroundStyle(.white)
                TextField("Paste a YouTube link or video ID", text: $input)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                if let inputError {
                    Text(inputError).font(.caption).foregroundStyle(accent)
                }
                Button {
                    if let videoID = TrapTubeStreamResolver.extractVideoID(from: input) {
                        inputError = nil
                        request = TrapTubePlayerRequest(videoID: videoID)
                    } else {
                        inputError = "Couldn't find a video ID in that text."
                    }
                } label: {
                    HStack {
                        Image(systemName: "play.fill")
                        Text("Play in TrapTube Player").font(.subheadline.weight(.bold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(accent, in: Capsule())
                }
                .buttonStyle(.plain)

                if let detectedID {
                    Button {
                        request = TrapTubePlayerRequest(videoID: detectedID)
                    } label: {
                        HStack {
                            Image(systemName: "play.circle.fill")
                            Text("Play the video open in YouTube (\(detectedID))")
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.white.opacity(0.08), in: Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
            .ttGlassCard(cornerRadius: 18)

            Text("Everything else in the app is untouched - this is an additional player, not a replacement for YouTube's screens. Some videos refuse direct playback (age gates, music licensing, signature protection); the player will say so plainly when that happens.")
                .font(.caption).foregroundStyle(Color.white.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { detectedID = TrapTubeCurrentVideo.detectVideoID() }
        .fullScreenCover(item: $request) { request in
            TrapTubeNativePlayerView(request: request)
        }
    }
}
