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

/// Mutable bag for the recursive account-JSON extraction in
/// TrapTubeYouTubeAuth (kept at file scope so the extractor can be a
/// plain static function).
private struct TrapTubeAccountFields {
    var channelID: String?
    var handle: String?
    var accountName: String?
    var titleNearChannelID: String?
}

enum TrapTubeYouTubeAuth {
    private static let cookieKey = "TrapTube.YouTube.CookieHeader"
    private static let sapisidKey = "TrapTube.YouTube.SAPISID"
    private static let channelIDKey = "TrapTube.YouTube.ChannelID"
    private static let channelTitleKey = "TrapTube.YouTube.ChannelTitle"
    private static let channelHandleKey = "TrapTube.YouTube.ChannelHandle"
    private static let staleKey = "TrapTube.YouTube.SessionStale"
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

    /// Set when YouTube answers an authenticated request with 401/403:
    /// the saved session is stale and the UI should say so (and prompt a
    /// fresh sign-in) instead of silently retrying forever (Round 14).
    static var isSessionStale: Bool { UserDefaults.standard.bool(forKey: staleKey) }

    static func noteAuthStatus(_ status: Int) {
        if status == 401 || status == 403 {
            UserDefaults.standard.set(true, forKey: staleKey)
        } else if status == 200 {
            UserDefaults.standard.removeObject(forKey: staleKey)
        }
    }

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
        // Round 14 hardening. The old code built the Cookie header from
        // every youtube.com AND google.com cookie (a browser never sends
        // google.com cookies to youtube.com, and duplicate names could
        // appear) and picked the SAPISID value by cookie-array order -
        // whichever of SAPISID / __Secure-3PAPISID happened to come last
        // in WKHTTPCookieStore's unordered list won. Now: the header is
        // exactly the youtube.com cookie set, one value per name, and
        // the SAPISID value is chosen by a fixed priority.
        let youtubeCookies = cookies.filter { $0.domain.contains("youtube.com") }
        let googleCookies = cookies.filter { $0.domain.contains("google.com") }
        func sapisidValue(in list: [HTTPCookie]) -> String? {
            for name in ["__Secure-3PAPISID", "SAPISID", "__Secure-1PAPISID"] {
                if let cookie = list.first(where: { $0.name == name && !$0.value.isEmpty }) {
                    return cookie.value
                }
            }
            return nil
        }
        let sapisid = sapisidValue(in: youtubeCookies) ?? sapisidValue(in: googleCookies)
        let sawLoginCookie = (youtubeCookies + googleCookies).contains {
            $0.name == "LOGIN_INFO" || $0.name == "__Secure-3PAPISID"
        }
        guard sapisid != nil || sawLoginCookie else { return false }
        // One value per cookie name, first occurrence wins. The
        // youtube.com set is what a browser sends to youtubei; the
        // google.com set is only a fallback for a capture that somehow
        // contains no youtube.com cookies at all.
        func headerValue(from list: [HTTPCookie]) -> String {
            var seenNames = Set<String>()
            return list.filter { !$0.value.isEmpty }.compactMap { cookie in
                seenNames.insert(cookie.name).inserted ? "\(cookie.name)=\(cookie.value)" : nil
            }.joined(separator: "; ")
        }
        var header = headerValue(from: youtubeCookies)
        if header.isEmpty { header = headerValue(from: googleCookies) }
        guard !header.isEmpty else { return false }
        UserDefaults.standard.set(header, forKey: cookieKey)
        if let sapisid {
            UserDefaults.standard.set(sapisid, forKey: sapisidKey)
        }
        UserDefaults.standard.removeObject(forKey: staleKey)
        return true
    }

    static func signOut() {
        for key in [cookieKey, sapisidKey, channelIDKey, channelTitleKey, channelHandleKey, staleKey] {
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
            // The web client sends its account index on every
            // authenticated call; the account endpoints expect it.
            request.setValue("0", forHTTPHeaderField: "X-Goog-AuthUser")
        }
    }

    /// Outcome of a My Channel fetch: the profile when one could be
    /// read, plus the last HTTP status/detail seen, so the sheet can
    /// show real evidence on failure instead of "try Refresh"
    /// (Round 14).
    struct ChannelFetchOutcome {
        let profile: TrapTubeChannelProfile?
        let lastStatus: Int?
        let lastDetail: String
    }

    static func fetchMyChannel() async -> TrapTubeChannelProfile? {
        await fetchMyChannelDetailed().profile
    }

    /// Fetches the signed-in account's own channel, trying in order:
    /// (i) account/getAccountMenu on the WEB client, (ii) browse
    /// FEaccount on the WEB client, (iii) an authenticated scrape of
    /// the /feed/you page HTML, whose embedded data carries the
    /// account's own channel metadata. The Round 11 version stopped at
    /// two `try?`-swallowed calls whose parser never saw the renderer
    /// shapes these endpoints actually answer with, so a signed-in user
    /// got "couldn't read your channel details" with no evidence why.
    static func fetchMyChannelDetailed() async -> ChannelFetchOutcome {
        guard isSignedIn else {
            return ChannelFetchOutcome(profile: nil, lastStatus: nil,
                                       lastDetail: "not signed in")
        }
        var lastStatus: Int?
        var lastDetail = "no attempt was made"

        let attempts: [(name: String, endpoint: String, body: [String: Any])] = [
            ("account menu", "https://www.youtube.com/youtubei/v1/account/getAccountMenu", [:]),
            ("account page", "https://www.youtube.com/youtubei/v1/browse", ["browseId": "FEaccount"]),
        ]
        for attempt in attempts {
            switch await TrapTubeInnerTube.postAccount(endpoint: attempt.endpoint, body: attempt.body) {
            case .success(let json):
                lastStatus = 200
                if let profile = parseChannelProfile(from: json) {
                    cache(profile: profile)
                    return ChannelFetchOutcome(profile: profile, lastStatus: 200,
                                               lastDetail: attempt.name)
                }
                lastDetail = "\(attempt.name): YouTube answered 200 but the response held no readable channel identity"
                NSLog("[TrapTube Account] %@ answered 200 with no parseable identity", attempt.name)
            case .failure(let status, let detail):
                if let status { lastStatus = status }
                lastDetail = "\(attempt.name): \(detail)"
                NSLog("[TrapTube Account] %@ failed: %@", attempt.name, detail)
            }
        }

        if let page = await fetchAccountPageHTML() {
            lastStatus = page.status
            if let profile = parseChannelProfile(fromHTML: page.html) {
                cache(profile: profile)
                return ChannelFetchOutcome(profile: profile, lastStatus: page.status,
                                           lastDetail: "account page HTML")
            }
            lastDetail = "account page HTML (HTTP \(page.status)): no channel identity found in the page"
        } else {
            lastDetail = "account page HTML: the page request failed before any response"
        }
        return ChannelFetchOutcome(profile: nil, lastStatus: lastStatus, lastDetail: lastDetail)
    }

    /// Authenticated GET of the "You" page for the HTML scrape variant.
    /// Cookies only - this is a plain page load, not an InnerTube call.
    private static func fetchAccountPageHTML() async -> (html: String, status: Int)? {
        guard let url = URL(string: "https://www.youtube.com/feed/you") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(TrapTubeInnerTube.webUserAgent, forHTTPHeaderField: "User-Agent")
        if let cookieHeader {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let html = String(data: data, encoding: .utf8) else { return nil }
            return (html, status)
        } catch {
            NSLog("[TrapTube Account] /feed/you page fetch failed: %@",
                  TrapTubeErrorFormatting.describe(error))
            return nil
        }
    }

    /// Extracts the account identity from a signed-in page's HTML. The
    /// embedded initial data for the account's own channel pairs
    /// "externalId" (the UC id) with "vanityChannelUrl" (the @handle)
    /// in its channel metadata, and the account header carries
    /// "accountName" / "channelHandleText".
    static func parseChannelProfile(fromHTML html: String) -> TrapTubeChannelProfile? {
        func firstMatch(_ pattern: String, in text: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range])
        }
        let channelID = firstMatch(#""externalId"\s*:\s*"(UC[A-Za-z0-9_-]{22})""#, in: html)
        var handle = firstMatch(#""vanityChannelUrl"\s*:\s*"https?:\\/\\/www\.youtube\.com\\/(@[A-Za-z0-9_.\-]+)""#, in: html)
        if handle == nil {
            handle = firstMatch(#""channelHandleText"\s*:\s*\{\s*"runs"\s*:\s*\[\s*\{\s*"text"\s*:\s*"(@[A-Za-z0-9_.\-]+)""#, in: html)
        }
        var title = firstMatch(#""accountName"\s*:\s*\{\s*"simpleText"\s*:\s*"([^"]{1,80})""#, in: html)
        if title == nil, let channelID, let idRange = html.range(of: channelID) {
            // The metadata block pairs "title" with the externalId:
            // search the window around the id instead of the whole page
            // (the page is full of other channels' titles).
            let lower = html.index(idRange.lowerBound, offsetBy: -800, limitedBy: html.startIndex) ?? html.startIndex
            let upper = html.index(idRange.upperBound, offsetBy: 800, limitedBy: html.endIndex) ?? html.endIndex
            title = firstMatch(#""title"\s*:\s*"([^"]{1,80})""#, in: String(html[lower..<upper]))
        }
        guard channelID != nil || handle != nil else { return nil }
        return TrapTubeChannelProfile(channelID: channelID ?? "",
                                      title: title ?? "Your channel",
                                      handle: handle)
    }

    static func parseChannelProfile(from json: [String: Any]) -> TrapTubeChannelProfile? {
        // Identity is collected globally first, then from any
        // accountItem subtrees (the FEaccount channel-switcher rows);
        // scoped values win, since the global tree of an account page
        // can also mention other channels.
        var global = TrapTubeAccountFields()
        collectAccountFields(json, into: &global)
        var subtrees: [Any] = []
        collectAccountItemSubtrees(json, into: &subtrees)
        var scoped = TrapTubeAccountFields()
        for subtree in subtrees {
            collectAccountFields(subtree, into: &scoped)
        }
        let channelID = scoped.channelID ?? global.channelID
        let handle = scoped.handle ?? global.handle
        let accountName = scoped.accountName ?? global.accountName
        let titleNearChannelID = scoped.titleNearChannelID ?? global.titleNearChannelID
        guard channelID != nil || handle != nil || accountName != nil else { return nil }
        return TrapTubeChannelProfile(
            channelID: channelID ?? "",
            title: accountName ?? titleNearChannelID ?? "Your channel",
            handle: handle.map { "@\($0)" })
    }

    private static func accountTextValue(_ node: Any?) -> String? {
        guard let dict = node as? [String: Any] else { return nil }
        if let simple = dict["simpleText"] as? String { return simple }
        if let content = dict["content"] as? String { return content }
        if let runs = dict["runs"] as? [[String: Any]] {
            let joined = runs.compactMap { $0["text"] as? String }.joined()
            return joined.isEmpty ? nil : joined
        }
        return nil
    }

    private static func collectAccountFields(_ node: Any, into found: inout TrapTubeAccountFields) {
        if let dict = node as? [String: Any] {
            if let id = dict["channelId"] as? String,
               id.hasPrefix("UC"), id.count >= 20 {
                if found.channelID == nil { found.channelID = id }
                if found.titleNearChannelID == nil {
                    found.titleNearChannelID = accountTextValue(dict["title"]) ?? accountTextValue(dict["name"])
                }
            }
            // The "Your channel" entry of the account menu carries the
            // UC id as a browse endpoint id, not a "channelId" key -
            // the Round 11 parser never looked here, which is one
            // reason My Channel came back empty. This extractor only
            // ever runs on account-surface responses, whose UC browse
            // ids belong to the signed-in account.
            if let browse = dict["browseId"] as? String,
               browse.hasPrefix("UC"), browse.count >= 20,
               found.channelID == nil {
                found.channelID = browse
            }
            if let canonical = dict["canonicalBaseUrl"] as? String,
               canonical.hasPrefix("/@"), found.handle == nil {
                found.handle = String(canonical.dropFirst())
            }
            if let vanity = dict["vanityChannelUrl"] as? String,
               let atRange = vanity.range(of: "/@"), found.handle == nil {
                found.handle = String(vanity[atRange.upperBound...])
            }
            if found.accountName == nil {
                if let name = accountTextValue(dict["accountName"]) {
                    found.accountName = name
                } else if let nameString = dict["accountName"] as? String, !nameString.isEmpty {
                    found.accountName = nameString
                }
            }
            // Current FEaccount header shape: pageHeaderRenderer whose
            // view model's title is the account name.
            if found.accountName == nil,
               let viewModel = dict["pageHeaderViewModel"] as? [String: Any],
               let titleNode = viewModel["title"] as? [String: Any],
               let dynamic = titleNode["dynamicTextViewModel"] as? [String: Any],
               let name = accountTextValue(dynamic["text"]) {
                found.accountName = name
            }
            if found.handle == nil {
                if let handleString = dict["handle"] as? String, handleString.hasPrefix("@") {
                    found.handle = String(handleString.dropFirst())
                } else if let handleText = accountTextValue(dict["handle"]), handleText.hasPrefix("@") {
                    found.handle = String(handleText.dropFirst())
                } else if let channelHandle = dict["channelHandle"] as? String,
                          channelHandle.hasPrefix("@") {
                    found.handle = String(channelHandle.dropFirst())
                } else if let handleText = accountTextValue(dict["channelHandleText"]),
                          handleText.hasPrefix("@") {
                    // activeAccountHeaderRenderer / accountItem carry
                    // the handle in this text node in current shapes.
                    found.handle = String(handleText.dropFirst())
                }
            }
            for value in dict.values { collectAccountFields(value, into: &found) }
        } else if let array = node as? [Any] {
            for value in array { collectAccountFields(value, into: &found) }
        }
    }

    private static func collectAccountItemSubtrees(_ node: Any, into list: inout [Any]) {
        if let dict = node as? [String: Any] {
            if let item = dict["accountItem"] {
                list.append(item)
            }
            for value in dict.values { collectAccountItemSubtrees(value, into: &list) }
        } else if let array = node as? [Any] {
            for value in array { collectAccountItemSubtrees(value, into: &list) }
        }
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

    /// Hard ceiling for a whole resolution (every profile's request
    /// plus its track loads). Round 14: on Build 169 a degraded
    /// response left the player sheet on an endless spinner because
    /// resolve() simply never came back - racing it against this
    /// deadline guarantees a terminal failure surfaces in the UI with
    /// a reason (and moves the EQ status off "attaching...") instead.
    static func resolveWithTimeout(videoID: String, seconds: Double = 45,
                                   onStep: ((String) -> Void)? = nil) async throws -> TrapTubeResolvedPlayback {
        try await withThrowingTaskGroup(of: TrapTubeResolvedPlayback.self) { group in
            group.addTask { try await resolve(videoID: videoID, onStep: onStep) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TrapTubePlayerError.network(
                    "YouTube took too long to hand over this video (over \(Int(seconds)) seconds) - check the connection and try again")
            }
            guard let result = try await group.next() else {
                throw TrapTubePlayerError.network("Playback resolution ended without a result")
            }
            group.cancelAll()
            return result
        }
    }

    // Round 15 diagnostics: onStep reports each milestone of the
    // resolution (profile attempt, response summary, item built, or the
    // real per-profile failure) to the player UI, so a screenshot of the
    // player IS the diagnosis instead of another round of guessing.
    static func resolve(videoID: String, onStep: ((String) -> Void)? = nil) async throws -> TrapTubeResolvedPlayback {
        var sawCipher = false
        var lastPlayability: String?
        var failures: [String] = []
        for profile in profiles {
            do {
                onStep?("\(profile.name): requesting")
                let json = try await fetchPlayerResponse(videoID: videoID, profile: profile)
                if let playability = json["playabilityStatus"] as? [String: Any],
                   let status = playability["status"] as? String, status != "OK" {
                    lastPlayability = (playability["reason"] as? String) ?? status
                    onStep?("\(profile.name): playability \(status) - \(lastPlayability ?? status)")
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
                let directCount = (muxed + adaptive).filter { $0.url != nil }.count
                onStep?("\(profile.name): playability OK, \(muxed.count) muxed + \(adaptive.count) adaptive, \(directCount) direct URLs")
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
                    // Round 17: bracket the item construction itself.
                    // Builds 173/176 stalled somewhere between the old
                    // "item built" step (which fired BEFORE the item
                    // existed) and resolve() returning, so the Diag trail
                    // could not separate "the AVPlayerItem initializer /
                    // its creation hooks park" from "the return path
                    // parks". "item init begin" now fires immediately
                    // before construction and "item built" immediately
                    // after it. The construction also runs inside the
                    // resolver-item marker window and the finished item
                    // is registered, so the host EQ hook chain skips our
                    // own items entirely (the controller attaches the EQ
                    // explicitly after play()); see TrapTubeAudioHook.
                    onStep?("\(profile.name): item init begin (muxed \(best.height)p)")
                    TrapTubeAudioHook.beginResolverItemConstruction()
                    let item = AVPlayerItem(asset: asset)
                    TrapTubeAudioHook.endResolverItemConstruction()
                    TrapTubeAudioHook.registerResolverItem(item)
                    onStep?("\(profile.name): item built (muxed \(best.height)p, tracks validated)")
                    return TrapTubeResolvedPlayback(title: title, author: author,
                                                    item: item,
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
                    // Round 17: same construction bracket + resolver
                    // marker/registration as the muxed path above.
                    onStep?("\(profile.name): item init begin (composition \(video.height)p)")
                    TrapTubeAudioHook.beginResolverItemConstruction()
                    let item = AVPlayerItem(asset: composition)
                    TrapTubeAudioHook.endResolverItemConstruction()
                    TrapTubeAudioHook.registerResolverItem(item)
                    onStep?("\(profile.name): item built (composition \(video.height)p + audio, tracks validated)")
                    return TrapTubeResolvedPlayback(title: title, author: author,
                                                    item: item,
                                                    profileName: profile.name)
                }
                failures.append("\(profile.name): formats were present but none were directly playable")
            } catch {
                // Item construction (or the player request itself) failed
                // for this profile: record the real error and try the next
                // client instead of treating the first failure as final.
                failures.append("\(profile.name): \(TrapTubeErrorFormatting.describe(error))")
                onStep?("\(profile.name): FAILED \(TrapTubeErrorFormatting.describe(error))")
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
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(profile.userAgent, forHTTPHeaderField: "User-Agent")
        // Round 14: NO auth headers on playback resolution, ever. These
        // signed-out client profiles are the proven Build J/K path -
        // they only ever carried the web session because Round 11
        // attached Cookie + SAPISIDHASH here too, and playback broke
        // on Build 169 the moment a session existed on the device.
        // Auth belongs to the account/feed surfaces only, never to
        // stream resolution.
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

// MARK: - SponsorBlock (skip-only, in our native player)
//
// YTLite ships its own SponsorBlock engine for the host player (REPORT
// section 3.8/3.9: SBManager, sb_* category keys). Our native player is
// the proven playback path in this build, so it gets its own small
// client for the same public SponsorBlock API: fetch the segments for a
// video, and skip the categories YTLite users expect skipped. Skip-only
// this round - no submit/vote/whitelist.

struct TrapTubeSponsorSegment {
    let category: String
    let start: Double
    let end: Double
}

enum TrapTubeSponsorBlock {
    /// Categories requested from the API - the category set YTLite
    /// models (sb_sponsor, sb_selfpromo, sb_interaction, sb_intro,
    /// sb_outro, sb_preview, sb_music_offtopic, sb_filler).
    static let requestedCategories = [
        "sponsor", "selfpromo", "interaction", "intro",
        "outro", "preview", "filler", "music_offtopic"
    ]

    /// Categories this player skips automatically. Mirrors the
    /// headline skip behavior; the rest are fetched (so the data model
    /// matches YTLite's) but left playing this round.
    static let skippedCategories: Set<String> = ["sponsor", "selfpromo"]

    /// Notice text for a skipped segment's category.
    static func skipNotice(for category: String) -> String {
        switch category {
        case "selfpromo": return "Skipped self-promo"
        default: return "Skipped sponsor"
        }
    }

    /// Fetch segments for a video from the public SponsorBlock API.
    /// Every failure (offline, 404 = no segments, malformed body) is
    /// logged and yields an empty list: SponsorBlock must never block,
    /// delay or error playback.
    static func fetchSegments(videoID: String) async -> [TrapTubeSponsorSegment] {
        var components = URLComponents(string: "https://sponsor.ajay.app/api/skipSegments")
        let categoriesJSON = "[" + requestedCategories.map { "\"\($0)\"" }.joined(separator: ",") + "]"
        components?.queryItems = [
            URLQueryItem(name: "videoID", value: videoID),
            URLQueryItem(name: "categories", value: categoriesJSON)
        ]
        guard let url = components?.url else {
            NSLog("[TrapTube SponsorBlock] Could not build skipSegments URL for %@", videoID)
            return []
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                // 404 is the API's "no segments for this video" answer.
                if http.statusCode != 404 {
                    NSLog("[TrapTube SponsorBlock] skipSegments returned HTTP %ld for %@",
                          http.statusCode, videoID)
                }
                return []
            }
            guard let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                NSLog("[TrapTube SponsorBlock] Unexpected skipSegments response shape for %@", videoID)
                return []
            }
            var segments: [TrapTubeSponsorSegment] = []
            for entry in list {
                guard let category = entry["category"] as? String,
                      let range = entry["segment"] as? [Double],
                      range.count == 2, range[1] > range[0] else { continue }
                segments.append(TrapTubeSponsorSegment(category: category,
                                                       start: range[0], end: range[1]))
            }
            segments.sort { $0.start < $1.start }
            NSLog("[TrapTube SponsorBlock] %ld segment(s) for %@ (%ld skippable)",
                  segments.count, videoID,
                  segments.filter { skippedCategories.contains($0.category) }.count)
            return segments
        } catch {
            NSLog("[TrapTube SponsorBlock] Segment fetch failed for %@: %@",
                  videoID, TrapTubeErrorFormatting.describe(error))
            return []
        }
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
    @Published var isMuted = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var rate: Float = 1.0

    // Round 15 diagnostics: a compact, always-visible trail of the
    // load's milestones (last resolver step, per-profile outcome, item
    // status/error) rendered under the EQ status line in the player, so
    // a screenshot of a failed load carries its own diagnosis.
    @Published var diagnosticsLine: String = "Diag: idle"
    private var diagSteps: [String] = []

    // Round 16 watchdog: started the moment play() is called; if the
    // item still isn't readyToPlay 10s later it appends the item/player
    // state that distinguishes a stalled item pipeline from a stalled
    // resolver (Build 173's screenshot proved the resolver healthy and
    // the park downstream of it).
    private var watchdogTask: Task<Void, Never>?
    private var playbackStartNoted = false

    // Round 17 heartbeat: an independent detached task that reports the
    // load's state at 3s/6s/10s while load() is in flight. It shares no
    // executor with the resolver or its task group, so its milestones
    // land even when the resolver is parked - and each one carries the
    // EQ hook chain's last recorded stage, which separates "parked
    // inside item construction / the hook" from "parked in the return
    // path" on a single screenshot.
    private var heartbeatTask: Task<Void, Never>?
    private var heartbeatResolveReturned = false
    private weak var heartbeatItem: AVPlayerItem?

    /// Append one milestone to the diagnostics trail (keeps the most
    /// recent few so the line stays compact and readable).
    func noteDiagnostic(_ step: String) {
        diagSteps.append(step)
        if diagSteps.count > 3 { diagSteps.removeFirst(diagSteps.count - 3) }
        diagnosticsLine = "Diag: " + diagSteps.joined(separator: " > ")
        NSLog("[TrapTube Player] Diag: %@", step)
    }

    // SponsorBlock state: segments for the current video (fetched on
    // load, never on the playback critical path), the transient skip
    // notice the view renders as a pill, and a guard against re-firing
    // a skip while its seek is still landing.
    @Published var skipNotice: String?
    private var sponsorSegments: [TrapTubeSponsorSegment] = []
    private var sponsorBlockTask: Task<Void, Never>?
    private var skipNoticeTask: Task<Void, Never>?
    private var lastSkippedSegmentEnd: Double = -1

    init() {
        // Round 17: register our own player with the hook bypass BEFORE
        // installing the explicit EQ hook, so the tweak's AVPlayer /
        // AVPlayerLayer install hooks skip this player (its EQ comes
        // from this controller's install(on:) alone) instead of adding
        // a second hook instance's synchronous work around our items.
        TrapTubeAudioHook.registerResolverPlayer(player)
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
                // Round 16: prove playback actually started (the playhead
                // advancing is the one signal no stall can fake).
                if time.seconds > 0.05, !self.playbackStartNoted {
                    self.playbackStartNoted = true
                    self.noteDiagnostic("playback started, time advancing")
                    // The load is proven alive; the heartbeat's job is done.
                    self.heartbeatTask?.cancel()
                    self.heartbeatTask = nil
                }
                if let itemDuration = self.player.currentItem?.duration.seconds,
                   itemDuration.isFinite {
                    self.duration = itemDuration
                }
                self.isPlaying = self.player.timeControlStatus == .playing
                self.checkSponsorSegments()
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
        watchdogTask?.cancel()
        watchdogTask = nil
        playbackStartNoted = false
        heartbeatTask?.cancel()
        heartbeatTask = nil
        heartbeatResolveReturned = false
        heartbeatItem = nil
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        isLoading = true
        errorMessage = nil
        title = ""
        author = ""
        diagSteps = []
        diagnosticsLine = "Diag: load \(videoID) started"
        // SponsorBlock resets with the video; the fetch runs parallel
        // to stream resolution and can only ever add skips, never block.
        sponsorBlockTask?.cancel()
        sponsorSegments = []
        lastSkippedSegmentEnd = -1
        skipNotice = nil
        sponsorBlockTask = Task { [weak self] in
            guard let self else { return }
            self.sponsorSegments = await TrapTubeSponsorBlock.fetchSegments(videoID: videoID)
        }
        startLoadHeartbeat()
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                // resolve() now builds and validates the AVPlayerItem
                // itself, per client profile, so a success here means a
                // real item exists and the EQ hook can observe it.
                let resolved = try await TrapTubeStreamResolver.resolveWithTimeout(videoID: videoID) { [weak self] step in
                    DispatchQueue.main.async { self?.noteDiagnostic(step) }
                }
                guard !Task.isCancelled else { return }
                self.heartbeatResolveReturned = true
                self.heartbeatItem = resolved.item
                // Round 16 ordering invariant: from here to play() the
                // sequence is purely synchronous - milestone, item in,
                // play() - with no suspension on any EQ work in between
                // (the workflow verifies this span stays suspension-
                // free). EQ attach reaches this item only through the
                // fire-and-forget hook paths, never through this path.
                self.noteDiagnostic("resolved via \(resolved.profileName)")
                self.title = resolved.title
                self.author = resolved.author
                self.observeItemStatus(resolved.item)
                self.player.replaceCurrentItem(with: resolved.item)
                self.isLoading = false
                self.player.play()
                self.noteDiagnostic("item set, play() called")
                // Round 19: land the EQ tap NOW, while the resolver's
                // validated tracks are still loaded, instead of waiting
                // for the hook's KVO round-trip and async track load.
                // Strictly after play(), outside the construction
                // window, and the span above stays suspension-free.
                self.hook.attachImmediately(to: resolved.item)
                self.startLoadWatchdog(for: resolved.item)
            } catch {
                guard !Task.isCancelled else { return }
                self.heartbeatTask?.cancel()
                self.heartbeatTask = nil
                self.isLoading = false
                self.noteDiagnostic("LOAD FAILED: \(TrapTubeErrorFormatting.describe(error))")
                self.errorMessage = TrapTubeErrorFormatting.playbackFailure(error)
                // No item ever existed, so no EQ attach could start: say
                // so plainly instead of leaving the status line sitting
                // on a stale "attaching..." from the hook probe. Round 15:
                // the EQ status line carries the same failure evidence
                // as the diagnostics line.
                TrapTubeEQManager.shared.setAttachmentStatus(
                    "Playback failed before EQ could attach - \(TrapTubeErrorFormatting.describe(error))")
                NSLog("[TrapTube Player] Load failed for %@: %@", videoID,
                      TrapTubeErrorFormatting.describe(error))
            }
        }
    }

    /// Round 17 heartbeat: while a load is in flight, report its state
    /// at 3s, 6s and 10s from a detached task that shares no executor
    /// with the resolver, its task group or the load task - so the
    /// milestones are written even when the resolver never returns.
    /// Each line carries the EQ hook chain's last recorded stage (see
    /// TrapTubeAudioHook.noteHookStage): "still awaiting resolve" plus
    /// a stage of resolverConstructionBegin with no matching End means
    /// the park is inside item construction or the creation hooks;
    /// both brackets present but the load still awaiting means the park
    /// is in the return/delivery path. Once the resolve has returned,
    /// the lines report the item's live status instead.
    private func startLoadHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task.detached { [weak self] in
            var elapsed = 0
            for target in [3, 6, 10] {
                let delta = target - elapsed
                elapsed = target
                try? await Task.sleep(nanoseconds: UInt64(delta) * 1_000_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    let stage = TrapTubeAudioHook.lastHookStage
                    if !self.heartbeatResolveReturned {
                        self.noteDiagnostic("HB \(target)s: still awaiting resolve, hook stage \(stage)")
                    } else if let item = self.heartbeatItem {
                        let status: String
                        switch item.status {
                        case .unknown: status = "unknown"
                        case .readyToPlay: status = "readyToPlay"
                        case .failed: status = "failed"
                        @unknown default: status = "other(\(item.status.rawValue))"
                        }
                        self.noteDiagnostic("HB \(target)s: resolve returned, item status \(status), hook stage \(stage)")
                    } else {
                        self.noteDiagnostic("HB \(target)s: resolve returned, no item, hook stage \(stage)")
                    }
                }
            }
        }
    }

    /// Round 16 watchdog: if the item play() was called on still isn't
    /// readyToPlay 10s later, append its full state to the Diag line -
    /// item status + error, the player's timeControlStatus and
    /// reasonForWaitingToPlay, which asset kind the resolver produced,
    /// and whether an EQ audioMix is sitting on the item - so the next
    /// screenshot names the stalled stage instead of just "spinner".
    private func startLoadWatchdog(for item: AVPlayerItem) {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self, weak item] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled, let self, let item else { return }
            guard item.status != .readyToPlay else { return }
            let itemStatus: String
            switch item.status {
            case .unknown: itemStatus = "unknown"
            case .failed: itemStatus = "failed"
            case .readyToPlay: itemStatus = "readyToPlay"
            @unknown default: itemStatus = "other(\(item.status.rawValue))"
            }
            let itemError = item.error.map { TrapTubeErrorFormatting.describe($0) } ?? "none"
            let controlStatus: String
            switch self.player.timeControlStatus {
            case .paused: controlStatus = "paused"
            case .playing: controlStatus = "playing"
            case .waitingToPlayAtSpecifiedRate: controlStatus = "waitingToPlay"
            @unknown default: controlStatus = "other"
            }
            let waitingReason = self.player.reasonForWaitingToPlay?.rawValue ?? "none"
            let assetKind: String
            if item.asset is AVURLAsset {
                assetKind = "AVURLAsset"
            } else if item.asset is AVMutableComposition {
                assetKind = "AVMutableComposition"
            } else {
                assetKind = String(describing: type(of: item.asset))
            }
            let mixState = item.audioMix != nil ? "audioMix assigned" : "no audioMix"
            self.noteDiagnostic("WATCHDOG 10s: item \(itemStatus), error \(itemError), player \(controlStatus), reasonForWaitingToPlay \(waitingReason), asset \(assetKind), \(mixState)")
        }
    }

    /// An item can also fail AFTER creation (network drop, a stream URL
    /// the player itself rejects). Surface that failure with its real
    /// domain/code instead of a bare "unknown error", and move the EQ
    /// status off "attaching...".
    private func observeItemStatus(_ item: AVPlayerItem) {
        itemStatusObservation?.invalidate()
        itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self, weak item] _, _ in
            guard let item else { return }
            if item.status == .readyToPlay {
                DispatchQueue.main.async { [weak self] in
                    self?.noteDiagnostic("item readyToPlay")
                }
                return
            }
            guard item.status == .failed else { return }
            let itemError = item.error
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let itemError {
                    self.noteDiagnostic("ITEM FAILED: \(TrapTubeErrorFormatting.describe(itemError))")
                    self.errorMessage = TrapTubeErrorFormatting.playbackFailure(itemError)
                    NSLog("[TrapTube Player] Item failed after creation: %@",
                          TrapTubeErrorFormatting.describe(itemError))
                    TrapTubeEQManager.shared.setAttachmentStatus(
                        "Playback failed before EQ could attach - \(TrapTubeErrorFormatting.describe(itemError))")
                } else {
                    self.noteDiagnostic("ITEM FAILED: status .failed with no error object")
                    self.errorMessage = "Playback failed (AVPlayerItem status became .failed with no error object)"
                    TrapTubeEQManager.shared.setAttachmentStatus("Playback failed before EQ could attach")
                }
                self.isLoading = false
            }
        }
    }

    // MARK: SponsorBlock skipping

    /// Runs from the periodic time observer (0.25s cadence): when the
    /// playhead is inside a skippable segment, seek to its end and flash
    /// the notice. Only while actually playing - a paused playhead parked
    /// inside a segment (e.g. by scrubbing) is left alone.
    private func checkSponsorSegments() {
        guard player.timeControlStatus == .playing, !sponsorSegments.isEmpty else { return }
        let now = currentTime
        if lastSkippedSegmentEnd >= 0, now >= lastSkippedSegmentEnd {
            lastSkippedSegmentEnd = -1
        }
        guard let segment = sponsorSegments.first(where: {
            TrapTubeSponsorBlock.skippedCategories.contains($0.category) &&
            now >= $0.start && now < $0.end
        }) else { return }
        // The seek lands asynchronously; don't re-fire for the same
        // segment while the playhead is still inside it.
        if segment.end == lastSkippedSegmentEnd { return }
        lastSkippedSegmentEnd = segment.end
        NSLog("[TrapTube SponsorBlock] Skipping %@ segment %.1f-%.1fs",
              segment.category, segment.start, segment.end)
        showSkipNotice(for: segment.category)
        player.seek(to: CMTime(seconds: segment.end, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func showSkipNotice(for category: String) {
        skipNotice = TrapTubeSponsorBlock.skipNotice(for: category)
        skipNoticeTask?.cancel()
        skipNoticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.skipNotice = nil
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

    /// Mute toggle for the player card's speaker button. The EQ tap sits
    /// post-effects on the item's mix, so muting the player does not
    /// disturb attachment - and the hook's play-state revalidation
    /// covers the resume side exactly like a pause/play cycle.
    func toggleMute() {
        player.isMuted.toggle()
        isMuted = player.isMuted
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
            sponsorBlockTask?.cancel()
            NSLog("[TrapTube Player] View dismissed during PiP; session retained until PiP stops")
            return
        }
        loadTask?.cancel()
        watchdogTask?.cancel()
        watchdogTask = nil
        sponsorBlockTask?.cancel()
        sponsorBlockTask = nil
        skipNoticeTask?.cancel()
        skipNoticeTask = nil
        sponsorSegments = []
        skipNotice = nil
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
                topBar
                videoCard
                titleBlock
                eqStrip
                transportRow
                statusBlock
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
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

    /// Round 19 restyle: the mockup's player has no title header - the
    /// title lives under the video card - so the top row is just the
    /// sheet's close button, kept because the screen still needs one.
    private var topBar: some View {
        HStack {
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
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(controller.title.isEmpty ? "TrapTube Player" : controller.title)
                .font(.system(size: 25, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !controller.author.isEmpty {
                Text(controller.author)
                    .font(.system(size: 16))
                    .foregroundStyle(Color.white.opacity(0.5))
                    .lineLimit(1)
            }
        }
        .padding(.top, 20)
    }

    /// Round 19 restyle: the video sits in a charcoal card like the
    /// mockup - rounded video, then the in-card strip (speaker, the red
    /// scrubber, fullscreen), then the time labels, all inside the
    /// card's padding. PiP keeps a glass button at the video's top
    /// right; the SponsorBlock pill moved to the top left so it never
    /// collides with the scrub strip.
    private var videoCard: some View {
        VStack(spacing: 6) {
            ZStack {
                TrapTubePlayerLayerView(player: controller.player,
                                        onLayerAvailable: { controller.registerPlayerLayer($0) })
                VStack {
                    HStack(spacing: 8) {
                        if let notice = controller.skipNotice {
                            HStack(spacing: 5) {
                                Image(systemName: "forward.end.fill")
                                    .font(.system(size: 10, weight: .bold))
                                Text(notice)
                                    .font(.caption.weight(.semibold))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: Capsule())
                            .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
                            .transition(.opacity)
                        }
                        Spacer()
                        Button { controller.togglePictureInPicture() } label: {
                            Image(systemName: controller.isPictureInPictureActive ? "pip.exit" : "pip.enter")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 38, height: 38)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(10)
                    Spacer()
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
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .animation(.easeInOut(duration: 0.2), value: controller.skipNotice)

            HStack(spacing: 12) {
                Button { controller.toggleMute() } label: {
                    Image(systemName: controller.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                scrubber
                Button { controller.presentFullscreen() } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 4)
            .padding(.top, 2)

            HStack {
                Text(timeLabel(scrubbing ? scrubTime : controller.currentTime))
                Spacer()
                Text(timeLabel(controller.duration))
            }
            .font(.system(size: 13).monospacedDigit())
            .foregroundStyle(Color.white.opacity(0.55))
            .padding(.horizontal, 4)
        }
        .padding(10)
        .background(Color(white: 0.09), in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22)
            .stroke(Color.white.opacity(0.06), lineWidth: 1))
    }

    /// The mockup's thin in-card scrubber: gray track, red played
    /// portion, red knob. It really seeks - drag (or tap) updates the
    /// scrub position, release commits the seek.
    private var scrubber: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            let displayTime = scrubbing ? scrubTime : controller.currentTime
            let fraction = controller.duration > 0
                ? min(1, max(0, displayTime / controller.duration)) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.25)).frame(height: 4)
                Capsule().fill(accent)
                    .frame(width: width * CGFloat(fraction), height: 4)
                Circle().fill(accent).frame(width: 13, height: 13)
                    .offset(x: width * CGFloat(fraction) - 6.5)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        scrubbing = true
                        let dragFraction = min(1, max(0, value.location.x / width))
                        scrubTime = Double(dragFraction) * max(controller.duration, 1)
                    }
                    .onEnded { value in
                        let dragFraction = min(1, max(0, value.location.x / width))
                        controller.seek(to: Double(dragFraction) * max(controller.duration, 1))
                        scrubbing = false
                    }
            )
        }
        .frame(height: 24)
    }

    /// True only when the EQ status line says the tap is on the stream;
    /// the EQ strip's waveform tint keys off this so the strip reflects
    /// real attachment instead of decorating unconditionally.
    private var eqIsAttached: Bool {
        streamStatus == "Attached to the playing stream"
    }

    /// The mockup's full-width EQ strip: audio-lines icon + "EQ" label
    /// on the left, a dotted waveform across the rest. Tapping opens
    /// the EQ sheet (presets + 16 bands). The waveform is a fixed
    /// decorative pattern (this path has no live analyser); its TINT is
    /// the honest part - accent while the tap is attached, dim gray
    /// while it is not.
    private var eqStrip: some View {
        Button { showEQ = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "waveform")
                    .font(.system(size: 19, weight: .semibold))
                Text("EQ")
                    .font(.system(size: 16, weight: .semibold))
                dottedWaveform
                    .frame(maxWidth: .infinity)
                    .clipped()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.35))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: 54)
            .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14)
                .stroke(Color.white.opacity(0.05), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .padding(.top, 18)
    }

    private var dottedWaveform: some View {
        HStack(alignment: .center, spacing: 3.5) {
            ForEach(Array(Self.waveformBarHeights.enumerated()), id: \.offset) { _, height in
                Capsule()
                    .fill(eqIsAttached ? accent : Color.white.opacity(0.35))
                    .frame(width: 2.5, height: height)
            }
        }
        .frame(height: 26)
    }

    private static let waveformBarHeights: [CGFloat] = [
        6, 11, 17, 9, 14, 22, 12, 7, 16, 20, 10, 5, 13, 19, 8, 15,
        23, 11, 6, 17, 12, 21, 9, 14, 7, 18, 10, 16, 5, 13, 20, 8,
        15, 11, 19, 6, 12, 17, 9, 14
    ]

    /// The mockup's transport row: speed, -15s, the big red play/pause
    /// button, +15s, EQ, and SETTINGS. SETTINGS is a menu of real
    /// player actions (fullscreen, PiP, the EQ enable switch, reset to
    /// flat) rather than a dead gear.
    private var transportRow: some View {
        HStack(alignment: .center, spacing: 4) {
            Menu {
                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { speed in
                    Button("\(speed, specifier: "%g")x") { controller.setRate(Float(speed)) }
                }
            } label: {
                Text("\(controller.rate, specifier: "%g")x")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 44)
            }
            Spacer()
            transportButton(symbol: "gobackward.15", caption: "15 SEC") {
                controller.skip(by: -15)
            }
            Spacer()
            Button { controller.togglePlayPause() } label: {
                Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 27, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 70, height: 70)
                    .background(accent, in: Circle())
                    .shadow(color: accent.opacity(0.35), radius: 12, y: 4)
            }
            .buttonStyle(.plain)
            Spacer()
            transportButton(symbol: "goforward.15", caption: "15 SEC") {
                controller.skip(by: 15)
            }
            Spacer()
            transportButton(symbol: "slider.horizontal.3", caption: "EQ") {
                showEQ = true
            }
            Spacer()
            Menu {
                Button { controller.presentFullscreen() } label: {
                    Label("Fullscreen", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                Button { controller.togglePictureInPicture() } label: {
                    Label("Picture in Picture", systemImage: "pip.enter")
                }
                Divider()
                Button {
                    TrapTubeEQManager.shared.setEQEnabled(!TrapTubeEQManager.shared.isEQEnabled)
                } label: {
                    Label(TrapTubeEQManager.shared.isEQEnabled ? "Disable EQ" : "Enable EQ",
                          systemImage: "waveform")
                }
                Button { TrapTubeEQManager.shared.resetAll() } label: {
                    Label("Reset EQ to Flat", systemImage: "arrow.counterclockwise")
                }
            } label: {
                VStack(spacing: 5) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 24))
                    Text("SETTINGS")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.4)
                }
                .foregroundStyle(.white)
                .frame(width: 58)
            }
        }
        .padding(.top, 22)
    }

    private func transportButton(symbol: String, caption: String,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 24))
                Text(caption)
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.4)
            }
            .foregroundStyle(.white)
            .frame(width: 58)
        }
        .buttonStyle(.plain)
    }

    /// The EQ status line and the Round 15 diagnostics line, kept
    /// visible under the transport row: they are the only on-device
    /// evidence of what attach did, so the restyle moves them but
    /// never hides them.
    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: 5) {
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

            Text(controller.diagnosticsLine)
                .font(.caption2.monospaced())
                .foregroundStyle(Color.white.opacity(0.55))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 18)
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
            let requestBody = body(continuation)
            // A response is only usable if the parser can pull at
            // least one video or a continuation token out of it;
            // anything else retries signed out inside postFeed.
            let json = try await TrapTubeInnerTube.postFeed(endpoint: endpoint, body: requestBody) { candidate in
                var probeItems: [TrapTubeFeedItem] = []
                var probeSeen = Set<String>()
                var probeToken: String?
                Self.collect(node: candidate, items: &probeItems, seen: &probeSeen, continuation: &probeToken)
                return !probeItems.isEmpty || probeToken != nil
            }
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
        request.timeoutInterval = 15
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

    /// Result of an account-surface POST: HTTP errors are data, not
    /// exceptions, so the caller can show the status as evidence.
    enum AccountPostResult {
        case success([String: Any])
        case failure(status: Int?, detail: String)
    }

    /// One InnerTube POST on the WEB client. Returns the parsed JSON
    /// and the HTTP status; throws only on transport/parse failure so
    /// each caller decides what an HTTP error means (Round 14). This
    /// is also the ONLY place auth headers are attached to an
    /// InnerTube request.
    private static func performPost(endpoint: String, body: [String: Any],
                                    authenticated: Bool,
                                    accountHeaders: Bool = false) async throws -> (json: [String: Any], status: Int) {
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
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(webUserAgent, forHTTPHeaderField: "User-Agent")
        if accountHeaders {
            // The headers the real web client sends to the account
            // surfaces alongside the session.
            request.setValue("1", forHTTPHeaderField: "X-Youtube-Client-Name")
            request.setValue((webContext["clientVersion"] as? String) ?? "",
                             forHTTPHeaderField: "X-Youtube-Client-Version")
            request.setValue(TrapTubeYouTubeAuth.origin, forHTTPHeaderField: "Origin")
            request.setValue(TrapTubeYouTubeAuth.origin + "/", forHTTPHeaderField: "Referer")
        }
        if authenticated {
            TrapTubeYouTubeAuth.applyAuth(to: &request)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: fullBody)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if authenticated {
            TrapTubeYouTubeAuth.noteAuthStatus(status)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TrapTubePlayerError.network("unexpected response")
        }
        return (json, status)
    }

    private static func httpErrorMessage(_ json: [String: Any], status: Int) -> String {
        ((json["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \(status)"
    }

    static func post(endpoint: String, body: [String: Any]) async throws -> [String: Any] {
        // Round 14: when signed in, an authenticated request that
        // YouTube refuses is retried as the identical signed-out
        // request before any error surfaces. The signed-out WEB path
        // is the proven one (it has carried the feed since Build I),
        // so being signed in must never make a surface worse than
        // being signed out.
        if TrapTubeYouTubeAuth.isSignedIn {
            do {
                let attempt = try await performPost(endpoint: endpoint, body: body, authenticated: true)
                if attempt.status == 200 { return attempt.json }
                NSLog("[TrapTube InnerTube] Authenticated request answered HTTP %ld; retrying signed out: %@",
                      attempt.status, endpoint)
            } catch {
                NSLog("[TrapTube InnerTube] Authenticated request failed (%@); retrying signed out: %@",
                      TrapTubeErrorFormatting.describe(error), endpoint)
            }
        }
        let attempt = try await performPost(endpoint: endpoint, body: body, authenticated: false)
        guard attempt.status == 200 else {
            throw TrapTubePlayerError.network(
                "YouTube refused the request: \(httpErrorMessage(attempt.json, status: attempt.status))")
        }
        return attempt.json
    }

    /// Feed/search variant of post(): a 200 whose payload parses to
    /// nothing usable also counts as a failed attempt, so a signed-in
    /// response shape the parser can't read falls back to the
    /// signed-out request instead of an empty feed.
    static func postFeed(endpoint: String, body: [String: Any],
                         isUsable: ([String: Any]) -> Bool) async throws -> [String: Any] {
        var lastJSON: [String: Any]?
        var lastError: Error?
        let attempts = TrapTubeYouTubeAuth.isSignedIn ? [true, false] : [false]
        for authenticated in attempts {
            do {
                let attempt = try await performPost(endpoint: endpoint, body: body,
                                                    authenticated: authenticated)
                guard attempt.status == 200 else {
                    lastError = TrapTubePlayerError.network(
                        "YouTube refused the request: \(httpErrorMessage(attempt.json, status: attempt.status))")
                    continue
                }
                if isUsable(attempt.json) { return attempt.json }
                lastJSON = attempt.json
                NSLog("[TrapTube InnerTube] Response (authenticated: %@) held nothing usable; falling back: %@",
                      authenticated ? "yes" : "no", endpoint)
            } catch {
                lastError = error
            }
        }
        if let lastJSON { return lastJSON }
        throw lastError ?? TrapTubePlayerError.network("request failed")
    }

    /// Account-surface POST (getAccountMenu / FEaccount): signed-in
    /// only, with the web client's account headers, and the HTTP
    /// status preserved for the caller instead of thrown away - the
    /// Round 11 version swallowed it with `try?`, leaving My Channel
    /// with nothing to show but "try Refresh".
    static func postAccount(endpoint: String, body: [String: Any]) async -> AccountPostResult {
        do {
            let attempt = try await performPost(endpoint: endpoint, body: body,
                                                authenticated: true, accountHeaders: true)
            if attempt.status == 200 {
                return .success(attempt.json)
            }
            return .failure(status: attempt.status,
                            detail: "YouTube answered HTTP \(attempt.status): \(httpErrorMessage(attempt.json, status: attempt.status))")
        } catch {
            return .failure(status: nil, detail: TrapTubeErrorFormatting.describe(error))
        }
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
        let outcome = await TrapTubeYouTubeAuth.fetchMyChannelDetailed()
        if let fetched = outcome.profile {
            profile = fetched
            message = nil
        } else if profile == nil {
            // Fail honestly, with the evidence: the last HTTP status
            // and what was tried, so a failure is diagnosable instead
            // of an endless "try Refresh" (Round 14).
            var text = "We couldn't read your channel details from YouTube."
            if let status = outcome.lastStatus {
                text += " Last answer from YouTube: HTTP \(status) - \(outcome.lastDetail)."
            } else {
                text += " \(outcome.lastDetail)."
            }
            if TrapTubeYouTubeAuth.isSessionStale {
                text += " YouTube is rejecting the saved sign-in (401/403) - sign out of the Player and sign in again."
            } else {
                text += " You're still signed in - try Refresh in a moment."
            }
            message = text
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
    @State private var authStale = TrapTubeYouTubeAuth.isSessionStale

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
            // Round 19: pay the EQ manager's one-time engine-graph
            // construction now, while the user browses the feed, so the
            // first attach doesn't carry it.
            TrapTubeEQManager.prewarm()
            authSignedIn = TrapTubeYouTubeAuth.isSignedIn
            authStale = TrapTubeYouTubeAuth.isSessionStale
            if feed.items.isEmpty { await feed.loadHome() }
            detectedID = TrapTubeCurrentVideo.detectVideoID()
        }
        .fullScreenCover(item: $request) { request in
            TrapTubeNativePlayerView(request: request)
        }
        .sheet(isPresented: $showSignIn, onDismiss: {
            authStale = TrapTubeYouTubeAuth.isSessionStale
            let nowSignedIn = TrapTubeYouTubeAuth.isSignedIn
            if nowSignedIn != authSignedIn {
                authSignedIn = nowSignedIn
                Task { await feed.loadHome() }
            }
        }) {
            TrapTubeSignInView()
        }
        .sheet(isPresented: $showProfile, onDismiss: {
            authStale = TrapTubeYouTubeAuth.isSessionStale
            authSignedIn = TrapTubeYouTubeAuth.isSignedIn
        }) {
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

            Text(authSignedIn ? (authStale ? "Sign-in expired" : "Signed in") : "Not signed in")
                .font(.caption)
                .foregroundStyle(authStale && authSignedIn ? accent : Color.white.opacity(0.45))
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
