import Foundation

class AICleanupService {
    private let systemPrompt = """
    Help me clean up this voice dictation transcript. The text I send you is raw speech-to-text output \
    that I dictated for use in another app, email, or document.

    What to do:
    - Remove filler sounds: uh, um, er, ah, hmm
    - Remove filler words and phrases: "like", "you know", "I mean", "basically", "actually", "literally", \
    "stuff like that", "and stuff", "or whatever", "kind of", "sort of", "right", "so yeah"
    - Keep these words ONLY when they carry real meaning (e.g., "I like this" or "sort the list")
    - Fix grammar mistakes and punctuation
    - Fix capitalization
    - Keep my exact wording as much as possible
    - Preserve technical terms, proper nouns, and jargon
    - Do not rewrite or paraphrase — only minimal corrections
    - Give me back just the cleaned text, nothing else
    """

    /// Patterns that indicate the LLM refused to process the text instead of cleaning it
    private let refusalPatterns = [
        "i'm sorry",
        "i can't assist",
        "i cannot assist",
        "i'm unable",
        "i can't help",
        "i cannot help",
        "i'm not able",
        "as an ai",
        "i cannot fulfill",
        "i can't fulfill",
        "i must decline",
        "against my guidelines",
        "i apologize, but",
        "not appropriate",
        "i'm afraid i can't"
    ]

    private func isRefusal(_ response: String) -> Bool {
        let lower = response.lowercased()
        return refusalPatterns.contains { lower.contains($0) }
    }

    func cleanup(rawText: String) async -> String {
        let replaced = SettingsManager.shared.applyReplacements(rawText)

        // Skip cleanup for very short text — not worth the round trip
        guard replaced.count >= 30 else {
            log("Short transcription (\(replaced.count) chars), skipping cleanup")
            return replaced
        }

        // Walk the provider chain (local Ollama first, cloud fallbacks after). The first
        // provider that returns a non-refusal response wins. If we ever fall past the
        // first provider, that's logged so degradation is visible, not silent.
        let providers = Config.cleanupProviders
        for (index, provider) in providers.enumerated() {
            do {
                let cleaned = try await callCleanupAPI(provider: provider, rawText: replaced)
                if isRefusal(cleaned) {
                    log("Cleanup provider '\(provider.name)' returned a refusal, trying next")
                    continue
                }
                if index > 0 {
                    log("Cleanup used FALLBACK provider '\(provider.name)' (local cleanup unavailable)")
                }
                return cleaned
            } catch {
                log("Cleanup provider '\(provider.name)' failed: \(error.localizedDescription)")
                continue
            }
        }

        log("All cleanup providers failed; using raw transcript")
        return replaced
    }

    /// URLSession with a hard cap on total request time
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15   // max idle time between packets
        config.timeoutIntervalForResource = 45  // max total time for entire request
        return URLSession(configuration: config)
    }()

    private func callCleanupAPI(provider: Config.CleanupProvider, rawText: String) async throws -> String {
        guard let url = URL(string: "\(provider.baseURL)/chat/completions") else {
            throw CleanupError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(provider.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "model": provider.model,
            "temperature": 0.1,
            "max_tokens": 2048,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": rawText]
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8).map { String($0.prefix(200)) } ?? "Unknown error"
            throw CleanupError.apiError(errorBody)
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let choices = json?["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw CleanupError.parseError
        }

        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    enum CleanupError: LocalizedError {
        case invalidURL
        case apiError(String)
        case parseError

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid cleanup API URL"
            case .apiError(let msg): return "Cleanup API error: \(msg)"
            case .parseError: return "Failed to parse cleanup response"
            }
        }
    }
}
