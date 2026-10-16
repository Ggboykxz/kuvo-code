import Foundation
import OpenCodeKit

/// A project's folders beyond its primary one, as a session's agent gets them: a permission
/// rule per folder, so working there doesn't count as leaving the project (opencode's own
/// ACP server does the same for an editor's extra folders), and an instruction naming each
/// one, so "in chugs-pinterest" means something to it.
nonisolated enum ProjectFolders {
    static let instructionKey = "kuvo.project-folders"

    /// Allows the folders, symlinks resolved too (`/var` is `/private/var`). They go after
    /// the approval rules: the last matching rule wins, and Ask First asks about any folder.
    static func rules(for folders: [String]) -> [PermissionRule] {
        var paths: [String] = []
        for folder in folders {
            for path in [folder, URL(filePath: folder).resolvingSymlinksInPath().path] where !paths.contains(path) {
                paths.append(path)
            }
        }
        return paths.map { PermissionRule(action: "external_directory", resource: ($0 as NSString).appendingPathComponent("*"), effect: .allow) }
    }

    static func isFolderRule(_ rule: PermissionRule) -> Bool {
        rule.action == "external_directory" && rule.effect == .allow && rule.resource.hasSuffix("/*")
    }

    /// `rules` with its folder rules replaced by those for `folders`. A bot's own folder stays
    /// allowed: it isn't one of the project's.
    static func permissions(_ rules: [PermissionRule], folders: [String]) -> [PermissionRule] {
        rules.filter { !isFolderRule($0) || $0.resource.contains("/bots/bot_") } + self.rules(for: folders)
    }

    static func instructions(primary: String, folders: [String]) -> String {
        let list = folders.map { "- \(($0 as NSString).lastPathComponent): \($0)" }.joined(separator: "\n")
        return """
        This project spans several folders. You work in its primary folder, \((primary as NSString).lastPathComponent) (\(primary)). \
        These folders belong to the project too, and you can read, search and change files in them the same way:
        \(list)
        When the user mentions one of these folders by name, they mean that folder.
        """
    }
}
