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
/// - the monitor device may not be the transmitter's device, because decoded
///   audio summed into a composite feed is on-air contamination;
/// - swapping the monitor device stops only the player, never the engine;
/// - losing the monitor device stops the monitor and leaves it stopped until
///   that same device comes back.
final class MonitorOutput {
    /// What `decide` concluded, so the rules can be unit-tested without CoreAudio.
    enum Decision: Equatable {
        case run(deviceID: AudioDeviceID)
        case off(note: String?)

        var isRunning: Bool { if case .run = self { return true }; return false }
    }

    private var ring: StereoInputRingBuffer?
    private var player: RingBufferPlayer?
    private var runningDeviceID: AudioDeviceID?
    private var runningUID: String?
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
    /// (0.60 audit, P0-5). Never taken from the render path.
    private let noteState = OSAllocatedUnfairLock<String?>(initialState: nil)
    var note: String? { noteState.withLock { $0 } }
    private func setNote(_ value: String?) { noteState.withLock { $0 = value } }

    var isRunning: Bool { active.load(ordering: .relaxed) }

    /// The rule set, as a pure function of the selection. `resolve` maps a UID
    /// to a device id (nil when the device is not present).
    static func decide(
        enabled: Bool,
        monitorUID: String?,
        txDeviceID: AudioDeviceID?,
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
            return .off(note: "The monitor device is the transmitter output; pick a different device.")
        }
        return .run(deviceID: deviceID)
    }

    /// Allocate the ring for a run. Sized against the PRODUCER's block, which
    /// is what makes the adaptive read stable (see `RingBufferPlayer`).
    func prepare(sampleRate: Double, blockFrames: Int) -> StereoInputRingBuffer {
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
    func reconcile(enabled: Bool, monitorUID: String?, txDeviceID: AudioDeviceID?) {
        let devices = (try? AudioDevices.list()) ?? []
        let decision = Self.decide(
            enabled: enabled, monitorUID: monitorUID, txDeviceID: txDeviceID,
            resolve: { uid in devices.first(where: { $0.uid == uid && $0.hasOutput })?.id })
        switch decision {
        case .off(let why):
            setNote(why)
            stop()
        case .run(let deviceID):
            setNote(nil)
            if isRunning, runningDeviceID == deviceID, runningUID == monitorUID { return }
            stop()
            start(deviceID: deviceID, uid: monitorUID)
        }
    }

    private func start(deviceID: AudioDeviceID, uid: String?) {
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
            try player.start(outputDeviceID: deviceID)
        } catch {
            setNote("The monitor device could not be started: \(error.localizedDescription)")
            return
        }
        self.player = player
        runningDeviceID = deviceID
        runningUID = uid
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
            guard let self, self.isRunning, let uid = self.runningUID else { return }
            let devices = (try? AudioDevices.list()) ?? []
            if !devices.contains(where: { $0.uid == uid && $0.hasOutput }) {
                setNote("The monitor device was disconnected.")
                self.stop()
            }
        }
    }

    func stop() {
        active.store(false, ordering: .relaxed)
        player?.stop()
        player = nil
        runningDeviceID = nil
        runningUID = nil
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
    }

    /// Release the ring too: the engine is going away.
    func shutdown() {
        stop()
        ring = nil
        setNote(nil)
    }
}
#endif
