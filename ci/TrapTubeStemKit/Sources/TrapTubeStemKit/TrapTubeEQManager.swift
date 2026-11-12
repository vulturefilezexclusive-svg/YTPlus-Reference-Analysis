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
    private var eqEnabled = true
    private var attachmentStatusText = "Not attached yet"
    // Attachment bookkeeping is separate from the audio callback's parameter lock.
    // The lock covers the entire install/restore transaction so async callers cannot
    // race and install duplicate taps on the same AVPlayerItem.
    private let attachmentLock = NSRecursiveLock()
    private final class EQTapContext {
        unowned let manager: TrapTubeEQManager
        var sampleRate: Double = 44100
        var isFloatPCM = false
        var isInt16PCM = false
        var states: [[BiquadState]] = []
        var coefficients = Array(repeating: BiquadCoefficients.identity, count: 17)
        init(manager: TrapTubeEQManager) { self.manager = manager }
    }
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
        if defaults.object(forKey: "TrapTube.EQ.Enabled") != nil { eqEnabled = defaults.bool(forKey: "TrapTube.EQ.Enabled") }
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

    public var isEQEnabled: Bool {
        lock.lock(); defer { lock.unlock() }; return eqEnabled
    }

    public func setEQEnabled(_ enabled: Bool) {
        lock.lock(); eqEnabled = enabled; lock.unlock()
        UserDefaults.standard.set(enabled, forKey: "TrapTube.EQ.Enabled")
    }

    public func isAttached(to item: AVPlayerItem) -> Bool {
        attachmentLock.lock(); defer { attachmentLock.unlock() }
        return attachmentRecords[ObjectIdentifier(item)]?.item === item
    }

    public var attachmentStatus: String {
        lock.lock(); defer { lock.unlock() }; return attachmentStatusText
    }

    private var hookFiredCount = 0

    /// Diagnostic probe: called from the tweak's player/item hooks so the EQ
    /// page's live status proves the hooks fired and how far attach got.
    @objc public func noteHookFired(_ source: String) {
        lock.lock(); hookFiredCount += 1; let count = hookFiredCount; lock.unlock()
        setAttachmentStatus("Player hook fired (\(source) #\(count)) - attaching...")
    }

    public func setAttachmentStatus(_ text: String) {
        lock.lock(); attachmentStatusText = text; lock.unlock()
        NotificationCenter.default.post(name: Notification.Name("TrapTubeEQAttachmentStatusChanged"),
                                        object: nil, userInfo: ["status": text])
    }

    public func resetAll() {
        for index in Self.frequencies.indices { setBandGain(0, at: index) }
        setBassBoost(0)
        setMasterGainPercent(100)
    }

    /// Attach after AVAsset has finished loading its audio-track metadata.
    /// This avoids the synchronous empty-track race when YouTube replaces items.
    public func attachWhenReady(to item: AVPlayerItem) async -> Bool {
        attachmentLock.lock()
        let alreadyAttached = attachmentRecords[ObjectIdentifier(item)]?.item === item
        attachmentLock.unlock()
        if alreadyAttached { return true }

        setAttachmentStatus("Loading this stream's audio tracks...")
        do {
            let tracks = try await item.asset.load(.tracks)
            guard !Task.isCancelled else { return false }
            let audioTracks = tracks.filter { $0.mediaType == .audio }
            if !audioTracks.isEmpty {
                setAttachmentStatus("Attaching EQ to the stream...")
            }
            return attach(to: item, tracks: audioTracks)
        } catch {
            setAttachmentStatus("Could not load this stream's audio tracks")
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
            setAttachmentStatus("No audio tracks exposed by this stream")
            NSLog("[TrapTube EQ] Player item has no loaded audio tracks")
            return false
        }
        attachmentLock.lock()
        defer { attachmentLock.unlock() }
        let itemID = ObjectIdentifier(item)
        if attachmentRecords[itemID]?.item === item { return true }

        let originalMix = item.audioMix
        // Host parameters that carry no processing tap of their own can be
        // reused: copy them, keep their settings, and add our tap. Only a
        // foreign tap already occupying one of this item's audio tracks is a
        // real conflict; previously ANY host parameter blocked attachment
        // for the whole item.
        var parameters: [AVAudioMixInputParameters] = []
        if let originalMix {
            for existing in originalMix.inputParameters {
                guard tracks.contains(where: { $0.trackID == existing.trackID }) else {
                    parameters.append(existing)
                    continue
                }
                if existing.audioTapProcessor != nil {
                    setAttachmentStatus("Another audio tap already controls this stream")
                    NSLog("[TrapTube EQ] A foreign audio tap already occupies track %d; leaving host mix untouched", existing.trackID)
                    return false
                }
                if let mutableCopy = existing.mutableCopy() as? AVMutableAudioMixInputParameters {
                    parameters.append(mutableCopy)
                } else {
                    parameters.append(existing)
                }
            }
        }

        let mix = AVMutableAudioMix()
        for track in tracks {
            // Attach to the reused host parameter copy for this track when one
            // exists, instead of adding a second parameter entry for it.
            let input = (parameters.first(where: { $0.trackID == track.trackID }) as? AVMutableAudioMixInputParameters)
                ?? AVMutableAudioMixInputParameters(track: track)
            let tapContext = EQTapContext(manager: self)
            let retainedTapContext = Unmanaged.passRetained(tapContext)
            var callbacks = MTAudioProcessingTapCallbacks(
                version: kMTAudioProcessingTapCallbacksVersion_0,
                clientInfo: retainedTapContext.toOpaque(),
                init: { _, clientInfo, storageOut in storageOut.pointee = clientInfo },
                finalize: { tap in
                    let raw = MTAudioProcessingTapGetStorage(tap)
                    Unmanaged<EQTapContext>.fromOpaque(raw).release()
                },
                prepare: { tap, _, processingFormat in
                    let raw = MTAudioProcessingTapGetStorage(tap)
                    let context = Unmanaged<EQTapContext>.fromOpaque(raw).takeUnretainedValue()
                    let format = processingFormat.pointee
                    context.sampleRate = max(8000, format.mSampleRate)
                    context.isFloatPCM = format.mFormatID == kAudioFormatLinearPCM &&
                                         (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0 &&
                                         (format.mFormatFlags & kAudioFormatFlagIsBigEndian) == 0 &&
                                         format.mBitsPerChannel == 32 &&
                                         format.mBytesPerFrame >= UInt32(MemoryLayout<Float>.size)
                    context.isInt16PCM = format.mFormatID == kAudioFormatLinearPCM &&
                                         (format.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0 &&
                                         (format.mFormatFlags & kAudioFormatFlagIsBigEndian) == 0 &&
                                         format.mBitsPerChannel == 16 &&
                                         format.mBytesPerFrame >= UInt32(MemoryLayout<Int16>.size)
                    let channelCount = max(1, Int(format.mChannelsPerFrame))
                    if context.isFloatPCM || context.isInt16PCM {
                        if (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0 {
                            context.states = (0..<channelCount).map { _ in
                                Array(repeating: BiquadState(), count: 17)
                            }
                        } else {
                            context.states = [Array(repeating: BiquadState(), count: channelCount * 17)]
                        }
                    } else {
                        context.states.removeAll(keepingCapacity: true)
                    }
                    if !context.isFloatPCM && !context.isInt16PCM {
                        NSLog("[TrapTube EQ] Unsupported decoded PCM format (flags=0x%x, bits=%u); EQ tap will pass audio unchanged",
                              format.mFormatFlags, format.mBitsPerChannel)
                    }
                },
                unprepare: { tap in
                    let raw = MTAudioProcessingTapGetStorage(tap)
                    let context = Unmanaged<EQTapContext>.fromOpaque(raw).takeUnretainedValue()
                    context.states.removeAll(keepingCapacity: true)
                },
                process: { tap, frames, _, bufferList, framesOut, flagsOut in
                    let status = MTAudioProcessingTapGetSourceAudio(tap, frames, bufferList, flagsOut, nil, framesOut)
                    guard status == noErr else { return }
                    let raw = MTAudioProcessingTapGetStorage(tap)
                    let context = Unmanaged<EQTapContext>.fromOpaque(raw).takeUnretainedValue()
                    context.manager.processTapBuffers(bufferList, frameCount: Int(framesOut.pointee), context: context)
                })
            var tap: MTAudioProcessingTap?
            let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                                    kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
            guard status == noErr, let tap else {
                // Creation did not transfer the retained client context to a tap.
                retainedTapContext.release()
                NSLog("[TrapTube EQ] MediaToolbox rejected audio tap creation (status=%d)", status)
                return false
            }
            input.audioTapProcessor = tap
            if !parameters.contains(where: { $0 === input }) { parameters.append(input) }
        }
        mix.inputParameters = parameters
        item.audioMix = mix
        attachmentRecords[itemID] = AttachmentRecord(item: item, originalMix: originalMix, installedMix: mix)
        setAttachmentStatus("Attached to the playing stream")
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
        setAttachmentStatus("Not attached")
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

    private func processTapBuffers(_ list: UnsafeMutablePointer<AudioBufferList>,
                                   frameCount: Int,
                                   context: EQTapContext) {
        guard frameCount > 0, context.isFloatPCM || context.isInt16PCM else { return }
        lock.lock()
        let gains = bandGains
        let bass = bassBoost
        let master = masterPercent / 100
        let enabled = eqEnabled
        lock.unlock()
        // Bypass: samples pass bit-transparent, including no saturation stage.
        guard enabled else { return }
        let sampleRate = context.sampleRate
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        // The state arrays are allocated in prepare(), never on the render callback.
        // If the host changes the buffer topology unexpectedly, bypass this block safely.
        guard context.states.count == buffers.count else { return }
        for (bufferIndex, buffer) in buffers.enumerated() {
            guard context.states[bufferIndex].count >= max(1, Int(buffer.mNumberChannels)) * 17 else { return }
        }
        for index in gains.indices {
            context.coefficients[index] = BiquadCoefficients.peaking(
                frequency: min(Double(Self.frequencies[index]), sampleRate * 0.45),
                gainDB: Double(gains[index]), sampleRate: sampleRate, q: 1.0
            )
        }
        context.coefficients[16] = BiquadCoefficients.lowShelf(
            frequency: min(100, sampleRate * 0.20), gainDB: Double(bass), sampleRate: sampleRate
        )
        for (bufferIndex, buffer) in buffers.enumerated() {
            guard let data = buffer.mData else { continue }
            let channels = max(1, Int(buffer.mNumberChannels))
            if context.isFloatPCM {
                guard buffer.mDataByteSize >= UInt32(MemoryLayout<Float>.size) else { continue }
                let samples = min(Int(buffer.mDataByteSize) / MemoryLayout<Float>.size, frameCount * channels)
                let pcm = data.bindMemory(to: Float.self, capacity: samples)
                for sample in 0..<samples {
                    pcm[sample] = processSample(pcm[sample], master: master, channel: sample % channels,
                                                bufferIndex: bufferIndex, context: context)
                }
            } else if context.isInt16PCM {
                guard buffer.mDataByteSize >= UInt32(MemoryLayout<Int16>.size) else { continue }
                let samples = min(Int(buffer.mDataByteSize) / MemoryLayout<Int16>.size, frameCount * channels)
                let pcm = data.bindMemory(to: Int16.self, capacity: samples)
                for sample in 0..<samples {
                    let input = Float(pcm[sample]) / 32768.0
                    let output = processSample(input, master: master, channel: sample % channels,
                                               bufferIndex: bufferIndex, context: context)
                    pcm[sample] = Int16(min(1, max(-1, output)) * 32767.0)
                }
            }
        }
    }

    private func processSample(_ input: Float, master: Float, channel: Int,
                               bufferIndex: Int, context: EQTapContext) -> Float {
        var value = input * master
        for band in 0..<17 {
            let stateIndex = channel * 17 + band
            value = context.states[bufferIndex][stateIndex].process(value, context.coefficients[band])
        }
        let magnitude = abs(value)
        if magnitude > 0.85 {
            let compressed = 0.85 + 0.15 * tanhf((magnitude - 0.85) / 0.15)
            return value < 0 ? -compressed : compressed
        }
        return value
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
    static let identity = Self(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)
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

