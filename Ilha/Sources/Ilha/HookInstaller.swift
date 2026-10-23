import Foundation

/// Instala/remove os hooks HTTP da Ilha em `~/.claude/settings.json`, sem mexer no resto.
enum HookInstaller {
    static let hookURL = "http://127.0.0.1:47821/hook"
    static let ourPrefix = "http://127.0.0.1:47821/"

    static let events: [(name: String, matcher: Bool, timeout: Int)] = [
        ("SessionStart", false, 5),
        ("UserPromptSubmit", false, 5),
        ("PreToolUse", true, 5),
        ("PostToolUse", true, 5),
        ("PermissionRequest", true, 300),
        ("Notification", false, 5),
        ("Stop", false, 5),
        ("SessionEnd", false, 5),
    ]

    enum InstallerError: LocalizedError {
        case invalidJSON
        var errorDescription: String? {
            "~/.claude/settings.json não é um JSON válido. Corrija o arquivo e tente de novo."
        }
    }

    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    static var backupURL: URL {
        settingsURL.deletingLastPathComponent().appendingPathComponent("settings.json.ilha-backup")
    }

    static func isInstalled() -> Bool {
        guard let settings = try? readSettings(), let hooks = settings["hooks"] as? [String: Any] else { return false }
        return events.allSatisfy { event in
            (hooks[event.name] as? [Any] ?? []).contains(where: isOurs)
        }
    }

    static func install() throws {
        var settings = try readSettings()
        try backupIfNeeded()
        var hooks = stripOurs(settings["hooks"] as? [String: Any] ?? [:])
        for event in events {
            var group: [String: Any] = [
                "hooks": [["type": "http", "url": hookURL, "timeout": event.timeout]]
            ]
            if event.matcher { group["matcher"] = "*" }
            hooks[event.name] = (hooks[event.name] as? [Any] ?? []) + [group]
        }
        settings["hooks"] = hooks
        try write(settings)
    }

    static func uninstall() throws {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return }
        var settings = try readSettings()
        guard let hooks = settings["hooks"] as? [String: Any] else { return }
        try backupIfNeeded()
        let stripped = stripOurs(hooks)
        if stripped.isEmpty {
            settings.removeValue(forKey: "hooks")
        } else {
            settings["hooks"] = stripped
        }
        try write(settings)
    }

    // MARK: - Internos

    private static func isOurs(_ group: Any) -> Bool {
        guard let group = group as? [String: Any], let hooks = group["hooks"] as? [Any] else { return false }
        return hooks.contains { (($0 as? [String: Any])?["url"] as? String)?.hasPrefix(ourPrefix) == true }
    }

    private static func stripOurs(_ hooks: [String: Any]) -> [String: Any] {
        var result = hooks
        for (event, value) in hooks {
            guard let groups = value as? [Any] else { continue }
            let kept = groups.filter { !isOurs($0) }
            if kept.isEmpty && kept.count != groups.count {
                result.removeValue(forKey: event)
            } else {
                result[event] = kept
            }
        }
        return result
    }

    private static func readSettings() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return [:] }
        let data = try Data(contentsOf: settingsURL)
        if String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [:]
        }
        guard let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw InstallerError.invalidJSON
        }
        return settings
    }

    private static func backupIfNeeded() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: settingsURL.path), !fm.fileExists(atPath: backupURL.path) else { return }
        try fm.copyItem(at: settingsURL, to: backupURL)
    }

    private static func write(_ settings: [String: Any]) throws {
        // Se o settings.json for um link (dotfiles), escreve no arquivo de verdade.
        let target = settingsURL.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        )
        try data.write(to: target, options: .atomic)
    }
}
