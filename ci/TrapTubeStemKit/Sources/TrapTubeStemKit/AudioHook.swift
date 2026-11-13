import AVFoundation
import Foundation

/// Installs TrapTube's EQ on AVPlayerItems whose decoded audio tracks expose
/// AVAudioMix processing. This deliberately does not attempt to bypass FairPlay
/// or custom renderers that do not expose an AVPlayerItem audio mix.
@objc(TrapTubeAudioHook)
public final class TrapTubeAudioHook: NSObject {
    private weak var player: AVPlayer?
    private var itemObservation: NSKeyValueObservation?
    private var statusObservation: NSKeyValueObservation?
    private var audioMixObservation: NSKeyValueObservation?
    private var attachmentTask: Task<Void, Never>?
    private weak var observedItem: AVPlayerItem?

    // MARK: - Round 17: hook breadcrumbs, resolver-construction marker, identity registry
    //
    // Build 176 still parked between "item built" and "item set, play()
    // called" with the EQ status frozen at the hook probe, so this round
    // stops guessing which synchronous call in the hook chain parks and
    // (a) records how far the hook chain got, in a store a parked thread
    // cannot hold hostage, and (b) removes the resolver's own items from
    // the hook chain entirely (see the marker + registry below).

    /// Last hook stage, written at each attach entry point. The store is
    /// guarded by its own lock whose critical sections are a single
    /// string assignment plus a counter increment - the lock is never
    /// held across any call, so no thread can park while holding it and
    /// the player controller's heartbeat can always read the stage back.
    private static let hookStageLock = NSLock()
    private static var hookStageText = "none"
    private static var hookStageCount = 0

    @objc public static func noteHookStage(_ stage: String) {
        hookStageLock.lock()
        hookStageText = stage
        hookStageCount += 1
        hookStageLock.unlock()
    }

    @objc public static var lastHookStage: String {
        hookStageLock.lock()
        defer { hookStageLock.unlock() }
        return "\(hookStageText) (#\(hookStageCount))"
    }

    /// Thread-local depth counter marking "the stream resolver is
    /// constructing one of its own items right now". The resolver sets it
    /// immediately before AVPlayerItem(asset:) and clears it immediately
    /// after, inside the same synchronous stretch (no suspension point in
    /// between, so the thread cannot change mid-window). Item-init hooks
    /// run synchronously on that same thread during construction, so the
    /// tweak can check the marker first and return without touching the
    /// EQ manager, its locks or any asset accessor for our own items.
    private static let constructionDepthKey = "TrapTube.ResolverItemConstructionDepth"

    @objc public static func beginResolverItemConstruction() {
        let dictionary = Thread.current.threadDictionary
        let depth = (dictionary[constructionDepthKey] as? NSNumber)?.intValue ?? 0
        dictionary[constructionDepthKey] = NSNumber(value: depth + 1)
        noteHookStage("resolverConstructionBegin")
    }

    @objc public static func endResolverItemConstruction() {
        let dictionary = Thread.current.threadDictionary
        let depth = (dictionary[constructionDepthKey] as? NSNumber)?.intValue ?? 0
        if depth <= 1 {
            dictionary.removeObject(forKey: constructionDepthKey)
        } else {
            dictionary[constructionDepthKey] = NSNumber(value: depth - 1)
        }
        noteHookStage("resolverConstructionEnd")
    }

    @objc public static func isResolverItemConstruction() -> Bool {
        ((Thread.current.threadDictionary[constructionDepthKey] as? NSNumber)?.intValue ?? 0) > 0
    }

    /// Identity registry for the player and items the StemKit player
    /// creates itself. The tweak's instance-scoped hooks (setAudioMix:,
    /// the audioMix getter, AVPlayerLayer setPlayer:, AVPlayer install
    /// hooks) check membership and skip StemKit's own objects, whose EQ
    /// is attached explicitly by the player controller's install(on:)
    /// path instead. Entries are weak: a stale identifier whose object
    /// died reads as "not registered", so a reused ObjectIdentifier can
    /// never produce a false positive. The lock's critical sections are
    /// single dictionary operations - never held across a call.
    private final class WeakItemBox {
        weak var item: AVPlayerItem?
        init(_ item: AVPlayerItem) { self.item = item }
    }
    private final class WeakPlayerBox {
        weak var player: AVPlayer?
        init(_ player: AVPlayer) { self.player = player }
    }
    private static let resolverRegistryLock = NSLock()
    private static var resolverItems: [ObjectIdentifier: WeakItemBox] = [:]
    private static var resolverPlayers: [ObjectIdentifier: WeakPlayerBox] = [:]

    @objc public static func registerResolverItem(_ item: AVPlayerItem) {
        resolverRegistryLock.lock()
        resolverItems[ObjectIdentifier(item)] = WeakItemBox(item)
        resolverRegistryLock.unlock()
    }

    @objc public static func isResolverItem(_ item: AVPlayerItem) -> Bool {
        resolverRegistryLock.lock()
        defer { resolverRegistryLock.unlock() }
        let identifier = ObjectIdentifier(item)
        guard let box = resolverItems[identifier] else { return false }
        guard let registered = box.item else {
            resolverItems.removeValue(forKey: identifier)
            return false
        }
        return registered === item
    }

    @objc public static func registerResolverPlayer(_ player: AVPlayer) {
        resolverRegistryLock.lock()
        resolverPlayers[ObjectIdentifier(player)] = WeakPlayerBox(player)
        resolverRegistryLock.unlock()
    }

    @objc public static func isResolverPlayer(_ player: AVPlayer) -> Bool {
        resolverRegistryLock.lock()
        defer { resolverRegistryLock.unlock() }
        let identifier = ObjectIdentifier(player)
        guard let box = resolverPlayers[identifier] else { return false }
        guard let registered = box.player else {
            resolverPlayers.removeValue(forKey: identifier)
            return false
        }
        return registered === player
    }

    /// Creator-agnostic entry point: called whenever an AVPlayerItem comes
    /// into existence or receives an audio mix, whoever created it. The
    /// manager de-dupes per item, so repeated calls are cheap no-ops.
    @objc public static func attachInBackground(to item: AVPlayerItem) {
        noteHookStage("attachEntered")
        TrapTubeEQManager.shared.noteHookFired("player item")
        noteHookStage("noteHookFiredDone")
        // Round 16: attach is strictly fire-and-forget. This entry point is
        // called synchronously from the AVPlayerItem creation hooks -
        // including inside the stream resolver's AVPlayerItem(asset:)
        // construction, before resolve() returns - so it must never run
        // attach work on the caller's thread. The fast path it used to run
        // inline starts with the legacy synchronous
        // asset.tracks(withMediaType:) accessor, which can park
        // indefinitely on these googlevideo assets (the manager's own
        // attach(to:) overload repeats the same call). On Build 173 that
        // park froze resolve() mid-construction: the Diag trail ended at
        // "item built", the EQ status never advanced past this hook probe,
        // and replaceCurrentItem/play() were never reached. All attach
        // work - the loaded-tracks fast path included - now runs in this
        // detached task, where a stall can only ever delay the EQ, never
        // playback. The async path below stalls on some host assets whose
        // track loading only completes inside the player's own pipeline,
        // which is why the fast path is kept - just moved off the
        // caller's thread.
        Task {
            if !item.asset.tracks(withMediaType: .audio).isEmpty,
               TrapTubeEQManager.shared.attach(to: item) {
                return
            }
            _ = await TrapTubeEQManager.shared.attachWhenReady(to: item)
        }
        noteHookStage("attachSpawned")
    }

    /// Async-only attach for very hot call sites (the audioMix getter hook),
    /// where a synchronous attach could re-enter itself.
    @objc public static func attachWhenReadyInBackground(to item: AVPlayerItem) {
        noteHookStage("whenReadyEntered")
        Task {
            let attached = await TrapTubeEQManager.shared.attachWhenReady(to: item)
            if attached {
                NSLog("[TrapTube EQ] Attached audio processing tap via item-creation path")
            }
        }
        noteHookStage("whenReadySpawned")
    }

    @objc public func install(on player: AVPlayer) {
        Self.noteHookStage("installEntered")
        TrapTubeEQManager.shared.noteHookFired("player")
        invalidate()
        self.player = player
        itemObservation = player.observe(\.currentItem, options: [.initial, .new]) { [weak self] observedPlayer, _ in
            DispatchQueue.main.async { [weak self, weak observedPlayer] in
                guard let self, let observedPlayer,
                      self.player === observedPlayer else { return }
                self.observeCurrentItem(observedPlayer.currentItem)
            }
        }
        Self.noteHookStage("installDone")
    }

    private func observeCurrentItem(_ item: AVPlayerItem?) {
        guard observedItem !== item else { return }
        attachmentTask?.cancel()
        attachmentTask = nil
        statusObservation?.invalidate()
        statusObservation = nil
        audioMixObservation?.invalidate()
        audioMixObservation = nil

        if let previous = observedItem {
            TrapTubeEQManager.shared.detach(from: previous)
        }
        observedItem = item
        guard let item else { return }

        // Track loading is asynchronous. Reading asset.tracks synchronously at
        // item replacement can return an empty array and permanently miss EQ.
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self, weak item] _, change in
            guard let self, let item else { return }
            if item.status == .failed {
                TrapTubeEQManager.shared.setAttachmentStatus("Playback failed before EQ could attach")
                NSLog("[TrapTube EQ] Player item failed before EQ attachment: %@", item.error?.localizedDescription ?? "unknown error")
            } else if item.status == .readyToPlay,
                      change.newValue != change.oldValue,
                      !TrapTubeEQManager.shared.isAttached(to: item) {
                // Retry once the item is actually ready to play: an earlier
                // attempt may have failed on transient track state and would
                // otherwise never be retried for this item.
                self.attachWhenTracksAreReady(item)
            }
        }
        observeAudioMixChanges(item)
        attachWhenTracksAreReady(item)
    }

    private func attachWhenTracksAreReady(_ item: AVPlayerItem) {
        attachmentTask?.cancel()
        attachmentTask = Task { [weak self, weak item] in
            guard let item else { return }
            var attached = false
            if !item.asset.tracks(withMediaType: .audio).isEmpty {
                attached = TrapTubeEQManager.shared.attach(to: item)
            }
            if !attached {
                attached = await TrapTubeEQManager.shared.attachWhenReady(to: item)
            }
            guard !Task.isCancelled else {
                TrapTubeEQManager.shared.detach(from: item)
                return
            }
            guard let self, self.player?.currentItem === item else {
                TrapTubeEQManager.shared.detach(from: item)
                return
            }
            if attached {
                NSLog("[TrapTube EQ] Attached audio processing tap to current YouTube AVPlayerItem")
            } else {
                NSLog("[TrapTube EQ] Current player item did not expose a compatible audio-processing path")
            }
        }
    }

    private func observeAudioMixChanges(_ item: AVPlayerItem) {
        audioMixObservation?.invalidate()
        audioMixObservation = item.observe(\.audioMix, options: [.new]) { [weak self, weak item] _, _ in
            guard let self, let item, self.observedItem === item else { return }
            guard !TrapTubeEQManager.shared.isAttached(to: item) else { return }
            // The host assigned or replaced this item's audio mix. If our tap
            // is not part of the current mix, try to attach again so a host
            // mix change cannot silently displace the EQ for the whole item.
            DispatchQueue.main.async { [weak self, weak item] in
                guard let self, let item, self.observedItem === item else { return }
                self.attachWhenTracksAreReady(item)
            }
        }
    }

    @objc public func invalidate() {
        attachmentTask?.cancel()
        attachmentTask = nil
        itemObservation?.invalidate()
        itemObservation = nil
        statusObservation?.invalidate()
        statusObservation = nil
        audioMixObservation?.invalidate()
        audioMixObservation = nil
        if let item = observedItem {
            TrapTubeEQManager.shared.detach(from: item)
        }
        observedItem = nil
        player = nil
    }

    deinit { invalidate() }
}
