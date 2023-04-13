//
//  AudioManager.swift
//  AudioSync
//
//  Created by Brian Gomberg on 10/12/21.
//

import AVFoundation
import Accelerate
import Foundation

class AudioManager: ObservableObject {
    public static let shared = AudioManager()

    private enum Constant {
        static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
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
    private var sourceNode: AVAudioSourceNode! = nil
    private var sinkNode: AVAudioSinkNode! = nil
    private var currentStartTime: TimeInterval = 0.0
    private var playAtSampleTime: AVAudioFramePosition = 0
    private var detectedSoundStart: Int = 0
    private var detectedFrequencySwitch: Int = 0

    public func setup(completion: @escaping () -> Void) {
        // Create the recording session
        let session = AVAudioSession.sharedInstance()
        try! session.setCategory(.playAndRecord, mode: .measurement, options: [.allowBluetoothA2DP, .defaultToSpeaker])
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

        // Create and connect the source node
        sourceNode = AVAudioSourceNode { _, timestamp, frameCount, audioBufferList -> OSStatus in
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let isPlaying = self.isPlaying
            let playAtSampleTime = self.playAtSampleTime
            let basePlaybackSampleTime = Int(timestamp.pointee.mSampleTime) - Int(playAtSampleTime)
            for frame in 0..<Int(frameCount) {
                let playbackSampleTime = basePlaybackSampleTime + frame
                let value: Float
                if isPlaying && playbackSampleTime >= 0 && playbackSampleTime < 480 {
                    // 2kHz wave
                    value = sin(2 * Float.pi * Float(playbackSampleTime) * (2000 / 48000)) * 1.0
                } else if isPlaying && playbackSampleTime >= 480 && playbackSampleTime < 960 {
                    // 8kHz wave
                    value = sin(2 * Float.pi * Float(playbackSampleTime) * (8000 / 48000)) * 1.0
                } else {
                    value = 0.0
                }
                for buffer in ablPointer {
                    let buf: UnsafeMutableBufferPointer<Float> = UnsafeMutableBufferPointer(buffer)
                    buf[frame] = value
                }
            }
            return noErr
        }
        audioEngine.attach(sourceNode)
        audioEngine.connect(sourceNode, to: audioEngine.mainMixerNode, format: Constant.format)

        // Create and connect the sink node
        sinkNode = AVAudioSinkNode() { timestamp, frameCount, audioBufferList in
            guard self.isPlaying else { return noErr }
            let buffer = UnsafeBufferPointer<Float>(audioBufferList.pointee.mBuffers)
            let sampleTime = Int(timestamp.pointee.mSampleTime)

//            // Write the raw data out to the console for debugging
//            for frame in 0..<Int(frameCount) {
//                print("\(sampleTime + frame), \(buffer[frame])")
//            }

            if self.detectedSoundStart == 0 {
                // Look for the start of the impulse
                for frame in 0..<Int(frameCount) where abs(buffer[frame]) > 0.2 {
                    self.detectedSoundStart = sampleTime + frame
                    break
                }
            }

            if self.detectedSoundStart != 0 && self.detectedFrequencySwitch == 0 {
                // Look for the frequency switch after the impulse by taking 24-sample windows and counting zero-crossings as a very basic way
                // to measure the frequency content
                var offset = self.detectedSoundStart > sampleTime ? self.detectedSoundStart - sampleTime : 0
                while offset + 24 < Int(frameCount) {
                    var lastIndex = UInt(0)
                    var numCrossings = UInt(0)
                    vDSP_nzcros(buffer.baseAddress!.advanced(by: offset), 1, vDSP_Length(frameCount), &lastIndex, &numCrossings, vDSP_Length(24))
                    if numCrossings > 4 {
                        self.detectedFrequencySwitch = sampleTime + offset
                        break
                    }
                    offset += 24
                }
            }

            return noErr
        }
        audioEngine.attach(sinkNode)
        audioEngine.connect(audioEngine.inputNode, to: sinkNode, format: Constant.format)
    }

    public func start() {
        guard !isPlaying else {
            fatalError("Already playing")
        }

        try! audioEngine.start()

        // Delay the playback so that we're not trying to play immediately when the engine starts
        playAtSampleTime = sourceNode.lastRenderTime!.sampleTime + AVAudioFramePosition(Constant.format.sampleRate / 2)

        print("Will start at: \(playAtSampleTime)")
        print("IO buffer: \(systemIoBufferDuration)")
        print("Input latency: \(systemInputLatency)")
        print("Output latency: \(systemOutputLatency)")
        isPlaying = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.finishedPlaying()
        }
    }

    private func finishedPlaying() {
        let totalLatencySamples = Int64((systemInputLatency + systemOutputLatency) * Constant.format.sampleRate)
        print("Total latency samples: \(totalLatencySamples)")
        let startError = AVAudioFramePosition(detectedSoundStart) - playAtSampleTime - totalLatencySamples
        print("Detected sound start at sample time \(detectedSoundStart) (errorSamples: \(startError), errorSeconds: \(Double(startError) / 48000))")
        let frequencySwitchError = AVAudioFramePosition(detectedFrequencySwitch) - (playAtSampleTime + 480) - totalLatencySamples
        print("Detected frequency switch at sample time \(detectedFrequencySwitch) (errorSamples: \(frequencySwitchError), errorSeconds: \(Double(frequencySwitchError) / 48000))")

        isPlaying = false
        detectedSoundStart = 0
        detectedFrequencySwitch = 0
    }
}
