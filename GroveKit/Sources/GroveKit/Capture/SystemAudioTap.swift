import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// Captures everything the Mac is playing — the far end of the call — using a
/// Core Audio process tap. This is the "no bot joins the meeting" mechanism:
/// Grove reads the system's own output rather than integrating with Zoom, Meet,
/// or Teams, so it works with all of them and none of them know it exists.
///
/// Each of the following is a way to get a tap that returns `noErr` and then
/// silently produces nothing; all of them were hit while building this:
///  - A raw IOProc must read the tap. `AVAudioEngine` accepts the aggregate
///    device and then ignores it.
///  - The real output device must be the aggregate's *main* sub-device with the
///    tap attached as a sub-tap, not the other way round.
///  - The exclude list holds process object IDs, not PIDs.
///  - The delivered buffers are **interleaved**; see `AudioBufferReader`.
public final class SystemAudioTap: @unchecked Sendable {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "app.grove.systemaudiotap", qos: .userInitiated)

    public private(set) var format: AVAudioFormat?
    public private(set) var outputDeviceName: String = ""
    private var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    /// Continuity accounting. The device timestamp says how many frames Core
    /// Audio believes elapsed, so any shortfall is audio we never received.
    /// Reported because every tap failure mode still returns `noErr`.
    public private(set) var callbackCount = 0
    public private(set) var deliveredFrames: Double = 0
    public private(set) var missingFrames: Double = 0
    private var nextExpectedSampleTime: Double = -1

    public var frameLossFraction: Double {
        let expected = deliveredFrames + missingFrames
        return expected > 0 ? missingFrames / expected : 0
    }

    public init() {}

    /// Builds the tap and its aggregate device without starting audio flow.
    public func prepare() throws {
        let outputDevice = try defaultOutputDeviceID()
        let outputUID = try deviceUID(outputDevice)
        outputDeviceName = deviceName(outputDevice)

        let description = CATapDescription(
            stereoGlobalTapButExcludeProcesses: [try processObjectID(for: getpid())])
        description.uuid = UUID()
        description.muteBehavior = CATapMuteBehavior.unmuted  // user still hears the call
        description.isPrivate = true
        description.isMixdown = true

        try check("AudioHardwareCreateProcessTap", AudioHardwareCreateProcessTap(description, &tapID))
        guard tapID != kAudioObjectUnknown else {
            throw CaptureError.message("Process tap created but returned an unknown object ID")
        }

        var formatAddr = address(kAudioTapPropertyFormat)
        var asbd = AudioStreamBasicDescription()
        var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(
            "AudioObjectGetPropertyData(TapFormat)",
            AudioObjectGetPropertyData(tapID, &formatAddr, 0, nil, &asbdSize, &asbd))
        guard let tapFormat = AVAudioFormat(streamDescription: &asbd) else {
            throw CaptureError.message("Tap reported a format AVAudioFormat cannot represent")
        }
        format = tapFormat

        let describeAggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Grove Capture",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                ]
            ],
        ]
        try check(
            "AudioHardwareCreateAggregateDevice",
            AudioHardwareCreateAggregateDevice(describeAggregate as CFDictionary, &aggregateID))
    }

    /// Starts delivery. `handler` is called from an audio thread: it must not
    /// allocate, lock, or block.
    public func start(handler: @escaping (AVAudioPCMBuffer) -> Void) throws {
        guard let format else { throw CaptureError.message("start() called before prepare()") }
        onBuffer = handler

        try check(
            "AudioDeviceCreateIOProcIDWithBlock",
            AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) {
                [weak self] _, inInputData, inInputTime, _, _ in
                guard let self, let handler = self.onBuffer,
                    let buffer = AVAudioPCMBuffer(
                        pcmFormat: format, bufferListNoCopy: inInputData, deallocator: nil)
                else { return }

                let frames = Double(buffer.frameLength)
                let sampleTime = inInputTime.pointee.mSampleTime
                if self.nextExpectedSampleTime >= 0 {
                    let gap = sampleTime - self.nextExpectedSampleTime
                    if gap > 1 { self.missingFrames += gap }
                }
                self.nextExpectedSampleTime = sampleTime + frames
                self.callbackCount += 1
                self.deliveredFrames += frames

                handler(buffer)
            })
        try check("AudioDeviceStart", AudioDeviceStart(aggregateID, ioProcID))
    }

    public func stop() {
        if let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        onBuffer = nil
    }

    deinit { stop() }
}
