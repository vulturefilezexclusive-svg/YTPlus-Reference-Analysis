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

    /// Creator-agnostic entry point: called whenever an AVPlayerItem comes
    /// into existence or receives an audio mix, whoever created it. The
    /// manager de-dupes per item, so repeated calls are cheap no-ops.
    @objc public static func attachInBackground(to item: AVPlayerItem) {
        TrapTubeEQManager.shared.noteHookFired("player item")
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
    }

    /// Async-only attach for very hot call sites (the audioMix getter hook),
    /// where a synchronous attach could re-enter itself.
    @objc public static func attachWhenReadyInBackground(to item: AVPlayerItem) {
        Task {
            let attached = await TrapTubeEQManager.shared.attachWhenReady(to: item)
            if attached {
                NSLog("[TrapTube EQ] Attached audio processing tap via item-creation path")
            }
        }
    }

    @objc public func install(on player: AVPlayer) {
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
