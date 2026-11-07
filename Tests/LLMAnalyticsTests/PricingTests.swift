import Testing
@testable import LLMAnalytics

@Suite struct PricingTests {
    @Test func oneHourCacheWritesBillAtTwiceInput() {
        // Opus 5.5: input $4/M → 1h cache write $8/M, 5m cache write $5/M.
        let oneHour = Pricing.cost(model: "claude-opus-5-5", tokens: TokenUsage(cacheWrite1h: 1_000_000))
        let fiveMin = Pricing.cost(model: "claude-opus-5-5", tokens: TokenUsage(cacheWrite: 1_000_000))
        #expect(abs(oneHour - 8) < 1e-9)
        #expect(abs(fiveMin - 5) < 1e-9)
    }

    @Test func fullRequestCost() {
        let t = TokenUsage(input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000)
        #expect(abs(Pricing.cost(model: "claude-opus-5-5", tokens: t) - (4 + 20 + 0.2)) < 1e-9)
    }

    @Test func haikuLongContextTier() {
        // ≤100K prompt tokens: $0.10/$0.50. Above: $0.50/$2.50.
        let short = Pricing.cost(model: "claude-haiku-5-5", tokens: TokenUsage(input: 100_000, output: 1_000))
        #expect(abs(short - (0.1 * 0.1 + 0.001 * 0.5)) < 1e-9)
        let long = Pricing.cost(model: "claude-haiku-5-5", tokens: TokenUsage(input: 200_000, output: 1_000))
        #expect(abs(long - (0.2 * 0.5 + 0.001 * 2.5)) < 1e-9)
        // Cache reads count toward the threshold and scale with the tier.
        let cached = Pricing.cost(model: "claude-haiku-5-5", tokens: TokenUsage(input: 10_000, cacheRead: 150_000))
        #expect(abs(cached - (0.01 * 0.5 + 0.15 * 0.05)) < 1e-9)
    }

    @Test func prefixOrderPicksMostSpecificModel() {
        #expect(Pricing.price(for: "claude-opus-5-5")?.input == 4)
        #expect(Pricing.price(for: "claude-opus-5")?.input == 5)
        #expect(Pricing.price(for: "claude-opus-4-1")?.input == 15)
        #expect(Pricing.price(for: "gpt-5-mini")?.input == 0.25)
        #expect(Pricing.price(for: "gpt-5.6-terra")?.input == 1.25)
    }

    @Test func normalizesProviderPrefixesAndDots() {
        #expect(Pricing.normalize("anthropic/claude-haiku-4.5") == "claude-haiku-4-5")
        #expect(Pricing.normalize("us.anthropic.claude-sonnet-4-6") == "claude-sonnet-4-6")
        #expect(Pricing.normalize("copilot/gpt-5-mini") == "gpt-5-mini")
    }

    @Test func unknownModelsCostNothing() {
        #expect(Pricing.cost(model: "muse-spark-free", tokens: TokenUsage(input: 1_000_000)) == 0)
    }
}
