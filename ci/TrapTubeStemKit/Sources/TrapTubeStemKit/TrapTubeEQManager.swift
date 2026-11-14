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
        // Round 24: the soft limiter's state. The gain is the
        // smoothed, stereo-linked gain reduction carried across
        // process calls; the two curves are per-process-call
        // scratch (per-frame peaks, then per-frame gains) sized
        // ONCE in prepare() to the host's maximum frame count, so
        // the render callback itself never allocates.
        var limiterGain: Float = 1
        var limiterPeaks: [Float] = []
        var limiterGains: [Float] = []
        init(manager: TrapTubeEQManager) { self.manager = manager }
    }
    private final class AttachmentRecord {
        weak var item: AVPlayerItem?
        let originalMix: AVAudioMix?
        let installedMix: AVAudioMix
        /// The same mix as a mutable object, kept so a re-attach can
        /// repair its parameter list IN PLACE (Round 20) instead of
        /// assigning a new mix to the playing item.
        let installedMutableMix: AVMutableAudioMix
        init(item: AVPlayerItem, originalMix: AVAudioMix?, installedMix: AVAudioMix,
             installedMutableMix: AVMutableAudioMix) {
            self.item = item
            self.originalMix = originalMix
            self.installedMix = installedMix
            self.installedMutableMix = installedMutableMix
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

    /// Round 24: posted by every settings setter so live
    /// readouts derived from the settings (the auto headroom
    /// line in the EQ panel) can refresh without polling.
    private func postSettingsChanged() {
        NotificationCenter.default.post(name: Notification.Name("TrapTubeEQSettingsChanged"),
                                        object: nil)
    }

    public func setBandGain(_ gain: Float, at index: Int) {
        guard Self.frequencies.indices.contains(index) else { return }
        let value = min(12, max(-12, gain))
        lock.lock(); bandGains[index] = value; lock.unlock()
        UserDefaults.standard.set(value, forKey: "TrapTube.EQ.Band.\(index)")
        engineEQ.bands[index].gain = value
        postSettingsChanged()
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
        postSettingsChanged()
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
        postSettingsChanged()
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
        postSettingsChanged()
    }

    // MARK: - Round 24: automatic headroom (ONE computation, both paths)
    //
    // YouTube's audio peaks at the format ceiling, so boosting a
    // curve into it has nowhere to go but clipping: before this
    // round neither render path had any headroom management at
    // all, and the bass shelf (up to +20 dB) stacks on top of the
    // 31/62 Hz band boosts and each preset's own bass value. The
    // compensation below evaluates the ACTUAL cascade magnitude
    // response of the current settings - designed with the very
    // BiquadCoefficients the tap renders with - at probe
    // frequencies (the 16 band centers plus probes across the
    // shelf's region, where stacking peaks), and pulls the whole
    // signal down by exactly the worst cumulative boost, ahead of
    // the user's master gain. Cuts need no compensation, so the
    // value is never positive. The tap applies it from its
    // render-time snapshot; the Ghost engine applies the same
    // number as its AVAudioUnitEQ globalGain (see
    // TrapTubeGhostAudio.applyManagerState); the EQ panel shows
    // it as a read-only "Headroom" line.

    /// Probes across the 100 Hz shelf's region (the band centers
    /// are probed too, from `frequencies`).
    private static let headroomShelfProbes: [Double] = [20, 40, 60, 80, 100, 150, 200]
    /// The reference rate the shared evaluation runs at. The
    /// tap's live path evaluates at the stream's real rate via
    /// the overload below; at these frequencies the difference
    /// is far below a tenth of a dB.
    private static let headroomReferenceSampleRate: Double = 48_000

    /// Designs the 17-section cascade (16 peaking + bass shelf)
    /// exactly as the tap's process callback designs it.
    private static func designedCoefficients(bandGains: [Float], bass: Float,
                                             sampleRate: Double) -> [BiquadCoefficients] {
        var coefficients: [BiquadCoefficients] = []
        for index in frequencies.indices {
            coefficients.append(.peaking(
                frequency: min(Double(frequencies[index]), sampleRate * 0.45),
                gainDB: Double(bandGains[index]), sampleRate: sampleRate, q: 1.0))
        }
        coefficients.append(.lowShelf(
            frequency: min(100, sampleRate * 0.20), gainDB: Double(bass),
            sampleRate: sampleRate))
        return coefficients
    }

    /// |H| of one designed cascade at one probe frequency, in dB.
    private static func cascadeResponseDB(coefficients: [BiquadCoefficients],
                                          probe: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * probe / sampleRate
        let cw = cos(w), sw = sin(w), cw2 = cos(2 * w), sw2 = sin(2 * w)
        var magnitude = 1.0
        for c in coefficients {
            let nr = c.b0 + c.b1 * cw + c.b2 * cw2
            let ni = -c.b1 * sw - c.b2 * sw2
            let dr = 1 + c.a1 * cw + c.a2 * cw2
            let di = -c.a1 * sw - c.a2 * sw2
            let section = (nr * nr + ni * ni).squareRoot() / max((dr * dr + di * di).squareRoot(), 1e-12)
            magnitude *= section
        }
        return magnitude > 0 ? 20 * log10(magnitude) : 0
    }

    /// The worst cumulative boost (dB, never negative) a designed
    /// cascade produces at any probe frequency. Scalar-only: the
    /// coefficient array is the caller's (the tap passes its
    /// context's preallocated one), so this is safe to run on the
    /// render thread.
    static func peakBoostDB(coefficients: [BiquadCoefficients], sampleRate: Double) -> Double {
        var peak = 0.0
        for index in frequencies.indices {
            peak = max(peak, cascadeResponseDB(coefficients: coefficients,
                                               probe: Double(frequencies[index]),
                                               sampleRate: sampleRate))
        }
        for probe in headroomShelfProbes {
            peak = max(peak, cascadeResponseDB(coefficients: coefficients,
                                               probe: probe, sampleRate: sampleRate))
        }
        return peak
    }

    /// The shared headroom computation: the worst-case cumulative
    /// boost of the given band gains + bass shelf, in dB.
    static func cascadePeakBoostDB(bandGains: [Float], bass: Float,
                                   sampleRate: Double = headroomReferenceSampleRate) -> Double {
        peakBoostDB(coefficients: designedCoefficients(bandGains: bandGains, bass: bass,
                                                       sampleRate: sampleRate),
                    sampleRate: sampleRate)
    }

    /// The compensation for the CURRENT settings, in dB: zero or
    /// negative, applied ahead of the master gain on both paths.
    public var headroomCompensationDB: Float {
        lock.lock()
        let gains = bandGains
        let bass = bassBoost
        lock.unlock()
        return Float(-Self.cascadePeakBoostDB(bandGains: gains, bass: bass))
    }

    /// Round 19: attachment truth is what is on the item NOW, not what
    /// was true when the tap was installed. The pre-Round-19 check only
    /// asked "does a record exist for this item?", and every retry path
    /// (the readyToPlay retry, the audioMix KVO, attachWhenReady) trusts
    /// that answer - so when anything replaced or reset the item's
    /// audioMix after installation (AVFoundation rebuilding the mix
    /// around a pause/stop, the fullscreen controller's handoff, a PiP
    /// restore), the tap was silently gone while the record kept saying
    /// "attached" and no path ever re-installed it. Validation compares
    /// the record against the item's LIVE mix: identity with the
    /// installed mix, or - because a live mix can be a copy that still
    /// carries our tap - any tap processor present in the current mix
    /// (this manager is the only tap installer in the app, and the
    /// foreign-tap guard in attach() refuses to install alongside one,
    /// so a tap on an item with a record is ours). A record whose tap
    /// is gone from the live mix is stale: it is pruned here so the
    /// next attach starts clean. Call with attachmentLock held.
    private func validatedAttachment(for item: AVPlayerItem) -> AttachmentRecord? {
        let itemID = ObjectIdentifier(item)
        guard let record = attachmentRecords[itemID], record.item === item else { return nil }
        let liveMix = item.audioMix
        if liveMix === record.installedMix {
            if record.installedMix.inputParameters.contains(where: { $0.audioTapProcessor != nil }) {
                return record
            }
        } else if let liveMix,
                  liveMix.inputParameters.contains(where: { $0.audioTapProcessor != nil }) {
            return record
        }
        // The installed mix was displaced and the live mix carries no
        // tap: drop the stale record WITHOUT touching item.audioMix
        // (that mix belongs to whoever installed it now).
        attachmentRecords.removeValue(forKey: itemID)
        NSLog("[TrapTube EQ] Attachment record was stale (tap no longer on the item's audio mix); pruned for re-attach")
        return nil
    }

    public func isAttached(to item: AVPlayerItem) -> Bool {
        attachmentLock.lock(); defer { attachmentLock.unlock() }
        return validatedAttachment(for: item) != nil
    }

    /// Round 19: build the shared manager - and with it the AVAudioEngine
    /// graph its init constructs and prepares - ahead of the first
    /// attach, so that one-time cost is paid while the user is still
    /// browsing the feed instead of inside the first tap-to-sound path.
    public static func prewarm() {
        _ = shared
    }

    public var attachmentStatus: String {
        lock.lock(); defer { lock.unlock() }
        // The RemoteIO output path (used for YouTube's own player, which
        // never vends an AVPlayer) reports through user defaults.
        if attachmentStatusText == "Not attached yet",
           let output = UserDefaults.standard.string(forKey: "TrapTube.EQ.OutputStatus") {
            return output
        }
        return attachmentStatusText
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
        let alreadyAttached = validatedAttachment(for: item) != nil
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
        // Round 20 (seamless re-attach): snapshot any existing record
        // and the playhead BEFORE validation prunes a stale record.
        // Nothing in this path ever replaces the player item, reloads
        // the asset or seeks - the playhead lives on the item's
        // timeline, which attach never touches - and the two install
        // modes below are ordered to disturb the live pipeline as
        // little as possible.
        let priorRecord = attachmentRecords[itemID]
        let isReattach = priorRecord != nil && priorRecord?.item === item
        let positionBefore = item.currentTime().seconds
        // Round 19: a record alone is not proof - validate against the
        // item's live mix (this also prunes a displaced record so the
        // install below starts from the mix that is actually there).
        if validatedAttachment(for: item) != nil { return true }
        setAttachmentStatus("Installing the EQ tap on this stream...")

        // Mode 1 (zero pipeline disturbance): the item's live mix IS
        // the mix object we installed earlier - only its parameter
        // list lost our tap. Rebuild the tap parameters on that same
        // object and return: the item keeps the identical mix
        // instance, AVFoundation swaps nothing, and playback runs
        // through the re-attach untouched at the same position.
        if isReattach, let priorRecord, let liveMix = item.audioMix,
           liveMix === priorRecord.installedMutableMix {
            guard let parameters = makeTapParameters(tracks: tracks, originalMix: liveMix) else { return false }
            priorRecord.installedMutableMix.inputParameters = parameters
            setAttachmentStatus("Attached to the playing stream")
            postReattachBreadcrumb(item: item, positionBefore: positionBefore, inPlace: true)
            NSLog("[TrapTube EQ] Re-attached EQ tap in place on the live mix (no mix swap, position preserved)")
            return true
        }

        // Mode 2: the live mix belongs to someone else now, so a new
        // mix carrying our tap must be assigned. This is the ONLY mix
        // assignment in the re-attach path, it is built from the
        // item's CURRENT mix (host parameters carried over by
        // makeTapParameters), and the breadcrumb below proves the
        // playhead survived it.
        let originalMix = item.audioMix
        guard let parameters = makeTapParameters(tracks: tracks, originalMix: originalMix) else { return false }
        let mix = AVMutableAudioMix()
        mix.inputParameters = parameters
        item.audioMix = mix
        attachmentRecords[itemID] = AttachmentRecord(item: item, originalMix: originalMix,
                                                    installedMix: mix, installedMutableMix: mix)
        setAttachmentStatus("Attached to the playing stream")
        NSLog("[TrapTube EQ] Installed audio tap on %lu audio track(s)", UInt(tracks.count))
        if isReattach {
            postReattachBreadcrumb(item: item, positionBefore: positionBefore, inPlace: false)
        }
        return true
    }

    /// Builds the input-parameter list for an install: the host's own
    /// parameters carried over (copied, settings intact) plus our tap
    /// on each of the item's audio tracks. Returns nil - leaving the
    /// item and its mix untouched - when a foreign tap already
    /// occupies one of the tracks.
    private func makeTapParameters(tracks: [AVAssetTrack], originalMix: AVAudioMix?) -> [AVAudioMixInputParameters]? {
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
                    return nil
                }
                if let mutableCopy = existing.mutableCopy() as? AVMutableAudioMixInputParameters {
                    parameters.append(mutableCopy)
                } else {
                    parameters.append(existing)
                }
            }
        }

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
                prepare: { tap, maxFrames, processingFormat in
                    let raw = MTAudioProcessingTapGetStorage(tap)
                    let context = Unmanaged<EQTapContext>.fromOpaque(raw).takeUnretainedValue()
                    let format = processingFormat.pointee
                    context.sampleRate = max(8000, format.mSampleRate)
                    // Round 24: size the limiter's per-frame
                    // scratch ONCE, here, to the host's stated
                    // maximum - the process callback chunks its
                    // work to this capacity and never allocates.
                    let capacity = max(8192, Int(maxFrames))
                    if context.limiterPeaks.count != capacity {
                        context.limiterPeaks = [Float](repeating: 0, count: capacity)
                        context.limiterGains = [Float](repeating: 1, count: capacity)
                    }
                    context.limiterGain = 1
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
                    context.limiterGain = 1
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
                setAttachmentStatus("The system rejected the EQ audio tap")
                NSLog("[TrapTube EQ] MediaToolbox rejected audio tap creation (status=%d)", status)
                return nil
            }
            input.audioTapProcessor = tap
            if !parameters.contains(where: { $0 === input }) { parameters.append(input) }
        }
        return parameters
    }

    /// Round 20: visible proof of a seamless re-attach. Compares the
    /// playhead across the install and posts the result for the
    /// player's status area: the re-attach happened at the preserved
    /// position - or, if a mix swap ever did move the playhead, the
    /// note says by how much instead of hiding it.
    private func postReattachBreadcrumb(item: AVPlayerItem, positionBefore: Double, inPlace: Bool) {
        let positionAfter = item.currentTime().seconds
        let deltaMs = (positionAfter - positionBefore) * 1000
        func clock(_ seconds: Double) -> String {
            guard seconds.isFinite, seconds >= 0 else { return "0:00" }
            let total = Int(seconds.rounded())
            return String(format: "%d:%02d", total / 60, total % 60)
        }
        let note: String
        if positionBefore.isFinite, positionAfter.isFinite, abs(deltaMs) < 500 {
            note = "EQ re-attached at \(clock(positionAfter)) - position kept\(inPlace ? " (in place, no mix swap)" : "")"
        } else {
            note = "EQ re-attached at \(clock(positionAfter)) - playhead moved \(Int(deltaMs.rounded())) ms"
        }
        NSLog("[TrapTube EQ] %@", note)
        NotificationCenter.default.post(name: Notification.Name("TrapTubeEQReattachBreadcrumb"),
                                        object: nil, userInfo: ["note": note])
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
        // Bypass: samples pass bit-transparent - no cascade, no
        // headroom compensation, no limiter.
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
        // Round 24: automatic headroom, evaluated from the REAL
        // coefficients just designed (the shared computation -
        // see headroomCompensationDB) and folded into the
        // pre-gain ahead of the user's master: a boosted curve
        // arrives at the limiter already level-compensated
        // instead of slamming it.
        let peakBoost = Self.peakBoostDB(coefficients: context.coefficients, sampleRate: sampleRate)
        let preGain = master * powf(10, Float(-peakBoost) / 20)
        // Round 24: the tap's soft limiter, replacing the old
        // per-sample tanh waveshaper (which, fed a hot boosted
        // signal, spent its life in the saturation region and
        // WAS the distortion users heard on bass-heavy presets).
        // This is a true gain-reduction limiter: pass 1 runs the
        // cascade and records the per-frame peak across ALL
        // buffers and channels; an attack/release envelope turns
        // the peaks into ONE gain per frame (stereo-linked, so
        // the image never shifts); pass 2 applies that gain and
        // a soft saturation ceiling as the last-resort guard for
        // transients that outrun the attack. Working ceiling is
        // -1 dBFS. Everything runs on the context's prepare-time
        // scratch (chunked to its capacity), so the callback
        // stays allocation-free with no locks taken here - the
        // settings snapshot above remains the only lock.
        // Enable state: always on while the EQ is enabled. The
        // tap path has never honored the Ghost engine's FX
        // settings (they are engine features by construction),
        // so there is no existing toggle to tie this to; a
        // protective limiter the user cannot switch off is the
        // point of the distortion fix. When the EQ is disabled
        // the whole stage is skipped (bit-transparent, above).
        let ceiling: Float = 0.8913 // -1 dBFS
        let limiting = !context.limiterPeaks.isEmpty
        let chunkSize = limiting ? context.limiterPeaks.count : frameCount
        let attackStep = 1 - expf(-1 / (0.0002 * Float(sampleRate)))
        let releaseStep = 1 - expf(-1 / (0.15 * Float(sampleRate)))
        var frameStart = 0
        while frameStart < frameCount {
            let frameEnd = min(frameStart + chunkSize, frameCount)
            let chunkFrames = frameEnd - frameStart
            if limiting {
                for frame in 0..<chunkFrames { context.limiterPeaks[frame] = 0 }
            }
            // Pass 1: cascade in place (+ peak tracking).
            for (bufferIndex, buffer) in buffers.enumerated() {
                guard let data = buffer.mData else { continue }
                let channels = max(1, Int(buffer.mNumberChannels))
                let firstSample = frameStart * channels
                if context.isFloatPCM {
                    guard buffer.mDataByteSize >= UInt32(MemoryLayout<Float>.size) else { continue }
                    let total = min(Int(buffer.mDataByteSize) / MemoryLayout<Float>.size, frameCount * channels)
                    let lastSample = min(frameEnd * channels, total)
                    guard lastSample > firstSample else { continue }
                    let pcm = data.bindMemory(to: Float.self, capacity: total)
                    for sample in firstSample..<lastSample {
                        let value = processCascadeSample(pcm[sample] * preGain,
                                                         channel: sample % channels,
                                                         bufferIndex: bufferIndex, context: context)
                        pcm[sample] = value
                        if limiting {
                            let frame = sample / channels - frameStart
                            let magnitude = abs(value)
                            if magnitude > context.limiterPeaks[frame] {
                                context.limiterPeaks[frame] = magnitude
                            }
                        }
                    }
                } else if context.isInt16PCM {
                    guard buffer.mDataByteSize >= UInt32(MemoryLayout<Int16>.size) else { continue }
                    let total = min(Int(buffer.mDataByteSize) / MemoryLayout<Int16>.size, frameCount * channels)
                    let lastSample = min(frameEnd * channels, total)
                    guard lastSample > firstSample else { continue }
                    let pcm = data.bindMemory(to: Int16.self, capacity: total)
                    for sample in firstSample..<lastSample {
                        let input = Float(pcm[sample]) / 32768.0
                        let value = processCascadeSample(input * preGain,
                                                         channel: sample % channels,
                                                         bufferIndex: bufferIndex, context: context)
                        pcm[sample] = Int16(min(1, max(-1, value)) * 32767.0)
                        if limiting {
                            let frame = sample / channels - frameStart
                            let magnitude = abs(value)
                            if magnitude > context.limiterPeaks[frame] {
                                context.limiterPeaks[frame] = magnitude
                            }
                        }
                    }
                }
            }
            if limiting {
                // The envelope: dive toward the needed reduction
                // with a ~0.2 ms attack, come back over ~150 ms.
                var gain = context.limiterGain
                for frame in 0..<chunkFrames {
                    let peak = context.limiterPeaks[frame]
                    let target: Float = peak > ceiling ? ceiling / peak : 1
                    if target < gain {
                        gain += attackStep * (target - gain)
                    } else {
                        gain += releaseStep * (target - gain)
                    }
                    context.limiterGains[frame] = gain
                }
                context.limiterGain = gain
                // Pass 2: apply the linked gain + soft ceiling.
                for (bufferIndex, buffer) in buffers.enumerated() {
                    guard let data = buffer.mData else { continue }
                    let channels = max(1, Int(buffer.mNumberChannels))
                    let firstSample = frameStart * channels
                    if context.isFloatPCM {
                        guard buffer.mDataByteSize >= UInt32(MemoryLayout<Float>.size) else { continue }
                        let total = min(Int(buffer.mDataByteSize) / MemoryLayout<Float>.size, frameCount * channels)
                        let lastSample = min(frameEnd * channels, total)
                        guard lastSample > firstSample else { continue }
                        let pcm = data.bindMemory(to: Float.self, capacity: total)
                        for sample in firstSample..<lastSample {
                            let frame = sample / channels - frameStart
                            pcm[sample] = softCeiling(pcm[sample] * context.limiterGains[frame],
                                                      ceiling: ceiling)
                        }
                    } else if context.isInt16PCM {
                        guard buffer.mDataByteSize >= UInt32(MemoryLayout<Int16>.size) else { continue }
                        let total = min(Int(buffer.mDataByteSize) / MemoryLayout<Int16>.size, frameCount * channels)
                        let lastSample = min(frameEnd * channels, total)
                        guard lastSample > firstSample else { continue }
                        let pcm = data.bindMemory(to: Int16.self, capacity: total)
                        for sample in firstSample..<lastSample {
                            let frame = sample / channels - frameStart
                            let value = softCeiling(Float(pcm[sample]) / 32768.0 * context.limiterGains[frame],
                                                    ceiling: ceiling)
                            pcm[sample] = Int16(min(1, max(-1, value)) * 32767.0)
                        }
                    }
                }
            }
            frameStart = frameEnd
        }
    }

    /// One sample through the 17 designed sections (16 peaking
    /// bands + the bass shelf). The pre-gain (master x headroom)
    /// is the caller's; level protection is the limiter's, in
    /// processTapBuffers.
    private func processCascadeSample(_ input: Float, channel: Int,
                                      bufferIndex: Int, context: EQTapContext) -> Float {
        var value = input
        for band in 0..<17 {
            let stateIndex = channel * 17 + band
            value = context.states[bufferIndex][stateIndex].process(value, context.coefficients[band])
        }
        return value
    }

    /// The limiter's last-resort ceiling: a soft saturation whose
    /// asymptote sits just above the -1 dBFS working ceiling. The
    /// gain reduction does the real work; this only catches what
    /// outruns the attack inside a single frame, and unlike the
    /// pre-Round-24 waveshaper it is fed a compensated signal, so
    /// it engages on transients instead of living in saturation.
    private func softCeiling(_ value: Float, ceiling: Float) -> Float {
        let magnitude = abs(value)
        guard magnitude > ceiling else { return value }
        let capped = ceiling + 0.05 * tanhf((magnitude - ceiling) / 0.05)
        return value < 0 ? -capped : capped
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

