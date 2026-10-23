import AppKit

/// Comandos rápidos digitados na ilha: "abrir {app/pasta/link}" e links soltos (abrem no Safari).
enum Launcher {
    enum Outcome: Sendable {
        case notCommand
        case opened(String)
        case failed(String)
    }

    private static let prefixes = ["abrir ", "abra ", "abre ", "open "]

    /// Extensões de código que parecem domínio ("billing.ts") mas não são links.
    private static let codeExtensions: Set<String> = [
        "ts", "js", "jsx", "tsx", "py", "swift", "json", "txt", "rs", "rb", "java", "kt",
        "yml", "yaml", "lock", "log", "csv", "md", "sh", "c", "h", "cpp", "go", "css",
    ]

    private static let folders: [String: String] = [
        "downloads": "~/Downloads",
        "documentos": "~/Documents",
        "documents": "~/Documents",
        "mesa": "~/Desktop",
        "desktop": "~/Desktop",
        "aplicativos": "/Applications",
        "applications": "/Applications",
        "home": "~",
        "inicio": "~",
    ]

    private static let aliases: [String: String] = [
        "vscode": "Visual Studio Code",
        "vs code": "Visual Studio Code",
        "code": "Visual Studio Code",
        "chrome": "Google Chrome",
        "configuracoes": "System Settings",
        "configuracoes do sistema": "System Settings",
        "ajustes": "System Settings",
    ]

    /// Checagem barata (sem varrer apps), para decidir se vale chamar `run`.
    static func looksLikeCommand(_ text: String) -> Bool {
        let lower = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return prefixes.contains(where: { lower.hasPrefix($0) }) || webURL(lower) != nil
    }

    static func run(_ text: String) -> Outcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()

        if let prefix = prefixes.first(where: { lower.hasPrefix($0) }) {
            let target = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            guard !target.isEmpty else { return .failed("Abrir o quê?") }
            return open(target)
        }
        if let url = webURL(trimmed) {
            return openInSafari(url)
        }
        return .notCommand
    }

    private static func open(_ target: String) -> Outcome {
        if let url = webURL(target) {
            return openInSafari(url)
        }

        let key = normalize(target)
        if let folder = folders[key] {
            return openPath(folder, label: target)
        }
        if target.hasPrefix("/") || target.hasPrefix("~") {
            return openPath(target, label: target)
        }

        if let app = findApp(aliases[key] ?? target) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: app, configuration: config)
            return .opened(FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: ""))
        }
        return .failed("Não achei “\(target)”.")
    }

    // MARK: - Links

    /// "gabrueldev.com", "https://x.com/a", "localhost:3000" → URL; o resto → nil.
    static func webURL(_ text: String) -> URL? {
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return nil }
        let lower = text.lowercased()

        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            return URL(string: text)
        }
        if lower.range(of: #"^localhost(:\d+)?(/\S*)?$"#, options: .regularExpression) != nil {
            return URL(string: "http://" + text)
        }
        guard lower.range(of: #"^([a-z0-9-]+\.)+[a-z]{2,}(:\d+)?([/?#]\S*)?$"#, options: .regularExpression) != nil else {
            return nil
        }
        let host = lower.split(whereSeparator: { "/?#:".contains($0) }).first ?? ""
        if let tld = host.split(separator: ".").last, codeExtensions.contains(String(tld)) {
            return nil
        }
        return URL(string: "https://" + text)
    }

    private static func openInSafari(_ url: URL) -> Outcome {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        if let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") {
            NSWorkspace.shared.open([url], withApplicationAt: safari, configuration: config)
        } else {
            NSWorkspace.shared.open(url)
        }
        return .opened(url.host ?? url.absoluteString)
    }

    // MARK: - Pastas e apps

    private static func openPath(_ path: String, label: String) -> Outcome {
        let expanded = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            return .failed("Não achei “\(label)”.")
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: expanded))
        return .opened(FileManager.default.displayName(atPath: expanded))
    }

    private static let appDirectories = [
        "/Applications",
        "/Applications/Utilities",
        "/System/Applications",
        "/System/Applications/Utilities",
        "/System/Library/CoreServices",
        "~/Applications",
    ]

    /// Procura pelo nome do arquivo e pelo nome localizado ("Calculadora" → Calculator.app).
    /// Ordem: nome exato, começa com, contém. Empate: o nome mais curto.
    static func findApp(_ name: String) -> URL? {
        let wanted = normalize(name)
        let candidates = installedApps().map { url in
            (names: [normalize(url.deletingPathExtension().lastPathComponent)] + localizedNames(url).map(normalize), url: url)
        }

        let tests: [(String) -> Bool] = [
            { $0 == wanted },
            { $0.hasPrefix(wanted) },
            { $0.contains(wanted) },
        ]
        for test in tests {
            // Para cada app, o tamanho do menor nome que passou no teste.
            let matches = candidates.compactMap { app in
                app.names.filter(test).map(\.count).min().map { (length: $0, url: app.url) }
            }
            if let best = matches.min(by: { $0.length < $1.length }) {
                return best.url
            }
        }
        return nil
    }

    /// Apps das pastas padrão, incluindo um nível de subpasta ("Adobe Photoshop 2026/…app").
    private static func installedApps() -> [URL] {
        let fm = FileManager.default
        var apps: [URL] = []
        for dir in appDirectories {
            let base = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
            guard let items = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else { continue }
            for item in items {
                if item.pathExtension == "app" {
                    apps.append(item)
                } else if dir != "/System/Library/CoreServices",
                          let inner = try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil) {
                    apps += inner.filter { $0.pathExtension == "app" }
                }
            }
        }
        return apps
    }

    /// Nomes traduzidos nos idiomas do usuário ("Calculator" → "Calculadora").
    private static func localizedNames(_ app: URL) -> [String] {
        let resources = app.appendingPathComponent("Contents/Resources")
        var languages: [String] = []
        for lang in Locale.preferredLanguages {
            let underscored = lang.replacingOccurrences(of: "-", with: "_")
            let base = String(lang.split(separator: "-").first ?? "")
            for l in [lang, underscored, base] where !languages.contains(l) { languages.append(l) }
        }

        var tables: [[String: Any]] = []
        if let loctable = NSDictionary(contentsOf: resources.appendingPathComponent("InfoPlist.loctable")) as? [String: Any] {
            tables += languages.compactMap { loctable[$0] as? [String: Any] }
        }
        for lang in languages {
            let strings = resources.appendingPathComponent("\(lang).lproj/InfoPlist.strings")
            if let table = NSDictionary(contentsOf: strings) as? [String: Any] { tables.append(table) }
        }
        return tables.flatMap { table in
            ["CFBundleDisplayName", "CFBundleName"].compactMap { table[$0] as? String }
        }
    }

    private static func normalize(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespaces)
    }
}
