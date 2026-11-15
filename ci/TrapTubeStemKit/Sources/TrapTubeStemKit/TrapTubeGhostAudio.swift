import AVFAudio
import AVFoundation
import AudioToolbox
import Foundation

// MARK: - Ghost audio path (Round 20, Tier 1: Stem Studio player only)
//
// Ported from the hybrid app's TrapTubeGhostAudio (Rounds 7-12 there),
// adapted to this build's structure: the AVPlayer plays the video
// muted while this engine renders the audio-only stream through its
// own graph - player node -> varispeed -> 10-band EQ -> reverb ->
// dynamics (limiter) -> main mixer - so the EQ the user hears is a
// real AVAudioUnitEQ, not a tap. Three feeds, tried in order:
// SAME-ASSET (Round 24: an AVAssetReader over the resolved
// stream - the one that just proved it loads on this device;
// Round 25: over a fresh clone of it, see below), STREAMED (an
// AVAssetReader pump over an independently
// minted audio-only URL, scheduling decoded PCM a few seconds
// ahead) and FILE (the audio file, fetched through the re-minting
// downloader below and scheduled by a chunk pump through the same
// gate) for streams the readers cannot run. Round 25: SAME-ASSET
// reads a FRESH CLONE of the resolved stream (built per prime
// from the resolver's stashed URL + header descriptor), never
// the playing item's live asset instance - readers over the
// live instance were refused at creation on device (-11838) -
// and every reader feed completes a full awaited property
// load before reader creation. Round 22 made Ghost
// the ONLY audio method (the Ghost/Tap A/B picker is gone); when
// every feed fails the player controller still falls back to the
// Round 19 tap path as a safety net and the status line says so.
// Round 24: every feed exit point records WHY (route, cause,
// error domain/code) in lastFailureReason - a bare "ghost failed"
// is no longer reachable. The Round 22 sound effects (reverb,
// limiter, virtual-surround width, crossfeed, balance) live in
// this engine - see TrapTubeFXSettings.
//
// The EQ curve itself stays owned by TrapTubeEQManager (the panel's
// 16 bands + bass + master). The controller re-applies the manager's
// state to this unit on every sync tick via applyManagerState(),
// reducing the 16-band curve to this unit's 10 bands by nearest
// frequency - the one structural deviation from the hybrid, whose
// sheet drove a 10-band EQ directly.
//
// Round 26: Build 220 refuted the live-instance theory - two
// independent FRESH clones, with the track list, readability,
// playability and format descriptions all loaded first, still
// threw -11838 at reader creation, and no AVAssetReader has
// ever read a googlevideo asset on this device in either
// TrapTube app. So the feeds became a STAGED LADDER rather
// than a bet on one mechanism, and every reader-creation
// attempt records the asset facts (class, readability,
// playability, protected-content flag, audio track count,
// scheme and host) with the attempt, so a failure trail
// discriminates instead of repeating a bare -11838.
//
// Round 28: the ladder is EXPORT-FIRST and every stage must
// prove it renders before it may be called live. Stage 1
// extracts the audio to a local file with an
// AVAssetExportSession passthrough over an audio-only
// composition - the media stack that demonstrably works on
// this device, being the stack AVPlayer itself uses - and
// feeds it through the file pump; Stage 2 is the streamed
// mint, Stage 3 the file download, Stage 4 the clone reader
// as last resort, and the tap remains the final fallback.
// Round 26's prime-before-play reader stage was removed
// outright: its awaited load delayed every play() and its
// reader has never once been allowed to exist here.

/// A download job's way back to a FRESH stream URL for the same
/// format. googlevideo URLs are signed for the IP that minted them
/// and expire about six hours later, so a URL captured when playback
/// started can be dead on arrival by the time a download runs; the
/// downloader re-mints once before the first byte and once more on
/// a 403 (the hybrid's Round 10 pattern).
typealias TrapTubeGhostStreamRefresher = @Sendable () async -> (url: URL, userAgent: String)?

enum TrapTubeGhostDownloadError: Error {
    case badStatus(Int, String)
    case emptyDownload
}

final class TrapTubeGhostDownloader: NSObject, URLSessionDownloadDelegate {
    static let shared = TrapTubeGhostDownloader()

    private var session: URLSession!
    private var continuations: [Int: CheckedContinuation<URL, Error>] = [:]
    private var progressBlocks: [Int: (Double) -> Void] = [:]
    private let stateLock = NSLock()

    private override init() {
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }

    func download(from url: URL, userAgent: String?, onProgress: @escaping (Double) -> Void) async throws -> URL {
        var request = URLRequest(url: url)
        if let userAgent, !userAgent.isEmpty {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        request.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let task = session.downloadTask(with: request)
            stateLock.lock()
            continuations[task.taskIdentifier] = continuation
            progressBlocks[task.taskIdentifier] = onProgress
            stateLock.unlock()
            task.resume()
        }
    }

    /// Download with re-minting: the refresher runs once BEFORE the
    /// first byte, so the job never starts from a stale URL, and once
    /// more if the server still answers 403; after that the job fails
    /// with the honest, host-named error.
    func downloadWithRemint(from url: URL, userAgent: String?,
                            remint: @escaping TrapTubeGhostStreamRefresher,
                            onProgress: @escaping (Double) -> Void) async throws -> URL {
        var currentURL = url
        var currentUA = userAgent
        if let fresh = await remint() {
            currentURL = fresh.url
            currentUA = fresh.userAgent
        }
        do {
            return try await download(from: currentURL, userAgent: currentUA, onProgress: onProgress)
        } catch let error as TrapTubeGhostDownloadError {
            guard case .badStatus(403, _) = error, let fresh = await remint() else { throw error }
            NSLog("[TrapTube Ghost] Download 403 - re-minted and retrying once")
            return try await download(from: fresh.url, userAgent: fresh.userAgent, onProgress: onProgress)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        stateLock.lock()
        let block = progressBlocks[downloadTask.taskIdentifier]
        stateLock.unlock()
        block?(fraction)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // The file at `location` is deleted as soon as this callback
        // returns, so move it into the temp directory right here.
        let suggested = downloadTask.response?.suggestedFilename ?? "download.bin"
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("tt-ghost-dl-\(UUID().uuidString)-\(suggested)")
        let result: Result<URL, Error>
        if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            result = .failure(TrapTubeGhostDownloadError.badStatus(http.statusCode, http.url?.host ?? "googlevideo"))
        } else if (try? FileManager.default.moveItem(at: location, to: destination)) != nil {
            result = .success(destination)
        } else {
            result = .failure(TrapTubeGhostDownloadError.emptyDownload)
        }
        finish(taskIdentifier: downloadTask.taskIdentifier, result: result)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        finish(taskIdentifier: task.taskIdentifier, result: .failure(error))
    }

    private func finish(taskIdentifier: Int, result: Result<URL, Error>) {
        stateLock.lock()
        let continuation = continuations.removeValue(forKey: taskIdentifier)
        progressBlocks.removeValue(forKey: taskIdentifier)
        stateLock.unlock()
        continuation?.resume(with: result)
    }
}

/// Round 32: a lock-protected peak-level accumulator fed by a
/// tap on the Ghost engine's main mixer output. The render
/// thread records; the main actor reads-and-resets per
/// measurement window. It exists because the Round 27/28
/// liveness proof (the rendered position advances) shows the
/// render clock runs - it says nothing about whether the
/// samples leaving the chain are nonzero. Build 242's device
/// recording had drift in the ±30 ms band and "audio at N s"
/// advancing while the user heard nothing: a chain rendering
/// silence in perfect sync passes every existing check. This
/// meter is the missing half of the proof.
final class TrapTubeOutputPeakMeter {
    private let lock = NSLock()
    private var peak: Float = 0

    func record(_ buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        var local: Float = 0
        if buffer.format.commonFormat == .pcmFormatFloat32,
           let channelData = buffer.floatChannelData {
            let channels = Int(buffer.format.channelCount)
            if buffer.format.isInterleaved {
                let data = channelData[0]
                let total = frames * channels
                for index in 0..<total {
                    let value = abs(data[index])
                    if value > local { local = value }
                }
            } else {
                for channel in 0..<channels {
                    let data = channelData[channel]
                    for index in 0..<frames {
                        let value = abs(data[index])
                        if value > local { local = value }
                    }
                }
            }
        } else if buffer.format.commonFormat == .pcmFormatInt16,
                  let channelData = buffer.int16ChannelData {
            let channels = Int(buffer.format.channelCount)
            if buffer.format.isInterleaved {
                let data = channelData[0]
                let total = frames * channels
                for index in 0..<total {
                    let value = abs(Float(data[index]) / 32_768)
                    if value > local { local = value }
                }
            } else {
                for channel in 0..<channels {
                    let data = channelData[channel]
                    for index in 0..<frames {
                        let value = abs(Float(data[index]) / 32_768)
                        if value > local { local = value }
                    }
                }
            }
        }
        guard local > 0 else { return }
        lock.lock()
        if local > peak { peak = local }
        lock.unlock()
    }

    /// The peak since the last take, without resetting - the
    /// diagnostics snapshot's read.
    var currentPeak: Float {
        lock.lock()
        defer { lock.unlock() }
        return peak
    }

    /// Returns the peak since the last take and resets the
    /// accumulator: one measurement window per call.
    func take() -> Float {
        lock.lock()
        defer { lock.unlock() }
        let value = peak
        peak = 0
        return value
    }
}

// MARK: - Ghost sound effects (Round 22: the Poweramp port)
//
// A persisted settings store for the effects that live in the
// Ghost engine: reverb and a protective limiter as units in the
// chain, and virtual-surround width, crossfeed and balance as
// buffer processing in the pump. Edited from the EQ panel's
// Sound Effects section (which the EQ tab also embeds); values
// persist in UserDefaults under TrapTube.FX.* and apply live:
// applyFXSettings() re-parameterizes the two units from this
// store on the controller's sync tick - the same propagation the
// EQ state uses via applyManagerState - and the buffer effects
// read the store directly on every scheduled buffer, so they are
// never a tick behind. None of these exist on the tap fallback:
// they are Ghost-engine features by construction.

enum TrapTubeReverbPreset: Int, CaseIterable, Identifiable {
    case off, smallRoom, mediumRoom, largeRoom, mediumHall, largeHall, cathedral, plate

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .smallRoom: return "Small Room"
        case .mediumRoom: return "Medium Room"
        case .largeRoom: return "Large Room"
        case .mediumHall: return "Medium Hall"
        case .largeHall: return "Large Hall"
        case .cathedral: return "Cathedral"
        case .plate: return "Plate"
        }
    }

    var factoryPreset: AVAudioUnitReverbPreset? {
        switch self {
        case .off: return nil
        case .smallRoom: return .smallRoom
        case .mediumRoom: return .mediumRoom
        case .largeRoom: return .largeRoom
        case .mediumHall: return .mediumHall
        case .largeHall: return .largeHall
        case .cathedral: return .cathedral
        case .plate: return .plate
        }
    }
}

final class TrapTubeFXSettings {
    static let shared = TrapTubeFXSettings()
    static let changeNotification = Notification.Name("TrapTubeFXSettingsChanged")

    private enum Key {
        static let reverbPreset = "TrapTube.FX.ReverbPreset"
        static let reverbMix = "TrapTube.FX.ReverbMix"
        static let limiterEnabled = "TrapTube.FX.LimiterEnabled"
        static let widthPercent = "TrapTube.FX.WidthPercent"
        static let crossfeedPercent = "TrapTube.FX.CrossfeedPercent"
        static let balance = "TrapTube.FX.Balance"
    }

    private(set) var reverbPreset: TrapTubeReverbPreset
    private(set) var reverbMix: Float
    private(set) var limiterEnabled: Bool
    private(set) var widthPercent: Float
    private(set) var crossfeedPercent: Float
    private(set) var balance: Float

    /// Round 24: the Ghost limiter's runtime liveness, written by
    /// every Ghost engine at build time from its ACTUAL unit
    /// creation result (TrapTubeGhostAudio.init) and read by the
    /// Sound Effects card ("Limiter: active / unavailable").
    /// nil until the first Ghost engine exists in this process:
    /// no engine, no limiter, and the card says that instead of
    /// implying one is running.
    /// Round 32 (A2): the storage now sits behind a lock - the
    /// value is written at engine creation and read by SwiftUI
    /// views, and until this round that was plain unsynchronized
    /// shared state. Same call sites, same semantics; the fix
    /// stays a drive-by, not an actor refactor.
    private let limiterAvailabilityLock = NSLock()
    private var limiterAvailabilityStorage: Bool?

    var ghostLimiterAvailability: Bool? {
        limiterAvailabilityLock.lock()
        defer { limiterAvailabilityLock.unlock() }
        return limiterAvailabilityStorage
    }

    func noteGhostLimiterAvailability(_ available: Bool) {
        limiterAvailabilityLock.lock()
        limiterAvailabilityStorage = available
        limiterAvailabilityLock.unlock()
    }

    private init() {
        let defaults = UserDefaults.standard
        reverbPreset = TrapTubeReverbPreset(rawValue: defaults.integer(forKey: Key.reverbPreset)) ?? .off
        reverbMix = defaults.object(forKey: Key.reverbMix) != nil ? defaults.float(forKey: Key.reverbMix) : 30
        limiterEnabled = defaults.object(forKey: Key.limiterEnabled) != nil ? defaults.bool(forKey: Key.limiterEnabled) : true
        widthPercent = defaults.object(forKey: Key.widthPercent) != nil ? defaults.float(forKey: Key.widthPercent) : 100
        crossfeedPercent = defaults.float(forKey: Key.crossfeedPercent)
        balance = defaults.float(forKey: Key.balance)
    }

    func setReverbPreset(_ preset: TrapTubeReverbPreset) {
        guard preset != reverbPreset else { return }
        reverbPreset = preset
        UserDefaults.standard.set(preset.rawValue, forKey: Key.reverbPreset)
        postChange()
    }

    func setReverbMix(_ value: Float) {
        let clamped = min(max(value, 0), 100)
        guard clamped != reverbMix else { return }
        reverbMix = clamped
        UserDefaults.standard.set(clamped, forKey: Key.reverbMix)
        postChange()
    }

    func setLimiterEnabled(_ enabled: Bool) {
        guard enabled != limiterEnabled else { return }
        limiterEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Key.limiterEnabled)
        postChange()
    }

    func setWidthPercent(_ value: Float) {
        let clamped = min(max(value, 0), 200)
        guard clamped != widthPercent else { return }
        widthPercent = clamped
        UserDefaults.standard.set(clamped, forKey: Key.widthPercent)
        postChange()
    }

    func setCrossfeedPercent(_ value: Float) {
        let clamped = min(max(value, 0), 100)
        guard clamped != crossfeedPercent else { return }
        crossfeedPercent = clamped
        UserDefaults.standard.set(clamped, forKey: Key.crossfeedPercent)
        postChange()
    }

    func setBalance(_ value: Float) {
        let clamped = min(max(value, -100), 100)
        guard clamped != balance else { return }
        balance = clamped
        UserDefaults.standard.set(clamped, forKey: Key.balance)
        postChange()
    }

    private func postChange() {
        NotificationCenter.default.post(name: Self.changeNotification, object: nil)
    }
}

@MainActor
final class TrapTubeGhostAudio {
    enum Feed {
        case none, sameAsset, streamed, file, exported
    }

    struct Source {
        let url: URL
        let userAgent: String
        let refresher: TrapTubeGhostStreamRefresher
    }

    /// Round 25: the Ghost clone descriptor, stashed by the
    /// resolver at resolve time alongside the resolved item: the
    /// URL and the EXACT header fields the resolver's own asset
    /// was built with - the muxed file's URL for a muxed
    /// resolution, the AUDIO LEG's URL for a composition (the
    /// leg was inserted into the composition at .zero from a
    /// range starting at .zero, so the leg's own timeline IS
    /// the composition's audio timeline and Ghost, which only
    /// needs audio, can read the leg alone from the same
    /// offsets). The same-asset feed builds a FRESH AVURLAsset
    /// from this descriptor on every prime and NEVER touches
    /// the playing item's live asset instance: on the Build 217
    /// device, an AVAssetReader over the player's own asset
    /// (and over a tracks-only-loaded streamed asset) was
    /// refused at creation with AVFoundationErrorDomain -11838
    /// (AVErrorOperationNotAllowed), which is why both reader
    /// feeds died before pumping a single buffer.
    struct CloneSource {
        let url: URL
        let headers: [String: String]
    }

    static let bandFrequencies: [Float] = [32, 64, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000]
    /// Which TrapTubeEQManager band feeds each ghost band (nearest
    /// frequency): 31, 62, 125, 250, 500, 1k, 2k, 4k, 8k, 16k.
    static let managerBandIndices = [0, 1, 2, 3, 4, 6, 8, 10, 12, 15]

    private(set) var feed: Feed = .none
    var isLive: Bool { feed != .none }
    private(set) var streamEnded = false
    private(set) var audioDuration: TimeInterval = 0

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let varispeed = AVAudioUnitVarispeed()
    private let eqUnit = AVAudioUnitEQ(numberOfBands: 10)
    private let reverbUnit = AVAudioUnitReverb()
    /// Round 24 LIMITER AUDIT. Round 22 created this unit
    /// through the generic component-instantiation API with an
    /// empty option set - which loads the unit OUT of process -
    /// and its completion handler discarded the error parameter
    /// entirely: a nil unit, a failed cast, or a completion that
    /// never fired all left the chain silently limiter-less
    /// while the Sound Effects card implied a limiter was
    /// running. On a sideloaded build the out-of-process route
    /// is exactly where that call can die. The fix is
    /// structural: the unit is created SYNCHRONOUSLY, in
    /// process, through AVAudioUnitEffect - the same
    /// construction TrapTubeEQManager uses for its PeakLimiter
    /// in this very module - so it exists (or not) before init
    /// returns, wireChain always sees the real answer, and the
    /// creation result is published to the FX store for the
    /// Sound Effects card's "Limiter: active / unavailable"
    /// line. Configuration still goes through the AUAudioUnit
    /// parameter tree (see configureDynamicsUnit).
    private let dynamicsUnit: AVAudioUnitEffect? = {
        let description = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_DynamicsProcessor,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0)
        return AVAudioUnitEffect(audioComponentDescription: description)
    }()

    /// Whether the limiter unit exists - created, attached and
    /// wired into the chain by wireChain. This (not the toggle)
    /// is what the Sound Effects card's status line reports.
    var limiterAvailable: Bool { dynamicsUnit != nil }

    private var connected = false
    private var graphFormat: AVAudioFormat?
    private var bandGains: [Float] = Array(repeating: 0, count: 10)
    /// Round 24: the shared auto-headroom compensation (dB, <= 0)
    /// cached from the EQ manager so an engine reset cannot lose
    /// it - applyParameters re-applies it as the EQ unit's
    /// globalGain after every wireChain.
    private var headroomGainDB: Float = 0
    private var bypassed = false
    private var baselineRate: Float = 1
    private var correction: Float = 1
    private var outputLevelValue: Float = 1
    /// Round 28: the two reasons the mixer can be silent
    /// apart from the level itself - the user's own mute
    /// (setMuted) and the HANDOFF SILENCE: while a takeover
    /// prime is proving it renders, the feed renders at zero
    /// mixer level, so the still-audible item stays the only
    /// sound the user hears; the level opens the instant the
    /// controller mutes the item at the handoff. Every write
    /// of the mixer's outputVolume goes through
    /// refreshMixerLevel, so a parameter re-apply (an engine
    /// reset rebuilds the graph and re-applies everything)
    /// can never stomp either state mid-handoff.
    private var userMuted = false
    private var handoffSilenced = false

    /// Round 32 (A1): the generation stamp that owns the
    /// current handoff silence. handoffSilenced is set by
    /// three entry points (start, switchToFile, resync) and
    /// cleared from several exits, and the controller cancels
    /// the previous Ghost task before a new start - but task
    /// cancellation is cooperative, so a cancelled start
    /// suspended mid-prime can still run its clear and lift
    /// the silence during the NEXT start's prime. Each entry
    /// point bumps this counter and captures its value; a
    /// clear only lands when its captured value is still
    /// current - the feedGeneration discipline, applied to
    /// the silence flag.
    private var silenceGeneration = 0

    /// Begin a handoff silence owned by a fresh generation;
    /// returns the generation the caller must present to
    /// endSilence(_:) for its clear to land.
    private func beginSilence() -> Int {
        silenceGeneration += 1
        handoffSilenced = true
        return silenceGeneration
    }

    /// End a handoff silence, but only for the generation
    /// that currently owns it: a stale attempt's clear is
    /// dropped, so the live attempt's prime stays silenced
    /// until IT decides otherwise.
    private func endSilence(_ generation: Int) {
        guard generation == silenceGeneration else { return }
        handoffSilenced = false
        refreshMixerLevel()
    }

    private func refreshMixerLevel() {
        engine.mainMixerNode.outputVolume = (userMuted || handoffSilenced) ? 0 : outputLevelValue
    }

    // Round 22 effects state, cached exactly like the EQ state
    // above: an engine reset returns the units to factory defaults,
    // so applyParameters() re-applies these. loadedReverbPreset
    // tracks what the reverb unit was last told to load, so a sync
    // tick never reloads the same factory preset (which would reset
    // its mix and glitch); a graph reset invalidates it.
    private var fxReverbPreset: TrapTubeReverbPreset = .off
    private var fxReverbMix: Float = 30
    private var fxLimiterEnabled = true
    private var loadedReverbPreset: TrapTubeReverbPreset = .off

    /// Crossfeed filter state (one-pole low-pass per channel),
    /// carried across buffers within a feed and reset whenever a
    /// feed is torn down, so one song's tail never bleeds into the
    /// next song's head.
    private var crossfeedLowL: Float = 0
    private var crossfeedLowR: Float = 0

    private var source: Source?
    /// Round 25: the clone descriptor stashed at resolve time,
    /// kept so every same-asset prime (start, resync, re-prime)
    /// builds a FRESH asset from it. Round 24 kept the resolved
    /// item's own asset here instead - the live instance the
    /// AVPlayer was playing - and readers over it were refused
    /// at creation on device (-11838); the descriptor replaces
    /// the instance, never the other way round.
    private var cloneSource: CloneSource?
    private var desiredPlaying = false

    // MARK: Round 28: the staged ladder's bookkeeping
    //
    // lastEngagedStage records which ladder stage owns the
    // live feed (1 export extraction, 2 streamed mint,
    // 3 file download, 4 post-play clone reader) so the
    // controller's diagnostics can name it - above all in
    // the re-engagement note, "ghost re-engaged (stage N)".
    // Round 26's prime-before-play stage and its adoption
    // bookkeeping are GONE: the pre-play prime's awaited
    // clone load sat between the resolver's return and
    // play() on every load, and the reader it built has
    // never once been allowed to exist on the user's device
    // (AVAssetReader creation refused with -11838 in both
    // apps, at every timing) - pure latency in front of
    // every playback, for a route with a zero-percent
    // record. The reader survives only as the ladder's
    // last resort (Stage 4 in start(), and last in the
    // reader-feed resync).
    // currentVideoID keys the Stage 1 export cache.
    private(set) var lastEngagedStage: Int?
    private var currentVideoID: String?
    /// The local file the exported feed is pumping (a cache
    /// file, or a staging file that could not be moved into
    /// the cache). Kept apart from tempFileURL: teardown must
    /// never delete the export cache.
    private var exportedFileURL: URL?
    /// The videoIDs whose export cache files may stay on disk,
    /// most recent first, capped at two (current + previous).
    private var exportKeepIDs: [String] = []

    // MARK: Round 27: export windows + engine notes
    //
    // The exported feed no longer extracts a whole long video
    // before the first sample can play. It works in windows:
    // ~180 s of audio beginning 2 s before the playhead the
    // window was requested for. The extracted file's frame 0
    // is media time exportWindowStart and the window covers
    // [exportWindowStart, exportWindowEnd); a legacy Build 223
    // full-range cache file is simply the window that starts
    // at 0. primeFile takes the window start so the anchor it
    // sets (primeOffset) stays on the MEDIA timeline the sync
    // loop compares against the video.
    private(set) var exportWindowStart: TimeInterval = 0
    private(set) var exportWindowEnd: TimeInterval = 0
    /// A next-window prefetch extraction is in flight.
    private var exportPrefetchInFlight = false
    /// Engine notes the controller mirrors into the player's
    /// Diag line (window extractions, prefetches) - successes
    /// the failure trail never sees.
    var onDiagnosticNote: ((String) -> Void)?

    /// Round 31 candidate: whether the session currently wants the
    /// engine rendering. The controller's sync loop reads it to tell a
    /// pause the transport buttons already relayed from a pause the
    /// video item took on its own.
    var isDesiredPlaying: Bool { desiredPlaying }

    /// Round 31 candidate: one line of ground truth about the output
    /// path for the Share diagnostics export - engine, node, mixer
    /// level and every silence flag - so "I can't hear anything"
    /// names its cause instead of needing a guess.
    var diagnosticsSnapshot: String {
        let rendered = position().map { String(format: "%.1f s", $0) } ?? "no render time"
        let engineText = engine.isRunning ? "running" : "STOPPED"
        let nodeText = node.isPlaying ? "playing" : "not playing"
        let mixerText = String(format: "%.2f", engine.mainMixerNode.outputVolume)
        let aheadText = String(format: "%.1f", scheduledAhead())
        var line = "engine \(engineText) · node \(nodeText) · mixer \(mixerText)"
        line += String(format: " · output peak %.3f", outputPeakMeter.currentPeak)
        line += " · handoff-silence \(handoffSilenced ? "ON" : "off")"
        line += " · user-mute \(userMuted ? "ON" : "off")"
        line += " · wants \(desiredPlaying ? "play" : "pause")"
        line += " · scheduled ahead \(aheadText) s · rendered \(rendered)"
        if let lastEngineStartError { line += " · \(lastEngineStartError)" }
        return line
    }

    /// The exported feed's current window, for the
    /// controller's prefetch trigger.
    var exportWindow: (start: TimeInterval, end: TimeInterval)? {
        guard feed == .exported, exportedFileURL != nil else { return nil }
        return (exportWindowStart, exportWindowEnd)
    }

    // MARK: Round 24: failure reasons
    //
    // Before this round a Ghost failure reached the user as the
    // bare words "ghost failed": the streamed prime swallowed
    // its track-load error with `try?`, the file prime returned
    // false from four silent exits, and start() reported only a
    // Feed enum. Now EVERY exit point records its route, cause
    // and the real NSError domain/code here. The controller puts
    // lastFailureReason in the player's Diag line and
    // lastFailureShort in the audio-path status, so a screenshot
    // of a fallback carries its own diagnosis.

    /// Full reason for the last failed start/escalation: every
    /// attempted feed's exit, in order, joined for the Diag.
    private(set) var lastFailureReason: String?
    /// The compact form ("track load CoreMediaErrorDomain
    /// -12660") for the audio-path status line.
    private(set) var lastFailureShort: String?
    private var failureTrail: [String] = []

    private func recordFailure(route: String, cause: String, short: String) {
        failureTrail.append("\(route): \(cause)")
        lastFailureShort = short
        NSLog("[TrapTube Ghost] %@ prime exit: %@", route, cause)
    }

    private func finishFailure() {
        lastFailureReason = failureTrail.joined(separator: " · ")
    }

    /// Round 29 candidate: the last AVAudioEngine.start() error, so
    /// an engine that refuses to start names itself in the Diag
    /// instead of surfacing only as "rendered no progress".
    private var lastEngineStartError: String?

    /// Starts the engine when it is stopped. Replaces the bare
    /// `try? engine.start()` call sites, which swallowed the error
    /// (the silent-exit failure class). Returns true when the engine
    /// is running afterwards.
    @discardableResult
    private func ensureEngineRunning(context: String) -> Bool {
        if engine.isRunning { lastEngineStartError = nil; return true }
        do {
            try engine.start()
            lastEngineStartError = nil
            return true
        } catch {
            let ns = error as NSError
            let text = "\(context): engine start failed \(ns.domain) \(ns.code)"
            lastEngineStartError = text
            NSLog("[TrapTube Ghost] %@", text)
            return false
        }
    }

    /// "Domain code" for an error, naming the DEEPEST underlying
    /// error too when it differs - the surface wrapper (a -11800
    /// or an NSURLErrorDomain -1) is never the actionable part;
    /// the CoreMedia 403 underneath it is.
    private static func describe(_ error: Error) -> String {
        let top = error as NSError
        var deepest = top
        while let next = deepest.userInfo[NSUnderlyingErrorKey] as? NSError, next !== deepest {
            deepest = next
        }
        if deepest !== top {
            return "\(top.domain) \(top.code) (underlying: \(deepest.domain) \(deepest.code))"
        }
        return "\(top.domain) \(top.code)"
    }

    private static func shortCode(_ error: Error) -> String {
        let top = error as NSError
        var deepest = top
        while let next = deepest.userInfo[NSUnderlyingErrorKey] as? NSError, next !== deepest {
            deepest = next
        }
        return "\(deepest.domain) \(deepest.code)"
    }

    // MARK: Round 32: output audibility proof
    //
    // A tap on the main mixer's output bus feeds the peak
    // meter: the samples that actually LEAVE the chain, after
    // every unit and after the mixer level itself (so a stuck
    // handoff silence reads as the 0.000 it sounds like). The
    // controller pairs each liveness window with one take of
    // this meter (see takeOutputPeak in the sync loop's
    // audibility guard).
    private let outputPeakMeter = TrapTubeOutputPeakMeter()
    private var outputMeterTapInstalled = false

    /// The peak amplitude at the mixer output since the last
    /// take; taking resets the window.
    func takeOutputPeak() -> Float { outputPeakMeter.take() }

    /// Installs the level tap once per graph build.
    /// engine.reset() (in wireChain) removes node taps, so
    /// wireChain clears the flag and connectGraph re-installs
    /// after every rebuild; primes that reuse the graph keep
    /// the tap they already have.
    private func ensureOutputMeterTap() {
        guard !outputMeterTapInstalled else { return }
        outputMeterTapInstalled = true
        let meter = outputPeakMeter
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 2048, format: nil) { buffer, _ in
            meter.record(buffer)
        }
    }

    private var reader: AVAssetReader?
    private var readerOutput: AVAssetReaderTrackOutput?
    private var pumpTask: Task<Void, Never>?
    private var scheduledFrames: AVAudioFramePosition = 0
    private var primeOffset: TimeInterval = 0
    private var lastBufferAt = Date.distantPast
    private var stallReported = false
    var onStreamStalled: (() -> Void)?

    /// The ONE format the streamed feed connects the graph with and
    /// schedules in: 48 kHz float32 interleaved stereo. Reader
    /// buffers are never trusted to already be in it -
    /// AVAudioPlayerNode.scheduleBuffer raises an uncatchable
    /// NSException when a buffer's format differs from the connection
    /// format in ANY detail - so every reader buffer is converted
    /// into exactly this format (see canonicalBuffer) and
    /// re-checked against the graph format immediately before the
    /// schedule call. (Hybrid Round 8 lesson, learned in a crash.)
    private let streamFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)
    private var streamConverter: AVAudioConverter?
    private var streamConverterFormat: AVAudioFormat?
    /// Bumped by teardownFeed on every feed replacement; a pump whose
    /// captured generation no longer matches exits before it can touch
    /// the new feed's reader or node.
    private var feedGeneration = 0

    private var loadedFile: AVAudioFile?
    private var tempFileURL: URL?

    init() {
        engine.attach(node)
        engine.attach(varispeed)
        engine.attach(eqUnit)
        engine.attach(reverbUnit)
        if let dynamicsUnit { engine.attach(dynamicsUnit) }
        applyFXSettings()
        applyParameters()
        // Round 24: publish the limiter's creation result so the
        // Sound Effects card reports the engine that ACTUALLY
        // got built, not the one the settings assume.
        TrapTubeFXSettings.shared.noteGhostLimiterAvailability(dynamicsUnit != nil)
    }

    // MARK: Parameters (cached: an engine reset must not lose them)

    private func applyParameters() {
        for (index, frequency) in Self.bandFrequencies.enumerated() {
            let band = eqUnit.bands[index]
            band.filterType = .parametric
            band.frequency = frequency
            band.bandwidth = 1.0
            band.gain = bandGains[index]
            band.bypass = false
        }
        eqUnit.bypass = bypassed
        eqUnit.globalGain = headroomGainDB
        varispeed.rate = baselineRate * correction
        refreshMixerLevel()
        pushReverbState()
        configureDynamicsUnit()
    }

    /// The limiter: a protective ceiling, not a compressor sound.
    /// The generically-created DynamicsProcessor unit is set
    /// through its AUAudioUnit parameter tree using the raw
    /// parameter IDs from AudioUnitParameters.h (the
    /// kDynamicsProcessor_* constants are not surfaced to Swift):
    /// threshold 0, headroom 1, expansion ratio 2, expansion
    /// threshold 3, attack 4, release 5, master gain 6. Threshold
    /// -1 dB with 1 dB of headroom puts the effective ceiling at
    /// 0 dBFS, attack 1 ms, release 150 ms, no expansion, neutral
    /// master gain: it catches peaks (EQ boosts and reverb tails
    /// included) without pumping on typical content. Bypass
    /// follows the persisted limiter toggle.
    private func configureDynamicsUnit() {
        guard let unit = dynamicsUnit else { return }
        let tree = unit.auAudioUnit.parameterTree
        func set(_ id: AUParameterAddress, _ value: AUValue) {
            tree?.parameter(withAddress: id)?.setValue(value, originator: nil)
        }
        set(0, -1)     // kDynamicsProcessor_ThresholdParam
        set(1, 1)      // kDynamicsProcessor_HeadRoomParam
        set(2, 1)      // kDynamicsProcessor_ExpansionRatioParam
        set(3, -80)    // kDynamicsProcessor_ExpansionThresholdParam
        set(4, 0.001)  // kDynamicsProcessor_AttackTimeParam
        set(5, 0.15)   // kDynamicsProcessor_ReleaseTimeParam
        set(6, 0)      // kDynamicsProcessor_MasterGainParam
        unit.bypass = !fxLimiterEnabled
    }

    /// Loads the selected factory preset into the reverb unit
    /// when (and only when) the selection changed, then sets the
    /// wet/dry mix - 0 whenever the preset is Off, so Off is a
    /// true bypass of the effect.
    private func pushReverbState() {
        if fxReverbPreset != loadedReverbPreset {
            if let factory = fxReverbPreset.factoryPreset {
                reverbUnit.loadFactoryPreset(factory)
            }
            loadedReverbPreset = fxReverbPreset
        }
        reverbUnit.wetDryMix = fxReverbPreset == .off ? 0 : fxReverbMix
    }

    /// Round 22: pull the persisted effects state (TrapTubeFXSettings)
    /// into the reverb and dynamics units. Called on the
    /// controller's sync tick next to applyManagerState() and at
    /// graph setup, so an edit in the EQ panel lands on the live
    /// units within a tick and never restarts the feed. The
    /// buffer-level effects (width, crossfeed, balance) are not
    /// handled here - processEffects reads the store per buffer.
    func applyFXSettings() {
        let fx = TrapTubeFXSettings.shared
        fxReverbPreset = fx.reverbPreset
        fxReverbMix = fx.reverbMix
        fxLimiterEnabled = fx.limiterEnabled
        pushReverbState()
        dynamicsUnit?.bypass = !fxLimiterEnabled
        // Round 24: re-assert the limiter's parameters on the
        // same tick. The AUAudioUnit parameter tree only exists
        // once the unit is realized (at graph connection), so a
        // configure attempted before that silently lands on a
        // nil tree; the tick guarantees the values land after.
        configureDynamicsUnit()
    }

    /// Pulls the EQ state from TrapTubeEQManager (the panel's source
    /// of truth) into this unit: 16 bands reduced to 10 by nearest
    /// frequency, the bass boost folded into the lowest band, bypass
    /// from the manager's enable switch, and the master gain as the
    /// mixer level (capped at unity - a mixer cannot exceed 1.0 the
    /// way the tap path's globalGain can reach 200%).
    func applyManagerState() {
        let manager = TrapTubeEQManager.shared
        for (ghostIndex, managerIndex) in Self.managerBandIndices.enumerated() {
            var gain = manager.bandGain(at: managerIndex)
            if ghostIndex == 0 { gain += manager.bassBoostDecibels }
            let clamped = min(max(gain, -12), 12)
            bandGains[ghostIndex] = clamped
            if connected { eqUnit.bands[ghostIndex].gain = clamped }
        }
        bypassed = !manager.isEQEnabled
        if connected { eqUnit.bypass = bypassed }
        // Round 24: automatic headroom - the ONE shared
        // compensation (the manager's cascadePeakBoostDB over
        // the panel's 16 bands + bass shelf), applied as this
        // unit's globalGain: ahead of the master level below, so
        // a boosted curve is pulled down by exactly its worst
        // cumulative boost instead of clipping the unit output.
        headroomGainDB = manager.headroomCompensationDB
        eqUnit.globalGain = headroomGainDB
        outputLevelValue = min(max(manager.masterGainPercent / 100, 0), 1)
        if connected { refreshMixerLevel() }
    }

    func setBaselineRate(_ rate: Float) {
        baselineRate = rate
        varispeed.rate = baselineRate * correction
    }

    /// Micro-correction from the sync loop: 1 = locked to the
    /// baseline rate; the loop clamps its input to ±3%.
    func setCorrection(_ factor: Float) {
        correction = min(max(factor, 0.97), 1.03)
        varispeed.rate = baselineRate * correction
    }

    /// The player view's own mute toggle, applied on top of the
    /// manager-driven level.
    func setMuted(_ muted: Bool) {
        userMuted = muted
        refreshMixerLevel()
    }

    // MARK: Graph

    /// Connects node -> varispeed -> EQ -> reverb -> dynamics
    /// (limiter) -> mixer in `format`. A degenerate format is
    /// refused here and the caller aborts the prime (degrading to
    /// the next feed) instead of proceeding with a half-built
    /// graph: engine.connect raises an uncatchable exception on a
    /// format it cannot route.
    @discardableResult
    private func connectGraph(format: AVAudioFormat) -> Bool {
        if connected, graphFormat == format {
            ensureOutputMeterTap()
            return true
        }
        guard format.sampleRate > 0, format.channelCount > 0 else { return false }
        graphFormat = format
        connected = true
        wireChain(format: format)
        ensureOutputMeterTap()
        return true
    }

    /// (Re)builds the connections in `format`: node -> varispeed
    /// -> EQ -> reverb -> dynamics (limiter, when the unit
    /// exists) -> mixer. A format change needs fresh connections;
    /// reset() drops them (and node parameters), so re-apply ours
    /// after. The reset also drops the reverb unit's loaded
    /// preset - invalidate the cache so applyParameters reloads
    /// it. Since Round 24 the limiter is created synchronously at
    /// init, so it is simply present (or honestly absent) every
    /// time this runs - there is no late arrival to insert.
    private func wireChain(format: AVAudioFormat) {
        engine.reset()
        // Round 32: the reset also removes the output level
        // tap; connectGraph re-installs it after the rebuild.
        outputMeterTapInstalled = false
        loadedReverbPreset = .off
        engine.connect(node, to: varispeed, format: format)
        engine.connect(varispeed, to: eqUnit, format: format)
        engine.connect(eqUnit, to: reverbUnit, format: format)
        if let dynamics = dynamicsUnit {
            engine.connect(reverbUnit, to: dynamics, format: format)
            engine.connect(dynamics, to: engine.mainMixerNode, format: format)
        } else {
            engine.connect(reverbUnit, to: engine.mainMixerNode, format: format)
        }
        applyParameters()
        applyManagerState()
    }

    // MARK: Starting feeds

    /// Round 28: the ladder is EXPORT-FIRST. Stage 1 is the
    /// windowed export extraction - the one route with a
    /// perfect record on the user's device, because it reads
    /// through the media stack AVPlayer itself uses; Stage 2
    /// the independently minted streamed feed; Stage 3 the
    /// file download; Stage 4 the post-play clone reader as
    /// last resort (its creation has been refused on this
    /// device in every build of both apps). Round 26's
    /// prime-before-play stage is GONE, not demoted: its
    /// awaited clone load sat between the resolver's return
    /// and play() on EVERY load, delaying playback itself to
    /// build a reader this device has never once allowed -
    /// pure latency, zero successes. The position provider
    /// is consulted at the moment each stage actually
    /// primes, so a slow extraction or download still lands
    /// on the video's current position. A nil minted source
    /// no longer starves Ghost: Stages 1 and 4 need no mint
    /// at all, which is the structural answer to the
    /// Build 213 failure (IOS legs refused at load, ANDROID
    /// minting no audio-only URL at all, while the ANDROID
    /// muxed stream played fine).
    ///
    /// Round 28 NO-SILENCE HANDOFF: the whole ladder runs
    /// with the mixer handoff-silenced while the controller
    /// leaves the item AUDIBLE, and a stage only wins when
    /// its prime has also proven it renders (confirmOrFail).
    /// The controller mutes the item the moment start
    /// returns a feed - the same instant this silence lifts
    /// - so the user never hears a gap and never hears the
    /// two legs double. The code this replaces muted the
    /// item BEFORE the ladder ran, and a slow stage became
    /// an open-ended silent video (Build 228: an 88-minute
    /// mix audible for two seconds, then cut hard to
    /// silence under "GHOST STARTING...").
    func start(source: Source?, clone: CloneSource?, videoID: String?,
               position: @escaping () -> TimeInterval) async -> Feed {
        self.source = source
        if let clone { self.cloneSource = clone }
        if let videoID { self.currentVideoID = videoID }
        failureTrail = []
        lastEngineStartError = nil
        lastFailureReason = nil
        lastFailureShort = nil
        teardownFeed(deleteTemp: true)
        let silence = beginSilence()
        defer { endSilence(silence) }
        if await primeExport(position: position),
           await confirmOrFail(route: "export") {
            lastEngagedStage = 1
            return .exported
        }
        if let source {
            if await primeStreamed(source: source, startAt: position()),
               await confirmOrFail(route: "streamed") {
                lastEngagedStage = 2
                return .streamed
            }
            if await primeFileRoute(source: source, position: position),
               await confirmOrFail(route: "file") {
                lastEngagedStage = 3
                return .file
            }
        }
        if await primeSameAsset(startAt: position()),
           await confirmOrFail(route: "same-asset") {
            lastEngagedStage = 4
            return .sameAsset
        }
        feed = .none
        finishFailure()
        return .none
    }

    func switchToFile(position: @escaping () -> TimeInterval) async -> Bool {
        guard let source else {
            recordFailure(route: "file", cause: "no minted source to download",
                          short: "no minted source")
            finishFailure()
            return false
        }
        // The trail is NOT reset here: the stall that escalated
        // to this call belongs to the same failure chain, and if
        // the file feed also fails the Diag should show both.
        // Round 28: the escalation runs under the same
        // handoff discipline as start() - the controller has
        // restored the item's audio for the duration, the new
        // feed renders silenced until it has proven itself,
        // and only then does the takeover mute land again.
        teardownFeed(deleteTemp: true)
        let silence = beginSilence()
        defer { endSilence(silence) }
        var ok = await primeFileRoute(source: source, position: position)
        if ok { ok = await confirmOrFail(route: "file") }
        if !ok { finishFailure() }
        return ok
    }

    /// Round 24: the NEW primary feed. The reader pumps the
    /// audio track out of the stream the RESOLVER already built
    /// and the PLAYER is already playing. No second mint and no
    /// second URL family to be refused - if the video is
    /// playing, this URL's bytes are already flowing.
    ///
    /// Round 25: what the reader is built over changed. Round
    /// 24 handed primeReader the playing item's OWN asset
    /// instance (the very AVURLAsset, or the composition
    /// itself), and on the Build 217 device AVAssetReader
    /// creation over it threw AVFoundationErrorDomain -11838
    /// (AVErrorOperationNotAllowed) before a single buffer was
    /// pumped. Now the resolver stashes a CloneSource (URL +
    /// the exact headers its own asset was built with - for a
    /// composition resolution, the audio leg's URL: Ghost only
    /// needs audio, and the leg's timeline starts at zero
    /// exactly where the composition inserted it) and every
    /// prime builds a FRESH AVURLAsset from that descriptor.
    /// The player's live instance is never read. The feed joins
    /// the same pump, the same canonical conversion and the
    /// same sync discipline as the streamed feed. Round 28: the
    /// item stays AUDIBLE until a feed has proven it renders -
    /// the takeover mute lands at the handoff, never before
    /// (see start).
    private func primeSameAsset(startAt: TimeInterval, route: String = "same-asset") async -> Bool {
        guard let cloneSource else {
            recordFailure(route: route,
                          cause: "the resolver stashed no clone descriptor for this item",
                          short: "no clone descriptor")
            return false
        }
        let asset = AVURLAsset(url: cloneSource.url, options: [
            "AVURLAssetHTTPHeaderFieldsKey": cloneSource.headers
        ])
        guard let loaded = await loadReaderTrack(asset: asset, route: route) else {
            return false
        }
        return primeReader(asset: asset, track: loaded.track, facts: loaded.facts,
                           feedKind: .sameAsset, route: route, startAt: startAt)
    }

    private func primeStreamed(source: Source, startAt: TimeInterval) async -> Bool {
        let asset = AVURLAsset(url: source.url, options: [
            "AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": source.userAgent, "Referer": "https://www.youtube.com/"]
        ])
        // Round 24: the load below replaces a `try?` that used
        // to swallow the real error whole - on the Build 213
        // device this is where an IOS leg's 403 went to die
        // without leaving a reason anywhere.
        guard let loaded = await loadReaderTrack(asset: asset, route: "streamed") else {
            return false
        }
        return primeReader(asset: asset, track: loaded.track, facts: loaded.facts,
                           feedKind: .streamed, route: "streamed", startAt: startAt)
    }

    /// Round 25: the FULL awaited load every reader feed
    /// performs before AVAssetReader creation: the audio track
    /// list, the asset's readability/playability, and the
    /// track's format descriptions. Round 24 loaded ONLY the
    /// track list; on the Build 217 device both reader feeds
    /// then died at reader creation with -11838
    /// (AVErrorOperationNotAllowed) - an asset whose readable
    /// state was never established is exactly the asset a
    /// reader is allowed to refuse. Every failure breadcrumbs
    /// with its real error (no try? anywhere in this path), and
    /// an asset that reports itself not readable names that as
    /// its own distinct cause.
    ///
    /// Round 26, Stage 0: the load also returns the FACTS
    /// string every reader-creation attempt must carry - the
    /// asset's class, its readability and playability, its
    /// protected-content flag, the audio track count, and (for
    /// a URL asset) the scheme and host ONLY, never the full
    /// URL or any header value. Build 220 proved the -11838
    /// refusal survives fresh clones and full loads alike; the
    /// facts are what let the next device trail say WHAT was
    /// refused instead of repeating the bare code.
    private func loadReaderTrack(asset: AVAsset, route: String) async -> (track: AVAssetTrack, facts: String)? {
        let track: AVAssetTrack
        let audioTrackCount: Int
        do {
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard let first = tracks.first else {
                recordFailure(route: route,
                              cause: "the asset exposes no audio track",
                              short: "no audio track")
                return nil
            }
            track = first
            audioTrackCount = tracks.count
        } catch {
            recordFailure(route: route,
                          cause: "track load failed - \(Self.describe(error))",
                          short: "track load \(Self.shortCode(error))")
            return nil
        }
        let facts: String
        do {
            let readable = try await asset.load(.isReadable)
            let playable = try await asset.load(.isPlayable)
            let protected = try await asset.load(.hasProtectedContent)
            _ = try await track.load(.formatDescriptions)
            var parts = ["asset \(String(describing: type(of: asset)))",
                         "readable \(readable)", "playable \(playable)",
                         "protected \(protected)", "audio tracks \(audioTrackCount)"]
            if let urlAsset = asset as? AVURLAsset {
                let scheme = urlAsset.url.scheme ?? "?"
                let host = urlAsset.url.host ?? "?"
                parts.append("\(scheme)://\(host)")
            }
            facts = parts.joined(separator: ", ")
            guard readable else {
                recordFailure(route: route,
                              cause: "the asset reports it is not readable [\(facts)]",
                              short: "asset not readable")
                return nil
            }
        } catch {
            recordFailure(route: route,
                          cause: "asset property load failed - \(Self.describe(error))",
                          short: "property load \(Self.shortCode(error))")
            return nil
        }
        return (track, facts)
    }

    /// The reader prime both streamed-class feeds share: build
    /// the reader over the given asset/track, connect the graph
    /// in the canonical format, start reading, start the pump.
    /// The graph format is the canonical stream format, NOT a
    /// locally rebuilt twin of what we hope the reader emits: the
    /// pump converts every emitted buffer into exactly this
    /// format before scheduling.
    private func primeReader(asset: AVAsset, track: AVAssetTrack, facts: String,
                             feedKind: Feed, route: String, startAt: TimeInterval) -> Bool {
        let newReader: AVAssetReader
        do {
            newReader = try AVAssetReader(asset: asset)
        } catch {
            // Round 26, Stage 0: the attempt's asset facts ride
            // the cause - class, readability, playability,
            // protected flag, track count, scheme and host - so
            // a refusal trail discriminates instead of repeating
            // the bare error code.
            recordFailure(route: route,
                          cause: "reader creation failed [\(facts)] - \(Self.describe(error))",
                          short: "reader \(Self.shortCode(error))")
            return false
        }
        guard let format = streamFormat else {
            recordFailure(route: route, cause: "canonical stream format unavailable",
                          short: "no stream format")
            return false
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false
        ])
        output.alwaysCopiesSampleData = false
        guard newReader.canAdd(output) else {
            recordFailure(route: route, cause: "reader refused the PCM output",
                          short: "reader refused output")
            return false
        }
        newReader.add(output)
        if startAt > 0 {
            newReader.timeRange = CMTimeRange(start: CMTime(seconds: startAt, preferredTimescale: 600),
                                              duration: .positiveInfinity)
        }
        // Retire any previous feed first (its pump is cancelled and
        // generation-invalidated) so two pumps can never read one
        // output or schedule into one node concurrently.
        teardownFeed(deleteTemp: false)
        guard connectGraph(format: format) else {
            recordFailure(route: route, cause: "graph connect refused the canonical format",
                          short: "graph refused format")
            return false
        }
        node.stop()
        reader = newReader
        readerOutput = output
        primeOffset = startAt
        scheduledFrames = 0
        streamEnded = false
        stallReported = false
        lastBufferAt = Date()
        audioDuration = 0
        // Round 25: creation (above) and start stay SEPARATE
        // breadcrumb points on purpose - a created reader whose
        // start is refused names reader.error here as its own
        // "reader start refused" cause, so a device trail can
        // discriminate the two refusals.
        guard newReader.startReading() else {
            let cause = newReader.error.map { "reader start refused [\(facts)] - \(Self.describe($0))" }
                ?? "reader start refused [\(facts)]"
            recordFailure(route: route, cause: cause, short: "reader start refused")
            teardownFeed(deleteTemp: false)
            return false
        }
        feed = feedKind
        startPump()
        ensureEngineRunning(context: "reader feed start")
        if desiredPlaying { node.play() }
        return true
    }

    // MARK: Round 28, Stage 1: export extraction
    //
    // The structural bypass for assets that refuse readers:
    // the audio is extracted to a LOCAL file by an
    // AVAssetExportSession - which reads through the media
    // stack AVPlayer itself uses, the one fetch path that
    // demonstrably works on this device - and the local file
    // feeds the existing file pump. The export source is a
    // fresh clone of the descriptor's asset (the muxed file,
    // or the audio leg for a composition resolution) reduced
    // to an audio-only AVMutableComposition, exported with
    // the Passthrough preset so the AAC bitstream is carried
    // untouched into an .m4a - never re-encoded. A hybrid-era
    // note rejected export for riding "the same failing
    // track-load"; that premise does not hold here, because
    // THIS resolver's winning asset loads its tracks fine
    // (the item builds and plays, and the clones complete the
    // full property load) - the failure is specifically at
    // AVAssetReader creation, which export never attempts.
    // Extracted files are cached per videoID under Caches, so
    // a replay or a re-prime of the same video skips the
    // extraction entirely. Round 27 made the extraction
    // WINDOWED (~180 s from just behind the playhead, next
    // window prefetched in the background), so time-to-first-
    // audio no longer scales with the video's length - on
    // Build 223 a 22:42 video's whole-file extraction was
    // also what left the prime anchored seconds in the past.

    /// Round 27: the window length, and how far behind the
    /// playhead a window starts (the preroll that lets a prime
    /// land mid-window instead of at its very edge).
    private static let exportWindowLength: TimeInterval = 180
    private static let exportWindowPreroll: TimeInterval = 2

    private static var exportCacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TrapTubeGhostExport", isDirectory: true)
    }

    /// Round 27: windowed cache files are named
    /// "<videoID>@<windowStartMilliseconds>.m4a". The Build 223
    /// full-range file keeps its plain "<videoID>.m4a" name and
    /// reads as the window starting at 0, so it satisfies any
    /// window it covers.
    private static func exportCacheURL(videoID: String, windowStart: TimeInterval) -> URL {
        exportCacheDirectory
            .appendingPathComponent("\(videoID)@\(Int((windowStart * 1000).rounded())).m4a")
    }

    /// Bounds the cache directory: the four most recently
    /// modified window files stay (the live window, its
    /// prefetched successor, the previous video's pair);
    /// anything older is deleted. A file the live pump holds
    /// open survives deletion on this platform - the pump's
    /// captured AVAudioFile is unaffected.
    private func noteExportEngaged(videoID: String) {
        exportKeepIDs = [videoID]
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: Self.exportCacheDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let sorted = entries.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return da > db
        }
        for entry in sorted.dropFirst(4) {
            try? fm.removeItem(at: entry)
        }
    }

    /// A cached window (or the legacy full-range file) whose
    /// span covers the anchor with at least a second of runway
    /// left: the file URL plus its media-timeline window.
    private func cachedExportWindow(videoID: String, covering anchor: TimeInterval)
        -> (url: URL, start: TimeInterval, end: TimeInterval)? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: Self.exportCacheDirectory, includingPropertiesForKeys: nil) else { return nil }
        var best: (url: URL, start: TimeInterval, end: TimeInterval)?
        for entry in entries {
            let name = entry.lastPathComponent
            let start: TimeInterval
            if name == "\(videoID).m4a" {
                start = 0
            } else if name.hasPrefix("\(videoID)@"), name.hasSuffix(".m4a"),
                      let millis = Double(String(name.dropFirst(videoID.count + 1).dropLast(4))) {
                start = millis / 1000
            } else {
                continue
            }
            guard let file = try? AVAudioFile(forReading: entry),
                  file.processingFormat.sampleRate > 0 else { continue }
            let end = start + Double(file.length) / file.processingFormat.sampleRate
            guard anchor >= start, anchor < end - 1 else { continue }
            if best == nil || end > best!.end { best = (entry, start, end) }
        }
        return best
    }

    /// Stage 1 entry: serve the window covering the CURRENT
    /// playhead from cache when one exists; otherwise extract
    /// it (see extractExportWindow). The position provider is
    /// consulted at prime time, never at ladder time: the
    /// Build 223 prime passed a value captured when Stage 3
    /// was ENTERED, the (whole-file) extraction then ran for
    /// many seconds while the video played on, and the pump
    /// anchored itself that many seconds in the past.
    private func primeExport(position: @escaping () -> TimeInterval) async -> Bool {
        guard let cloneSource else {
            recordFailure(route: "export",
                          cause: "no clone descriptor to extract from",
                          short: "export: no descriptor")
            return false
        }
        let anchor = position()
        if let videoID = currentVideoID,
           let hit = cachedExportWindow(videoID: videoID, covering: anchor) {
            exportedFileURL = hit.url
            exportWindowStart = hit.start
            exportWindowEnd = hit.end
            if primeFile(localURL: hit.url, startAt: anchor, feedKind: .exported,
                         route: "export", windowStart: hit.start) {
                noteExportEngaged(videoID: videoID)
                NSLog("[TrapTube Ghost] export feed: cache hit for %@ (window %.0f-%.0f)",
                      videoID, hit.start, hit.end)
                return true
            }
            // primeFile recorded why the cached file would not
            // pump; fall through to a fresh extraction.
        }
        return await extractExportWindow(cloneSource: cloneSource, anchor: anchor,
                                         position: position, prime: true)
    }

    /// Round 27: background prefetch of the window beginning
    /// at `start` (the live window's end), so the boundary
    /// switch primes from cache instead of waiting on the
    /// media stack. Fire-and-forget; a no-op when a prefetch
    /// is already running or the window is already cached.
    func prefetchExportWindow(startingAt start: TimeInterval) {
        guard !exportPrefetchInFlight, let cloneSource,
              let videoID = currentVideoID else { return }
        if cachedExportWindow(videoID: videoID, covering: start + 1) != nil { return }
        exportPrefetchInFlight = true
        Task { [weak self] in
            guard let self else { return }
            _ = await self.extractExportWindow(
                cloneSource: cloneSource,
                anchor: start + Self.exportWindowPreroll, position: nil, prime: false)
            self.exportPrefetchInFlight = false
        }
    }

    /// Extracts the window of audio beginning one preroll
    /// before `anchor` (~180 s, or to the end of the media)
    /// and caches it under the video's window slot. With
    /// prime == true the extracted window is also primed - at
    /// the LIVE playhead re-read at completion, never at the
    /// anchor the extraction started from. With prime == false
    /// (prefetch) the file is only cached.
    private func extractExportWindow(cloneSource: CloneSource, anchor: TimeInterval,
                                     position: (() -> TimeInterval)?,
                                     prime: Bool) async -> Bool {
        let asset = AVURLAsset(url: cloneSource.url, options: [
            "AVURLAssetHTTPHeaderFieldsKey": cloneSource.headers
        ])
        guard let loaded = await loadReaderTrack(asset: asset, route: "export") else {
            return false
        }
        let track = loaded.track
        let composition = AVMutableComposition()
        guard let compTrack = composition.addMutableTrack(withMediaType: .audio,
                                                          preferredTrackID: kCMPersistentTrackID_Invalid) else {
            recordFailure(route: "export",
                          cause: "the audio-only composition track could not be created",
                          short: "export composition failed")
            return false
        }
        let windowStart: TimeInterval
        let windowEnd: TimeInterval
        do {
            let fullRange = try await track.load(.timeRange)
            let mediaEnd = (fullRange.start + fullRange.duration).seconds
            // Short media is one whole window; otherwise the
            // window begins one preroll before the anchor
            // (clamped at 0) and runs ~180 s or to the end of
            // the media.
            windowStart = mediaEnd <= Self.exportWindowLength
                ? 0 : max(0, anchor - Self.exportWindowPreroll)
            windowEnd = min(mediaEnd, windowStart + Self.exportWindowLength)
            guard windowEnd > windowStart else {
                // The anchor sits at/past the end of the
                // audio. For a prefetch that is a benign no-op
                // (nothing beyond the end to cache); for a real
                // prime it is an honest failure.
                if prime {
                    recordFailure(route: "export",
                                  cause: "the requested position is past the end of the audio",
                                  short: "export past end")
                }
                return false
            }
            let range = CMTimeRange(
                start: fullRange.start + CMTime(seconds: windowStart, preferredTimescale: 600),
                duration: CMTime(seconds: windowEnd - windowStart, preferredTimescale: 600))
            try compTrack.insertTimeRange(range, of: track, at: .zero)
        } catch {
            recordFailure(route: "export",
                          cause: "audio track insertion failed - \(Self.describe(error))",
                          short: "export insert \(Self.shortCode(error))")
            return false
        }
        guard let session = AVAssetExportSession(asset: composition,
                                                 presetName: AVAssetExportPresetPassthrough) else {
            recordFailure(route: "export",
                          cause: "export session could not be created for the audio-only composition",
                          short: "export session unavailable")
            return false
        }
        // Stage to a unique temp file; only a completed export
        // is moved into the video's window cache slot.
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("tt-ghost-export-\(UUID().uuidString).m4a")
        session.outputURL = staging
        session.outputFileType = .m4a
        let status: AVAssetExportSession.Status = await withCheckedContinuation { continuation in
            session.exportAsynchronously { continuation.resume(returning: session.status) }
        }
        guard status == .completed else {
            let statusName = status == .failed ? "failed"
                : status == .cancelled ? "cancelled" : "status \(status.rawValue)"
            let errorText = session.error.map { " - \(Self.describe($0))" } ?? ""
            recordFailure(route: "export",
                          cause: "export \(statusName)\(errorText)",
                          short: "export \(statusName)")
            try? FileManager.default.removeItem(at: staging)
            return false
        }
        var finalURL = staging
        if let videoID = currentVideoID {
            let cached = Self.exportCacheURL(videoID: videoID, windowStart: windowStart)
            try? FileManager.default.createDirectory(at: cached.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: cached)
            if (try? FileManager.default.moveItem(at: staging, to: cached)) != nil {
                finalURL = cached
            }
        }
        onDiagnosticNote?("ghost export window [\(Self.fmtSeconds(windowStart))–\(Self.fmtSeconds(windowEnd))]")
        guard prime else {
            NSLog("[TrapTube Ghost] export prefetch cached window %.0f-%.0f for %@",
                  windowStart, windowEnd, currentVideoID ?? "unknown video")
            return true
        }
        exportedFileURL = finalURL
        exportWindowStart = windowStart
        exportWindowEnd = windowEnd
        // The prime position is re-read NOW, at completion:
        // the extraction may have taken seconds while the
        // video played on (the Build 223 stale-anchor defect).
        let live = position?() ?? anchor
        guard primeFile(localURL: finalURL, startAt: live, feedKind: .exported,
                        route: "export", windowStart: windowStart) else {
            return false
        }
        if let videoID = currentVideoID { noteExportEngaged(videoID: videoID) }
        NSLog("[TrapTube Ghost] export feed: window %.0f-%.0f extracted for %@",
              windowStart, windowEnd, currentVideoID ?? "unknown video")
        return true
    }

    private static func fmtSeconds(_ value: TimeInterval) -> String {
        String(format: "%.1f", value)
    }

    private func primeFileRoute(source: Source, position: () -> TimeInterval) async -> Bool {
        let downloaded: URL
        do {
            downloaded = try await TrapTubeGhostDownloader.shared.downloadWithRemint(
                from: source.url, userAgent: source.userAgent,
                remint: source.refresher, onProgress: { _ in })
        } catch let error as TrapTubeGhostDownloadError {
            switch error {
            case .badStatus(let status, let host):
                recordFailure(route: "file",
                              cause: "download answered HTTP \(status) from \(host)",
                              short: "download HTTP \(status)")
            case .emptyDownload:
                recordFailure(route: "file", cause: "download delivered no data",
                              short: "download empty")
            }
            return false
        } catch {
            recordFailure(route: "file",
                          cause: "download failed - \(Self.describe(error))",
                          short: "download \(Self.shortCode(error))")
            return false
        }
        // AVAudioFile needs a real audio extension to open the
        // container; the downloader's temp files carry none.
        let local = FileManager.default.temporaryDirectory
            .appendingPathComponent("tt-ghost-\(UUID().uuidString).m4a")
        if (try? FileManager.default.moveItem(at: downloaded, to: local)) == nil {
            guard (try? FileManager.default.copyItem(at: downloaded, to: local)) != nil else {
                recordFailure(route: "file", cause: "could not stage the downloaded file",
                              short: "file staging failed")
                return false
            }
            try? FileManager.default.removeItem(at: downloaded)
        }
        tempFileURL = local
        return primeFile(localURL: local, startAt: position())
    }

    /// Round 26: feedKind and route are parameters because the
    /// Stage 1 export feed pumps a local file through this
    /// exact path - same pump, same conversion gate - while
    /// remaining a distinct feed (.exported) with its own
    /// failure attribution.
    private func primeFile(localURL: URL, startAt: TimeInterval,
                           feedKind: Feed = .file, route: String = "file",
                           windowStart: TimeInterval = 0) -> Bool {
        guard let file = try? AVAudioFile(forReading: localURL) else {
            recordFailure(route: route, cause: "the local file could not be opened as audio",
                          short: "file open failed")
            return false
        }
        let format = file.processingFormat
        // A degenerate processing format would poison the frame
        // math below and the graph connection alike.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            recordFailure(route: route, cause: "the local file reports a degenerate audio format",
                          short: "bad file format")
            return false
        }
        // Same retirement as the streamed prime: the file pump
        // must be the only producer on this node.
        teardownFeed(deleteTemp: false)
        // Round 22: the graph connects in the ONE canonical
        // format, exactly like the streamed feed. Before this
        // round the file feed connected in the file's own format
        // and scheduled with scheduleSegment - a path no buffer
        // effect could ever touch, which is why the file feed now
        // decodes through the shared pump instead.
        guard let canonical = streamFormat, connectGraph(format: canonical) else {
            recordFailure(route: route, cause: "graph connect refused the canonical format",
                          short: "graph refused format")
            return false
        }
        node.stop()
        loadedFile = file
        audioDuration = Double(file.length) / format.sampleRate
        // Round 27: windowStart is the media time of the
        // file's frame 0 (0 for whole-file feeds). The prime
        // lands at the MEDIA position startAt - the file-local
        // position startAt - windowStart - and primeOffset,
        // the anchor position() reports, stays on the media
        // timeline.
        let localStart = min(max(startAt - windowStart, 0), audioDuration)
        primeOffset = windowStart + localStart
        scheduledFrames = 0
        streamEnded = false
        stallReported = false
        lastBufferAt = Date()
        let startFrame = AVAudioFramePosition(localStart * format.sampleRate)
        guard startFrame < file.length else {
            recordFailure(route: route, cause: "the requested position is past the end of the audio",
                          short: "position past end")
            return false
        }
        file.framePosition = startFrame
        feed = feedKind
        startFilePump()
        ensureEngineRunning(context: "file feed start")
        if desiredPlaying { node.play() }
        return true
    }

    /// The file feed's pump: reads the downloaded file in
    /// quarter-second chunks and routes every chunk through the
    /// same scheduling gate as the streamed feed
    /// (scheduleProcessed: canonical conversion, the Round 22
    /// buffer effects, then schedule), keeping only a few seconds
    /// scheduled ahead - the file is never held in memory whole.
    /// It mirrors the streamed pump's discipline: captured file,
    /// feed generation check, and streamEnded when the file is
    /// fully scheduled.
    private func startFilePump() {
        pumpTask?.cancel()
        guard let pumpFile = loadedFile else { return }
        let generation = feedGeneration
        // Round 26: the pump serves both local-file feeds (the
        // downloaded .file and the extracted .exported); like
        // the reader pump it captures WHICH one at prime time.
        let pumpFeed = feed
        let chunkFrames = AVAudioFrameCount(max(pumpFile.processingFormat.sampleRate / 4, 1024))
        pumpTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.feedGeneration == generation,
                  self.feed == pumpFeed, self.loadedFile === pumpFile {
                // Round 27: never schedule into a paused node.
                // While the user has the video paused the node
                // renders nothing, but the position clock is
                // host-derived - an ungated pump keeps feeding
                // the queue against it, can drain the whole
                // file (setting streamEnded at EOF, which used
                // to veto the sync loop's hard resync), and
                // leaves the resume anchor corrupt. Idling here
                // keeps the pause state exactly where the prime
                // left it; the controller's resume resync
                // re-bases the feed at the live position.
                if !self.desiredPlaying {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    continue
                }
                if self.scheduledAhead() > 3.5 {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    continue
                }
                guard let raw = AVAudioPCMBuffer(pcmFormat: pumpFile.processingFormat,
                                                 frameCapacity: chunkFrames) else { return }
                do {
                    try pumpFile.read(into: raw, frameCount: chunkFrames)
                } catch {
                    NSLog("[TrapTube Ghost] File pump exit: read failed - %@", "\(error)")
                    self.streamEnded = true
                    return
                }
                if raw.frameLength == 0 {
                    // The whole file is scheduled; the node
                    // drains it at the video's pace.
                    self.streamEnded = true
                    return
                }
                if !self.scheduleProcessed(raw) {
                    NSLog("[TrapTube Ghost] File pump exit: chunk not schedulable in the graph format")
                    self.streamEnded = true
                    return
                }
            }
        }
    }

    // MARK: The reader pump

    private func startPump() {
        pumpTask?.cancel()
        // The pump works on CAPTURED reader/output values and the
        // feed generation at prime time - never on the live
        // properties, which a resync may swap mid-loop.
        guard let pumpReader = reader, let pumpOutput = readerOutput else { return }
        // Round 24: the pump serves both reader feeds; it
        // captures WHICH one at prime time so its loop condition
        // and its failure reasons name the right route.
        let pumpFeed = feed
        let pumpRoute = pumpFeed == .sameAsset ? "same-asset" : "streamed"
        let generation = feedGeneration
        pumpTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.feedGeneration == generation,
                  self.feed == pumpFeed, self.reader === pumpReader {
                if pumpReader.status == .failed {
                    // Round 24: the reader's own error joins the
                    // trail before the stall escalates, so the
                    // eventual fallback can say WHY the feed died.
                    let cause = pumpReader.error.map { "reader failed mid-stream - \(Self.describe($0))" }
                        ?? "reader failed mid-stream"
                    self.recordFailure(route: pumpRoute, cause: cause, short: "reader failed")
                    self.finishFailure()
                    self.reportStall()
                    return
                }
                if pumpReader.status == .completed {
                    self.streamEnded = true
                    return
                }
                // Round 27: same pause discipline as the file
                // pump - do not consume the reader into a
                // paused node's queue.
                if !self.desiredPlaying {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    continue
                }
                if self.scheduledAhead() > 3.5 {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    continue
                }
                if let sampleBuffer = pumpOutput.copyNextSampleBuffer() {
                    // Route the raw samples through the one
                    // scheduling gate (scheduleProcessed): convert
                    // into the graph's one format, re-verify
                    // equality, run the buffer effects, schedule.
                    // scheduleBuffer raises an uncatchable
                    // exception on ANY format mismatch, so a buffer
                    // that is not provably in the connection format
                    // is dropped, never scheduled.
                    if let raw = Self.rawPCMBuffer(from: sampleBuffer) {
                        self.scheduleProcessed(raw)
                    }
                    continue
                }
                // Nothing available right now: a live feed that
                // starves for over five seconds while playing is
                // treated as failed so the session can fall back to
                // the file feed.
                if self.desiredPlaying, self.scheduledAhead() < 0.5,
                   Date().timeIntervalSince(self.lastBufferAt) > 5 {
                    self.recordFailure(route: pumpRoute,
                                       cause: "reader starved - no buffers for over five seconds while playing",
                                       short: "reader starved")
                    self.finishFailure()
                    self.reportStall()
                    return
                }
                try? await Task.sleep(nanoseconds: 60_000_000)
            }
        }
    }

    private func reportStall() {
        guard !stallReported else { return }
        stallReported = true
        onStreamStalled?()
    }

    private func scheduledAhead() -> TimeInterval {
        guard let format = graphFormat else { return 0 }
        let scheduledEnd = primeOffset + Double(scheduledFrames) / format.sampleRate
        return scheduledEnd - (position() ?? primeOffset)
    }

    /// The reader's samples in the reader's OWN format, whatever
    /// layout the emitted format description actually carries.
    /// Never scheduled directly - this is only the input to the
    /// canonical conversion below.
    private static func rawPCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: formatDescription)
        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0, format.sampleRate > 0, format.channelCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        buffer.frameLength = frameCount
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frameCount), into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }

    /// A raw stereo buffer converted into the graph's canonical
    /// stream format - the conversion both feeds' pumps share.
    /// AVAudioConverter reports failure as a status (it never
    /// raises), so any stream whose layout cannot be converted
    /// yields nil - the chunk is dropped, and if that keeps
    /// happening the streamed pump's starve detection escalates
    /// the feed to FILE, then the session to TAP. The converter is
    /// cached ONLY when creation succeeded: caching a nil
    /// converter poisons the format for every later buffer
    /// (hybrid Round 9 lesson).
    private func canonicalBuffer(from raw: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let target = streamFormat, raw.frameLength > 0 else { return nil }
        if raw.format == target { return raw }
        if streamConverterFormat != raw.format {
            guard let created = AVAudioConverter(from: raw.format, to: target) else { return nil }
            streamConverter = created
            streamConverterFormat = raw.format
        }
        guard let converter = streamConverter, raw.frameLength > 0 else { return nil }
        let ratio = target.sampleRate / raw.format.sampleRate
        guard ratio.isFinite, ratio > 0 else { return nil }
        let capacity = AVAudioFrameCount((Double(raw.frameLength) * ratio).rounded(.up)) + 32
        guard capacity > 32,
              let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: converted, error: &conversionError) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .endOfStream
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return raw
        }
        guard status != .error, converted.frameLength > 0 else { return nil }
        return converted
    }

    /// The one scheduling gate BOTH feeds pass through: convert
    /// to the canonical format, verify it against the graph
    /// format immediately before the schedule call, run the
    /// Round 22 buffer effects, then schedule and book-keep. The
    /// streamed pump's reader chunks and the file pump's decoded
    /// chunks converge here - that convergence is what lets the
    /// buffer effects cover both feeds with one implementation.
    @discardableResult
    private func scheduleProcessed(_ raw: AVAudioPCMBuffer) -> Bool {
        guard let pcm = canonicalBuffer(from: raw),
              pcm.format == graphFormat else { return false }
        processEffects(pcm)
        node.scheduleBuffer(pcm, completionHandler: nil)
        scheduledFrames += AVAudioFramePosition(pcm.frameLength)
        lastBufferAt = Date()
        return true
    }

    /// Round 22 buffer effects: virtual surround (mid/side
    /// width), crossfeed and balance, applied in place to a
    /// canonical-format buffer immediately before scheduling.
    /// Values are read from TrapTubeFXSettings on every buffer, so
    /// an edit in the EQ panel is audible from the next scheduled
    /// chunk with no restart. Fast path first: at width 100,
    /// crossfeed 0 and balance 0 the buffer passes untouched with
    /// no per-sample work; anything that is not float32 stereo is
    /// passed through untouched as well.
    ///
    /// Conventions: width works on mid = (L+R)/2 and
    /// side = (L-R)/2 with the side scaled by width/100 - at 0
    /// both channels carry the mono mid, at 100 the signal is
    /// identical, at 200 the side is doubled. Crossfeed bleeds a
    /// low-passed (~700 Hz at 48 kHz) copy of each channel into
    /// the other at up to 50% for a full amount - the headphone
    /// virtualization half of the Poweramp port. Balance
    /// attenuates the far channel linearly: at +/-100 it is
    /// silent and the near channel is unchanged.
    private func processEffects(_ buffer: AVAudioPCMBuffer) {
        let fx = TrapTubeFXSettings.shared
        let width = fx.widthPercent
        let crossfeed = fx.crossfeedPercent
        let balance = fx.balance
        if width == 100, crossfeed == 0, balance == 0 { return }
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              buffer.format.channelCount == 2,
              let channelData = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        let sideGain = width / 100
        let bleed = crossfeed / 100 * 0.5
        let lpAlpha: Float = 0.0876
        let gainL: Float = balance > 0 ? 1 - balance / 100 : 1
        let gainR: Float = balance < 0 ? 1 + balance / 100 : 1
        var lpL = crossfeedLowL
        var lpR = crossfeedLowR
        if buffer.format.isInterleaved {
            let data = channelData[0]
            for frame in 0..<frames {
                var l = data[frame * 2]
                var r = data[frame * 2 + 1]
                if bleed > 0 {
                    lpL += lpAlpha * (l - lpL)
                    lpR += lpAlpha * (r - lpR)
                    l += bleed * lpR
                    r += bleed * lpL
                }
                if sideGain != 1 {
                    let mid = (l + r) * 0.5
                    let side = (l - r) * 0.5 * sideGain
                    l = mid + side
                    r = mid - side
                }
                data[frame * 2] = l * gainL
                data[frame * 2 + 1] = r * gainR
            }
        } else {
            let left = channelData[0]
            let right = channelData[1]
            for frame in 0..<frames {
                var l = left[frame]
                var r = right[frame]
                if bleed > 0 {
                    lpL += lpAlpha * (l - lpL)
                    lpR += lpAlpha * (r - lpR)
                    l += bleed * lpR
                    r += bleed * lpL
                }
                if sideGain != 1 {
                    let mid = (l + r) * 0.5
                    let side = (l - r) * 0.5 * sideGain
                    l = mid + side
                    r = mid - side
                }
                left[frame] = l * gainL
                right[frame] = r * gainR
            }
        }
        crossfeedLowL = lpL
        crossfeedLowR = lpR
    }

    // MARK: Position + transport

    /// The audio timeline position: where the stream primed plus
    /// what the node has actually rendered since (the player-node
    /// clock follows real consumption, varispeed included).
    func position() -> TimeInterval? {
        guard feed != .none,
              let nodeTime = node.lastRenderTime,
              let playerTime = node.playerTime(forNodeTime: nodeTime),
              playerTime.sampleRate > 0 else { return nil }
        return primeOffset + Double(playerTime.sampleTime) / playerTime.sampleRate
    }

    /// Round 28: whether the audio engine itself is running -
    /// a liveness signal the controller's sync loop now
    /// consults directly. A stopped engine (a media-services
    /// reset, a session deactivation forced by the host app)
    /// freezes every rendered-position signal with it, which
    /// the position-based guard could previously only infer
    /// after its window lapsed, and nothing anywhere
    /// restarted it.
    var engineIsRunning: Bool { engine.isRunning }

    /// Round 28: restart a stopped engine under a live feed
    /// and resume rendering. Returns true when a restart was
    /// needed (and attempted), so the caller can breadcrumb
    /// it; the rendered-position guard remains the arbiter of
    /// whether the feed actually recovered.
    @discardableResult
    func restartEngineIfStopped() -> Bool {
        guard feed != .none, !engine.isRunning else { return false }
        ensureEngineRunning(context: "engine restart")
        if desiredPlaying { node.play() }
        return true
    }

    /// Round 28: the handoff proof. A prime only ever proved
    /// the feed OPENED - Build 223 declared "ghost live" over
    /// an exported file that rendered nothing at all. This
    /// waits until the player node's rendered position
    /// actually ADVANCES (the Round 27 liveness definition)
    /// before the caller may treat the feed as live. It runs
    /// under the handoff silence (see start), so the proof
    /// costs the user nothing: the item stays the only
    /// audible leg until the controller mutes it at the
    /// handoff. A paused session cannot prove rendering, so
    /// it passes; the sync loop's guard owns liveness from
    /// the first playing tick after a resume.
    private func confirmRendering() async -> Bool {
        guard desiredPlaying else { return true }
        let deadline = Date().addingTimeInterval(1.5)
        var baseline: TimeInterval?
        while Date() < deadline {
            if Task.isCancelled { return false }
            guard feed != .none else { return false }
            if !desiredPlaying { return true }
            if let now = position() {
                if let baseline {
                    if now > baseline + 0.03 { return true }
                } else {
                    baseline = now
                }
            }
            try? await Task.sleep(nanoseconds: 60_000_000)
        }
        return false
    }

    /// Round 28: the gate every ladder prime now passes
    /// through - primed AND proven rendering, or the prime
    /// is torn down and its exit recorded, so a feed that
    /// opens but renders nothing falls through to the next
    /// stage instead of being declared live over silence.
    private func confirmOrFail(route: String) async -> Bool {
        if await confirmRendering() { return true }
        let engineNote = lastEngineStartError.map { " (\($0))" } ?? ""
        recordFailure(route: route,
                      cause: "primed but rendered no progress within 1.5 s" + engineNote,
                      short: lastEngineStartError == nil ? "\(route) rendered nothing"
                                                         : "\(route) engine start failed")
        teardownFeed(deleteTemp: true)
        return false
    }

    func setDesiredPlaying(_ playing: Bool) {
        desiredPlaying = playing
        guard feed != .none else { return }
        if playing {
            ensureEngineRunning(context: "set desired playing")
            node.play()
        } else {
            node.pause()
        }
    }

    /// Stall-follow: pauses rendering without changing the desired
    /// state the session asked for.
    func pauseRendering() { node.pause() }

    func resumeRendering() {
        guard desiredPlaying, feed != .none else { return }
        ensureEngineRunning(context: "resume rendering")
        node.play()
    }

    /// Hard resync: flush the node and re-prime the same feed at
    /// the video's current position. Round 28: a resync is a
    /// re-prime, so it runs under start()'s handoff discipline -
    /// the feed renders silenced until it has proven it renders
    /// (confirmOrFail), and only a proven resync lets the
    /// controller land (or keep) the takeover mute. When the
    /// resync is a recovery, the controller has the item audible
    /// for its duration.
    func resync(to position: TimeInterval) async -> Bool {
        guard feed != .none else { return false }
        // A resync owns a fresh failure trail: its primes record
        // anew, and the caller (hard resync, then escalate or
        // fall back) reads the reason for THIS attempt, not a
        // stale one from the original start.
        failureTrail = []
        let silence = beginSilence()
        defer { endSilence(silence) }
        var ok: Bool
        switch feed {
        case .sameAsset, .streamed:
            // Round 28: a resync of a reader feed re-runs the
            // ladder in start()'s export-first order (Round 26
            // ran the clone reader first, then the export; the
            // reader's record on this device is still zero
            // successes, so it goes last here too). Whichever
            // stage lands is recorded in lastEngagedStage for
            // the re-engagement note.
            if await primeExport(position: { position }) {
                lastEngagedStage = 1
                ok = true
            } else if let source {
                if await primeStreamed(source: source, startAt: position) {
                    lastEngagedStage = 2
                    ok = true
                } else if await primeFileRoute(source: source, position: { position }) {
                    lastEngagedStage = 3
                    ok = true
                } else if await primeSameAsset(startAt: position) {
                    lastEngagedStage = 4
                    ok = true
                } else {
                    ok = false
                }
            } else if await primeSameAsset(startAt: position) {
                lastEngagedStage = 4
                ok = true
            } else {
                ok = false
            }
        case .exported:
            // Round 27: windows. A target inside the live
            // window re-primes the same file at its local
            // offset; a target outside it (a seek past the
            // window's end, an exhausted window) goes back
            // through Stage 1, which serves the covering
            // window from cache - the prefetched next window
            // makes that instant - or extracts it.
            if let exportedFileURL,
               position >= exportWindowStart, position < exportWindowEnd,
               primeFile(localURL: exportedFileURL, startAt: position,
                         feedKind: .exported, route: "export",
                         windowStart: exportWindowStart) {
                ok = true
            } else {
                // Covers an out-of-window target AND an
                // in-window prime that failed (a pruned cache
                // file is not a dead end): Stage 1 re-serves or
                // re-extracts the covering window.
                ok = await primeExport(position: { position })
            }
            if ok { lastEngagedStage = 1 }
        case .file:
            if let tempFileURL {
                ok = primeFile(localURL: tempFileURL, startAt: position)
            } else {
                ok = false
            }
        case .none:
            ok = false
        }
        if ok {
            // The confirmation names the feed that actually
            // primed - after a ladder re-run that can differ
            // from the feed that was resynced.
            let route: String
            switch feed {
            case .exported: route = "export"
            case .streamed: route = "streamed"
            case .file: route = "file"
            case .sameAsset: route = "same-asset"
            case .none: route = "resync"
            }
            ok = await confirmOrFail(route: route)
        }
        if !ok { finishFailure() }
        return ok
    }

    func teardownFeed(deleteTemp: Bool) {
        // Invalidate any live pump BEFORE cancelling it: Task
        // cancellation is cooperative, so the generation check is
        // what actually stops a mid-loop pump from touching the
        // next feed's reader or node.
        feedGeneration += 1
        pumpTask?.cancel()
        pumpTask = nil
        reader?.cancelReading()
        reader = nil
        readerOutput = nil
        node.stop()
        loadedFile = nil
        crossfeedLowL = 0
        crossfeedLowR = 0
        feed = .none
        streamEnded = false
        if deleteTemp, let tempFileURL {
            try? FileManager.default.removeItem(at: tempFileURL)
            self.tempFileURL = nil
        }
    }

    func shutdown() {
        teardownFeed(deleteTemp: true)
        engine.stop()
        source = nil
        cloneSource = nil
        desiredPlaying = false
        // Round 28: the ladder state belongs to one item's
        // session; a new load starts its staging from scratch.
        // Round 32 (A1): the generation bump retires any
        // in-flight attempt's pending clear along with it.
        silenceGeneration += 1
        handoffSilenced = false
        lastEngagedStage = nil
        currentVideoID = nil
        exportedFileURL = nil
        exportWindowStart = 0
        exportWindowEnd = 0
    }
}
