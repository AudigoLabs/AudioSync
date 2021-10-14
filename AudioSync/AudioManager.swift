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
    private static let SCHEDULE_DELAY = 0.33

    private static let SECONDS_TO_TICKS: Double = {
        var tinfo = mach_timebase_info()
        mach_timebase_info(&tinfo)
        let timecon = Double(tinfo.denom) / Double(tinfo.numer)
        return timecon * 1_000_000_000
    }()

    private var systemIoBufferDuration: TimeInterval {
        return AVAudioSession.sharedInstance().ioBufferDuration
    }
    private var systemInputLatency: TimeInterval {
        return AVAudioSession.sharedInstance().inputLatency
    }
    private var systemOutputLatency: TimeInterval {
        return AVAudioSession.sharedInstance().outputLatency
    }

    @Published private(set) var isRecording: Bool = false
    @Published private(set) var hasBackingTrack: Bool = true

    private var recorder: AVAudioRecorder!
    private var audioEngine = AVAudioEngine()
    private var playerNode = AVAudioPlayerNode()
    private var playbackAudioFile: AVAudioFile! = nil
    private var currentStartTime: TimeInterval = 0.0

    private override init() {
        super.init()
    }

    public func setup(completion: @escaping () -> Void) {
        guard FileManager.default.fileExists(atPath: Self.BACKING_FILE_URL.path) else {
            fatalError("Backing track doesn't exist")
        }

        playbackAudioFile = try! AVAudioFile(forReading: Self.BACKING_FILE_URL)

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

        print("IO Buffer: \(systemIoBufferDuration)")
        print("Input latency: \(systemInputLatency)")
        print("Output latency: \(systemOutputLatency)")

        audioEngine.attach(playerNode)
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: audioEngine.mainMixerNode.inputFormat(forBus: 0))

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
        recorder = try! AVAudioRecorder(url: Self.OVERLAY_FILE_URL, settings: settings)
        recorder.delegate = self
    }

    public func startRecording() {
        guard !isRecording else {
            fatalError("Already recording")
        }

        let frameCount = playbackAudioFile.length
        try! audioEngine.start()

        // Delay the playback of the initial buffer so that we're not trying to play immediately when the engine starts
        let audioStartTime = AVAudioTime(hostTime: mach_absolute_time() + UInt64((Self.SCHEDULE_DELAY - systemOutputLatency) * Self.SECONDS_TO_TICKS))
        currentStartTime = Double(audioStartTime.hostTime) / Self.SECONDS_TO_TICKS

        playerNode.play()
        playerNode.scheduleSegment(playbackAudioFile, startingFrame: 0, frameCount: AVAudioFrameCount(frameCount), at: audioStartTime) {
            DispatchQueue.main.async {
                self.playerNode.stop()
                print("Backing track completed playback")
            }
        }

        guard recorder.record(atTime: recorder.deviceCurrentTime + Self.SCHEDULE_DELAY - systemInputLatency) else {
            fatalError("Failed to start recording")
        }
        isRecording = true
    }

    public func stopRecording() {
        guard isRecording else {
            fatalError("Not recording")
        }

        let recordStartTime = recorder.deviceCurrentTime - recorder.currentTime
        recorder.stop()
        isRecording = false

        print("Started at: \(currentStartTime)")
        print("Recording actually started at: \(recordStartTime)")
        print("Recording offset: \(recordStartTime - currentStartTime)")
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
}
