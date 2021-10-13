//
//  AudioManager.swift
//  AudioSync
//
//  Created by Brian Gomberg on 10/12/21.
//

import AVFoundation

class AudioManager: NSObject, AVAudioRecorderDelegate, ObservableObject {
    public static let shared = AudioManager()

    private static let DOC_DIR_URL = try! FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    private static let ASSETS_DIR_URL = DOC_DIR_URL.appendingPathComponent("assets", isDirectory: true)
    private static let BACKING_FILE_URL = ASSETS_DIR_URL.appendingPathComponent("backing.wav")
    private static let OVERLAY_FILE_URL = ASSETS_DIR_URL.appendingPathComponent("overlay.wav")
    private static let SCHEDULE_DELAY = 0.1

    @Published private(set) var isRecording: Bool = false
    @Published private(set) var hasBackingTrack: Bool = false

    private var recorder: AVAudioRecorder!
    private var playbackEngine = AVAudioEngine()
    private var playbackPlayerNode = AVAudioPlayerNode()
    private var playbackAudioFile: AVAudioFile! = nil
    private var playbackOffset: TimeInterval = 0.0
    private var playbackOutputLatency: TimeInterval = 0.0

    private override init() {
        super.init()
    }

    public func setup(completion: @escaping () -> Void) {
        // Create the assets directory and remove any existing files
        try! FileManager.default.createDirectory(at: Self.ASSETS_DIR_URL, withIntermediateDirectories: true, attributes: nil)
        try? FileManager.default.removeItem(at: Self.BACKING_FILE_URL)
        try? FileManager.default.removeItem(at: Self.OVERLAY_FILE_URL)
        print("Documents path: \(Self.DOC_DIR_URL)")

        // Create the recording session
        let session = AVAudioSession.sharedInstance()
        try! session.setCategory(.playAndRecord, mode: .default)
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

        playbackEngine.attach(playbackPlayerNode)
        playbackEngine.connect(playbackPlayerNode, to: playbackEngine.mainMixerNode, format: nil)
    }

    public func startRecording() {
        guard !isRecording else {
            fatalError("Already recording")
        }

        if hasBackingTrack {
            // Start playback of the backing track
            playbackAudioFile = try! AVAudioFile(forReading: Self.BACKING_FILE_URL)

            print("Starting playback")
            try! playbackEngine.start()

            playbackOutputLatency = AVAudioSession.sharedInstance().outputLatency
            print("playbackOutputLatency: \(playbackOutputLatency)")

            var delayTime = Self.SCHEDULE_DELAY
            let adjustedTimeOffset = playbackOffset
            var startingFrame: AVAudioFramePosition = 0
            let outputFormat = playbackPlayerNode.outputFormat(forBus: 0)
            if adjustedTimeOffset < 0 {
                // negative offset, so calculate non-zero starting frame:
                let startingTime = abs(adjustedTimeOffset)
                startingFrame = AVAudioFramePosition(outputFormat.sampleRate * startingTime)
            } else {
                // positive (or zero) offset, so calculate delay time
                delayTime += adjustedTimeOffset
            }

            //delay the playback of the initial buffer so that we're not trying to play immediately when the engine starts

            var tinfo = mach_timebase_info()
            mach_timebase_info(&tinfo)
            let timecon = Double(tinfo.denom) / Double(tinfo.numer)
            let secondsToTicks = timecon * 1_000_000_000
            let delay = 0.33 * secondsToTicks
            let startTime = AVAudioTime(hostTime: mach_absolute_time() + UInt64(delay))

//            let lastRenderTime = playbackPlayerNode.lastRenderTime!
//            let lastRenderTimeInSamples = lastRenderTime.sampleTime
//            let startSampleTime = lastRenderTimeInSamples + AVAudioFramePosition(delayTime * outputFormat.sampleRate)
//            let startTime = AVAudioTime(sampleTime: startSampleTime, atRate: outputFormat.sampleRate)

            var frameCount = AVAudioFrameCount(playbackAudioFile.length)
            frameCount -= UInt32(exactly: startingFrame) ?? 0

            print("arrangmentTimeOffset: \(playbackOffset)")
            print("adjustedTimeOffset: \(adjustedTimeOffset)")
            print("startingFrame: \(startingFrame)")
            print("delayTime: \(delayTime)")
            print("startTime: \(Double(startTime.hostTime)/secondsToTicks)")
            print("frameCount: \(frameCount)")

            var isFirstOutput = true
            let outFormat = playbackEngine.mainMixerNode.outputFormat(forBus: 0)
            playbackEngine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: outFormat) { (pcmBuffer, timestamp) in
                if isFirstOutput {
                    print("OUT TIME", Double(timestamp.hostTime)/secondsToTicks)
                    isFirstOutput = false
                }
            }

            playbackPlayerNode.scheduleSegment(playbackAudioFile, startingFrame: startingFrame, frameCount: frameCount, at: nil, completionCallbackType: .dataPlayedBack) { _ in
                DispatchQueue.main.async {
                    self.playbackPlayerNode.stop()
                    print("Backing track completed playback")
                }
            }
            playbackPlayerNode.prepare(withFrameCount: frameCount)

            playbackPlayerNode.play(at: startTime)
        }

        let settings: [String:Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsFloatKey: false,
        ]
        try? FileManager.default.removeItem(at: Self.OVERLAY_FILE_URL)
        recorder = try! AVAudioRecorder(url: hasBackingTrack ? Self.OVERLAY_FILE_URL : Self.BACKING_FILE_URL, settings: settings)
        recorder.delegate = self
        guard recorder.record() else {
            fatalError("Failed to start recording")
        }
        print(Date().timeIntervalSince1970, recorder.deviceCurrentTime, recorder.currentTime)
        isRecording = true
    }

    public func stopRecording() {
        guard isRecording else {
            fatalError("Not recording")
        }

        let playbackTime = hasBackingTrack ? currentAbsoluteTime() : nil
        let recorderTime = recorder.currentTime
        print(Date().timeIntervalSince1970, recorder.deviceCurrentTime, recorderTime, playbackTime)
        print(AVAudioSession.sharedInstance().inputLatency, AVAudioSession.sharedInstance().outputLatency, AVAudioSession.sharedInstance().ioBufferDuration)
        print(playbackPlayerNode.outputPresentationLatency, playbackPlayerNode.latency)
        print(playbackEngine.mainMixerNode.latency, playbackEngine.mainMixerNode.outputPresentationLatency)

        recorder.stop()
        recorder = nil
        isRecording = false
        hasBackingTrack = true
        playbackAudioFile = nil
    }

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        print("Finished recording (successfully=\(flag))")
        if !flag {
            stopRecording()
        }
    }

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        guard let error = error else {
            print("Unknown recorder encode error occurred!")
            return
        }
        print("Recorder encode error: \(error)")
    }

    private func currentAbsoluteTime() -> TimeInterval? {
        guard let nodeTime = playbackPlayerNode.lastRenderTime, let playerTime = playbackPlayerNode.playerTime(forNodeTime: nodeTime) else {
            return nil
        }

        let trackTime = Double(playerTime.sampleTime) / playerTime.sampleRate

        // If arrangementTimeOffset > 0, add to arrangementTime to get "absolute" time.
        // Do not add if negative (ie subtract), due to how AVAudioPlayerNodes are scheduled:
        var arrangementTime = trackTime + max(0, playbackOffset)

        // Account for the output latency (based on the value at the start of recording to keep things simple for now)
        arrangementTime -= playbackOutputLatency

        // `arrangementTime` may be negative, due to the player being scheduled in the future.
        // Return nil until non-negative:
        guard arrangementTime >= 0 else {
            return nil
        }

        return arrangementTime
    }
}
