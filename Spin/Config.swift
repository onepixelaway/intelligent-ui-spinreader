import Foundation

enum Config {
    static var openAIKey: String {
        if let envKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"],
           !envKey.isEmpty {
            return envKey
        }
        return ""
    }
}
