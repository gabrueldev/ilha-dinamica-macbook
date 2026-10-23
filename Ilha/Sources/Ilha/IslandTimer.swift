import Foundation

struct IslandTimer: Equatable {
    let id = UUID()
    let label: String       // "Pomodoro", "Pausa", "Timer"
    let duration: TimeInterval
    let end: Date

    func remaining(at date: Date = Date()) -> TimeInterval {
        max(0, end.timeIntervalSince(date))
    }

    func progress(at date: Date = Date()) -> Double {
        duration > 0 ? 1 - remaining(at: date) / duration : 1
    }

    /// 1499 s → "24:59"; 3900 s → "1:05:00". Arredonda para cima: nunca mostra "0:00" antes de acabar.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(ceil(seconds))
        let h = total / 3600, m = total / 60 % 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// 1500 s → "25 min"; 90 s → "1 min 30 s"; 5400 s → "1 h 30 min".
    static func spoken(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = total / 60 % 60, s = total % 60
        var parts: [String] = []
        if h > 0 { parts.append("\(h) h") }
        if m > 0 { parts.append("\(m) min") }
        if s > 0 { parts.append("\(s) s") }
        return parts.isEmpty ? "0 s" : parts.joined(separator: " ")
    }
}

/// Comandos de timer digitados na ilha: "pomodoro", "pausa", "timer 25", "timer 90s", "timer 1h30", "cancelar timer".
enum TimerCommand {
    enum Action: Equatable {
        case start(seconds: TimeInterval, label: String)
        case cancel
    }

    private static let prefixes = ["timer ", "temporizador "]
    private static let cancelWords: Set<String> = [
        "cancelar timer", "parar timer", "timer parar", "timer cancelar", "timer off", "timer stop", "stop timer",
    ]
    private static let maxSeconds: TimeInterval = 24 * 3600

    static func parse(_ text: String) -> Action? {
        let lower = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .folding(options: .diacriticInsensitive, locale: nil)

        if cancelWords.contains(lower) { return .cancel }
        switch lower {
        case "pomodoro": return .start(seconds: 25 * 60, label: "Pomodoro")
        case "pausa", "intervalo": return .start(seconds: 5 * 60, label: "Pausa")
        case "pausa longa": return .start(seconds: 15 * 60, label: "Pausa")
        default: break
        }

        guard let prefix = prefixes.first(where: { lower.hasPrefix($0) }) else { return nil }
        let rest = String(lower.dropFirst(prefix.count))
        guard let seconds = duration(rest), seconds > 0, seconds <= maxSeconds else { return nil }
        return .start(seconds: seconds, label: "Timer")
    }

    /// "25" (minutos), "25m", "25 min", "90s", "90 seg", "1h", "1h30", "1h 30m", "1:30" (min:seg).
    static func duration(_ text: String) -> TimeInterval? {
        let s = text.replacingOccurrences(of: " ", with: "")
        guard !s.isEmpty else { return nil }

        if let n = Double(s.replacingOccurrences(of: ",", with: ".")) { return n * 60 }

        if s.range(of: #"^\d+:\d{1,2}$"#, options: .regularExpression) != nil {
            let parts = s.split(separator: ":").compactMap { Double($0) }
            return parts[0] * 60 + parts[1]
        }

        // Sequência de número + unidade; um número final sem unidade herda a unidade seguinte ("1h30" → 30 min).
        // Unidades longas antes das curtas, senão "25min" casa só "25m".
        let pattern = #"(\d+(?:[.,]\d+)?)(horas|hora|hrs|hr|h|minutos|minuto|mins|min|m|segundos|segundo|segs|seg|s)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }

        var total: TimeInterval = 0
        var consumed = 0
        var lastUnit = ""
        for match in regex.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            guard match.range.location == consumed,
                  let numberRange = Range(match.range(at: 1), in: s),
                  let n = Double(s[numberRange].replacingOccurrences(of: ",", with: ".")) else { return nil }
            consumed = match.range.location + match.range.length
            let unit = Range(match.range(at: 2), in: s).map { String(s[$0]) }
                ?? (lastUnit.hasPrefix("h") ? "m" : lastUnit.hasPrefix("m") ? "s" : "m")
            lastUnit = unit
            switch unit.first {
            case "h": total += n * 3600
            case "s": total += n
            default: total += n * 60
            }
        }
        return consumed == (s as NSString).length ? total : nil
    }
}
