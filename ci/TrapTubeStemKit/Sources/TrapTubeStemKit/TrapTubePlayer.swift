import Foundation
import AVFoundation
import AVKit
import SwiftUI
import UIKit
import WebKit
import CryptoKit

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
    case allProfilesFailed(String)

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
        case .allProfilesFailed(let details):
            return "Playback failed - every YouTube client profile failed to build a playable stream. \(details)"
        }
    }
}

/// Formats any error with its NSError domain and code, so a failure never
/// surfaces as a bare "unknown error" (AVFoundation's -11800 localized
/// description is literally that string, with the real cause hidden in the
/// domain/code and the underlying error).
enum TrapTubeErrorFormatting {
    static func describe(_ error: Error) -> String {
        if let playerError = error as? TrapTubePlayerError,
           let description = playerError.errorDescription {
            return description
        }
        let nsError = error as NSError
        var text = "\(nsError.domain) \(nsError.code): \(nsError.localizedDescription)"
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying !== nsError {
            text += " (underlying: \(underlying.domain) \(underlying.code): \(underlying.localizedDescription))"
        }
        return text
    }

    static func playbackFailure(_ error: Error) -> String {
        if let playerError = error as? TrapTubePlayerError,
           let description = playerError.errorDescription {
            return description
        }
        return "Playback failed (\(describe(error)))"
    }
}

// MARK: - YouTube account auth (Player section only)
//
// A dedicated sign-in for the TrapTube Player, separate from the host
// YouTube app's own sign-in: a WKWebView completes Google's web login,
// the resulting youtube.com cookies are stored locally, and subsequent
// InnerTube requests carry Cookie + SAPISIDHASH Authorization headers so
// the feed/search/player can answer as the signed-in account. The cookie
// string is only ever stored in UserDefaults (the store this codebase
// already uses for prefs) and attached to youtube.com requests - it is
// never logged.

struct TrapTubeChannelProfile {
    let channelID: String
    let title: String
    let handle: String?

    var channelURL: URL? {
        if !channelID.isEmpty {
            return URL(string: "https://www.youtube.com/channel/\(channelID)")
        }
        if let handle, !handle.isEmpty {
            let clean = handle.hasPrefix("@") ? handle : "@\(handle)"
            return URL(string: "https://www.youtube.com/\(clean)")
        }
        return nil
    }
}

enum TrapTubeYouTubeAuth {
    private static let cookieKey = "TrapTube.YouTube.CookieHeader"
    private static let sapisidKey = "TrapTube.YouTube.SAPISID"
    private static let channelIDKey = "TrapTube.YouTube.ChannelID"
    private static let channelTitleKey = "TrapTube.YouTube.ChannelTitle"
    private static let channelHandleKey = "TrapTube.YouTube.ChannelHandle"
    static let origin = "https://www.youtube.com"

    static var cookieHeader: String? {
        let value = UserDefaults.standard.string(forKey: cookieKey)
        return (value?.isEmpty == false) ? value : nil
    }

    static var sapisid: String? {
        let value = UserDefaults.standard.string(forKey: sapisidKey)
        return (value?.isEmpty == false) ? value : nil
    }

    static var isSignedIn: Bool { sapisid != nil || cookieHeader != nil }

    static var cachedProfile: TrapTubeChannelProfile? {
        guard let title = UserDefaults.standard.string(forKey: channelTitleKey), !title.isEmpty else {
            return nil
        }
        return TrapTubeChannelProfile(
            channelID: UserDefaults.standard.string(forKey: channelIDKey) ?? "",
            title: title,
            handle: UserDefaults.standard.string(forKey: channelHandleKey))
    }

    /// Stores the auth cookies found in the web view's cookie store.
    /// Returns true when a real sign-in cookie (SAPISID family or
    /// LOGIN_INFO) was present - callers must not fake a signed-in state
    /// when this returns false.
    @discardableResult
    static func store(cookies: [HTTPCookie]) -> Bool {
        let relevant = cookies.filter {
            $0.domain.contains("youtube.com") || $0.domain.contains("google.com")
        }
        var sapisidValue: String?
        var sawLoginCookie = false
        for cookie in relevant {
            if cookie.name == "SAPISID" || cookie.name == "__Secure-3PAPISID" {
                sapisidValue = cookie.value
            }
            if cookie.name == "LOGIN_INFO" || cookie.name == "__Secure-3PAPISID" {
                sawLoginCookie = true
            }
        }
        guard sapisidValue != nil || sawLoginCookie else { return false }
        let header = relevant
            .filter { !$0.value.isEmpty }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
        guard !header.isEmpty else { return false }
        UserDefaults.standard.set(header, forKey: cookieKey)
        if let sapisidValue {
            UserDefaults.standard.set(sapisidValue, forKey: sapisidKey)
        }
        return true
    }

    static func signOut() {
        for key in [cookieKey, sapisidKey, channelIDKey, channelTitleKey, channelHandleKey] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    static func cache(profile: TrapTubeChannelProfile) {
        UserDefaults.standard.set(profile.channelID, forKey: channelIDKey)
        UserDefaults.standard.set(profile.title, forKey: channelTitleKey)
        if let handle = profile.handle {
            UserDefaults.standard.set(handle, forKey: channelHandleKey)
        }
    }

    /// SAPISIDHASH per YouTube's public web scheme:
    /// sha1("<timestamp> <SAPISID> <origin>"), sent as
    /// "SAPISIDHASH <timestamp>_<hex>".
    static func authorizationHeader() -> String? {
        guard let sapisid else { return nil }
        let timestamp = Int(Date().timeIntervalSince1970)
        let input = "\(timestamp) \(sapisid) \(origin)"
        let digest = Insecure.SHA1.hash(data: Data(input.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "SAPISIDHASH \(timestamp)_\(hex)"
    }

    static func applyAuth(to request: inout URLRequest) {
        if let cookieHeader {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        if let authValue = authorizationHeader() {
            request.setValue(authValue, forHTTPHeaderField: "Authorization")
            request.setValue(origin, forHTTPHeaderField: "X-Origin")
        }
    }

    /// Fetches the signed-in account's own channel through authenticated
    /// InnerTube calls. Tries the account-menu endpoint first, then the
    /// account browse page, parsing both defensively: any unexpected JSON
    /// shape just yields nil instead of a crash or a guessed identity.
    static func fetchMyChannel() async -> TrapTubeChannelProfile? {
        guard isSignedIn else { return nil }
        if let json = try? await TrapTubeInnerTube.post(
            endpoint: "https://www.youtube.com/youtubei/v1/account/getAccountMenu",
            body: [:]),
           let profile = parseChannelProfile(from: json) {
            cache(profile: profile)
            return profile
        }
        if let json = try? await TrapTubeInnerTube.post(
            endpoint: "https://www.youtube.com/youtubei/v1/browse",
            body: ["browseId": "FEaccount"]),
           let profile = parseChannelProfile(from: json) {
            cache(profile: profile)
            return profile
        }
        return nil
    }

    static func parseChannelProfile(from json: [String: Any]) -> TrapTubeChannelProfile? {
        var channelID: String?
        var handle: String?
        var accountName: String?
        var titleNearChannelID: String?

        func textValue(_ node: Any?) -> String? {
            guard let dict = node as? [String: Any] else { return nil }
            if let simple = dict["simpleText"] as? String { return simple }
            if let runs = dict["runs"] as? [[String: Any]] {
                let joined = runs.compactMap { $0["text"] as? String }.joined()
                return joined.isEmpty ? nil : joined
            }
            return nil
        }

        func walk(_ node: Any) {
            if let dict = node as? [String: Any] {
                if let id = dict["channelId"] as? String,
                   id.hasPrefix("UC"), id.count >= 20 {
                    if channelID == nil { channelID = id }
                    if titleNearChannelID == nil {
                        titleNearChannelID = textValue(dict["title"]) ?? textValue(dict["name"])
                    }
                }
                if let canonical = dict["canonicalBaseUrl"] as? String,
                   canonical.hasPrefix("/@"), handle == nil {
                    handle = String(canonical.dropFirst())
                }
                if let vanity = dict["vanityChannelUrl"] as? String,
                   let atRange = vanity.range(of: "/@"), handle == nil {
                    handle = String(vanity[atRange.upperBound...])
                }
                if accountName == nil {
                    if let name = textValue(dict["accountName"]) {
                        accountName = name
                    } else if let nameString = dict["accountName"] as? String, !nameString.isEmpty {
                        accountName = nameString
                    }
                }
                if handle == nil {
                    if let handleString = dict["handle"] as? String, handleString.hasPrefix("@") {
                        handle = String(handleString.dropFirst())
                    } else if let handleText = textValue(dict["handle"]), handleText.hasPrefix("@") {
                        handle = String(handleText.dropFirst())
                    } else if let channelHandle = dict["channelHandle"] as? String,
                              channelHandle.hasPrefix("@") {
                        handle = String(channelHandle.dropFirst())
                    }
                }
                for value in dict.values { walk(value) }
            } else if let array = node as? [Any] {
                for value in array { walk(value) }
            }
        }
        walk(json)

        guard channelID != nil || handle != nil || accountName != nil else { return nil }
        return TrapTubeChannelProfile(
            channelID: channelID ?? "",
            title: accountName ?? titleNearChannelID ?? "Your channel",
            handle: handle.map { "@\($0)" })
    }
}

struct TrapTubeResolvedPlayback {
    let title: String
    let author: String
    let item: AVPlayerItem
    let profileName: String
}

enum TrapTubeStreamResolver {
    // Each InnerTube client pairs with its own public app key; sending the
    // WEB key with the IOS/ANDROID contexts (or an outdated clientVersion)
    // makes YouTube reject the request outright ("Precondition check
    // failed"), which the app used to surface as an empty feed.
    private struct ClientProfile {
        let name: String
        let apiKey: String
        let userAgent: String
        let context: [String: Any]
    }

    private static let profiles: [ClientProfile] = [
        ClientProfile(
            name: "IOS",
            apiKey: "AIzaSyB-63vPrdThhKuerbB2N_l7Kwwcxj6yUAc",
            userAgent: "com.google.ios.youtube/20.45.3 (iPhone16,2; U; CPU iOS 18_1_0 like Mac OS X)",
            context: ["clientName": "IOS", "clientVersion": "20.45.3",
                      "deviceMake": "Apple", "deviceModel": "iPhone16,2",
                      "osName": "iPhone", "osVersion": "18.1.0", "hl": "en", "gl": "US"]),
        ClientProfile(
            name: "ANDROID",
            apiKey: "AIzaSyA8eiZmM1FaDVjRy-df2KTyQ_vz_yYM39w",
            userAgent: "com.google.android.youtube/20.45.38 (Linux; U; Android 14; en_US; Pixel 8) gzip",
            context: ["clientName": "ANDROID", "clientVersion": "20.45.38",
                      "androidSdkVersion": 34, "osName": "Android", "osVersion": "14",
                      "hl": "en", "gl": "US"]),
        ClientProfile(
            name: "WEB_EMBEDDED_PLAYER",
            apiKey: "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8",
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
        var failures: [String] = []
        for profile in profiles {
            do {
                let json = try await fetchPlayerResponse(videoID: videoID, profile: profile)
                if let playability = json["playabilityStatus"] as? [String: Any],
                   let status = playability["status"] as? String, status != "OK" {
                    lastPlayability = (playability["reason"] as? String) ?? status
                    continue
                }
                guard let streaming = json["streamingData"] as? [String: Any] else {
                    failures.append("\(profile.name): no streaming data in the response")
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

                // Every AVURLAsset carries the resolving profile's
                // User-Agent (plus a youtube.com Referer): googlevideo
                // rejects AVPlayer's default agent on some clients, which
                // used to fail track loading with a bare "unknown error".
                // The header-fields option key is written as its literal
                // string value - the current SDK no longer exports the
                // AVURLAssetHTTPHeaderFieldsKey constant to Swift.
                let headers: [String: String] = [
                    "User-Agent": profile.userAgent,
                    "Referer": "https://www.youtube.com/",
                ]

                // 1) A muxed MP4 (itag 22/18 style) is the simplest playable
                //    item - build AND validate it here, inside the profile
                //    loop, so a failure falls through to the next profile
                //    instead of dead-ending playback.
                let playableMuxed = muxed
                    .filter { $0.url != nil && $0.hasVideo && $0.hasAudio && $0.mime.contains("mp4") }
                    .sorted { $0.height > $1.height }
                if let best = playableMuxed.first, let urlString = best.url, let url = URL(string: urlString) {
                    let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
                    let videoTracks = try await asset.loadTracks(withMediaType: .video)
                    let audioTracks = try await asset.loadTracks(withMediaType: .audio)
                    guard !videoTracks.isEmpty, !audioTracks.isEmpty else {
                        throw TrapTubePlayerError.noPlayableFormat
                    }
                    return TrapTubeResolvedPlayback(title: title, author: author,
                                                    item: AVPlayerItem(asset: asset),
                                                    profileName: profile.name)
                }

                // 2) Otherwise combine the best MP4 video-only and audio-only
                //    adaptive formats into one composition; the composed
                //    audio track accepts the EQ tap like any other track.
                let videos = adaptive
                    .filter { $0.url != nil && $0.hasVideo && !$0.hasAudio && $0.mime.contains("mp4") && $0.mime.contains("avc1") }
                    .sorted { $0.height != $1.height ? $0.height > $1.height : $0.bitrate > $1.bitrate }
                let audios = adaptive
                    .filter { $0.url != nil && $0.hasAudio && !$0.hasVideo && $0.mime.contains("mp4") }
                    .sorted { $0.bitrate > $1.bitrate }
                if let video = videos.first(where: { $0.height <= 720 }) ?? videos.first,
                   let audio = audios.first,
                   let videoURL = URL(string: video.url ?? ""), let audioURL = URL(string: audio.url ?? "") {
                    let videoAsset = AVURLAsset(url: videoURL, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
                    let audioAsset = AVURLAsset(url: audioURL, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
                    guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first,
                          let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first else {
                        throw TrapTubePlayerError.noPlayableFormat
                    }
                    let videoDuration = try await videoAsset.load(.duration)
                    let audioDuration = try await audioAsset.load(.duration)
                    guard videoDuration.isValid, videoDuration.seconds > 0 else {
                        throw TrapTubePlayerError.noPlayableFormat
                    }
                    // Clamp each track's range to its OWN duration: the
                    // audio track is routinely a fraction shorter than the
                    // video track, and inserting the video-length range for
                    // it throws AVFoundationErrorDomain -11800 - literally
                    // "unknown error".
                    let videoRange = CMTimeRange(start: .zero, duration: videoDuration)
                    let audioRange = (audioDuration.isValid && audioDuration.seconds > 0)
                        ? CMTimeRange(start: .zero, duration: audioDuration.seconds < videoDuration.seconds ? audioDuration : videoDuration)
                        : videoRange
                    let composition = AVMutableComposition()
                    guard let compVideo = composition.addMutableTrack(withMediaType: .video,
                                                                      preferredTrackID: kCMPersistentTrackID_Invalid),
                          let compAudio = composition.addMutableTrack(withMediaType: .audio,
                                                                      preferredTrackID: kCMPersistentTrackID_Invalid) else {
                        throw TrapTubePlayerError.noPlayableFormat
                    }
                    try compVideo.insertTimeRange(videoRange, of: videoTrack, at: .zero)
                    try compAudio.insertTimeRange(audioRange, of: audioTrack, at: .zero)
                    return TrapTubeResolvedPlayback(title: title, author: author,
                                                    item: AVPlayerItem(asset: composition),
                                                    profileName: profile.name)
                }
                failures.append("\(profile.name): formats were present but none were directly playable")
            } catch {
                // Item construction (or the player request itself) failed
                // for this profile: record the real error and try the next
                // client instead of treating the first failure as final.
                failures.append("\(profile.name): \(TrapTubeErrorFormatting.describe(error))")
                NSLog("[TrapTube Player] Profile %@ failed: %@", profile.name,
                      TrapTubeErrorFormatting.describe(error))
                continue
            }
        }
        if !failures.isEmpty {
            throw TrapTubePlayerError.allProfilesFailed(failures.joined(separator: " | "))
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
        guard let endpoint = URL(string: "https://www.youtube.com/youtubei/v1/player?key=\(profile.apiKey)&prettyPrint=false") else {
            throw TrapTubePlayerError.network("bad endpoint")
        }
        var clientContext = profile.context
        if let visitor = await TrapTubeInnerTube.visitorData() {
            clientContext["visitorData"] = visitor
        }
        var body: [String: Any] = [
            "context": ["client": clientContext],
            "videoId": videoID,
            "racyCheckOk": true,
            "contentCheckOk": true,
        ]
        if profile.name == "WEB_EMBEDDED_PLAYER" {
            body["context"] = ["client": clientContext,
                               "thirdParty": ["embedUrl": "https://www.youtube.com/embed/\(videoID)"]]
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(profile.userAgent, forHTTPHeaderField: "User-Agent")
        TrapTubeYouTubeAuth.applyAuth(to: &request)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw TrapTubePlayerError.network("unexpected response")
            }
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                let serverMessage = ((json["error"] as? [String: Any])?["message"] as? String)
                    ?? "HTTP \(http.statusCode)"
                throw TrapTubePlayerError.network("YouTube refused the \(profile.name) player request: \(serverMessage)")
            }
            return json
        } catch let error as TrapTubePlayerError {
            throw error
        } catch {
            throw TrapTubePlayerError.network(TrapTubeErrorFormatting.describe(error))
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

/// Delegate bridge for AVPictureInPictureController. Kept as its own
/// non-isolated NSObject so the @MainActor player controller never has to
/// satisfy AVKit's delegate requirements directly; callbacks hop to the
/// main actor through the closures the controller installs.
private final class TrapTubePiPDelegateBridge: NSObject, AVPictureInPictureControllerDelegate {
    var onDidStart: (() -> Void)?
    var onDidStop: (() -> Void)?
    var onFailed: ((Error) -> Void)?

    func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController) {
        onDidStart?()
    }

    func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController) {
        onDidStop?()
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error) {
        onFailed?(error)
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler
        completionHandler: @escaping (Bool) -> Void) {
        // The inline player sheet is dismissed while PiP runs, so there is
        // no inline interface to restore into; ending PiP then tears the
        // retained session down cleanly (see onDidStop in the controller).
        completionHandler(false)
    }
}

@MainActor
final class TrapTubePlayerController: ObservableObject {
    let player = AVPlayer()
    private let hook = TrapTubeAudioHook()
    private var timeObserver: Any?
    private var itemStatusObservation: NSKeyValueObservation?
    private var loadTask: Task<Void, Never>?

    // Picture-in-picture state. The controller owns the PiP controller and
    // its delegate bridge; the inline view hands its AVPlayerLayer over via
    // registerPlayerLayer(_:) because PiP binds to the layer, not the view.
    private var pipController: AVPictureInPictureController?
    private let pipDelegate = TrapTubePiPDelegateBridge()
    private weak var playerLayer: AVPlayerLayer?
    @Published var isPictureInPictureActive = false
    /// Incremented every time PiP actually starts; the view observes this
    /// to dismiss the player sheet, which is the standard PiP behavior.
    @Published var pictureInPictureStartCount = 0

    /// While PiP is running the player sheet (and with it this controller's
    /// @StateObject owner) goes away, so the controller retains itself here
    /// until PiP stops; otherwise the AVPlayer, its EQ tap and the PiP
    /// session would all be released the moment the sheet dismisses.
    private static var retainedForPictureInPicture: TrapTubePlayerController?

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
        pipDelegate.onDidStart = { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isPictureInPictureActive = true
                self.pictureInPictureStartCount += 1
                NSLog("[TrapTube Player] Picture in Picture started")
            }
        }
        pipDelegate.onDidStop = { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isPictureInPictureActive = false
                NSLog("[TrapTube Player] Picture in Picture stopped")
                // If the sheet is gone, this controller only exists because
                // stop() retained it for the PiP session: finish teardown.
                if Self.retainedForPictureInPicture === self {
                    Self.retainedForPictureInPicture = nil
                    self.player.pause()
                    self.hook.invalidate()
                    self.itemStatusObservation?.invalidate()
                    self.itemStatusObservation = nil
                    if let timeObserver = self.timeObserver {
                        self.player.removeTimeObserver(timeObserver)
                        self.timeObserver = nil
                    }
                }
            }
        }
        pipDelegate.onFailed = { [weak self] error in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isPictureInPictureActive = false
                NSLog("[TrapTube Player] Picture in Picture failed to start: %@",
                      TrapTubeErrorFormatting.describe(error))
                TrapTubeEQManager.shared.setAttachmentStatus(
                    "Picture in Picture couldn't start (\(TrapTubeErrorFormatting.describe(error)))")
            }
        }
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
        // Picture in Picture requires a .playback audio session. The host
        // YouTube app very likely already runs one, so any failure here is
        // logged and playback continues untouched.
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        } catch {
            NSLog("[TrapTube Player] Audio session setup failed (continuing): %@",
                  TrapTubeErrorFormatting.describe(error))
        }
        loadTask?.cancel()
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        isLoading = true
        errorMessage = nil
        title = ""
        author = ""
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                // resolve() now builds and validates the AVPlayerItem
                // itself, per client profile, so a success here means a
                // real item exists and the EQ hook can observe it.
                let resolved = try await TrapTubeStreamResolver.resolve(videoID: videoID)
                guard !Task.isCancelled else { return }
                self.title = resolved.title
                self.author = resolved.author
                self.observeItemStatus(resolved.item)
                self.player.replaceCurrentItem(with: resolved.item)
                self.isLoading = false
                self.player.play()
            } catch {
                guard !Task.isCancelled else { return }
                self.isLoading = false
                self.errorMessage = TrapTubeErrorFormatting.playbackFailure(error)
                // No item ever existed, so no EQ attach could start: say
                // so plainly instead of leaving the status line sitting
                // on a stale "attaching..." from the hook probe.
                TrapTubeEQManager.shared.setAttachmentStatus("Playback failed before EQ could attach")
                NSLog("[TrapTube Player] Load failed for %@: %@", videoID,
                      TrapTubeErrorFormatting.describe(error))
            }
        }
    }

    /// An item can also fail AFTER creation (network drop, a stream URL
    /// the player itself rejects). Surface that failure with its real
    /// domain/code instead of a bare "unknown error", and move the EQ
    /// status off "attaching...".
    private func observeItemStatus(_ item: AVPlayerItem) {
        itemStatusObservation?.invalidate()
        itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self, weak item] _, _ in
            guard let item, item.status == .failed else { return }
            let itemError = item.error
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let itemError {
                    self.errorMessage = TrapTubeErrorFormatting.playbackFailure(itemError)
                    NSLog("[TrapTube Player] Item failed after creation: %@",
                          TrapTubeErrorFormatting.describe(itemError))
                } else {
                    self.errorMessage = "Playback failed (AVPlayerItem status became .failed with no error object)"
                }
                self.isLoading = false
                TrapTubeEQManager.shared.setAttachmentStatus("Playback failed before EQ could attach")
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

    // MARK: Fullscreen + Picture in Picture

    /// The inline layer view reports its AVPlayerLayer here; PiP binds to
    /// that layer, so this is the controller's only handle on it.
    func registerPlayerLayer(_ layer: AVPlayerLayer) {
        playerLayer = layer
        setupPictureInPictureIfNeeded()
    }

    private func setupPictureInPictureIfNeeded() {
        guard pipController == nil,
              let layer = playerLayer,
              AVPictureInPictureController.isPictureInPictureSupported() else { return }
        guard let pip = AVPictureInPictureController(playerLayer: layer) else {
            NSLog("[TrapTube Player] AVPictureInPictureController init returned nil")
            return
        }
        pip.delegate = pipDelegate
        pip.requiresLinearPlayback = false
        pip.canStartPictureInPictureAutomaticallyFromInline = false
        pipController = pip
    }

    /// PiP button action. Never a silent dead button: every failure path
    /// lands on the EQ status line and in the log.
    func togglePictureInPicture() {
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            TrapTubeEQManager.shared.setAttachmentStatus("Picture in Picture isn't supported on this device")
            return
        }
        setupPictureInPictureIfNeeded()
        guard let pip = pipController else {
            NSLog("[TrapTube Player] No PiP controller available for toggle")
            TrapTubeEQManager.shared.setAttachmentStatus("Picture in Picture isn't ready yet - try again in a moment")
            return
        }
        if pip.isPictureInPictureActive {
            pip.stopPictureInPicture()
        } else if pip.isPictureInPicturePossible {
            pip.startPictureInPicture()
        } else {
            NSLog("[TrapTube Player] PiP toggled while not possible (item not ready)")
            TrapTubeEQManager.shared.setAttachmentStatus("Picture in Picture is available once the video is playing")
        }
    }

    /// Native fullscreen: Apple's own AVPlayerViewController UI (with its
    /// own PiP affordance) over the SAME AVPlayer, so playback position,
    /// playing state and the EQ tap all carry across and survive the
    /// return to the inline view. No presenter -> safe no-op.
    func presentFullscreen() {
        guard let presenter = Self.topViewController() else {
            NSLog("[TrapTube Player] Fullscreen requested but no presenter found")
            return
        }
        let fullscreen = AVPlayerViewController()
        fullscreen.player = player
        fullscreen.showsPlaybackControls = true
        fullscreen.allowsPictureInPicturePlayback = true
        fullscreen.modalPresentationStyle = .fullScreen
        presenter.present(fullscreen, animated: true)
    }

    /// Topmost presented view controller in the foreground scene, found by
    /// the same scene/root walk TrapTubeCurrentVideo uses in this file.
    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive })
                ?? scenes.first,
              var top = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController
                ?? scene.windows.first?.rootViewController else { return nil }
        while let presented = top.presentedViewController { top = presented }
        return top
    }

    func stop() {
        // PiP is live: the sheet is dismissing BECAUSE PiP started. Keep
        // the player, its EQ tap and this controller alive (self-retained)
        // until the PiP delegate reports the session has fully stopped.
        if isPictureInPictureActive || pipController?.isPictureInPictureActive == true {
            Self.retainedForPictureInPicture = self
            loadTask?.cancel()
            NSLog("[TrapTube Player] View dismissed during PiP; session retained until PiP stops")
            return
        }
        loadTask?.cancel()
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        pipController?.delegate = nil
        pipController = nil
        player.pause()
        hook.invalidate()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
    }
}

// MARK: - Player layer

private struct TrapTubePlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    /// Hands the concrete AVPlayerLayer to the controller, which needs it
    /// to bind AVPictureInPictureController.
    var onLayerAvailable: ((AVPlayerLayer) -> Void)?

    final class LayerView: UIView {
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        override class var layerClass: AnyClass { AVPlayerLayer.self }
    }

    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        onLayerAvailable?(view.playerLayer)
        return view
    }

    func updateUIView(_ uiView: LayerView, context: Context) {
        uiView.playerLayer.player = player
        onLayerAvailable?(uiView.playerLayer)
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
        .onChange(of: controller.pictureInPictureStartCount) { _ in
            // Standard PiP behavior: once the video is floating, the
            // inline player sheet steps out of the way. The controller
            // retains the session (see stop()) so playback + EQ continue.
            dismiss()
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
            TrapTubePlayerLayerView(player: controller.player,
                                    onLayerAvailable: { controller.registerPlayerLayer($0) })
            VStack {
                Spacer()
                HStack(spacing: 8) {
                    Spacer()
                    Button { controller.togglePictureInPicture() } label: {
                        Image(systemName: controller.isPictureInPictureActive ? "pip.exit" : "pip.enter")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    Button { controller.presentFullscreen() } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.trailing, 10)
                .padding(.bottom, 10)
            }
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

/// One-tap EQ presets for the panel. Band gains are dB for the manager's
/// 16 frequencies in order (31, 62, 125, 250, 500, 750, 1k, 1.5k, 2k, 3k,
/// 4k, 6k, 8k, 10k, 12k, 16k); every value sits inside the manager's
/// clamps (±12 dB bands, 0-20 dB bass, 0-200% master), so applying one is
/// just the normal setters, live on the playing stream.
struct TrapTubeEQPreset {
    let name: String
    let bandGains: [Float]
    let bass: Float
    let master: Float

    static let flat = TrapTubeEQPreset(
        name: "Flat",
        bandGains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
        bass: 0, master: 100)
    static let trap = TrapTubeEQPreset(
        name: "Trap",
        bandGains: [7, 6, 4, 1, -1, -1, 0, 1, 2, 2, 3, 3, 4, 4, 3, 2],
        bass: 8, master: 105)
    static let drill = TrapTubeEQPreset(
        name: "Drill",
        bandGains: [8, 7, 5, 2, 0, -2, -1, 0, 1, 2, 3, 4, 5, 5, 4, 3],
        bass: 10, master: 105)
    static let hipHop = TrapTubeEQPreset(
        name: "Hip-Hop",
        bandGains: [5, 5, 4, 2, 1, 0, 1, 2, 3, 3, 2, 2, 2, 1, 0, 0],
        bass: 6, master: 105)
    static let bass = TrapTubeEQPreset(
        name: "Bass",
        bandGains: [10, 9, 7, 4, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
        bass: 14, master: 95)
    static let clarity = TrapTubeEQPreset(
        name: "Clarity",
        bandGains: [-2, -2, -1, -3, -2, 0, 1, 2, 3, 4, 4, 3, 3, 4, 4, 5],
        bass: 2, master: 110)

    /// Genre-first order; Flat sits last as the reset-style option.
    static let all: [TrapTubeEQPreset] = [.trap, .drill, .hipHop, .bass, .clarity, .flat]
}

struct TrapTubeEqualizerPanel: View {
    @State private var streamStatus = "Not attached yet"
    @State private var selectedPresetName: String? =
        UserDefaults.standard.string(forKey: "TrapTube.EQ.Preset")
    /// TrapTubeEQSliderRow snapshots its value at init, so after a preset
    /// is applied programmatically this token is bumped and used as the
    /// slider cards' .id(...) to force fresh rows showing the new values.
    @State private var eqRefreshToken = 0
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

    /// Applies a preset live through the manager setters, remembers it,
    /// and forces the (snapshot-based) slider rows to rebuild so the
    /// sliders visibly jump to the preset's values.
    private func applyPreset(_ preset: TrapTubeEQPreset) {
        for (index, gain) in preset.bandGains.enumerated() {
            manager.setBandGain(gain, at: index)
        }
        manager.setBassBoost(preset.bass)
        manager.setMasterGainPercent(preset.master)
        selectedPresetName = preset.name
        UserDefaults.standard.set(preset.name, forKey: "TrapTube.EQ.Preset")
        eqRefreshToken += 1
    }

    /// A manual slider move means the sound no longer matches any preset.
    private func noteManualEQChange() {
        if selectedPresetName != nil {
            selectedPresetName = nil
            UserDefaults.standard.removeObject(forKey: "TrapTube.EQ.Preset")
        }
    }

    private var presetsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("PRESETS").font(.caption.weight(.black))
                .tracking(1.5).foregroundStyle(accent)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(TrapTubeEQPreset.all, id: \.name) { preset in
                        Button { applyPreset(preset) } label: {
                            Text(preset.name)
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(selectedPresetName == preset.name
                                            ? AnyShapeStyle(accent)
                                            : AnyShapeStyle(.ultraThinMaterial),
                                            in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Text("One tap sets all 16 bands, bass and master for the sound you want - tweak any slider afterwards to make it yours.")
                .font(.caption).foregroundStyle(Color.white.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .ttGlassCard(cornerRadius: 18)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Equalizer").font(.headline.weight(.bold)).foregroundStyle(.white)
                    Text("A 16-band graphic equalizer with bass boost and master gain.")
                        .font(.caption).foregroundStyle(Color.white.opacity(0.55))
                }
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
                        Button("Reset EQ to flat") { applyPreset(.flat) }
                            .font(.subheadline.weight(.bold)).foregroundStyle(accent)
                    }
                    .padding(16)
                    .ttGlassCard(cornerRadius: 18)

                    presetsCard

                    VStack(alignment: .leading, spacing: 16) {
                        TrapTubeEQSliderRow(title: "Bass boost", value: manager.bassBoostDecibels,
                                            range: 0...20, suffix: " dB") {
                            manager.setBassBoost($0)
                            noteManualEQChange()
                        }
                        TrapTubeEQSliderRow(title: "Master gain", value: manager.masterGainPercent,
                                            range: 0...200, suffix: "%") {
                            manager.setMasterGainPercent($0)
                            noteManualEQChange()
                        }
                    }
                    .padding(16)
                    .ttGlassCard(cornerRadius: 18)
                    .id(eqRefreshToken)

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
                                noteManualEQChange()
                            }
                        }
                    }
                    .padding(16)
                    .ttGlassCard(cornerRadius: 18)
                    .id(eqRefreshToken)

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
// A YouTube-style feed and search, backed by the same InnerTube interface
// the resolver uses, on the WEB client. Signed out, YouTube serves an
// empty home grid to every client, so the home view is category searches
// (Music first); every row plays in the native player.

struct TrapTubeFeedItem: Identifiable {
    let videoID: String
    let title: String
    let channel: String
    let duration: String?
    let meta: String
    let thumbnailURL: URL?
    var id: String { videoID }
}

struct TrapTubeFeedCategory: Identifiable {
    let name: String
    let query: String
    var id: String { name }
}

@MainActor
final class TrapTubeFeedModel: ObservableObject {
    @Published var items: [TrapTubeFeedItem] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var isSearching = false
    @Published var selectedCategory = "Music"

    // Signed out, YouTube serves an empty home grid to every client, so the
    // feed's home is a row of category searches (real results, WEB client)
    // with Music first — this is a music app. Search covers everything else.
    static let categories: [TrapTubeFeedCategory] = [
        TrapTubeFeedCategory(name: "Music", query: "music"),
        TrapTubeFeedCategory(name: "Gaming", query: "gaming"),
        TrapTubeFeedCategory(name: "Podcasts", query: "podcasts"),
        TrapTubeFeedCategory(name: "Live", query: "live streams"),
        TrapTubeFeedCategory(name: "Comedy", query: "comedy"),
        TrapTubeFeedCategory(name: "News", query: "news"),
        TrapTubeFeedCategory(name: "Sports", query: "sports highlights"),
        TrapTubeFeedCategory(name: "Tech", query: "technology"),
    ]

    var sectionTitle: String {
        if isSearching { return "Results" }
        return selectedCategory == "Music" ? "Popular music" : selectedCategory
    }

    private var continuation: String?
    private var currentQuery: String?
    private var generation = 0

    func loadHome() async {
        await loadCategory(Self.categories[0])
    }

    func loadCategory(_ category: TrapTubeFeedCategory) async {
        selectedCategory = category.name
        currentQuery = category.query
        isSearching = false
        await load(reset: true) { token in
            token == nil
                ? ["query": category.query, "params": "EgIQAQ%3D%3D"]
                : ["query": category.query, "continuation": token as Any]
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
        guard continuation != nil, !isLoading, let query = currentQuery else { return }
        await load(reset: false) { token in
            ["query": query, "continuation": token as Any]
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
            let endpoint = "https://www.youtube.com/youtubei/v1/search"
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

actor TrapTubeVisitorDataStore {
    private var cached: String?
    private var fetched = false

    func value() async -> String? {
        if fetched { return cached }
        fetched = true
        guard let url = URL(string: "https://www.youtube.com/youtubei/v1/visitor_id?key=AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8&prettyPrint=false") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(TrapTubeInnerTube.webUserAgent, forHTTPHeaderField: "User-Agent")
        let body: [String: Any] = ["context": ["client": TrapTubeInnerTube.webContext]]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let context = json["responseContext"] as? [String: Any],
              let visitor = context["visitorData"] as? String else {
            return nil
        }
        cached = visitor
        return visitor
    }
}

enum TrapTubeInnerTube {
    // The feed and search run on the WEB client: it is the one surface that
    // answers signed-out requests with real results. The signed-out home
    // grid (FEwhat_to_watch) comes back empty for every client without
    // account cookies, so the feed's home is category searches instead.
    static let webUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
    static let webContext: [String: Any] = ["clientName": "WEB", "clientVersion": "2.20241126.01.00",
                                            "hl": "en", "gl": "US"]
    private static let visitorStore = TrapTubeVisitorDataStore()

    static func visitorData() async -> String? {
        await visitorStore.value()
    }

    static func post(endpoint: String, body: [String: Any]) async throws -> [String: Any] {
        guard let url = URL(string: "\(endpoint)?key=AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8&prettyPrint=false") else {
            throw TrapTubePlayerError.network("bad endpoint")
        }
        var clientContext = webContext
        if let visitor = await visitorData() {
            clientContext["visitorData"] = visitor
        }
        var fullBody = body
        fullBody["context"] = ["client": clientContext]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(webUserAgent, forHTTPHeaderField: "User-Agent")
        TrapTubeYouTubeAuth.applyAuth(to: &request)
        request.httpBody = try JSONSerialization.data(withJSONObject: fullBody)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TrapTubePlayerError.network("unexpected response")
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let serverMessage = ((json["error"] as? [String: Any])?["message"] as? String)
                ?? "HTTP \(http.statusCode)"
            throw TrapTubePlayerError.network("YouTube refused the request: \(serverMessage)")
        }
        return json
    }
}

// MARK: - Sign-in sheet and profile (Player section)
//
// Google is known to sometimes block embedded-browser logins ("This
// browser or app may not be secure"). That path is handled honestly: the
// sheet explains the block and that the main YouTube app's sign-in is a
// separate system that does not carry cookies into the Player.

private struct TrapTubeSignInWebView: UIViewRepresentable {
    let onCookies: ([HTTPCookie]) -> Void
    let onBlocked: () -> Void

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: TrapTubeSignInWebView
        weak var webView: WKWebView?
        var pollTimer: Timer?
        var blockedReported = false

        init(parent: TrapTubeSignInWebView) {
            self.parent = parent
        }

        func startPolling() {
            pollTimer?.invalidate()
            pollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
                self?.checkCookies()
            }
        }

        func stopPolling() {
            pollTimer?.invalidate()
            pollTimer = nil
        }

        func checkCookies() {
            webView?.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                self?.parent.onCookies(cookies)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            checkCookies()
            webView.evaluateJavaScript("document.body ? document.body.innerText : ''") { [weak self] result, _ in
                guard let self, !self.blockedReported,
                      let text = result as? String else { return }
                if text.contains("may not be secure") || text.contains("Couldn't sign you in") {
                    self.blockedReported = true
                    self.parent.onBlocked()
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        context.coordinator.startPolling()
        if let url = URL(string: "https://www.youtube.com/signin") {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.parent = self
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.stopPolling()
    }
}

struct TrapTubeSignInView: View {
    @State private var signedIn = TrapTubeYouTubeAuth.isSignedIn
    @State private var blockedMessage: String?
    @State private var statusText = "Sign in with the Google account you use on YouTube. This sign-in is only for the TrapTube Player - the main YouTube app's sign-in is separate."
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
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(signedIn ? "YouTube account" : "Sign in to YouTube")
                        .font(.headline.weight(.bold)).foregroundStyle(.white)
                    Text(statusText)
                        .font(.caption).foregroundStyle(Color.white.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .font(.subheadline.weight(.bold)).foregroundStyle(accent)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            if signedIn {
                VStack(spacing: 12) {
                    Image(systemName: "person.crop.circle.badge.checkmark")
                        .font(.system(size: 44)).foregroundStyle(accent)
                    Text("Signed in")
                        .font(.headline.weight(.bold)).foregroundStyle(.white)
                    Text("The Player feed, search and playback now use your account. Use My Channel to see your profile.")
                        .font(.subheadline).foregroundStyle(Color.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    Button("Sign out of the Player") {
                        TrapTubeYouTubeAuth.signOut()
                        signedIn = false
                        statusText = "Signed out of the TrapTube Player. The main YouTube app is unaffected."
                    }
                    .font(.subheadline.weight(.bold)).foregroundStyle(accent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let blockedMessage {
                VStack(spacing: 12) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 40)).foregroundStyle(accent)
                    Text(blockedMessage)
                        .font(.subheadline).foregroundStyle(Color.white.opacity(0.75))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Try again") { self.blockedMessage = nil }
                        .font(.subheadline.weight(.bold)).foregroundStyle(accent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TrapTubeSignInWebView(onCookies: { cookies in
                    if TrapTubeYouTubeAuth.store(cookies: cookies) {
                        signedIn = true
                        statusText = "Signed in to the TrapTube Player."
                    }
                }, onBlocked: {
                    blockedMessage = "Sign-in was blocked by Google in this embedded browser - Google sometimes refuses logins from in-app web views. The main YouTube app's sign-in is separate and doesn't carry over to the Player, so the Player will keep working signed-out until Google allows this login."
                })
            }
        }
        .background(Color(red: 0.03, green: 0.03, blue: 0.045).ignoresSafeArea())
        .preferredColorScheme(.dark)
    }
}

struct TrapTubeProfileView: View {
    @State private var profile: TrapTubeChannelProfile? = TrapTubeYouTubeAuth.cachedProfile
    @State private var isLoading = false
    @State private var message: String?
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
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                Text("My Channel")
                    .font(.headline.weight(.bold)).foregroundStyle(.white)
                Spacer()
                Button("Done") { dismiss() }
                    .font(.subheadline.weight(.bold)).foregroundStyle(accent)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            VStack(spacing: 14) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 56)).foregroundStyle(accent)
                if let profile {
                    Text(profile.title)
                        .font(.title3.weight(.bold)).foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                    if let handle = profile.handle {
                        Text(handle)
                            .font(.subheadline).foregroundStyle(Color.white.opacity(0.6))
                    }
                    if let url = profile.channelURL {
                        Button {
                            UIApplication.shared.open(url)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "play.rectangle.fill")
                                Text("Open in YouTube")
                            }
                            .font(.subheadline.weight(.bold)).foregroundStyle(.white)
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(accent, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                } else if isLoading {
                    ProgressView().tint(.white)
                    Text("Loading your channel…")
                        .font(.subheadline).foregroundStyle(Color.white.opacity(0.6))
                } else {
                    Text(message ?? "We couldn't read your channel details from YouTube yet. You're still signed in - try Refresh in a moment.")
                        .font(.subheadline).foregroundStyle(Color.white.opacity(0.65))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Refresh") { Task { await loadProfile() } }
                    .font(.subheadline.weight(.bold)).foregroundStyle(accent)
                Spacer(minLength: 0)
            }
            .padding(.top, 24)
            .frame(maxWidth: .infinity)
        }
        .background(Color(red: 0.03, green: 0.03, blue: 0.045).ignoresSafeArea())
        .preferredColorScheme(.dark)
        .task { await loadProfile() }
    }

    private func loadProfile() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        if let fetched = await TrapTubeYouTubeAuth.fetchMyChannel() {
            profile = fetched
            message = nil
        } else if profile == nil {
            message = "We couldn't read your channel details from YouTube yet. You're still signed in - try Refresh in a moment."
        }
    }
}

struct TrapTubePlayerHomeView: View {
    @StateObject private var feed = TrapTubeFeedModel()
    @State private var searchText = ""
    @State private var request: TrapTubePlayerRequest?
    @State private var detectedID: String?
    @State private var showSignIn = false
    @State private var showProfile = false
    @State private var authSignedIn = TrapTubeYouTubeAuth.isSignedIn

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
            accountBar
            if !feed.isSearching {
                categoryChips
            }
            if let detectedID {
                detectedButton(detectedID)
            }
            content
        }
        .task {
            authSignedIn = TrapTubeYouTubeAuth.isSignedIn
            if feed.items.isEmpty { await feed.loadHome() }
            detectedID = TrapTubeCurrentVideo.detectVideoID()
        }
        .fullScreenCover(item: $request) { request in
            TrapTubeNativePlayerView(request: request)
        }
        .sheet(isPresented: $showSignIn, onDismiss: {
            let nowSignedIn = TrapTubeYouTubeAuth.isSignedIn
            if nowSignedIn != authSignedIn {
                authSignedIn = nowSignedIn
                Task { await feed.loadHome() }
            }
        }) {
            TrapTubeSignInView()
        }
        .sheet(isPresented: $showProfile) {
            TrapTubeProfileView()
        }
    }

    private var accountBar: some View {
        HStack(spacing: 8) {
            Button {
                showSignIn = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: authSignedIn ? "person.crop.circle.badge.checkmark" : "person.crop.circle")
                    Text(authSignedIn ? "Account · Signed in" : "Sign in")
                        .lineLimit(1)
                }
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
            }
            .buttonStyle(.plain)

            Button {
                if authSignedIn {
                    showProfile = true
                } else {
                    showSignIn = true
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "rectangle.stack.person.crop")
                    Text("My Channel")
                        .lineLimit(1)
                }
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(authSignedIn ? accent : Color.white.opacity(0.08), in: Capsule())
            }
            .buttonStyle(.plain)

            Text(authSignedIn ? "Signed in" : "Not signed in")
                .font(.caption)
                .foregroundStyle(Color.white.opacity(0.45))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
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

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(TrapTubeFeedModel.categories) { category in
                    let selected = feed.selectedCategory == category.name
                    Button {
                        Task { await feed.loadCategory(category) }
                    } label: {
                        Text(category.name)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(selected ? .white : Color.white.opacity(0.65))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(selected ? accent : Color.white.opacity(0.08), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
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
                    Text(feed.sectionTitle.uppercased())
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
