import AVFoundation
import Foundation
import Speech

struct TranscriptLine: Identifiable {
    var id = UUID()
    let time: TimeInterval   // 録音開始からの秒数
    let speaker: String
    let text: String
}

/// 録音中の音を Apple の音声認識で文字にする。
/// 話の区切り（約3秒、認識結果が変わらない）か約50秒ごとに区切り、
/// 区切った分は認識の「確定結果」を待ってから1行として保存する。
final class LiveTranscriber {
    let speaker: String
    var onPartial: ((String) -> Void)?       // 認識途中の文字
    var onFinal: ((TranscriptLine) -> Void)? // 確定した1行

    private struct Segment {
        let offset: TimeInterval
        var text: String = ""
        var task: SFSpeechRecognitionTask?
    }

    private let recognizer: SFSpeechRecognizer?
    private let queue = DispatchQueue(label: "mixrec.transcribe")
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: 16_000, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?          // 音声スレッドだけが触る
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var segments: [Int: Segment] = [:]        // 確定待ちを含む区切りごとの状態
    private var currentID = 0
    private var requestStarted = Date()
    private var lastChange = Date()
    private var recordingStart = Date()
    private var timer: DispatchSourceTimer?
    private var running = false
    private var failures = 0          // 連続エラー数（やり直しの間隔を広げる）
    private var loggedFirstText = false

    private let silenceToSplit: TimeInterval = 3.0
    private let maxSegment: TimeInterval = 50
    private let finalTimeout: TimeInterval = 5

    init(speaker: String, locale: Locale = Locale(identifier: "ja-JP")) {
        self.speaker = speaker
        self.recognizer = SFSpeechRecognizer(locale: locale)
    }

    var isOnDevice: Bool { recognizer?.supportsOnDeviceRecognition ?? false }

    static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
        }
    }

    func start(recordingStart: Date) {
        queue.async {
            guard let recognizer = self.recognizer else {
                Log.write("[\(self.speaker)] 日本語の音声認識が使えません")
                return
            }
            Log.write("[\(self.speaker)] 文字起こし開始（使用可能: \(recognizer.isAvailable), オンデバイス: \(recognizer.supportsOnDeviceRecognition)）")
            self.running = true
            self.failures = 0
            self.loggedFirstText = false
            self.recordingStart = recordingStart
            self.startRequest()
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + 0.5, repeating: 0.5)
            t.setEventHandler { [weak self] in self?.checkSplit() }
            t.resume()
            self.timer = t
        }
    }

    /// 音声スレッドから呼ばれる。渡された buffer はこの呼び出しの間だけ有効なので、ここで変換・コピーする。
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let converted = convert(buffer) else { return }
        queue.async { self.request?.append(converted) }
    }

    /// 止める。最後の区切りの確定結果を少し待つので、画面のスレッド以外から呼ぶこと。
    func stop() {
        queue.sync {
            running = false
            timer?.cancel()
            timer = nil
            request?.endAudio()
            request = nil
        }
        // 確定結果が届くのを最大2秒待つ
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let remaining = queue.sync { segments.count }
            if remaining == 0 { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        queue.sync {
            for id in segments.keys.sorted() { finalize(id) }
            onPartial?("")
        }
    }

    // MARK: - 内部処理（queue 上で動く）

    private func startRequest() {
        guard running, let recognizer else { return }
        currentID += 1
        let id = currentID
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition {
            req.requiresOnDeviceRecognition = true
        }
        request = req
        requestStarted = Date()
        lastChange = Date()
        var segment = Segment(offset: Date().timeIntervalSince(recordingStart))

        segment.task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            self.queue.async { self.handle(id: id, result: result, error: error) }
        }
        segments[id] = segment
    }

    private func handle(id: Int, result: SFSpeechRecognitionResult?, error: Error?) {
        guard segments[id] != nil else { return }
        if let result {
            let text = result.bestTranscription.formattedString
            if !loggedFirstText, !text.isEmpty {
                loggedFirstText = true
                Log.write("[\(speaker)] 最初の文字を認識しました")
            }
            failures = 0
            // 区切ったあと空っぽの確定結果が返ることがあるので、空では上書きしない
            if !text.isEmpty, text != segments[id]?.text {
                segments[id]?.text = text
                if id == currentID {
                    lastChange = Date()
                    onPartial?(text)
                }
            }
            if result.isFinal {
                finalize(id)
                if id == currentID { restartAfterEnd() }
            }
        } else if let error {
            let ns = error as NSError
            // 1110 =「声が検出されない」。黙っている間に認識が自動で終わっただけなので失敗扱いしない
            let isSilence = ns.domain == "kAFAssistantErrorDomain" && ns.code == 1110
            if !isSilence {
                Log.write("[\(speaker)] 認識エラー: \(ns.domain) \(ns.code) \(ns.localizedDescription)")
                if id == currentID { failures += 1 }
            }
            finalize(id)
            // 無音が続いた時などに認識が終わることがある。少し待ってから次を始める
            if id == currentID { restartAfterEnd() }
        }
    }

    private func restartAfterEnd() {
        request = nil
        onPartial?("")
        // エラーが続くときは間隔を広げる（0.5秒→最大30秒）
        let delay = failures == 0 ? 0.1 : min(30, pow(2, Double(failures)))
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.running, self.request == nil else { return }
            self.startRequest()
        }
    }

    private func checkSplit() {
        guard running, request != nil, let current = segments[currentID] else { return }
        let now = Date()
        let age = now.timeIntervalSince(requestStarted)
        let hasText = !current.text.isEmpty
        if hasText, now.timeIntervalSince(lastChange) > silenceToSplit || age > maxSegment {
            split()
        } else if !hasText, age > maxSegment {
            split() // 無音のまま長く続くと止まるので作り直す
        }
    }

    /// 今の区切りの音声入力を終えて確定結果を待ちつつ、すぐ次の区切りの認識を始める
    private func split() {
        let endingID = currentID
        request?.endAudio()
        onPartial?("")
        startRequest()
        // 確定結果が来なかった場合の保険
        queue.asyncAfter(deadline: .now() + finalTimeout) { [weak self] in
            self?.finalize(endingID)
        }
    }

    /// 区切りを1行として保存する（2回目以降は何もしない）
    private func finalize(_ id: Int) {
        guard let segment = segments.removeValue(forKey: id) else { return }
        segment.task?.finish()
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        Log.write("[\(speaker)] 1行確定: \(text.prefix(30))")
        onFinal?(TranscriptLine(time: segment.offset, speaker: speaker, text: text))
    }

    // MARK: - 音声の変換（16kHz・モノラルに）

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
            converter?.downmix = true
        }
        guard let converter, buffer.frameLength > 0 else { return nil }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }

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
