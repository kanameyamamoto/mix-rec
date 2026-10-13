import SwiftUI

@main
struct MixRecApp: App {
    @StateObject private var model = RecorderModel()

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

struct ContentView: View {
    @EnvironmentObject var model: RecorderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("MixRec").font(.headline)
                Spacer()
                if model.isRecording {
                    Text(model.elapsedText)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.red)
                }
            }

            Button(action: model.toggle) {
                HStack {
                    Image(systemName: model.isRecording ? "stop.fill" : "record.circle")
                    Text(model.isRecording ? "停止して保存" : (model.isStarting ? "準備中…" : "録音開始"))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.isRecording ? .red : .accentColor)
            .disabled(model.isSaving || model.isStarting)

            Divider()

            // 内部音声
            VStack(alignment: .leading, spacing: 6) {
                Toggle("内部音声（Macの音）", isOn: $model.recordSystem)
                HStack {
                    Image(systemName: "speaker.wave.2").foregroundStyle(.secondary)
                    Slider(value: $model.systemVolume, in: 0...1)
                }
                .disabled(!model.recordSystem)
            }
            .disabled(model.isRecording)

            // マイク
            VStack(alignment: .leading, spacing: 6) {
                Toggle("マイク（自分の声）", isOn: $model.recordMic)
                Picker("マイク", selection: $model.selectedMicUID) {
                    ForEach(model.micDevices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                .labelsHidden()
                .disabled(!model.recordMic)
                HStack {
                    Image(systemName: "mic").foregroundStyle(.secondary)
                    Slider(value: $model.micVolume, in: 0...1)
                }
                .disabled(!model.recordMic)
            }
            .disabled(model.isRecording)

            Toggle("文字起こし（録音中に表示）", isOn: $model.transcribe)
                .disabled(model.isRecording)

            // 録音を始めたときに画面の大きさが変わらないよう、文字起こしONなら最初から出しておく
            if model.transcribe || !model.transcript.isEmpty {
                TranscriptView()
            }

            Divider()

            HistoryView()

            Divider()

            FooterView()
        }
        .padding(16)
        .frame(width: 340)
        .onAppear { model.refreshMics() }
    }
}

struct TranscriptView: View {
    @EnvironmentObject var model: RecorderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("文字起こし").font(.subheadline.bold())
                Spacer()
                if !model.transcript.isEmpty {
                    Button("コピー") { model.copyTranscript() }
                        .controlSize(.small)
                }
            }

            TranscriptScroll()
        }
    }
}

/// 文字起こしの表示欄。一番下を見ているときだけ新しい文字についていき、
/// 上にさかのぼって読んでいるときは勝手に動かさない。
struct TranscriptScroll: View {
    @EnvironmentObject var model: RecorderModel
    @State private var followLatest = true

    var body: some View {
        let rows = model.displayRows
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(rows) { r in
                        TranscriptRow(row: r)
                    }
                    if model.isRecording && rows.isEmpty {
                        Text("話し始めると、ここに文字が出ます")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 180)
            .padding(8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .defaultScrollAnchor(.bottom)
            .modifier(TrackBottom(isAtBottom: $followLatest))
            .onChange(of: rows) { _, _ in
                guard followLatest else { return }
                // アニメーションなしで、一番下に揃え直す
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .overlay(alignment: .bottomTrailing) {
                if !followLatest {
                    Button {
                        followLatest = true
                        proxy.scrollTo("bottom", anchor: .bottom)
                    } label: {
                        Label("最新へ", systemImage: "arrow.down")
                            .font(.caption)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(6)
                }
            }
        }
    }
}

struct TranscriptRow: View {
    let row: RecorderModel.DisplayRow

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(row.speaker)
                    .font(.caption2.bold())
                    .foregroundStyle(row.speaker == RecorderModel.micSpeaker ? Color.accentColor : Color.orange)
                // 話している途中も時間の欄を出しておき、確定しても高さが変わらないようにする
                Text(RecorderModel.timeLabel(row.time))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .opacity(row.live ? 0.5 : 1)
            }
            Text(row.text)
                .font(.callout)
                .foregroundStyle(row.live ? .secondary : .primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 一番下付近を見ているかどうかを調べる（macOS 15 以降）
struct TrackBottom: ViewModifier {
    @Binding var isAtBottom: Bool

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.onScrollGeometryChange(for: Bool.self) { geo in
                geo.contentOffset.y + geo.containerSize.height >= geo.contentSize.height - 24
            } action: { _, atBottom in
                if atBottom != isAtBottom { isAtBottom = atBottom }
            }
        } else {
            content
        }
    }
}

/// メニューバーのアイコン。録音中は「波形＋時間」を毎回同じ幅の画像として描く。
/// （文字のままだと数字ごとに幅が変わり、アイコンの真下に出る画面が毎秒左右に動いてしまうため）
struct MenuBarLabel: View {
    @ObservedObject var model: RecorderModel

    var body: some View {
        if model.isRecording {
            Image(nsImage: Self.render(time: model.elapsedText))
        } else {
            // 待機中は波形（丸で囲まない）
            Image(systemName: "waveform")
        }
    }

    @MainActor
    static func render(time: String) -> NSImage {
        let content = HStack(spacing: 4) {
            // 録音中も同じ波形を左に置き、右に時間。波形は動かさず、時間だけ進む
            Image(systemName: "waveform")
                .font(.system(size: 13, weight: .medium))
            Text(time)
                .font(.system(size: 13, weight: .medium).monospacedDigit())
        }
        .frame(width: time.count > 5 ? 86 : 68, height: 18, alignment: .leading)
        .foregroundStyle(.black)

        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage()
        image.isTemplate = true   // メニューバーの明るさに合わせて色が変わる
        return image
    }
}

/// 過去の録音一覧。各行の「コピー」で、その回の文字起こし全文をコピーできる
struct HistoryView: View {
    @EnvironmentObject var model: RecorderModel
    @AppStorage("historyExpanded") private var expanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if model.history.isEmpty {
                Text("文字起こしの付いた録音がまだありません")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(model.history) { item in
                            HistoryRow(item: item)
                        }
                    }
                }
                .frame(height: min(CGFloat(model.history.count) * 44, 176))
                .padding(.top, 4)
            }
        } label: {
            HStack {
                Text("録音一覧").font(.subheadline.bold())
                Text("\(model.history.count)件")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { model.refreshHistory() }
    }
}

struct HistoryRow: View {
    @EnvironmentObject var model: RecorderModel
    let item: RecordingItem
    @State private var hovering = false

    var body: some View {
        let copied = model.copiedItemID == item.id
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                // 上に日時、下にAIタイトル（まだ無ければ「作成中…」、作れなかったら最初の発言）
                Text(item.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Group {
                    if let ai = item.aiTitle {
                        Text(ai)
                            .foregroundStyle(.primary)
                    } else if model.titlingIDs.contains(item.id) {
                        Text("タイトル作成中…")
                            .foregroundStyle(.tertiary)
                    } else {
                        Text(item.preview.isEmpty ? "（文字なし）" : item.preview)
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption.bold())
                .lineLimit(2)   // 長いタイトルは2行まで折り返す
                .fixedSize(horizontal: false, vertical: true)
                .help(item.aiTitle ?? item.preview)   // カーソルを合わせると全文が見える
            }
            Spacer(minLength: 4)
            if hovering {
                Button {
                    model.revealRecording(item)
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Finderで表示")
            }

            Button {
                model.copyRecording(item)
            } label: {
                Label(copied ? "コピー済み" : "コピー",
                      systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption)
            }
            .controlSize(.small)
            .fixedSize()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(hovering ? Color.primary.opacity(0.06) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .onHover { hovering = $0 }
    }
}

/// 画面の一番下。状態の1行と、保存先・メニューを1行にまとめる
struct FooterView: View {
    @EnvironmentObject var model: RecorderModel

    private var statusIcon: (name: String, color: Color) {
        if model.isRecording { return ("record.circle.fill", .red) }
        if model.isSaving || model.isStarting { return ("hourglass", .secondary) }
        if model.status.contains("失敗") || model.status.contains("できません") || model.status.contains("許可されていません") {
            return ("exclamationmark.triangle.fill", .orange)
        }
        if model.status.hasPrefix("保存しました") || model.status.contains("コピーしました") {
            return ("checkmark.circle.fill", .green)
        }
        return ("circle.fill", .green)
    }

    var body: some View {
        let busy = model.isRecording || model.isSaving || model.isStarting
        VStack(alignment: .leading, spacing: 8) {
            // 状態（1行。長いときはカーソルを合わせると全文）
            HStack(spacing: 6) {
                Image(systemName: statusIcon.name)
                    .font(.system(size: statusIcon.name == "circle.fill" ? 6 : 10))
                    .foregroundStyle(statusIcon.color)
                    .frame(width: 12)
                Text(model.status)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(model.status)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            // 保存先（押すとFinderで開く）とメニュー
            HStack(spacing: 6) {
                Button {
                    model.revealLastRecording()
                } label: {
                    Label(model.saveFolder.lastPathComponent, systemImage: "folder")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.borderless)
                .help("保存先をFinderで開く：\(model.saveFolder.path)")

                Spacer()

                Menu {
                    Button("保存先を変更…") { model.chooseFolder() }
                        .disabled(busy)
                    Button("保存先を開く") { model.revealLastRecording() }
                    Divider()
                    Button("MixRecを終了") { NSApp.terminate(nil) }
                        .disabled(busy)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("設定と終了")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
