import Foundation

/// What Kairos knows about a cloud model for resume work: its price, whether a free account gets
/// it, and how it did in Kairos's own eval. Prices are Ollama Cloud's per million tokens, from
/// ollama.com/pricing on 2026-10-23; advice is from building the five Yes jobs with each model that
/// day, or from a quick test where it says so. Settings shows this beside the live model list.
public struct ModelGuide: Sendable, Equatable {
    public enum Advice: String, Sendable, CaseIterable {
        /// Writes resumes well: the first pick for its price.
        case recommended
        /// Works, with more failed checks or fewer bullets: a fallback, not a first pick.
        case fallback
        /// Not tried on full builds yet: cheap enough to be worth a try once you have credits.
        case untried
        /// Not worth it for resumes: too costly, too small, made for code, or not a chat model.
        case skip
    }

    public let model: String
    /// Dollars per million tokens.
    public let inputPrice: Double
    public let outputPrice: Double
    /// On Ollama's Free plan; the rest answer 402 until you add credits.
    public let free: Bool
    public let advice: Advice
    public let note: String

    /// A resume build's tokens, roughly: about 20,000 in and 6,000 out across its calls (the five
    /// Yes jobs, 2026-10-23, letter included).
    public static let tokensPerBuild = (input: 20_000.0, output: 6_000.0)

    /// What one build costs on it, in dollars.
    public var costPerBuild: Double {
        (Self.tokensPerBuild.input * inputPrice + Self.tokensPerBuild.output * outputPrice) / 1_000_000
    }

    /// "free", "about 1¢ a resume", "about 15¢ a resume".
    public var costLine: String {
        if free { return "free on Ollama's Free plan" }
        let cents = max(1, Int((costPerBuild * 100).rounded()))
        return "about \(cents)¢ a resume, needs credits"
    }

    /// What Ollama's Free plan includes each month, per account. Every model's calls spend it, the
    /// free ones too (each of four keys' balances, 2026-10-23).
    public static let freePlanCredits = 2.50

    /// "about 480 resumes a month on the Free plan's $2.50": how far the plan's credits go on a
    /// model it has, rounded down to tens. Nil for the others.
    public var freePlanLine: String? {
        guard free, costPerBuild > 0 else { return nil }
        let resumes = Int(Self.freePlanCredits / costPerBuild) / 10 * 10
        return "about \(resumes) resumes a month on the Free plan's $2.50"
    }

    /// The guide's entry for a model id as a provider lists it ("gemma4:31b", "deepseek-v4.1-flash:1017").
    public static func entry(for model: String) -> ModelGuide? {
        let name = model.lowercased().replacing("-cloud", with: "").replacing(":cloud", with: "")
        return ollamaCloud.first { name == $0.model } ?? ollamaCloud.first { name.hasPrefix($0.model + ":") }
    }

    /// What it costs for these tokens, in dollars.
    public func cost(input: Int, output: Int) -> Double {
        (Double(input) * inputPrice + Double(output) * outputPrice) / 1_000_000
    }

    public static let ollamaCloud: [ModelGuide] = [
        ModelGuide(
            model: "gemma4:31b", inputPrice: 0.14, outputPrice: 0.40, free: true, advice: .recommended,
            note: "The best free writer: every call passed its checks, 12 to 23 bullets, and all five letters written."),
        ModelGuide(
            model: "gpt-oss:120b", inputPrice: 0.15, outputPrice: 0.60, free: true, advice: .fallback,
            note: "Free and fast, but 4 of 30 calls failed their checks and 2 of 5 letters were left out."),
        ModelGuide(
            model: "nemotron-3-super", inputPrice: 0.015, outputPrice: 0.60, free: true, advice: .untried,
            note: "Free; answered well in a quick test, not yet on full builds."),
        ModelGuide(
            model: "deepseek-v4.1-flash", inputPrice: 0.30, outputPrice: 1.20, free: false, advice: .untried,
            note: "The value pick with credits; half price outside 12:00 to 18:00 UTC on weekdays."),
        ModelGuide(
            model: "glm-5.3-flash", inputPrice: 0.15, outputPrice: 0.50, free: false, advice: .untried,
            note: "Cheap with credits; not yet tried."),
        ModelGuide(
            model: "minimax-m3.1-flash", inputPrice: 0.15, outputPrice: 0.60, free: false, advice: .untried,
            note: "Cheap with credits; not yet tried."),
        ModelGuide(
            model: "gpt-oss:20b", inputPrice: 0.07, outputPrice: 0.30, free: true, advice: .skip,
            note: "Too small: it spent its whole reply thinking and sent nothing."),
        ModelGuide(
            model: "nemotron-3-nano", inputPrice: 0.06, outputPrice: 0.24, free: true, advice: .skip,
            note: "Too small: it spent its whole reply thinking and sent nothing."),
        ModelGuide(
            model: "kimi-k3", inputPrice: 3.00, outputPrice: 15.00, free: false, advice: .skip,
            note: "About 15¢ a resume: far more than resume bullets need."),
        ModelGuide(
            model: "kimi-k2.7-code", inputPrice: 0.95, outputPrice: 4.00, free: false, advice: .skip,
            note: "Made for code, not writing."),
        ModelGuide(
            model: "kimi-k2.6", inputPrice: 0.95, outputPrice: 4.00, free: false, advice: .skip,
            note: "Costs several times the flash models for no gain in bullets."),
        ModelGuide(
            model: "glm-5.3", inputPrice: 1.40, outputPrice: 4.40, free: false, advice: .skip,
            note: "Costly; glm-5.3-flash does the same job for a tenth."),
        ModelGuide(
            model: "glm-5.2", inputPrice: 1.40, outputPrice: 4.40, free: false, advice: .skip,
            note: "Costly and older than glm-5.3."),
        ModelGuide(
            model: "deepseek-v4-pro", inputPrice: 1.32, outputPrice: 3.96, free: false, advice: .skip,
            note: "Costly; deepseek-v4.1-flash is the better buy."),
        ModelGuide(
            model: "mistral-large-4", inputPrice: 0.68, outputPrice: 2.09, free: false, advice: .skip,
            note: "Still rolling out (403 on a free account), and pricier than the flash models."),
        ModelGuide(
            model: "mistral-large-3", inputPrice: 0.50, outputPrice: 1.50, free: false, advice: .skip,
            note: "Older and pricier than the flash models."),
        ModelGuide(
            model: "minimax-m3", inputPrice: 0.60, outputPrice: 2.40, free: false, advice: .skip,
            note: "minimax-m3.1-flash is newer and a quarter of the price."),
        ModelGuide(
            model: "minimax-m2.7", inputPrice: 0.30, outputPrice: 1.20, free: false, advice: .skip,
            note: "Older than minimax-m3.1-flash."),
        ModelGuide(
            model: "nemotron-3-ultra", inputPrice: 0.10, outputPrice: 3.00, free: false, advice: .skip,
            note: "Output costs five times nemotron-3-super's."),
        ModelGuide(
            model: "muse-spark-open", inputPrice: 1.25, outputPrice: 4.25, free: false, advice: .skip,
            note: "Costly and untested for writing."),
        ModelGuide(
            model: "clef", inputPrice: 0.24, outputPrice: 0, free: false, advice: .skip,
            note: "Not a chat writer."),
        ModelGuide(
            model: "beam", inputPrice: 0, outputPrice: 0, free: false, advice: .skip, note: "Not a chat writer."),
    ]
}
