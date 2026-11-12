import AVFoundation
import MediaToolbox
import UIKit

/// TrapTube EQ for app-owned audio and AVPlayerItem audio tracks that expose an
/// editable audio mix. FairPlay or custom YouTube renderers may reject/bypass taps.
@objc(TrapTubeEQManager)
public final class TrapTubeEQManager: NSObject {
    public static let frequencies: [Float] = [31, 62, 125, 250, 500, 750, 1000, 1500,
                                               2000, 3000, 4000, 6000, 8000, 10000, 12000, 16000]
    public static let shared = TrapTubeEQManager()

    private let lock = NSLock()
    private var bandGains = Array(repeating: Float(0), count: 16)
    private var bassBoost: Float = 0
    private var masterPercent: Float = 100
    // Attachment bookkeeping is separate from the audio callback's parameter lock.
    // The lock covers the entire install/restore transaction so async callers cannot
    // race and install duplicate taps on the same AVPlayerItem.
    private let attachmentLock = NSRecursiveLock()
    private final class AttachmentRecord {
        weak var item: AVPlayerItem?
        let originalMix: AVAudioMix?
        let installedMix: AVAudioMix
        init(item: AVPlayerItem, originalMix: AVAudioMix?, installedMix: AVAudioMix) {
            self.item = item
            self.originalMix = originalMix
            self.installedMix = installedMix
        }
    }
    private var attachmentRecords: [ObjectIdentifier: AttachmentRecord] = [:]

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let engineEQ = AVAudioUnitEQ(numberOfBands: 17)
    private let limiter: AVAudioUnitEffect = {
        let description = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_PeakLimiter,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        return AVAudioUnitEffect(audioComponentDescription: description)
    }()

    private override init() {
        super.init()
        configureEngineGraph()
        let defaults = UserDefaults.standard
        for index in Self.frequencies.indices {
            let key = "TrapTube.EQ.Band.\(index)"
            if defaults.object(forKey: key) != nil { setBandGain(defaults.float(forKey: key), at: index) }
        }
        if defaults.object(forKey: "TrapTube.EQ.Bass") != nil { setBassBoost(defaults.float(forKey: "TrapTube.EQ.Bass")) }
        if defaults.object(forKey: "TrapTube.EQ.Master") != nil { setMasterGainPercent(defaults.float(forKey: "TrapTube.EQ.Master")) }
        NotificationCenter.default.addObserver(self, selector: #selector(handleInterruption(_:)),
                                               name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleRouteChange(_:)),
                                               name: AVAudioSession.routeChangeNotification, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    public func setBandGain(_ gain: Float, at index: Int) {
        guard Self.frequencies.indices.contains(index) else { return }
        let value = min(12, max(-12, gain))
        lock.lock(); bandGains[index] = value; lock.unlock()
        UserDefaults.standard.set(value, forKey: "TrapTube.EQ.Band.\(index)")
        engineEQ.bands[index].gain = value
    }

    public func bandGain(at index: Int) -> Float {
        guard Self.frequencies.indices.contains(index) else { return 0 }
        lock.lock(); defer { lock.unlock() }; return bandGains[index]
    }

    public func setBassBoost(_ decibels: Float) {
        let value = min(20, max(0, decibels))
        lock.lock(); bassBoost = value; lock.unlock()
        UserDefaults.standard.set(value, forKey: "TrapTube.EQ.Bass")
        engineEQ.bands[16].gain = value
    }

    public var bassBoostDecibels: Float {
        lock.lock(); defer { lock.unlock() }; return bassBoost
    }

    public func setMasterGainPercent(_ percent: Float) {
        let value = min(200, max(0, percent))
        lock.lock(); masterPercent = value; lock.unlock()
        // AVAudioUnitEQ globalGain provides the 0-200% master gain range.
        UserDefaults.standard.set(value, forKey: "TrapTube.EQ.Master")
        engineEQ.globalGain = value == 0 ? -96 : 20 * log10(value / 100)
    }

    public var masterGainPercent: Float {
        lock.lock(); defer { lock.unlock() }; return masterPercent
    }

    /// Attach after AVAsset has finished loading its audio-track metadata.
    /// This avoids the synchronous empty-track race when YouTube replaces items.
    public func attachWhenReady(to item: AVPlayerItem) async -> Bool {
        attachmentLock.lock()
        let alreadyAttached = attachmentRecords[ObjectIdentifier(item)]?.item === item
        attachmentLock.unlock()
        if alreadyAttached { return true }

        do {
            let tracks = try await item.asset.load(.tracks)
            guard !Task.isCancelled else { return false }
            return attach(to: item, tracks: tracks.filter { $0.mediaType == .audio })
        } catch {
            NSLog("[TrapTube EQ] Unable to load player audio tracks: %@", error.localizedDescription)
            return false
        }
    }

    /// Synchronous compatibility path for callers whose asset tracks are already loaded.
    @discardableResult
    public func attachToPlayer(_ player: AVPlayer) -> Bool {
        guard let item = player.currentItem else { return false }
        return attach(to: item)
    }

    @discardableResult
    public func attach(to item: AVPlayerItem) -> Bool {
        attach(to: item, tracks: item.asset.tracks(withMediaType: .audio))
    }

    @discardableResult
    private func attach(to item: AVPlayerItem, tracks: [AVAssetTrack]) -> Bool {
        guard !tracks.isEmpty else {
            NSLog("[TrapTube EQ] Player item has no loaded audio tracks")
            return false
        }
        attachmentLock.lock()
        defer { attachmentLock.unlock() }
        let itemID = ObjectIdentifier(item)
        if attachmentRecords[itemID]?.item === item { return true }

        let originalMix = item.audioMix
        // A second processing tap on a track, or replacing existing per-track
        // mix parameters, can silently disable host processing. Fail closed rather
        // than altering an audio mix we do not own.
        if let originalMix,
           originalMix.inputParameters.contains(where: { existing in
               tracks.contains(where: { $0.trackID == existing.trackID })
           }) {
            NSLog("[TrapTube EQ] Existing host audio-mix parameters found; leaving host mix untouched")
            return false
        }

        let mix = AVMutableAudioMix()
        var parameters: [AVAudioMixInputParameters] = originalMix?.inputParameters ?? []
        for track in tracks {
            let input = AVMutableAudioMixInputParameters(track: track)
            var callbacks = MTAudioProcessingTapCallbacks(
                version: kMTAudioProcessingTapCallbacksVersion_0,
                clientInfo: Unmanaged.passUnretained(self).toOpaque(),
                init: { _, clientInfo, storageOut in storageOut.pointee = clientInfo },
                finalize: { _ in },
                prepare: { tap, _, processingFormat in
                    let raw = MTAudioProcessingTapGetStorage(tap)
                    let manager = Unmanaged<TrapTubeEQManager>.fromOpaque(raw).takeUnretainedValue()
                    let flags = processingFormat.pointee.mFormatFlags
                    let isFloat = (flags & kAudioFormatFlagIsFloat) != 0
                    manager.configureTap(sampleRate: processingFormat.pointee.mSampleRate, isFloatPCM: isFloat)
                    if !isFloat {
                        NSLog("[TrapTube EQ] Unsupported decoded PCM format (flags=0x%x, bits=%u); EQ tap will pass audio unchanged",
                              flags, processingFormat.pointee.mBitsPerChannel)
                    }
                },
                unprepare: { _ in },
                process: { tap, frames, _, bufferList, framesOut, flagsOut in
                    let status = MTAudioProcessingTapGetSourceAudio(tap, frames, bufferList, flagsOut, nil, framesOut)
                    guard status == noErr else { return }
                    let raw = MTAudioProcessingTapGetStorage(tap)
                    let manager = Unmanaged<TrapTubeEQManager>.fromOpaque(raw).takeUnretainedValue()
                    manager.processTapBuffers(bufferList, frameCount: Int(framesOut.pointee))
                })
            var tap: MTAudioProcessingTap?
            let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                                    kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
            guard status == noErr, let tap else {
                NSLog("[TrapTube EQ] MediaToolbox rejected audio tap creation (status=%d)", status)
                return false
            }
            input.audioTapProcessor = tap
            parameters.append(input)
        }
        mix.inputParameters = parameters
        item.audioMix = mix
        attachmentRecords[itemID] = AttachmentRecord(item: item, originalMix: originalMix, installedMix: mix)
        NSLog("[TrapTube EQ] Installed audio tap on %lu audio track(s)", UInt(tracks.count))
        return true
    }

    public func detach(from item: AVPlayerItem) {
        attachmentLock.lock()
        defer { attachmentLock.unlock() }
        let itemID = ObjectIdentifier(item)
        guard let record = attachmentRecords[itemID], record.item === item else {
            attachmentRecords.removeValue(forKey: itemID)
            return
        }
        // Restore only if our mix is still installed. If the host replaced it
        // after attachment, do not overwrite that newer host-owned mix.
        if item.audioMix === record.installedMix {
            item.audioMix = record.originalMix
        }
        attachmentRecords.removeValue(forKey: itemID)
    }

    /// Use this engine path for audio files/stems owned and decoded by TrapTube.
    public func play(file url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default,
                                                        options: [.allowAirPlay, .allowBluetoothA2DP, .mixWithOthers])
        try AVAudioSession.sharedInstance().setActive(true)
        if !engine.isRunning { try engine.start() }
        playerNode.stop()
        playerNode.scheduleFile(file, at: nil)
        playerNode.play()
    }

    public func stopOwnedAudio() { playerNode.stop() }

    private func configureEngineGraph() {
        engine.attach(playerNode)
        engine.attach(engineEQ)
        engine.attach(limiter)
        for index in 0..<16 {
            let band = engineEQ.bands[index]
            band.filterType = .parametric
            band.frequency = Self.frequencies[index]
            band.bandwidth = 1.0
            band.gain = 0
            band.bypass = false
        }
        let shelf = engineEQ.bands[16]
        shelf.filterType = .lowShelf
        shelf.frequency = 100
        shelf.gain = 0
        shelf.bypass = false
        engine.connect(playerNode, to: engineEQ, format: nil)
        engine.connect(engineEQ, to: limiter, format: nil)
        engine.connect(limiter, to: engine.mainMixerNode, format: nil)
        engine.prepare()
    }

    private func configureTap(sampleRate: Double, isFloatPCM: Bool) {
        lock.lock()
        tapSampleRate = max(8000, sampleRate)
        tapIsFloatPCM = isFloatPCM
        tapStates = []
        lock.unlock()
    }

    private func processTapBuffers(_ list: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) {
        guard frameCount > 0 else { return }
        lock.lock()
        let gains = bandGains
        let bass = bassBoost
        let master = masterPercent / 100
        let sampleRate = tapSampleRate
        let isFloatPCM = tapIsFloatPCM
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        if !isFloatPCM { lock.unlock(); return }
        if tapStates.count != buffers.count || buffers.enumerated().contains(where: { index, buffer in
            tapStates[index].count != max(1, Int(buffer.mNumberChannels)) * 17
        }) {
            tapStates = buffers.map { buffer in Array(repeating: BiquadState(), count: max(1, Int(buffer.mNumberChannels)) * 17) }
        }
        for (bufferIndex, buffer) in buffers.enumerated() {
            guard let data = buffer.mData, buffer.mDataByteSize >= UInt32(MemoryLayout<Float>.size) else { continue }
            let channels = max(1, Int(buffer.mNumberChannels))
            let samples = min(Int(buffer.mDataByteSize) / MemoryLayout<Float>.size, frameCount * channels)
            let pcm = data.bindMemory(to: Float.self, capacity: samples)
            var coefficients = gains.enumerated().map { index, gain in
                BiquadCoefficients.peaking(frequency: Double(Self.frequencies[index]), gainDB: Double(gain), sampleRate: sampleRate, q: 1.0)
            }
            coefficients.append(BiquadCoefficients.lowShelf(frequency: 100, gainDB: Double(bass), sampleRate: sampleRate))
            for sample in 0..<samples {
                var value = pcm[sample] * master
                let channel = sample % channels
                for band in 0..<17 {
                    let stateIndex = channel * 17 + band
                    value = tapStates[bufferIndex][stateIndex].process(value, coefficients[band])
                }
                let magnitude = abs(value)
                if magnitude > 0.85 {
                    let compressed = 0.85 + 0.15 * tanhf((magnitude - 0.85) / 0.15)
                    pcm[sample] = value < 0 ? -compressed : compressed
                } else {
                    pcm[sample] = value
                }
            }
        }
        lock.unlock()
    }

    @objc private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if type == .ended {
            do { try AVAudioSession.sharedInstance().setActive(true); try engine.start() }
            catch { NSLog("[TrapTube EQ] Audio engine resume failed: %@", error.localizedDescription) }
        } else {
            playerNode.pause()
        }
    }

    @objc private func handleRouteChange(_ note: Notification) {
        guard engine.isRunning else { return }
        engine.pause()
        do { try engine.start() }
        catch { NSLog("[TrapTube EQ] Route-change restart failed: %@", error.localizedDescription) }
    }
}


struct BiquadCoefficients {
    var b0: Double; var b1: Double; var b2: Double
    var a1: Double; var a2: Double
    static func peaking(frequency: Double, gainDB: Double, sampleRate: Double, q: Double) -> Self {
        let a = pow(10, gainDB / 40)
        let w = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(w) / (2 * q)
        let cosine = cos(w)
        let a0 = 1 + alpha / a
        return Self(b0: (1 + alpha * a) / a0, b1: (-2 * cosine) / a0,
                    b2: (1 - alpha * a) / a0, a1: (-2 * cosine) / a0,
                    a2: (1 - alpha / a) / a0)
    }
    static func lowShelf(frequency: Double, gainDB: Double, sampleRate: Double) -> Self {
        let a = pow(10, gainDB / 40)
        let w = 2 * Double.pi * frequency / sampleRate
        let cosine = cos(w), sine = sin(w), alpha = sine / sqrt(2)
        let root = 2 * sqrt(a) * alpha
        let a0 = (a + 1) + (a - 1) * cosine + root
        return Self(b0: a * ((a + 1) - (a - 1) * cosine + root) / a0,
                    b1: 2 * a * ((a - 1) - (a + 1) * cosine) / a0,
                    b2: a * ((a + 1) - (a - 1) * cosine - root) / a0,
                    a1: -2 * ((a - 1) + (a + 1) * cosine) / a0,
                    a2: ((a + 1) + (a - 1) * cosine - root) / a0)
    }
}
struct BiquadState {
    var z1 = 0.0
    var z2 = 0.0
    mutating func process(_ input: Float, _ c: BiquadCoefficients) -> Float {
        let x = Double(input)
        let output = c.b0 * x + z1
        z1 = c.b1 * x - c.a1 * output + z2
        z2 = c.b2 * x - c.a2 * output
        return Float(output)
    }
}

