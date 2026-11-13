import AVFoundation
import Foundation

// MARK: - Ghost audio path (Round 20, Tier 1: Stem Studio player only)
//
// Ported from the hybrid app's TrapTubeGhostAudio (Rounds 7-12 there),
// adapted to this build's structure: the AVPlayer plays the video
// muted while this engine renders the audio-only stream through its
// own graph - player node -> varispeed -> 10-band EQ -> main mixer -
// so the EQ the user hears is a real AVAudioUnitEQ, not a tap. Two
// feeds: STREAMED (an AVAssetReader pump schedules decoded PCM a few
// seconds ahead) and FILE (the whole audio file, fetched through the
// re-minting downloader below) for streams the reader cannot run.
// When both feeds fail the player controller falls back to the
// Round 19 tap path and the status line says TAP (FALLBACK).
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

    private var connected = false
    private var graphFormat: AVAudioFormat?
    private var bandGains: [Float] = Array(repeating: 0, count: 10)
    private var bypassed = false
    private var baselineRate: Float = 1
    private var correction: Float = 1
    private var outputLevelValue: Float = 1

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
    /// into exactly this format (see schedulableBuffer) and
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
        applyParameters()
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

    /// Connects node -> varispeed -> EQ -> mixer in `format`. A
    /// degenerate format is refused here and the caller aborts the
    /// prime (degrading to the next feed) instead of proceeding with
    /// a half-built graph: engine.connect raises an uncatchable
    /// exception on a format it cannot route.
    @discardableResult
    private func connectGraph(format: AVAudioFormat) -> Bool {
        if connected, graphFormat == format { return true }
        guard format.sampleRate > 0, format.channelCount > 0 else { return false }
        // A format change needs fresh connections; reset() drops
        // them (and node parameters), so re-apply ours after.
        engine.reset()
        engine.connect(node, to: varispeed, format: format)
        engine.connect(varispeed, to: eqUnit, format: format)
        engine.connect(eqUnit, to: engine.mainMixerNode, format: format)
        graphFormat = format
        connected = true
        applyParameters()
        applyManagerState()
        return true
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
        // Same retirement as the streamed prime: scheduleSegment
        // must be the only producer on this node.
        teardownFeed(deleteTemp: false)
        // The file's own processing format is the one format
        // scheduleSegment accepts for it - self-consistent by
        // construction.
        guard connectGraph(format: format) else { return false }
        node.stop()
        loadedFile = file
        primeOffset = min(max(startAt, 0), Double(file.length) / format.sampleRate)
        scheduledFrames = file.length
        audioDuration = Double(file.length) / format.sampleRate
        streamEnded = false
        let startFrame = AVAudioFramePosition(primeOffset * format.sampleRate)
        let frames = file.length - startFrame
        guard frames > 0 else { return false }
        node.scheduleSegment(file, startingFrame: startFrame,
                             frameCount: AVAudioFrameCount(frames), at: nil)
        feed = .file
        if !engine.isRunning { try? engine.start() }
        if desiredPlaying { node.play() }
        return true
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
                    // Convert into the graph's one format and
                    // re-verify equality immediately before the
                    // schedule call: scheduleBuffer raises an
                    // uncatchable exception on ANY format mismatch,
                    // so a buffer that is not provably in the
                    // connection format is dropped, never scheduled.
                    if let pcm = self.schedulableBuffer(from: sampleBuffer),
                       pcm.format == self.graphFormat {
                        self.node.scheduleBuffer(pcm, completionHandler: nil)
                        self.scheduledFrames += AVAudioFramePosition(pcm.frameLength)
                        self.lastBufferAt = Date()
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

    /// The only buffer the pump may schedule: the raw samples
    /// converted into the graph's canonical stream format.
    /// AVAudioConverter reports failure as a status (it never
    /// raises), so any stream whose layout cannot be converted
    /// yields nil - the chunk is dropped, and if that keeps
    /// happening the pump's starve detection escalates the feed to
    /// FILE, then the session to TAP. The converter is cached ONLY
    /// when creation succeeded: caching a nil converter poisons the
    /// format for every later buffer (hybrid Round 9 lesson).
    private func schedulableBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let target = streamFormat,
              let raw = Self.rawPCMBuffer(from: sampleBuffer) else { return nil }
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
