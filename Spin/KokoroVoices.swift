import Foundation

enum KokoroVoiceCatalog {
    struct Voice: Identifiable, Hashable {
        let name: String
        var id: String { name }

        var displayName: String {
            let base = String(name.dropFirst(3))
            return base.prefix(1).uppercased() + base.dropFirst()
        }

        var accent: String {
            switch name.first {
            case "a": return "American"
            case "b": return "British"
            default: return "Other"
            }
        }

        var gender: String {
            guard name.count >= 2 else { return "" }
            return name[name.index(name.startIndex, offsetBy: 1)] == "f" ? "Female" : "Male"
        }

        var qualityLabel: String { "\(accent) \(gender)" }
    }

    static let all: [Voice] = [
        // American Female
        Voice(name: "af_heart"),
        Voice(name: "af_bella"),
        Voice(name: "af_nicole"),
        Voice(name: "af_aoede"),
        Voice(name: "af_kore"),
        Voice(name: "af_sarah"),
        Voice(name: "af_nova"),
        Voice(name: "af_sky"),
        Voice(name: "af_alloy"),
        Voice(name: "af_jessica"),
        Voice(name: "af_river"),
        // American Male
        Voice(name: "am_michael"),
        Voice(name: "am_fenrir"),
        Voice(name: "am_puck"),
        Voice(name: "am_echo"),
        Voice(name: "am_eric"),
        Voice(name: "am_liam"),
        Voice(name: "am_onyx"),
        Voice(name: "am_santa"),
        Voice(name: "am_adam"),
        // British Female
        Voice(name: "bf_emma"),
        Voice(name: "bf_isabella"),
        Voice(name: "bf_alice"),
        Voice(name: "bf_lily"),
        // British Male
        Voice(name: "bm_george"),
        Voice(name: "bm_fable"),
        Voice(name: "bm_lewis"),
        Voice(name: "bm_daniel"),
    ]

    static let defaultVoice = "af_heart"

    static func voice(named name: String) -> Voice? {
        all.first { $0.name == name }
    }

    static var grouped: [(String, [Voice])] {
        let americanFemale = all.filter { $0.name.hasPrefix("af_") }
        let americanMale = all.filter { $0.name.hasPrefix("am_") }
        let britishFemale = all.filter { $0.name.hasPrefix("bf_") }
        let britishMale = all.filter { $0.name.hasPrefix("bm_") }
        return [
            ("American Female", americanFemale),
            ("American Male", americanMale),
            ("British Female", britishFemale),
            ("British Male", britishMale),
        ]
    }
}
