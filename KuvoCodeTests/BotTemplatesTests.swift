import Foundation
import Testing
@testable import KuvoCode

/// New Bot's templates: a bot started from one gets its name and look, and its first message
/// typed in for you, saying its job once, then the whole of what it's to do, then to start; a
/// personality a template names is one of the presets, so it comes along. Each template is its own.
@MainActor
@Suite struct BotTemplatesTests {
    @Test func eachTemplatesFirstMessage() {
        for template in BotTemplate.all {
            let message = BotTemplate.firstMessage(job: template.job, instructions: template.instructions)
            #expect(message.hasPrefix("Your job, in a few words: \(template.job)."), "\(template.name): \(message.prefix(80))")
            #expect(message.components(separatedBy: template.job).count == 2, "\(template.name): its job said once")
            #expect(message.contains(template.instructions.trimmingCharacters(in: .whitespacesAndNewlines)), "\(template.name): what it's to do, whole")
            #expect(message.hasSuffix("set that up."), "\(template.name): then to start")
            if let personality = template.personality {
                #expect(Personalities.presets.contains { $0.id == personality }, "\(template.name) names a personality that isn't there: \(personality)")
            }
            #expect(!template.name.isEmpty && !template.job.isEmpty)
        }
    }

    @Test func eachTemplateIsItsOwn() {
        #expect(BotTemplate.all.count > 1)
        #expect(Set(BotTemplate.all.map(\.id)).count == BotTemplate.all.count)
        #expect(Set(BotTemplate.all.map(\.name)).count == BotTemplate.all.count)
    }
}
