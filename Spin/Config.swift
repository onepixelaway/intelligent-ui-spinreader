import Foundation

enum Config {
    static var openAIKey: String {
        if let envKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"],
           !envKey.isEmpty {
            return envKey
        }
        if let plistKey = Bundle.main.object(forInfoDictionaryKey: "OpenAIAPIKey") as? String,
           !plistKey.isEmpty,
           !plistKey.hasPrefix("$(") {
            return plistKey
        }
        return ""
    }
}
