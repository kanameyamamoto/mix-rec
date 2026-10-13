# MixRec

Macのメニューバーに常駐する録音アプリです。**Macの内部音声（動画・会議の相手の声）と自分のマイクを同時に録音**し、録音しながら日本語で文字起こしします。

BlackHole などの仮想オーディオや「複数出力装置」は不要です。音はイヤホンやスピーカーからいつもどおり聞こえ、音量キーも普段どおり使えます。

## できること

- **内部音声＋マイクの同時録音**：1つの `.m4a` にまとめて保存。それぞれの音量バランスも調整できる
- **リアルタイム文字起こし**：「自分」（マイク）と「相手」（Macの音）を分けて、時間付きで表示。停止すると `.txt` でも保存
- **録音一覧**：過去の録音が新しい順に並び、「コピー」ボタンで文字起こし全文を1発コピー（そのままAIに貼れる）
- **AIタイトル**：Mac内蔵のAI（Apple Intelligence）が、録音ごとに内容を表す短いタイトルを自動で付ける
- メニューバーには波形のアイコン。録音中はその右に録音時間を表示

文字起こしもタイトル付けもすべてMac内で動くので、無料・ネット不要です。

## 動作環境

- macOS 26 以降（文字起こしに SpeechAnalyzer、タイトル付けに Foundation Models を使用）
  - macOS 14.2〜15 でも録音はでき、文字起こしは旧方式（SFSpeechRecognizer）になります
- Xcode は不要。コマンドラインツールだけでビルドできます（`xcode-select --install`）
- AIタイトルには Apple Intelligence をオンにしておく必要があります

## ビルドと起動

```sh
./build.sh
```

`~/Applications/MixRec.app` に入り、そのまま起動します。メニューバーの波形マークから使います。

初回の録音時に、マイク・システムオーディオ録音・音声認識の許可を求められます。内部音声が無音になる場合は、システム設定 → プライバシーとセキュリティ →「画面収録とシステムオーディオ録音」で MixRec をオンにしてください。

## 保存されるもの

保存先（初期設定は `~/Music/MixRec`）に、録音ごとに次のファイルができます。

| ファイル | 中身 |
|---|---|
| `録音 YYYY-MM-DD HH.mm.ss.m4a` | 内部音声とマイクをまとめた音声 |
| `録音 YYYY-MM-DD HH.mm.ss.txt` | 文字起こし（`[00:00:04] 自分：…` の形式） |
| `録音 YYYY-MM-DD HH.mm.ss.title` | AIが付けたタイトル |

動作の記録は `~/Library/Logs/MixRec.log` に残ります。

## しくみ

| ファイル | 役割 |
|---|---|
| `Sources/Capture.swift` | Core Audio Tap で内部音声を、マイク装置から直接マイク音声を受け取って書き出す。最後に1つの .m4a にまとめる |
| `Sources/ModernTranscriber.swift` | macOS 26 の SpeechAnalyzer による文字起こし |
| `Sources/Transcriber.swift` | 旧方式（SFSpeechRecognizer）の文字起こし。macOS 26 未満で使う |
| `Sources/TitleMaker.swift` | Foundation Models でタイトルを作る |
| `Sources/RecorderModel.swift` | 録音・文字起こし・録音一覧の状態管理 |
| `Sources/MixRecApp.swift` | メニューバーの画面 |
| `Sources/CoreAudioHelper.swift` | 音声装置の一覧や情報の取得 |
