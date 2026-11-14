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
// real AVAudioUnitEQ, not a tap. Two feeds: STREAMED (an
// AVAssetReader pump schedules decoded PCM a few seconds ahead) and
// FILE (the audio file, fetched through the re-minting downloader
// below and scheduled by a chunk pump through the same gate) for
// streams the reader cannot run. Round 22 made Ghost the ONLY audio
// method (the Ghost/Tap A/B picker is gone); when both feeds fail
// the player controller still falls back to the Round 19 tap path
// as a safety net and the status line says TAP (FALLBACK). The
// Round 22 sound effects (reverb, limiter, virtual-surround width,
// crossfeed, balance) live in this engine - see TrapTubeFXSettings.
//
// The EQ curve itself stays owned by TrapTubeEQManager (the panel's
// 16 bands + bass + master). The controller re-applies the manager's
// state to this unit on every sync tick via applyManagerState(),
// reducing the 16-band curve to this unit's 10 bands by nearest
// frequency - the one structural deviation from the hybrid, whose
// sheet drove a 10-band EQ directly.

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
        case none, streamed, file
    }

    struct Source {
        let url: URL
        let userAgent: String
        let refresher: TrapTubeGhostStreamRefresher
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
    /// Round 22 fix (runs 203/204): the iOS 27 SDK no longer
    /// vends the AVAudioUnitDynamicsProcessor class to Swift, so
    /// the very same DynamicsProcessor audio unit is created
    /// through AVAudioUnit's generic component instantiation
    /// (see instantiateDynamicsUnit) and configured through its
    /// AUAudioUnit parameter tree. Nil until that in-process
    /// instantiation lands - milliseconds after init - and the
    /// chain simply runs without the limiter stage until then;
    /// wireChain inserts it the moment it arrives.
    private var dynamicsUnit: AVAudioUnit?

    private var connected = false
    private var graphFormat: AVAudioFormat?
    private var bandGains: [Float] = Array(repeating: 0, count: 10)
    private var bypassed = false
    private var baselineRate: Float = 1
    private var correction: Float = 1
    private var outputLevelValue: Float = 1

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
    private var desiredPlaying = false

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
        applyFXSettings()
        applyParameters()
        instantiateDynamicsUnit()
    }

    /// Creates Apple's DynamicsProcessor effect unit ('aufx' /
    /// 'dyna' / 'appl') through AVAudioUnit's generic component
    /// instantiation - the route that survives the iOS 27 SDK
    /// dropping the typed Swift subclass. Loaded in-process: no
    /// extension host, completes in milliseconds. On arrival the
    /// unit is attached and configured, and if the graph is
    /// already connected it is rewired with the limiter inserted.
    private func instantiateDynamicsUnit() {
        let description = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_DynamicsProcessor,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0)
        AVAudioUnit.instantiate(with: description, options: [.loadInProcess]) { [weak self] unit, _ in
            DispatchQueue.main.async {
                guard let self, let unit else { return }
                self.dynamicsUnit = unit
                self.engine.attach(unit)
                self.applyParameters()
                if self.connected, let format = self.graphFormat {
                    self.wireChain(format: format)
                }
            }
        }
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
        varispeed.rate = baselineRate * correction
        engine.mainMixerNode.outputVolume = outputLevelValue
        pushReverbState()
        configureDynamicsUnit()
    }

    /// The limiter: a protective ceiling, not a compressor sound.
    /// The generically-created DynamicsProcessor unit is set
    /// through its AUAudioUnit parameter tree - the addresses are
    /// the classic kDynamicsProcessor_* parameter IDs (threshold
    /// 0, headroom 1, expansion ratio 2, expansion threshold 3,
    /// attack 4, release 5, master gain 6). Threshold -1 dB with
    /// 1 dB of headroom puts the effective ceiling at 0 dBFS,
    /// attack 1 ms, release 150 ms, no expansion, neutral master
    /// gain: it catches peaks (EQ boosts and reverb tails
    /// included) without pumping on typical content. Bypass
    /// follows the persisted limiter toggle.
    private func configureDynamicsUnit() {
        guard let unit = dynamicsUnit else { return }
        let tree = unit.auAudioUnit.parameterTree
        func set(_ id: AUParameterAddress, _ value: AUValue) {
            tree?.parameter(withAddress: id)?.setValue(value, originator: nil)
        }
        set(AUParameterAddress(kDynamicsProcessor_ThresholdParam), -1)
        set(AUParameterAddress(kDynamicsProcessor_HeadRoomParam), 1)
        set(AUParameterAddress(kDynamicsProcessor_ExpansionRatioParam), 1)
        set(AUParameterAddress(kDynamicsProcessor_ExpansionThresholdParam), -80)
        set(AUParameterAddress(kDynamicsProcessor_AttackTimeParam), 0.001)
        set(AUParameterAddress(kDynamicsProcessor_ReleaseTimeParam), 0.15)
        set(AUParameterAddress(kDynamicsProcessor_MasterGainParam), 0)
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
        outputLevelValue = min(max(manager.masterGainPercent / 100, 0), 1)
        if connected { engine.mainMixerNode.outputVolume = outputLevelValue }
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
        engine.mainMixerNode.outputVolume = muted ? 0 : outputLevelValue
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
        if connected, graphFormat == format { return true }
        guard format.sampleRate > 0, format.channelCount > 0 else { return false }
        graphFormat = format
        connected = true
        wireChain(format: format)
        return true
    }

    /// (Re)builds the connections in `format`: node -> varispeed
    /// -> EQ -> reverb -> dynamics (limiter, when the unit has
    /// landed) -> mixer. A format change needs fresh connections;
    /// reset() drops them (and node parameters), so re-apply ours
    /// after. The reset also drops the reverb unit's loaded
    /// preset - invalidate the cache so applyParameters reloads
    /// it. Also called from the dynamics instantiation completion
    /// to insert the limiter into an already-connected graph.
    private func wireChain(format: AVAudioFormat) {
        engine.reset()
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

    /// Tries the streamed feed first, then the file feed. The
    /// position provider is consulted at the moment each feed
    /// actually primes, so a slow download still lands on the
    /// video's current position.
    func start(source: Source, position: @escaping () -> TimeInterval) async -> Feed {
        self.source = source
        teardownFeed(deleteTemp: true)
        if await primeStreamed(source: source, startAt: position()) {
            return .streamed
        }
        if await primeFileRoute(source: source, position: position) {
            return .file
        }
        feed = .none
        return .none
    }

    func switchToFile(position: @escaping () -> TimeInterval) async -> Bool {
        guard let source else { return false }
        teardownFeed(deleteTemp: true)
        return await primeFileRoute(source: source, position: position)
    }

    private func primeStreamed(source: Source, startAt: TimeInterval) async -> Bool {
        let asset = AVURLAsset(url: source.url, options: [
            "AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": source.userAgent, "Referer": "https://www.youtube.com/"]
        ])
        // The graph format is the canonical stream format, NOT a
        // locally rebuilt twin of what we hope the reader emits: the
        // pump converts every emitted buffer into exactly this
        // format before scheduling.
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let format = streamFormat,
              let newReader = try? AVAssetReader(asset: asset) else {
            NSLog("[TrapTube Ghost] Streamed prime exit: track/reader setup failed")
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
            NSLog("[TrapTube Ghost] Streamed prime exit: reader refused the output")
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
            NSLog("[TrapTube Ghost] Streamed prime exit: graph connect refused the format")
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
        guard newReader.startReading() else {
            NSLog("[TrapTube Ghost] Streamed prime exit: startReading failed")
            teardownFeed(deleteTemp: false)
            return false
        }
        feed = .streamed
        startPump()
        if !engine.isRunning { try? engine.start() }
        if desiredPlaying { node.play() }
        return true
    }

    private func primeFileRoute(source: Source, position: () -> TimeInterval) async -> Bool {
        let downloaded: URL
        do {
            downloaded = try await TrapTubeGhostDownloader.shared.downloadWithRemint(
                from: source.url, userAgent: source.userAgent,
                remint: source.refresher, onProgress: { _ in })
        } catch {
            NSLog("[TrapTube Ghost] File prime exit: download failed - %@", "\(error)")
            return false
        }
        // AVAudioFile needs a real audio extension to open the
        // container; the downloader's temp files carry none.
        let local = FileManager.default.temporaryDirectory
            .appendingPathComponent("tt-ghost-\(UUID().uuidString).m4a")
        if (try? FileManager.default.moveItem(at: downloaded, to: local)) == nil {
            guard (try? FileManager.default.copyItem(at: downloaded, to: local)) != nil else { return false }
            try? FileManager.default.removeItem(at: downloaded)
        }
        tempFileURL = local
        return primeFile(localURL: local, startAt: position())
    }

    private func primeFile(localURL: URL, startAt: TimeInterval) -> Bool {
        guard let file = try? AVAudioFile(forReading: localURL) else { return false }
        let format = file.processingFormat
        // A degenerate processing format would poison the frame
        // math below and the graph connection alike.
        guard format.sampleRate > 0, format.channelCount > 0 else { return false }
        // Same retirement as the streamed prime: the file pump
        // must be the only producer on this node.
        teardownFeed(deleteTemp: false)
        // Round 22: the graph connects in the ONE canonical
        // format, exactly like the streamed feed. Before this
        // round the file feed connected in the file's own format
        // and scheduled with scheduleSegment - a path no buffer
        // effect could ever touch, which is why the file feed now
        // decodes through the shared pump instead.
        guard let canonical = streamFormat, connectGraph(format: canonical) else { return false }
        node.stop()
        loadedFile = file
        audioDuration = Double(file.length) / format.sampleRate
        primeOffset = min(max(startAt, 0), audioDuration)
        scheduledFrames = 0
        streamEnded = false
        stallReported = false
        lastBufferAt = Date()
        let startFrame = AVAudioFramePosition(primeOffset * format.sampleRate)
        guard startFrame < file.length else { return false }
        file.framePosition = startFrame
        feed = .file
        startFilePump()
        if !engine.isRunning { try? engine.start() }
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
        let chunkFrames = AVAudioFrameCount(max(pumpFile.processingFormat.sampleRate / 4, 1024))
        pumpTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.feedGeneration == generation,
                  self.feed == .file, self.loadedFile === pumpFile {
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
        let generation = feedGeneration
        pumpTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.feedGeneration == generation,
                  self.feed == .streamed, self.reader === pumpReader {
                if pumpReader.status == .failed {
                    self.reportStall()
                    return
                }
                if pumpReader.status == .completed {
                    self.streamEnded = true
                    return
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

    func setDesiredPlaying(_ playing: Bool) {
        desiredPlaying = playing
        guard feed != .none else { return }
        if playing {
            if !engine.isRunning { try? engine.start() }
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
        if !engine.isRunning { try? engine.start() }
        node.play()
    }

    /// Hard resync: flush the node and re-prime the same feed at
    /// the video's current position.
    func resync(to position: TimeInterval) async -> Bool {
        guard let source, feed != .none else { return false }
        switch feed {
        case .streamed:
            return await primeStreamed(source: source, startAt: position)
        case .file:
            guard let tempFileURL else { return false }
            return primeFile(localURL: tempFileURL, startAt: position)
        case .none:
            return false
        }
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
        desiredPlaying = false
    }
}
