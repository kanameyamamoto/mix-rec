import AppKit
import SwiftUI
import AVFoundation
import Foundation

@MainActor
final class RecorderModel: ObservableObject {
    @Published var isRecording = false
    @Published var isSaving = false
    @Published var isStarting = false
    @Published var elapsed: TimeInterval = 0
    @Published var status = "準備OK"
    @Published var lastSavedURL: URL?
    @Published var micDevices: [AudioDevice] = []
    @Published var transcript: [TranscriptLine] = []
    @Published var partials: [String: String] = [:]   // 話者ごとの認識途中の文字
    /// 話者ごとの「話し始めた時間」。途中の文字も確定した文字も、この時間で並べる
    private var partialStarts: [String: TimeInterval] = [:]
    /// 話者ごとの「今話している行」のID。確定してもこのIDを引き継ぎ、行を作り直さない
    private var partialIDs: [String: UUID] = [:]

    /// 画面に出す行（確定した行と話している途中の行を、話し始めた時間順に並べたもの）
    struct DisplayRow: Identifiable, Equatable {
        let id: String
        let time: TimeInterval
        let speaker: String
        let text: String
        let live: Bool
    }

    var displayRows: [DisplayRow] {
        var rows = transcript.map {
            DisplayRow(id: $0.id.uuidString, time: $0.time, speaker: $0.speaker, text: $0.text, live: false)
        }
        for (speaker, text) in partials {
            rows.append(DisplayRow(id: (partialIDs[speaker] ?? UUID()).uuidString, time: partialStarts[speaker] ?? elapsed,
                                   speaker: speaker, text: text, live: true))
        }
        // 同じ時間なら確定した行を先に。並びが入れ替わらないよう安定した順にする
        return rows.enumerated().sorted {
            if $0.element.time != $1.element.time { return $0.element.time < $1.element.time }
            if $0.element.live != $1.element.live { return !$0.element.live }
            return $0.offset < $1.offset
        }.map(\.element)
    }
    @Published var lastTranscriptURL: URL?
    @Published var history: [RecordingItem] = []
    @Published var copiedItemID: URL?   // 直前にコピーした録音（ボタンに「コピー済み」を出す用）
    @Published var titlingIDs: Set<URL> = []   // AIがタイトルを考え中の録音
    private var titleAttempted: Set<URL> = []   // 同じものに何度も挑戦しない
    private var titleTask: Task<Void, Never>?
    private lazy var aiAvailable: Bool = TitleMaker.isAvailable

    @Published var recordSystem: Bool { didSet { defaults.set(recordSystem, forKey: "recordSystem") } }
    @Published var recordMic: Bool { didSet { defaults.set(recordMic, forKey: "recordMic") } }
    @Published var systemVolume: Double { didSet { defaults.set(systemVolume, forKey: "systemVolume") } }
    @Published var micVolume: Double { didSet { defaults.set(micVolume, forKey: "micVolume") } }
    @Published var selectedMicUID: String { didSet { defaults.set(selectedMicUID, forKey: "micUID") } }
    @Published var saveFolder: URL { didSet { defaults.set(saveFolder.path, forKey: "saveFolder") } }
    @Published var transcribe: Bool { didSet { defaults.set(transcribe, forKey: "transcribe") } }

    private let defaults = UserDefaults.standard
    private let system = SystemAudioCapture()
    private let mic = MicCapture()
    private var timer: Timer?
    private var startDate: Date?
    private var tempDir: URL?
    private let captureQueue = DispatchQueue(label: "mixrec.capture", qos: .userInitiated)
    private var transcribers: [Transcribing] = []

    static let micSpeaker = "自分"
    static let systemSpeaker = "相手"

    init() {
        let d = UserDefaults.standard
        recordSystem = d.object(forKey: "recordSystem") as? Bool ?? true
        recordMic = d.object(forKey: "recordMic") as? Bool ?? true
        systemVolume = d.object(forKey: "systemVolume") as? Double ?? 1.0
        micVolume = d.object(forKey: "micVolume") as? Double ?? 1.0
        selectedMicUID = d.string(forKey: "micUID") ?? ""
        transcribe = d.object(forKey: "transcribe") as? Bool ?? true
        if let path = d.string(forKey: "saveFolder") {
            saveFolder = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            saveFolder = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Music/MixRec", isDirectory: true)
        }
        refreshMics()
        refreshHistory()
    }

    /// 録音開始からの今の秒数（表示用タイマーより細かい）
    var currentElapsed: TimeInterval {
        startDate.map { Date().timeIntervalSince($0) } ?? elapsed
    }

    var elapsedText: String {
        let s = Int(elapsed)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// マイク一覧を更新。未選択なら内蔵マイクを優先する（AirPodsのマイクは音質が落ちるため）。
    func refreshMics() {
        micDevices = CoreAudioHelper.inputDevices()
        if !micDevices.contains(where: { $0.uid == selectedMicUID }) {
            selectedMicUID = micDevices.first(where: { $0.isBuiltIn })?.uid
                ?? micDevices.first?.uid ?? ""
        }
    }

    func toggle() {
        isRecording ? stop() : start()
    }

    func start() {
        guard !isRecording, !isSaving, !isStarting else { return }
        guard recordSystem || recordMic else {
            status = "内部音声かマイクのどちらかをONにしてください"
            return
        }

        Task {
            if recordMic {
                let granted = await AVCaptureDevice.requestAccess(for: .audio)
                guard granted else {
                    status = "マイクが許可されていません（システム設定 → プライバシーとセキュリティ → マイク）"
                    return
                }
            }
            var useTranscription = transcribe
            if useTranscription {
                let ok = await LiveTranscriber.requestAuthorization()
                if !ok {
                    useTranscription = false
                    status = "音声認識が許可されていないため、文字起こしなしで録音します"
                }
            }
            await beginCapture(transcription: useTranscription)
        }
    }

    /// 音声装置の操作は時間がかかったり止まったりすることがあるので、画面とは別の場所で行う
    private func onCaptureQueue(_ work: @escaping () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            captureQueue.async {
                do { try work(); cont.resume() } catch { cont.resume(throwing: error) }
            }
        }
    }

    private func makeTranscriber(speaker: String) -> Transcribing {
        let t = TranscriberFactory.make(speaker: speaker)
        t.onPartial = { [weak self] text in
            DispatchQueue.main.async {
                guard let self else { return }
                if text.isEmpty {
                    // 途中の行が取り消された。時間とIDも忘れる（残すと次の行が古い時間になる）
                    self.partials[speaker] = nil
                    self.partialStarts[speaker] = nil
                    self.partialIDs[speaker] = nil
                } else {
                    // 話し始めた瞬間の時間とIDを覚えておく（その後は動かさない）
                    if self.partialStarts[speaker] == nil {
                        self.partialStarts[speaker] = self.currentElapsed
                        self.partialIDs[speaker] = UUID()
                    }
                    self.partials[speaker] = text
                }
            }
        }
        t.onFinal = { [weak self] line in
            DispatchQueue.main.async {
                guard let self else { return }
                // 途中の行と同じ位置・同じIDのまま確定させる（消えて出る点滅やワープをなくす）
                // 途中の行がなかったときは、認識が返した時間をそのまま使う
                let start = self.partialStarts.removeValue(forKey: line.speaker) ?? line.time
                let id = self.partialIDs.removeValue(forKey: line.speaker) ?? line.id
                let fixed = TranscriptLine(id: id, time: start, speaker: line.speaker, text: line.text)
                let index = self.transcript.firstIndex { $0.time > start } ?? self.transcript.endIndex
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) {
                    self.partials[line.speaker] = nil   // 同じ更新の中で差し替えるので、一瞬消えることがない
                    self.transcript.insert(fixed, at: index)
                }
            }
        }
        return t
    }

    private func beginCapture(transcription: Bool) async {
        isStarting = true
        status = "準備中…"
        defer { isStarting = false }
        do {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("MixRec-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            tempDir = dir

            let useSystem = recordSystem
            let useMic = recordMic
            let deviceID = micDevices.first(where: { $0.uid == selectedMicUID })?.id
            let system = self.system
            let mic = self.mic
            let recordingStart = Date()

            // 文字起こしの準備（音が届くたびに渡す）
            transcript = []
            partials = [:]
            partialStarts = [:]
            partialIDs = [:]
            lastTranscriptURL = nil
            transcribers = []
            system.onBuffer = nil
            mic.onBuffer = nil
            if transcription {
                if useMic {
                    let t = makeTranscriber(speaker: Self.micSpeaker)
                    mic.onBuffer = { t.append($0) }
                    transcribers.append(t)
                }
                if useSystem {
                    let t = makeTranscriber(speaker: Self.systemSpeaker)
                    system.onBuffer = { t.append($0) }
                    transcribers.append(t)
                }
                Log.write("文字起こし: \(TranscriberFactory.engineName)")
                transcribers.forEach { $0.start(recordingStart: recordingStart) }
            }

            try await onCaptureQueue {
                Log.write("録音開始（内部音声: \(useSystem), マイク: \(useMic), マイクID: \(deviceID.map(String.init) ?? "既定")）")
                // 先にマイクを始める。内部音声用の装置を作った直後はmacOSの音声システムが
                // 組み直し中になり、そのあとにマイクを始めると数十秒待たされるため。
                if useMic {
                    Log.write("マイクの準備を開始")
                    try mic.start(deviceID: deviceID, writingTo: dir.appendingPathComponent("mic.caf"))
                    Log.write("マイクの準備OK")
                }
                if useSystem {
                    Log.write("内部音声の準備を開始")
                    do {
                        try system.start(writingTo: dir.appendingPathComponent("system.caf"))
                    } catch {
                        mic.stop()
                        throw error
                    }
                    Log.write("内部音声の準備OK")
                }
            }

            isRecording = true
            startDate = recordingStart
            elapsed = 0
            status = "録音中…"
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let start = self.startDate else { return }
                    self.elapsed = Date().timeIntervalSince(start)
                }
            }
        } catch {
            let failed = transcribers
            transcribers = []
            captureQueue.async { failed.forEach { $0.stop() } }
            Log.write("開始失敗: \(error.localizedDescription)")
            status = "開始できませんでした：\(error.localizedDescription)"
            if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
            tempDir = nil
        }
    }

    func stop() {
        guard isRecording else { return }
        timer?.invalidate()
        timer = nil
        isRecording = false
        isSaving = true
        status = "保存中…"

        guard let dir = tempDir else { isSaving = false; return }
        Task { await finishRecording(dir: dir) }
    }

    private func finishRecording(dir: URL) async {
        let system = self.system
        let mic = self.mic
        try? await onCaptureQueue {
            Log.write("停止")
            system.stop()
            mic.stop()
            Log.write("停止OK")
        }
        // 文字起こしの最後の確定を待つ（少し時間がかかるので画面とは別の場所で）
        let activeTranscribers = transcribers
        transcribers = []
        try? await onCaptureQueue {
            activeTranscribers.forEach { $0.stop() }
        }
        // 最後の行の反映（メインスレッドに積まれた分）を待つ
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { c.resume() }
        }
        partials = [:]
        partialStarts = [:]
        partialIDs = [:]

        var sources: [(url: URL, volume: Float)] = []
        let systemURL = dir.appendingPathComponent("system.caf")
        let micURL = dir.appendingPathComponent("mic.caf")
        if recordSystem, FileManager.default.fileExists(atPath: systemURL.path) {
            sources.append((systemURL, Float(systemVolume)))
        }
        if recordMic, FileManager.default.fileExists(atPath: micURL.path) {
            sources.append((micURL, Float(micVolume)))
        }

        let folder = saveFolder
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
            let output = folder.appendingPathComponent("録音 \(formatter.string(from: Date())).m4a")

            try await Mixer.mix(sources: sources, to: output)
            try? FileManager.default.removeItem(at: dir)
            lastSavedURL = output
            status = "保存しました：\(output.lastPathComponent)"

            if !transcript.isEmpty {
                let textURL = output.deletingPathExtension().appendingPathExtension("txt")
                try transcriptText().write(to: textURL, atomically: true, encoding: .utf8)
                lastTranscriptURL = textURL
                refreshHistory()
                status += "（文字起こしも保存）"
            }
            Log.write("保存OK: \(output.path)")
        } catch {
            // まとめに失敗しても元の録音は残す
            Log.write("保存失敗: \(error.localizedDescription)")
            status = "保存に失敗しました（元の音声は残しています）：\(error.localizedDescription)"
            NSWorkspace.shared.activateFileViewerSelecting([dir])
        }
        tempDir = nil
        isSaving = false
    }

    static func timeLabel(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    }

    /// 保存用の文字起こしテキスト
    func transcriptText() -> String {
        transcript
            .map { "[\(Self.timeLabel($0.time))] \($0.speaker)：\($0.text)" }
            .joined(separator: "\n") + "\n"
    }

    /// 保存先フォルダの文字起こし（.txt）を新しい順に読み込む
    func refreshHistory() {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let files = (try? fm.contentsOfDirectory(at: saveFolder, includingPropertiesForKeys: keys)) ?? []
        history = files
            .filter { $0.pathExtension.lowercased() == "txt" }
            .compactMap { RecordingItem(url: $0) }
            .sorted { $0.date > $1.date }
        makeMissingTitles()
    }

    /// タイトルがまだない録音に、新しい順に1つずつAIでタイトルを付ける
    private func makeMissingTitles() {
        guard titleTask == nil, aiAvailable else { return }
        let targets = history.filter { $0.aiTitle == nil && !titleAttempted.contains($0.id) && $0.lineCount > 0 }
        guard !targets.isEmpty else { return }
        titleTask = Task { [weak self] in
            for item in targets {
                guard let self else { return }
                self.titleAttempted.insert(item.id)
                self.titlingIDs.insert(item.id)
                let title = await TitleMaker.makeTitle(for: item.url)
                self.titlingIDs.remove(item.id)
                if let title, let i = self.history.firstIndex(where: { $0.id == item.id }) {
                    self.history[i].aiTitle = title
                }
            }
            self?.titleTask = nil
            self?.makeMissingTitles()   // 途中で新しい録音が増えていたら続ける
        }
    }

    /// 過去の録音の文字起こし全文をコピーする
    func copyRecording(_ item: RecordingItem) {
        guard let text = try? String(contentsOf: item.url, encoding: .utf8) else {
            status = "読み込めませんでした：\(item.url.lastPathComponent)"
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedItemID = item.id
        status = "「\(item.title)」の文字起こしをコピーしました"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            if self?.copiedItemID == item.id { self?.copiedItemID = nil }
        }
    }

    func revealRecording(_ item: RecordingItem) {
        let audio = item.url.deletingPathExtension().appendingPathExtension("m4a")
        let target = FileManager.default.fileExists(atPath: audio.path) ? audio : item.url
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    func copyTranscript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcriptText(), forType: .string)
        status = "文字起こしをコピーしました"
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = saveFolder
        panel.prompt = "ここに保存"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            saveFolder = url
            refreshHistory()
        }
    }

    func revealLastRecording() {
        if let lastSavedURL {
            NSWorkspace.shared.activateFileViewerSelecting([lastSavedURL])
        } else {
            try? FileManager.default.createDirectory(at: saveFolder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(saveFolder)
        }
    }
}

/// 録音一覧の1行（保存された文字起こしファイル1つ）
struct RecordingItem: Identifiable, Equatable {
    let url: URL
    let date: Date
    let title: String     // 例「10/13（火）09:56」
    let preview: String   // 最初の発言
    let lineCount: Int
    var aiTitle: String?  // Mac内蔵AIが付けたタイトル

    var id: URL { url }

    init?(url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        self.url = url

        // ファイル名「録音 2026-10-13 09.56.12.txt」から日時を読む。読めなければ更新日時
        let name = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "録音 ", with: "")
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        self.date = parser.date(from: name) ?? modified ?? .distantPast

        let display = DateFormatter()
        display.locale = Locale(identifier: "ja_JP")
        display.dateFormat = "M/d（E）HH:mm"
        self.title = display.string(from: date)

        let lines = text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        self.lineCount = lines.count
        self.aiTitle = TitleMaker.savedTitle(for: url)
        // 「[00:00:04] 自分：」の部分を外して、最初の発言だけ出す
        let first = lines.first ?? ""
        if let range = first.range(of: "：") {
            self.preview = String(first[range.upperBound...])
        } else {
            self.preview = first
        }
    }
}
