//
//  AudioManager.swift
//  AudioSync
//
//  Created by Brian Gomberg on 10/12/21.
//

import AVFoundation

class AudioManager: ObservableObject {
    public static let shared = AudioManager()

    private enum Constant {
        static let scheduleDelay = 0.5
        static let pluckOffset = 1.0
        static let ticksToSeconds = {
            var info = mach_timebase_info()
            let err = mach_timebase_info(&info)
            guard err == 0 else { fatalError() }
            return Double(info.numer) / Double(info.denom) / 1_000_000_000
        }()
    }

    private var systemIoBufferDuration: TimeInterval {
        return AVAudioSession.sharedInstance().ioBufferDuration
    }
    private var systemInputLatency: TimeInterval {
        return AVAudioSession.sharedInstance().inputLatency
    }
    private var systemOutputLatency: TimeInterval {
        return AVAudioSession.sharedInstance().outputLatency
    }

    @Published private(set) var isPlaying: Bool = false

    private var audioEngine = AVAudioEngine()
    private var playerNode = AVAudioPlayerNode()
    private var sinkNode: AVAudioSinkNode! = nil
    private var playbackAudioFile: AVAudioFile! = nil
    private var currentStartTime: TimeInterval = 0.0

    public func setup(completion: @escaping () -> Void) {
        playbackAudioFile = try! AVAudioFile(forReading: Bundle.main.url(forResource: "backing", withExtension: "wav")!)

        // Create the recording session
        let session = AVAudioSession.sharedInstance()
        try! session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothA2DP, .defaultToSpeaker])
        print("Requesting permission")
        session.requestRecordPermission { allowed in
            guard allowed else {
                fatalError("Not allowed to record")
            }
            print("Got permission")
            DispatchQueue.main.async {
                completion()
            }
        }

        try! session.setActive(true, options: [])
        print("Audio session active")

        let outputFormat = audioEngine.mainMixerNode.outputFormat(forBus: 0)
        print("Mixer output format: \(outputFormat)")

        audioEngine.attach(playerNode)
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: outputFormat)

        // Create and connect the sink node
        let input = audioEngine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        print("Input format: \(inputFormat)")
        var prevLoudFrameTimestamp = 0.0
        sinkNode = AVAudioSinkNode() { timestamp, _, ptr in
            // Get the index of the first loud frame in the input buffer, if any
            let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, bufferListNoCopy: ptr)!
            let firstLoudFrame = (0..<Int(buffer.frameLength))
                .first(where: { abs(buffer.floatChannelData![0][$0]) > 0.2 })
            guard let firstLoudFrame else { return noErr }

            // Calculate the host time of the first loud frame based on the specified timestamp
            let loudFrameTimestamp = Double(timestamp.pointee.mHostTime) * Constant.ticksToSeconds + Double(firstLoudFrame) / inputFormat.sampleRate - self.systemInputLatency

            // Check that it's been at least half a second since our last loud frame
            guard loudFrameTimestamp - prevLoudFrameTimestamp > 0.5 else { return noErr }
            prevLoudFrameTimestamp = loudFrameTimestamp

            print("Loud timestamp: \(loudFrameTimestamp) (error=\(loudFrameTimestamp - self.currentStartTime - Constant.pluckOffset))")
            return noErr
        }
        audioEngine.attach(sinkNode)
        audioEngine.connect(input, to: sinkNode, format: inputFormat)
    }

    public func start() {
        guard !isPlaying else {
            fatalError("Already playing")
        }

        let frameCount = playbackAudioFile.length
        try! audioEngine.start()

        // Delay the playback of the initial buffer so that we're not trying to play immediately when the engine starts
        currentStartTime = Double(mach_absolute_time()) * Constant.ticksToSeconds + Constant.scheduleDelay

        playerNode.scheduleSegment(playbackAudioFile, startingFrame: 0, frameCount: AVAudioFrameCount(frameCount), at: nil) {
            DispatchQueue.main.async {
                self.playerNode.stop()
                self.isPlaying = false
                print("Backing track completed playback")
            }
        }
        playerNode.play(at: AVAudioTime(hostTime: UInt64((currentStartTime - systemOutputLatency) / Constant.ticksToSeconds)))

        print("Started at: \(currentStartTime)")
        print("IO Buffer: \(systemIoBufferDuration)")
        print("Input latency: \(systemInputLatency)")
        print("Output latency: \(systemOutputLatency)")
        isPlaying = true
    }
}
