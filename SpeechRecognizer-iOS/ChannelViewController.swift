//
//  ChannelViewController.swift
//  SpeechRecognizer-iOS
//
//  Created by GongYuhua on 2019/7/8.
//  Copyright © 2019 Agora. All rights reserved.
//

import UIKit
import Speech
import AgoraRtcKit
import AVFoundation

class ChannelViewController: UIViewController {

    @IBOutlet var remoteUidLabel: UILabel!
    @IBOutlet var remoteTextView: UITextView!
    @IBOutlet var remoteToggle: UIButton!
    
    var agoraCaptureSession: AgoraCaptureSession = AgoraCaptureSession()
    
    var channel: String!
    var local: Locale!
    
    private lazy var speechRecognizer = SFSpeechRecognizer(locale: local)!
    private let recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
    private var recognitionTask: SFSpeechRecognitionTask?
    
    private var remoteUid: UInt = 0
    
    private lazy var engine: AgoraRtcEngineKit = {
        let engine = AgoraRtcEngineKit.sharedEngine(withAppId: KeyCenter.AppId, delegate: self)
        return engine
    }()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        remoteTextView.isUserInteractionEnabled = false

        // engine.setAudioProfile(.musicStandardStereo, scenario: .chatRoomGaming) // @cavansu: uncomment this line and every thing sounds bad.
        engine.joinChannel(byToken: nil, channelId: channel, info: nil, uid: 0, joinSuccess: nil)
        
        MediaWorker.setDelegate(self)
        speechRecognizer.delegate = self
        
        startRecognize()
        MediaWorker.registerAudioBuffer(inEngine: engine)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: true)
    }
    
    @IBAction func doLeaveChannel() {
        MediaWorker.setDelegate(nil)
        MediaWorker.deregisterAudioBuffer(inEngine: engine)
        stopRecognize()
        engine.leaveChannel(nil)
        navigationController?.popViewController(animated: true)
    }
    
    @IBAction func toggleRecording() {
        if agoraCaptureSession.isRecording {
            agoraCaptureSession.stopRecording()
            remoteToggle.backgroundColor = .systemGreen
            self.exportRecentRecording()
        } else {
            agoraCaptureSession.startRecording()
            remoteToggle.backgroundColor = .systemPink
        }
    }
    
    func exportRecentRecording() {
        guard let fileURL = AgoraCaptureSession.mostRecentRecording else { return }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }

        // Create the Array which includes the files you want to share
        var filesToShare = [Any]()

        // Add the path of the file to the Array
        filesToShare.append(fileURL)

        // Make the activityViewContoller which shows the share-view
        let activityViewController = UIActivityViewController(activityItems: filesToShare, applicationActivities: nil)

        // Show the share-view
        self.present(activityViewController, animated: true, completion: nil)
    }
}

private extension ChannelViewController {
    func startRecognize() {
        recognitionRequest.shouldReportPartialResults = true
        
        // You can keep speech recognition data on device since iOS 13
        if #available(iOS 13, *) {
//            recognitionRequest.requiresOnDeviceRecognition = true
        }
        
        let textView = remoteTextView
        textView?.text = "Recognizing"
        
        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) {result, error in
            if let result = result {
                textView?.text = result.bestTranscription.formattedString
            }
            
            if let error = error {
                textView?.text = "Error: \(error.localizedDescription)"
            }
        }
    }
    
    func stopRecognize() {
        recognitionRequest.endAudio()
    }
}

extension ChannelViewController: SFSpeechRecognizerDelegate {
    public func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        if !available {
            remoteTextView.text = "Recognition Not Available"
        }
    }
}

extension ChannelViewController: MediaWorkerDelegate {
    func mediaWorkerDidReceiveRemotePCM(_ buffer: AVAudioPCMBuffer) {
        recognitionRequest.append(buffer)
        if self.agoraCaptureSession.isRecording {
            self.agoraCaptureSession.mediaWorkerDidReceiveRemotePCM(buffer)
        }
    }
}

extension ChannelViewController: AgoraRtcEngineDelegate {
    func rtcEngine(_ engine: AgoraRtcEngineKit, didJoinedOfUid uid: UInt, elapsed: Int) {
        guard remoteUid == 0 else {
            return
        }
        
        remoteUid = uid
        MediaWorker.setRemoteUid(uid)
        remoteUidLabel.text = "\(uid)"
    }
}

class AgoraCaptureSession: NSObject {
    static var player: AVAudioPlayer?
    static private var playerItemObserver: NSKeyValueObservation?

    var assetWriter: AVAssetWriter?
    static var mostRecentRecording: URL?
    private var recordedFileURL: URL {
        return URL(fileURLWithPath: "test \(Date().timeIntervalSince1970)", isDirectory: false, relativeTo: URL(fileURLWithPath: NSTemporaryDirectory())).appendingPathExtension(".mp4")
    }
    private var recordedFile: AVAssetWriterInput!
    var isRecording: Bool = false

    var counter: Int32 = 0

    static func playbackRecording() {
        if let url = Self.mostRecentRecording {
            Self.player?.stop()
            Self.player = try? AVAudioPlayer(contentsOf: url)
            Self.player?.play()
        }
    }

    private func configureAudioInput(_ asbd: AudioStreamBasicDescription) -> AVAssetWriterInput {
        // Audio Output Configuration
        var acl = AudioChannelLayout()
        acl.mChannelLayoutTag = asbd.mChannelsPerFrame == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
        acl.mChannelBitmap = AudioChannelBitmap(rawValue: UInt32(0))
        acl.mNumberChannelDescriptions = UInt32(0)

        let acll = MemoryLayout<AudioChannelLayout>.size

        let audioOutputSettings: Dictionary<String, Any> = [
            AVFormatIDKey : UInt(kAudioFormatMPEG4AAC),
            AVNumberOfChannelsKey : UInt(asbd.mChannelsPerFrame),
            AVSampleRateKey : asbd.mSampleRate,
            AVEncoderBitRateKey : 96000,
            AVChannelLayoutKey : NSData(bytes: &acl, length: acll),
        ]
        let audioInput = AVAssetWriterInput(
            mediaType: AVMediaType.audio,
            outputSettings: audioOutputSettings
        )
        audioInput.expectsMediaDataInRealTime = true

        if !assetWriter!.canAdd(audioInput) {
            print("Winston oh no")
        }

        return audioInput
    }

    func startRecording() {
        do {
            let recordingURL = recordedFileURL
            if FileManager.default.fileExists(atPath: recordingURL.path) {
                do {
                    try FileManager.default.removeItem(at: recordedFileURL)
                    print("removed existing recording")
                } catch {
                    print("error deleting", error)
                    return
                }
            }
            assetWriter = try AVAssetWriter(outputURL: recordingURL, fileType: AVFileType.mp4)
            isRecording = true
            print("Leyende started recording")
        } catch {
            print("Could not create file for recording: \(error)")
        }
    }

    func stopRecording() {
        if isRecording {
            isRecording = false
            if assetWriter?.status == AVAssetWriter.Status.writing {
                assetWriter?.finishWriting {
                    print("FinishedWriting")
                }
            }
            Self.mostRecentRecording = assetWriter?.outputURL
            recordedFile = nil // close file
            print("Leyende stopped recording")
        }
    }

    func processSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let assetWriter = self.assetWriter else {
            print("Leyende: no asset writer found!")
            return
        }
        if assetWriter.status == AVAssetWriter.Status.unknown {
            guard let fmt = CMSampleBufferGetFormatDescription(sampleBuffer) else {
                return
            }
            guard let absd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee else {
                return
            }
            recordedFile = configureAudioInput(absd)
            assetWriter.add(recordedFile)
            assetWriter.startWriting()
            assetWriter.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        }
        if self.recordedFile.isReadyForMoreMediaData {
            self.recordedFile!.append(sampleBuffer)
        }
    }

    func calculateAudioCMTime(sampleRate: Double, correction seconds: Double) -> CMTime {
        return CMTimeMakeWithSeconds(AVAudioTime.seconds(forHostTime: mach_absolute_time()) + seconds, preferredTimescale: Int32(sampleRate))
    }
}

extension AgoraCaptureSession: MediaWorkerDelegate {
    func mediaWorkerDidReceiveRemotePCM(_ buffer: AVAudioPCMBuffer) {
        if self.isRecording {
            let asbd = buffer.format.streamDescription
            let pts = calculateAudioCMTime(sampleRate: asbd.pointee.mSampleRate, correction: 0)
            counter += 1
            if counter % 5 == 0 {
                print("Leyende processed: \(counter) at PTS: \(CMTimeGetSeconds(pts))")
            }
            guard let cmBuf = buffer.toStandardSampleBuffer(pts: calculateAudioCMTime(sampleRate: asbd.pointee.mSampleRate, correction: 0), sampleRate: Int32(asbd.pointee.mSampleRate)) else {
                print("Leyende failed CMSampleBufferCreate")
                return
            }
            self.processSampleBuffer(cmBuf /* , with: .audioMic */ )
        }
    }
}

extension AVAudioPCMBuffer {

    public func toStandardSampleBuffer(duration: CMTime? = nil, pts: CMTime? = nil, sampleRate: Int32) -> CMSampleBuffer? {

        var sampleBuffer: CMSampleBuffer? = nil

        let based_pts = pts ?? CMTime.zero

        var timing = CMSampleTimingInfo(duration: CMTimeMake(value: 1, timescale: sampleRate), presentationTimeStamp: based_pts, decodeTimeStamp: CMTime.invalid)

        var output_format = self.format

        var pcmBuffer = self

        guard CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil, formatDescription: output_format.formatDescription, sampleCount: CMItemCount(self.frameLength), sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sampleBuffer) == noErr else { return nil }

        guard CMSampleBufferSetDataBufferFromAudioBufferList(sampleBuffer!, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: pcmBuffer.audioBufferList) == noErr else {
            return nil
        }

        return sampleBuffer

    }

}
