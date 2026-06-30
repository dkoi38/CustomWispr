import Foundation

enum Config {
    // Local whisper.cpp server
    static let whisperBaseURL = "http://localhost:8080"

    /// One cleanup backend (OpenAI-compatible chat/completions endpoint).
    struct CleanupProvider {
        let name: String
        let baseURL: String
        let model: String
        let apiKey: String
    }

    /// Ordered cleanup chain, tried top to bottom.
    ///
    /// PRIMARY is LOCAL Ollama: no API key, no rate limit, no key rotation — so it
    /// can't silently degrade. That silent degradation (a dead/rate-limited cloud key
    /// quietly forcing the slow fallback path) was the recurring cause of "dictation
    /// got slow." Cloud providers below are OPTIONAL fallbacks, used only if the local
    /// model is unreachable, and only if their key is present in ~/.custom-wispr.env.
    static var cleanupProviders: [CleanupProvider] {
        var chain: [CleanupProvider] = [
            CleanupProvider(
                name: "ollama-local",
                baseURL: "http://localhost:11434/v1",
                // qwen2.5:3b follows the "clean the words, NEVER answer/translate/summarize the
                // dictation" instruction far more reliably than llama3.2:3b at the same warm
                // latency. llama3.2:3b would execute questions/commands (e.g. dictating "what is
                // 2+2" typed "4", "translate..." typed the translation). Verified head-to-head.
                model: "qwen2.5:3b",
                apiKey: "ollama"   // Ollama ignores this; keeps the Bearer header well-formed
            )
        ]
        if let gemini = readKeyFromEnvFile("GEMINI_API_KEY") {
            chain.append(CleanupProvider(
                name: "gemini",
                baseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
                model: "gemini-2.5-flash-lite",
                apiKey: gemini
            ))
        }
        if let openai = readKeyFromEnvFile("OPENAI_API_KEY") {
            chain.append(CleanupProvider(
                name: "openai",
                baseURL: "https://api.openai.com/v1",
                model: "gpt-4.1-mini",
                apiKey: openai
            ))
        }
        return chain
    }

    // Local cleanup needs no key and is always available, so the app is always "ready".
    static var hasAPIKey: Bool { true }

    static func saveAPIKey(_ key: String) -> Bool {
        let path = NSString("~/.custom-wispr.env").expandingTildeInPath
        let content = "CLEANUP_API_KEY=\(key)\n"
        do {
            try content.write(toFile: path, atomically: true, encoding: .utf8)
            let fm = FileManager.default
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            return true
        } catch {
            fputs("[ERROR] Failed to save API key: \(error.localizedDescription)\n", stderr)
            return false
        }
    }

    private static func readKeyFromEnvFile(_ keyName: String) -> String? {
        let path = NSString("~/.custom-wispr.env").expandingTildeInPath
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }

        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: path),
           let posix = attrs[.posixPermissions] as? Int {
            if posix & 0o077 != 0 {
                fputs("[WARNING] ~/.custom-wispr.env is readable by other users. Run: chmod 600 ~/.custom-wispr.env\n", stderr)
            }
        }

        let prefix = "\(keyName)="
        for line in contents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(prefix) {
                let value = String(trimmed.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if !value.isEmpty {
                    return value
                }
            }
        }
        return nil
    }
}
