import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// Macの内部音声（システム全体の音）を Core Audio Tap で受け取り、ファイルに書き出す。
/// 出力先はスピーカーやAirPodsのままなので、音量キーも普段どおり使える。
final class SystemAudioCapture {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var file: AVAudioFile?
    private let queue = DispatchQueue(label: "mixrec.system-audio", qos: .userInitiated)
    /// 音が届くたびに呼ばれる（文字起こし用）。start の前に設定する。
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    func start(writingTo url: URL) throws {
        // 1. システム全体の音をステレオで受け取る Tap を作る
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        var err = AudioHardwareCreateProcessTap(description, &tap)
        guard err == noErr else {
            throw RecorderError.coreAudio("内部音声の取得を開始できませんでした", err)
        }
        tapID = tap

        // 2. 今の出力先（スピーカー/AirPods）を土台に、Tap を入力として持つ非公開の装置を作る
        let outputID = try CoreAudioHelper.defaultOutputDevice()
        guard let outputUID = CoreAudioHelper.stringProperty(outputID, kAudioDevicePropertyDeviceUID) else {
            cleanup()
            throw RecorderError.message("出力先の情報を読み取れませんでした")
        }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MixRec Tap",
            kAudioAggregateDeviceUIDKey: "MixRec-\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]

        var agg = AudioObjectID(kAudioObjectUnknown)
        err = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &agg)
        guard err == noErr else {
            cleanup()
            throw RecorderError.coreAudio("録音用の装置を作れませんでした", err)
        }
        aggregateID = agg

        // 3. Tap から届く音の形式を調べて、同じ形式でファイルを作る
        var addr = CoreAudioHelper.address(kAudioTapPropertyFormat)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        err = AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd)
        guard err == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
            cleanup()
            throw RecorderError.coreAudio("内部音声の形式を読み取れませんでした", err)
        }

        let file = try AVAudioFile(forWriting: url,
                                   settings: format.settings,
                                   commonFormat: format.commonFormat,
                                   interleaved: format.isInterleaved)
        self.file = file

        // 4. 音が届くたびにファイルへ書き込む
        let handler = onBuffer
        var procID: AudioDeviceIOProcID?
        err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, inputData, _, _, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                                bufferListNoCopy: inputData,
                                                deallocator: nil) else { return }
            try? file.write(from: buffer)
            handler?(buffer)
        }
        guard err == noErr, let procID else {
            cleanup()
            throw RecorderError.coreAudio("内部音声の受け取りを準備できませんでした", err)
        }
        ioProcID = procID

        err = AudioDeviceStart(aggregateID, procID)
        guard err == noErr else {
            cleanup()
            throw RecorderError.coreAudio("内部音声の録音を開始できませんでした", err)
        }
    }

    func stop() {
        cleanup()
    }

    private func cleanup() {
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        ioProcID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)

        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
        }
        tapID = AudioObjectID(kAudioObjectUnknown)

        queue.sync {} // 書き込み途中の分を待ってから閉じる
        file = nil
    }
}

/// マイクの音を、マイク装置から直接受け取ってファイルに書き出す。
/// （AVAudioEngine は出力側の装置まで準備するため、イヤホン接続時などに数十秒かかることがあった）
final class MicCapture {
    private var deviceID = AudioDeviceID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var file: AVAudioFile?
    private let queue = DispatchQueue(label: "mixrec.mic-audio", qos: .userInitiated)
    /// 音が届くたびに呼ばれる（文字起こし用）。start の前に設定する。
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    func start(deviceID requested: AudioDeviceID?, writingTo url: URL) throws {
        guard let device = requested ?? CoreAudioHelper.defaultInputDevice() else {
            throw RecorderError.message("マイクが見つかりません")
        }

        // マイクの1本目の入力ストリームの形式を調べる
        var addr = CoreAudioHelper.address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        var err = AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size)
        guard err == noErr, size >= UInt32(MemoryLayout<AudioStreamID>.size) else {
            throw RecorderError.coreAudio("マイクの情報を読み取れませんでした", err)
        }
        var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        err = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &streams)
        guard err == noErr, let stream = streams.first else {
            throw RecorderError.coreAudio("マイクの情報を読み取れませんでした", err)
        }

        var fmtAddr = CoreAudioHelper.address(kAudioStreamPropertyVirtualFormat)
        var asbd = AudioStreamBasicDescription()
        var fmtSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        err = AudioObjectGetPropertyData(stream, &fmtAddr, 0, nil, &fmtSize, &asbd)
        guard err == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
            throw RecorderError.coreAudio("マイクの音の形式を読み取れませんでした", err)
        }

        let file = try AVAudioFile(forWriting: url,
                                   settings: format.settings,
                                   commonFormat: format.commonFormat,
                                   interleaved: format.isInterleaved)
        self.file = file

        let handler = onBuffer
        var procID: AudioDeviceIOProcID?
        err = AudioDeviceCreateIOProcIDWithBlock(&procID, device, queue) { _, inputData, _, _, _ in
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            guard list.count > 0 else { return }
            // 1本目のストリームだけを使う
            var single = AudioBufferList(mNumberBuffers: 1, mBuffers: list[0])
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                                bufferListNoCopy: &single,
                                                deallocator: nil) else { return }
            try? file.write(from: buffer)
            handler?(buffer)
        }
        guard err == noErr, let procID else {
            self.file = nil
            throw RecorderError.coreAudio("マイクの受け取りを準備できませんでした", err)
        }

        err = AudioDeviceStart(device, procID)
        guard err == noErr else {
            AudioDeviceDestroyIOProcID(device, procID)
            self.file = nil
            throw RecorderError.coreAudio("マイクの録音を開始できませんでした", err)
        }
        self.deviceID = device
        self.ioProcID = procID
    }

    func stop() {
        if let ioProcID, deviceID != AudioDeviceID(kAudioObjectUnknown) {
            AudioDeviceStop(deviceID, ioProcID)
            AudioDeviceDestroyIOProcID(deviceID, ioProcID)
        }
        ioProcID = nil
        deviceID = AudioDeviceID(kAudioObjectUnknown)
        queue.sync {}
        file = nil
    }
}

/// 内部音声とマイクの2つのファイルを、音量バランスをつけて1つの .m4a にまとめる。
enum Mixer {
    static func mix(sources: [(url: URL, volume: Float)], to output: URL) async throws {
        let composition = AVMutableComposition()
        var parameters: [AVMutableAudioMixInputParameters] = []

        for source in sources {
            let asset = AVURLAsset(url: source.url)
            guard let sourceTrack = try await asset.loadTracks(withMediaType: .audio).first else { continue }
            let duration = try await asset.load(.duration)
            guard duration.seconds > 0,
                  let track = composition.addMutableTrack(withMediaType: .audio,
                                                          preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: sourceTrack, at: .zero)

            let p = AVMutableAudioMixInputParameters(track: track)
            p.setVolume(source.volume, at: .zero)
            parameters.append(p)
        }

        guard !parameters.isEmpty else {
            throw RecorderError.message("録音された音がありませんでした")
        }

        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = parameters

        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw RecorderError.message("保存の準備ができませんでした")
        }
        export.audioMix = audioMix
        export.outputFileType = .m4a
        export.outputURL = output

        let box = ExportBox(export)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            box.session.exportAsynchronously {
                if box.session.status == .completed {
                    cont.resume()
                } else {
                    cont.resume(throwing: box.session.error ?? RecorderError.message("保存に失敗しました"))
                }
            }
        }
    }
}

/// 書き出し完了の通知を別スレッドで受け取るための入れ物（ビルド時の警告を消すため）
private final class ExportBox: @unchecked Sendable {
    let session: AVAssetExportSession
    init(_ session: AVAssetExportSession) { self.session = session }
}
