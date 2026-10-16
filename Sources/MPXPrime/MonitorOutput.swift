#if os(macOS)
import AVFoundation
import CoreAudio
import Foundation
import MPXPrimeCore
import Atomics
import os

/// The second output: the operator's listening feed, on its own device and its
/// own audio engine, running ALONGSIDE the transmitter feed.
///
/// Until 0.50 "monitor" was an output MODE that replaced the transmitter feed,
/// so listening meant going off air. Now the encoder taps a copy of what it is
/// already producing into a ring, and this drains that ring to a second device.
/// The transmitter engine never learns the monitor exists: a monitor that
/// fails to start, or whose device is unplugged, is a note in the status line,
/// never an interruption of the air chain.
///
/// Rules this enforces, all of them to protect the air feed:
///
/// - an empty monitor device selection is OFF, never "the system default" --
///   the default output may BE the transmitter;
/// - the monitor may share the transmitter's DEVICE only on channels the
///   transmitter does not use (an 8-out box: feed on 7, 8, monitor on 1, 2),
///   because decoded audio summed into a composite feed is on-air
///   contamination -- overlapping channels, including both sides on the
///   device's first pair, are refused;
/// - swapping the monitor device or its channels stops only the player,
///   never the engine;
/// - losing the monitor device stops the monitor and leaves it stopped until
///   that same device comes back.
///
/// Threading: the engine's control thread calls `prepare`, `reconcile`,
/// `stop` and `shutdown`; the device observer runs on the main queue and may
/// stop the player at the same time. Every piece of player state below is
/// read and written only under `stateLock` (recursive, because `reconcile`
/// calls `stop`), which is what makes the `@unchecked Sendable` true. The
/// render thread touches only `active` (atomic) and the ring it was handed.
final class MonitorOutput: @unchecked Sendable {
    /// What `decide` concluded, so the rules can be unit-tested without CoreAudio.
    enum Decision: Equatable {
        /// Play on `deviceID`, on `channels` (nil = the device's first pair).
        case run(deviceID: AudioDeviceID, channels: ChannelPair?)
        case off(note: String?)

        var isRunning: Bool { if case .run = self { return true }; return false }
    }

    /// Why a monitor on the transmitter's device with overlapping channels
    /// stays off. One string, so the GUI, the dashboard and the tests agree.
    static let sharedChannelsNote =
        "The monitor shares the transmitter's output channels; pick different channels or another device."

    private let stateLock = NSRecursiveLock()
    private var ring: StereoInputRingBuffer?
    private var player: RingBufferPlayer?
    private var runningDeviceID: AudioDeviceID?
    private var runningUID: String?
    private var runningChannels: ChannelPair?
    private var observer: NSObjectProtocol?
    private var sampleRate: Double = 48_000
    private var targetFrames: Int = RingBufferPlayer.defaultTargetFrames
    private var deadbandFrames: Int = RingBufferPlayer.defaultDeadbandFrames

    /// Read by the render thread once per block to decide whether to write.
    let active = ManagedAtomic<Bool>(false)
    /// Operator-facing reason the monitor is not playing, if any.
    /// Written by the control thread and by the device observer on `.main`,
    /// read by the headless backend's actor -- a String is refcounted, so an
    /// unsynchronised read of one being replaced can crash, not just tear
    /// (0.65 audit, P0-5). Never taken from the render path.
    private let noteState = OSAllocatedUnfairLock<String?>(initialState: nil)
    var note: String? { noteState.withLock { $0 } }
    private func setNote(_ value: String?) { noteState.withLock { $0 = value } }

    var isRunning: Bool { active.load(ordering: .relaxed) }

    /// The device channels the monitor is playing on (zero-based), or nil.
    var appliedChannels: ChannelPair? { stateLock.withLock { player?.appliedChannels } }

    /// The rule set, as a pure function of the selection. `resolve` maps a UID
    /// to a device id (nil when the device is not present).
    ///
    /// `monitorChannels` / `txChannels` are the pairs each side uses on ITS
    /// device (nil = channels 1, 2). They only matter when both sides name
    /// the same device: then the monitor runs if and only if the two pairs
    /// are disjoint. The pair the player ends up with can still differ (a
    /// pair the device lacks falls back to 1, 2), which `reconcile` re-checks
    /// against the transmitter after the start.
    static func decide(
        enabled: Bool,
        monitorUID: String?,
        monitorChannels: ChannelPair?,
        txDeviceID: AudioDeviceID?,
        txChannels: ChannelPair?,
        resolve: (String) -> AudioDeviceID?
    ) -> Decision {
        guard enabled else { return .off(note: nil) }
        guard let uid = monitorUID, !uid.isEmpty else {
            return .off(note: "Monitor is on but no monitor device is selected.")
        }
        guard let deviceID = resolve(uid) else {
            return .off(note: "The monitor device is not connected.")
        }
        if let tx = txDeviceID, tx == deviceID {
            let monitorPair = monitorChannels ?? .stereoDefault
            let txPair = txChannels ?? .stereoDefault
            if monitorPair.overlaps(txPair) {
                return .off(note: sharedChannelsNote)
            }
        }
        return .run(deviceID: deviceID, channels: monitorChannels)
    }

    /// Allocate the ring for a run. Sized against the PRODUCER's block, which
    /// is what makes the adaptive read stable (see `RingBufferPlayer`).
    func prepare(sampleRate: Double, blockFrames: Int) -> StereoInputRingBuffer {
        stateLock.lock()
        defer { stateLock.unlock() }
        let target = max(4 * blockFrames, Int(sampleRate * 0.04))
        let capacity = 1 << Int(ceil(log2(Double(max(1024, 4 * target)))))
        let ring = StereoInputRingBuffer(capacityFrames: capacity)
        self.ring = ring
        self.sampleRate = sampleRate
        self.targetFrames = target
        self.deadbandFrames = max(64, blockFrames)
        return ring
    }

    /// Bring the monitor in line with the current selection. Safe to call on
    /// every runtime-config apply: it does nothing when nothing changed.
    /// Never throws into the caller -- a monitor problem is a note.
    func reconcile(
        enabled: Bool,
        monitorUID: String?,
        monitorChannels: ChannelPair?,
        txDeviceID: AudioDeviceID?,
        txChannels: ChannelPair?
    ) {
        stateLock.lock()
        defer { stateLock.unlock() }
        let devices = (try? AudioDevices.list()) ?? []
        let decision = Self.decide(
            enabled: enabled, monitorUID: monitorUID, monitorChannels: monitorChannels,
            txDeviceID: txDeviceID, txChannels: txChannels,
            resolve: { uid in devices.first(where: { $0.uid == uid && $0.hasOutput })?.id })
        switch decision {
        case .off(let why):
            setNote(why)
            stop()
        case .run(let deviceID, let channels):
            setNote(nil)
            if isRunning, runningDeviceID == deviceID, runningUID == monitorUID,
               runningChannels == channels { return }
            stop()
            // On a shared device the pair the player ACTUALLY takes must stay
            // clear of the transmitter's: a requested pair the device lacks
            // falls back to 1, 2, which may be exactly where the feed is.
            let keepClearOf = (txDeviceID == deviceID) ? (txChannels ?? .stereoDefault) : nil
            start(deviceID: deviceID, uid: monitorUID, channels: channels, keepClearOf: keepClearOf)
        }
    }

    private func start(
        deviceID: AudioDeviceID, uid: String?, channels: ChannelPair?, keepClearOf: ChannelPair?
    ) {
        guard let ring else {
            setNote("The monitor could not start: the engine is not running.")
            return
        }
        let player = RingBufferPlayer(
            ring: ring, sampleRate: sampleRate,
            targetFrames: targetFrames, deadbandFrames: deadbandFrames)
        do {
            // Drop whatever accumulated while the monitor was stopped, so it
            // starts at the target fill instead of a block of stale audio.
            ring.dropToTargetBufferedFrames(0)
            try player.start(outputDeviceID: deviceID, channels: channels)
        } catch {
            setNote("The monitor device could not be started: \(error.localizedDescription)")
            return
        }
        if let keepClearOf, let applied = player.appliedChannels, applied.overlaps(keepClearOf) {
            player.stop()
            setNote([player.channelNote, Self.sharedChannelsNote].compactMap { $0 }
                .joined(separator: " "))
            return
        }
        setNote(player.channelNote)
        self.player = player
        runningDeviceID = deviceID
        runningUID = uid
        runningChannels = channels
        active.store(true, ordering: .relaxed)
        observeDeviceChanges()
    }

    /// The monitor device going away must never touch the transmitter engine,
    /// and must never silently fall back to another device (that other device
    /// could be the transmitter). Stop, and wait for the same one to return.
    private func observeDeviceChanges() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.stopIfDeviceGone()
        }
    }

    private func stopIfDeviceGone() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard isRunning, let uid = runningUID else { return }
        let devices = (try? AudioDevices.list()) ?? []
        if !devices.contains(where: { $0.uid == uid && $0.hasOutput }) {
            setNote("The monitor device was disconnected.")
            stop()
        }
    }

    func stop() {
        stateLock.lock()
        defer { stateLock.unlock() }
        active.store(false, ordering: .relaxed)
        player?.stop()
        player = nil
        runningDeviceID = nil
        runningUID = nil
        runningChannels = nil
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
    }

    /// Release the ring too: the engine is going away.
    func shutdown() {
        stateLock.lock()
        defer { stateLock.unlock() }
        stop()
        ring = nil
        setNote(nil)
    }
}
#endif
