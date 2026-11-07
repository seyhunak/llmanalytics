import Foundation

/// USD per million tokens. Values are list API prices and are used only to *estimate* spend;
/// subscription plans (Claude Max, ChatGPT Plus, Copilot) are not billed per token.
/// Users can override or extend this table with ~/Library/Application Support/LLMAnalytics/pricing.json
struct ModelPrice: Codable, Hashable, Sendable {
    var input: Double
    var output: Double
    var cacheRead: Double
    var cacheWrite: Double
}

enum Pricing {
    /// Ordered: first prefix match wins, so put more specific prefixes first.
    static let builtIn: [(String, ModelPrice)] = [
        // Anthropic (cache write = 1.25x input, the 5-minute rate)
        ("claude-fable-5", .init(input: 10, output: 50, cacheRead: 0.25, cacheWrite: 12.5)),
        ("claude-mythos", .init(input: 10, output: 50, cacheRead: 0.25, cacheWrite: 12.5)),
        ("claude-opus-5-5", .init(input: 4, output: 20, cacheRead: 0.20, cacheWrite: 5)),
        ("claude-opus-5", .init(input: 5, output: 25, cacheRead: 0.50, cacheWrite: 6.25)),
        ("claude-opus-4-8", .init(input: 5, output: 25, cacheRead: 0.50, cacheWrite: 6.25)),
        ("claude-opus-4-7", .init(input: 5, output: 25, cacheRead: 0.50, cacheWrite: 6.25)),
        ("claude-opus-4-6", .init(input: 5, output: 25, cacheRead: 0.50, cacheWrite: 6.25)),
        ("claude-opus-4-5", .init(input: 5, output: 25, cacheRead: 0.50, cacheWrite: 6.25)),
        ("claude-opus-4", .init(input: 15, output: 75, cacheRead: 1.50, cacheWrite: 18.75)),
        ("claude-sonnet-5", .init(input: 2, output: 10, cacheRead: 0.20, cacheWrite: 2.5)),
        ("claude-sonnet-4", .init(input: 3, output: 15, cacheRead: 0.30, cacheWrite: 3.75)),
        ("claude-3-7-sonnet", .init(input: 3, output: 15, cacheRead: 0.30, cacheWrite: 3.75)),
        ("claude-haiku-5", .init(input: 0.10, output: 0.50, cacheRead: 0.01, cacheWrite: 0.125)),
        ("claude-haiku-4", .init(input: 1, output: 5, cacheRead: 0.10, cacheWrite: 1.25)),
        ("claude-3-5-haiku", .init(input: 0.8, output: 4, cacheRead: 0.08, cacheWrite: 1)),
        ("opus", .init(input: 4, output: 20, cacheRead: 0.20, cacheWrite: 5)),
        ("sonnet", .init(input: 2, output: 10, cacheRead: 0.20, cacheWrite: 2.5)),
        ("haiku", .init(input: 0.10, output: 0.50, cacheRead: 0.01, cacheWrite: 0.125)),
        // OpenAI (approximate list prices; edit pricing.json to correct)
        ("gpt-5-mini", .init(input: 0.25, output: 2, cacheRead: 0.025, cacheWrite: 0)),
        ("gpt-5-nano", .init(input: 0.05, output: 0.4, cacheRead: 0.005, cacheWrite: 0)),
        ("gpt-5", .init(input: 1.25, output: 10, cacheRead: 0.125, cacheWrite: 0)),
        ("gpt-4.1-mini", .init(input: 0.4, output: 1.6, cacheRead: 0.1, cacheWrite: 0)),
        ("gpt-4.1", .init(input: 2, output: 8, cacheRead: 0.5, cacheWrite: 0)),
        ("gpt-4o-mini", .init(input: 0.15, output: 0.6, cacheRead: 0.075, cacheWrite: 0)),
        ("gpt-4o", .init(input: 2.5, output: 10, cacheRead: 1.25, cacheWrite: 0)),
        ("o4-mini", .init(input: 1.1, output: 4.4, cacheRead: 0.275, cacheWrite: 0)),
        ("o3", .init(input: 2, output: 8, cacheRead: 0.5, cacheWrite: 0)),
        ("codex", .init(input: 1.25, output: 10, cacheRead: 0.125, cacheWrite: 0)),
        // Google (approximate)
        ("gemini-2.5-pro", .init(input: 1.25, output: 10, cacheRead: 0.31, cacheWrite: 0)),
        ("gemini-2.5-flash-lite", .init(input: 0.1, output: 0.4, cacheRead: 0.025, cacheWrite: 0)),
        ("gemini-2.5-flash", .init(input: 0.3, output: 2.5, cacheRead: 0.075, cacheWrite: 0)),
        ("gemini-3", .init(input: 2, output: 12, cacheRead: 0.2, cacheWrite: 0)),
        ("gemini", .init(input: 1.25, output: 10, cacheRead: 0.31, cacheWrite: 0)),
    ]

    nonisolated(unsafe) private static var overrides: [String: ModelPrice] = loadOverrides()

    static var overridesURL: URL {
        AppPaths.supportDir.appendingPathComponent("pricing.json")
    }

    private static func loadOverrides() -> [String: ModelPrice] {
        guard let data = try? Data(contentsOf: overridesURL),
              let dict = try? JSONDecoder().decode([String: ModelPrice].self, from: data) else { return [:] }
        return dict
    }

    static func reloadOverrides() { overrides = loadOverrides() }

    static func price(for rawModel: String) -> ModelPrice? {
        let model = normalize(rawModel)
        if let o = overrides.first(where: { model.hasPrefix($0.key.lowercased()) }) { return o.value }
        return builtIn.first { model.hasPrefix($0.0) }?.1
            ?? builtIn.first { model.contains($0.0) }?.1
    }

    static func normalize(_ raw: String) -> String {
        var m = raw.lowercased().components(separatedBy: "/").last ?? raw.lowercased()
        for prefix in ["us.anthropic.", "eu.anthropic.", "anthropic."] where m.hasPrefix(prefix) {
            m.removeFirst(prefix.count)
        }
        // Claude ids sometimes arrive dotted ("claude-haiku-4.5"); our table uses dashes.
        if m.contains("claude") { m = m.replacingOccurrences(of: ".", with: "-") }
        return m
    }

    static func cost(model: String, tokens: TokenUsage) -> Double {
        guard let p = price(for: model) else { return 0 }
        let m = 1_000_000.0
        return Double(tokens.input) / m * p.input
            + Double(tokens.output) / m * p.output
            + Double(tokens.cacheRead) / m * p.cacheRead
            + Double(tokens.cacheWrite) / m * p.cacheWrite
    }
}

enum AppPaths {
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    static var supportDir: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LLMAnalytics", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static func expand(_ relative: String) -> String { home.appendingPathComponent(relative).path }
}
