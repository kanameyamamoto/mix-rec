import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Mac内蔵のAI（Apple Intelligence）で、文字起こしに短いタイトルを付ける。
/// Mac内で動くので無料・ネット不要。使えないMacでは何もしない。
enum TitleMaker {
    /// タイトルの保存先（文字起こしと同じ名前で、拡張子だけ .title）
    static func titleURL(for transcriptURL: URL) -> URL {
        transcriptURL.deletingPathExtension().appendingPathExtension("title")
    }

    static func savedTitle(for transcriptURL: URL) -> String? {
        let text = try? String(contentsOf: titleURL(for: transcriptURL), encoding: .utf8)
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 内蔵AIが使えるか（使えない理由はログに残す）
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return true
            case .unavailable(let reason):
                Log.write("内蔵AIが使えません: \(reason)")
                return false
            }
        }
        #endif
        return false
    }

    /// 文字起こしからタイトルを作って保存する。作れなければ nil
    static func makeTitle(for transcriptURL: URL) async -> String? {
        guard let transcript = try? String(contentsOf: transcriptURL, encoding: .utf8) else { return nil }

        // 「[00:00:04] 」の時間は外して、AIに渡す量を減らす
        let body = transcript
            .split(separator: "\n")
            .map { line -> String in
                var s = String(line)
                if s.hasPrefix("["), let end = s.firstIndex(of: "]") {
                    s = String(s[s.index(after: end)...]).trimmingCharacters(in: .whitespaces)
                }
                return s
            }
            .joined(separator: "\n")
        guard body.count >= 15 else { return nil }   // 短すぎるものには付けない

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let session = LanguageModelSession(instructions: """
                あなたは、会話・会議・講義の録音の文字起こしに、短い日本語のタイトルを付けるアシスタントです。
                内容がひと目で分かる15文字以内のタイトルを1つだけ出力してください。
                かぎかっこ、記号、説明文、句点は付けないでください。
                """)
            do {
                let excerpt = String(body.prefix(1500))
                let response = try await session.respond(to: "次の文字起こしにタイトルを付けてください。\n\n\(excerpt)")
                let title = clean(response.content)
                guard !title.isEmpty else { return nil }
                try? title.write(to: titleURL(for: transcriptURL), atomically: true, encoding: .utf8)
                Log.write("タイトルを付けました: \(title)")
                return title
            } catch {
                Log.write("タイトルを付けられませんでした: \(error.localizedDescription)")
                return nil
            }
        }
        #endif
        return nil
    }

    private static func clean(_ raw: String) -> String {
        var s = raw.split(separator: "\n").first.map(String.init) ?? ""
        for prefix in ["タイトル：", "タイトル:", "Title:"] where s.hasPrefix(prefix) {
            s.removeFirst(prefix.count)
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "「」『』\"'“”。.#*"))
        return String(s.prefix(24))
    }
}
