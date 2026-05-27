import Foundation

enum Config {
    // Local whisper.cpp server
    static let whisperBaseURL = "http://localhost:8080"

    // Primary: Gemini 2.5 Flash-Lite via OpenAI-compatible endpoint (free tier)
    // 2.5-flash-lite benchmarks ~25% faster than 2.0-flash for short cleanup prompts
    // (5-run median: 580ms vs 793ms, May 27 2026).
    static let cleanupBaseURL = "https://generativelanguage.googleapis.com/v1beta/openai"
    static let cleanupModel = "gemini-2.5-flash-lite"

    // Fallback: OpenAI gpt-4.1-mini (paid, used when Gemini rate-limited or fails)
    static let fallbackBaseURL = "https://api.openai.com/v1"
    static let fallbackModel = "gpt-4.1-mini"

    static var cleanupAPIKey: String {
        if let key = readKeyFromEnvFile("GEMINI_API_KEY") { return key }
        if let key = readKeyFromEnvFile("CLEANUP_API_KEY") { return key }
        if let key = ProcessInfo.processInfo.environment["GEMINI_API_KEY"], !key.isEmpty { return key }
        return "not-needed"
    }

    static var fallbackAPIKey: String {
        if let key = readKeyFromEnvFile("OPENAI_API_KEY") { return key }
        if let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !key.isEmpty { return key }
        return ""
    }

    static var hasFallback: Bool { !fallbackAPIKey.isEmpty }

    // No API key required for local whisper — always ready
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
