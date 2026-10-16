import Foundation

/// How a bot talks. The same words tell you what it's like and tell the bot how to be.
struct Personality: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var description: String
    /// An SF Symbol for its tile.
    var symbol: String

    var isCustom: Bool { !id.hasPrefix("preset.") }

    /// What the bot is told.
    var instruction: String {
        "Your personality: \(name). \(description) Let it show in how you write, not in what you do or how carefully you work."
    }
}

/// The personalities to pick from: Kuvo Code's own, then ones you made, kept in
/// `personalities.json`.
@Observable
final class Personalities {
    static let shared = Personalities()

    static let presets: [Personality] = [
        Personality(id: "preset.straight", name: "Straight Shooter", description: "Direct and brief. Leads with the answer, skips the pleasantries, and says plainly when something's wrong.", symbol: "bolt"),
        Personality(id: "preset.cheerful", name: "Cheerleader", description: "Warm and upbeat. Celebrates progress and keeps spirits up, while staying honest about problems.", symbol: "sparkles"),
        Personality(id: "preset.mentor", name: "Mentor", description: "Patient and clear. Explains the why behind things, step by step, and points out what's worth learning.", symbol: "graduationcap"),
        Personality(id: "preset.skeptic", name: "Skeptic", description: "Questions assumptions and looks for what could go wrong. Wants evidence before agreeing, and says so when an idea won't hold.", symbol: "magnifyingglass"),
        Personality(id: "preset.pragmatist", name: "Pragmatist", description: "Gets things shipped. Prefers the simplest thing that works, names the tradeoffs, and leaves polish for later.", symbol: "hammer"),
        Personality(id: "preset.perfectionist", name: "Perfectionist", description: "Careful and thorough. Checks the edge cases, double-checks the facts, and won't call something done until it is.", symbol: "checkmark.seal"),
        Personality(id: "preset.visionary", name: "Visionary", description: "Thinks big. Connects the work to where it's going, proposes bold ideas, and names the first small step.", symbol: "lightbulb"),
        Personality(id: "preset.dry", name: "Dry Wit", description: "Calm, with a dry sense of humor. Understated and to the point, and never silly about serious things.", symbol: "theatermasks"),
    ]

    private(set) var custom: [Personality] = []
    private static var file: URL { AppInfo.supportDirectory.appending(path: "personalities.json") }

    private init() {
        custom = JSONFile.read([Personality].self, from: Self.file) ?? []
    }

    var all: [Personality] { Self.presets + custom }

    func personality(_ id: String?) -> Personality? {
        id.flatMap { id in all.first { $0.id == id } }
    }

    func add(name: String, description: String) -> Personality {
        let personality = Personality(id: "custom." + UUID().uuidString.lowercased(), name: name, description: description, symbol: "person.crop.circle")
        custom.append(personality)
        save()
        return personality
    }

    func update(_ personality: Personality) {
        guard let index = custom.firstIndex(where: { $0.id == personality.id }) else { return }
        custom[index] = personality
        save()
    }

    func delete(_ personality: Personality) {
        custom.removeAll { $0.id == personality.id }
        save()
    }

    private func save() {
        JSONFile.write(custom, to: Self.file, readable: true)
    }
}
