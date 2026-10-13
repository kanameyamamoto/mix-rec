import AVFoundation
import Foundation
import Speech

/// 文字起こしの共通の形（新旧どちらの仕組みでも同じように扱う）
protocol Transcribing: AnyObject, Sendable {
    var speaker: String { get }
    var onPartial: ((String) -> Void)? { get set }
    var onFinal: ((TranscriptLine) -> Void)? { get set }
    func start(recordingStart: Date)
    func append(_ buffer: AVAudioPCMBuffer)
    func stop()
}

extension LiveTranscriber: Transcribing, @unchecked Sendable {}

#if compiler(>=6.2)
/// macOS 26 の新しい音声認識（SpeechAnalyzer）を使う文字起こし。
/// 長い会議・講義向けに作られた仕組みで、沈黙で勝手に止まらず、Mac内で処理する。
@available(macOS 26.0, *)
final class ModernTranscriber: Transcribing, @unchecked Sendable {
    let speaker: String
    var onPartial: ((String) -> Void)?
    var onFinal: ((TranscriptLine) -> Void)?

    private let lock = NSLock()
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var targetFormat: AVAudioFormat?   // 準備ができるまでは nil（その間の音は捨てる）
    private var startOffset: TimeInterval?     // 録音開始から、最初の音を渡すまでの秒数
    private var recordingStart = Date()
    private var analyzer: SpeechAnalyzer?
    private var setupTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?
    private var converter: AVAudioConverter?   // 音声スレッドだけが触る

    init(speaker: String) {
        self.speaker = speaker
    }

    func start(recordingStart: Date) {
        self.recordingStart = recordingStart
        let (stream, cont) = AsyncStream.makeStream(of: AnalyzerInput.self)
        lock.withLock { continuation = cont }

        setupTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "ja-JP")) else {
                    Log.write("[\(self.speaker)] このMacでは日本語の新しい文字起こしが使えません")
                    self.onPartial?("このMacでは日本語の文字起こしが使えません")
                    return
                }
                let transcriber = SpeechTranscriber(locale: locale,
                                                    transcriptionOptions: [],
                                                    reportingOptions: [.volatileResults, .fastResults], // 途中経過を速く出す
                                                    attributeOptions: [.audioTimeRange])

                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    Log.write("[\(self.speaker)] 日本語の文字起こしデータをダウンロード中")
                    self.onPartial?("日本語の文字起こしデータをダウンロード中…（初回のみ）")
                    try await request.downloadAndInstall()
                    self.onPartial?("")
                    Log.write("[\(self.speaker)] ダウンロード完了")
                }

                let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
                let analyzer = SpeechAnalyzer(modules: [transcriber])

                let speaker = self.speaker
                let results = Task { [weak self] in
                    var volatileCount = 0
                    do {
                        for try await result in transcriber.results {
                            guard let self else { return }
                            let text = String(result.text.characters)
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            if result.isFinal {
                                // 空の確定は途中の行を消すだけ。中身があるときは、途中の行をそのまま確定に差し替える
                                guard !text.isEmpty else { self.onPartial?(""); continue }
                                let offset = self.lock.withLock { self.startOffset } ?? 0
                                let t = result.range.start.seconds
                                let time = offset + (t.isFinite ? t : 0)
                                Log.write("[\(speaker)] 1行確定（途中経過\(volatileCount)回）: \(text.prefix(30))")
                                volatileCount = 0
                                self.onFinal?(TranscriptLine(time: time, speaker: speaker, text: text))
                            } else {
                                volatileCount += 1
                                if volatileCount <= 3 {
                                    Log.write("[\(speaker)] 途中経過を受信: \(text.prefix(20))")
                                }
                                self.onPartial?(text)
                            }
                        }
                    } catch {
                        Log.write("[\(speaker)] 文字起こしエラー: \(error.localizedDescription)")
                    }
                }

                try await analyzer.start(inputSequence: stream)
                self.lock.withLock {
                    self.analyzer = analyzer
                    self.resultsTask = results
                    self.targetFormat = format
                }
                Log.write("[\(speaker)] 新しい文字起こしを開始（\(Int(format?.sampleRate ?? 0))Hz）")
            } catch {
                Log.write("[\(self.speaker)] 文字起こしを開始できませんでした: \(error.localizedDescription)")
                self.onPartial?("文字起こしを開始できませんでした")
            }
        }
    }

    /// 音声スレッドから呼ばれる。buffer はこの呼び出しの間だけ有効なので、ここで変換・コピーする。
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let format = targetFormat
        let cont = continuation
        if format != nil, startOffset == nil {
            startOffset = Date().timeIntervalSince(recordingStart)
        }
        lock.unlock()
        guard let format, let cont, let converted = convert(buffer, to: format) else { return }
        cont.yield(AnalyzerInput(buffer: converted))
    }

    /// 止める。最後の確定を待つので、画面のスレッド以外から呼ぶこと。
    func stop() {
        let cont: AsyncStream<AnalyzerInput>.Continuation? = lock.withLock {
            targetFormat = nil
            let c = continuation
            continuation = nil
            return c
        }
        cont?.finish()

        let done = DispatchSemaphore(value: 0)
        let setup = setupTask
        Task { [weak self] in
            await setup?.value
            guard let self else { done.signal(); return }
            let (analyzer, results) = self.lock.withLock { (self.analyzer, self.resultsTask) }
            if let analyzer {
                try? await analyzer.finalizeAndFinishThroughEndOfInput()
            }
            await results?.value
            done.signal()
        }
        if done.wait(timeout: .now() + 4) == .timedOut {
            // 話していない側は確定待ちが終わらないことがあるので、待たずに終える
            let analyzer = lock.withLock { self.analyzer }
            Task { try? await analyzer?.cancelAndFinishNow() }
            setupTask?.cancel()
        }
        onPartial?("")
    }

    private func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if converter == nil || converter?.inputFormat != buffer.format || converter?.outputFormat != format {
            converter = AVAudioConverter(from: buffer.format, to: format)
            converter?.downmix = true
        }
        guard let converter, buffer.frameLength > 0 else { return nil }

        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        var fed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0 else { return nil }
        return out
    }
}
#endif

enum TranscriberFactory {
    /// 使える中で一番よい文字起こしを選ぶ（macOS 26 なら新しい仕組み）
    static func make(speaker: String) -> Transcribing {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            return ModernTranscriber(speaker: speaker)
        }
        #endif
        return LiveTranscriber(speaker: speaker)
    }

    static var engineName: String {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) { return "新方式（SpeechAnalyzer）" }
        #endif
        return "旧方式（SFSpeechRecognizer）"
    }
}
