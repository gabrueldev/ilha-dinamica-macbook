import AppKit
import SwiftUI

enum SessionStatus: Equatable {
    case idle, working(String), waitingPermission, done(String)

    var label: String {
        switch self {
        case .idle: return "ocioso"
        case .working(let action): return action
        case .waitingPermission: return "esperando permissão"
        case .done: return "terminou"
        }
    }

    var mood: MascotMood {
        switch self {
        case .idle: return .idle
        case .working: return .working
        case .waitingPermission: return .waiting
        case .done: return .done
        }
    }
}

struct Session: Identifiable {
    let id: String          // session_id
    var project: String     // último componente do cwd
    var status: SessionStatus
    var lastUpdate: Date
}

struct PendingPermission: Identifiable {
    let id: UUID
    let sessionID: String
    let project: String
    let toolName: String
    let summary: String     // ex.: "git push origin main"
    let respond: (Data) -> Void   // envia a resposta HTTP e fecha a conexão
}

struct FinishedInfo: Equatable {
    let id = UUID()
    let project: String
    let message: String
}

enum IslandMode: Equatable {
    case collapsed, hover, permission, finished, dropTarget, ask
}

enum PermissionDecision {
    case allow, deny, terminal
}

@MainActor
final class SessionStore: ObservableObject {
    static let shared = SessionStore()
    static let panelSize = CGSize(width: 700, height: 500)
    static let topRadius: CGFloat = 6

    @Published private(set) var sessions: [Session] = []
    @Published private(set) var pending: [PendingPermission] = [] {
        didSet {
            if pending.first?.id != oldValue.first?.id { permissionShownAt = Date() }
        }
    }
    @Published private(set) var finished: FinishedInfo?
    @Published private(set) var askActive = false
    @Published private(set) var timer: IslandTimer?
    @Published var hovering = false
    @Published var dragging = false

    @Published var notchWidth: CGFloat = 200
    @Published var notchHeight: CGFloat = 32
    @Published var hasNotch = false

    let ask = AskModel()
    /// Lido pelo NotchController ao sair do modo ask.
    private(set) var restoreFocusOnClose = true
    /// Quando o cartão de permissão da frente apareceu (evita ⏎ acidental).
    private(set) var permissionShownAt = Date.distantPast
    private var cleanupTimer: Timer?
    private var countdown: Timer?

    private init() {
        UserDefaults.standard.register(defaults: ["soundOnFinish": true])
        ask.onClose = { [weak self] restoreFocus in self?.closeAsk(restoreFocus: restoreFocus) }
        ask.onTimer = { [weak self] action in self?.handleTimer(action) }
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.cleanup() }
        }
    }

    // MARK: - Estado derivado

    var mode: IslandMode {
        if !pending.isEmpty { return .permission }
        if askActive { return .ask }
        if dragging { return .dropTarget }
        if finished != nil { return .finished }
        if hovering { return .hover }
        return .collapsed
    }

    var overallStatus: SessionStatus {
        if !pending.isEmpty || sessions.contains(where: { $0.status == .waitingPermission }) {
            return .waitingPermission
        }
        if let s = sessions.first(where: { if case .working = $0.status { return true }; return false }) {
            return s.status
        }
        if let s = sessions.first(where: { if case .done = $0.status { return true }; return false }) {
            return s.status
        }
        return .idle
    }

    var islandSize: CGSize {
        let nh = notchHeight
        let tr = Self.topRadius
        switch mode {
        case .collapsed:
            let ears: CGFloat = timer != nil ? 112 : sessions.isEmpty ? 0 : 72
            return CGSize(width: notchWidth + ears + 2 * tr, height: nh)
        case .hover:
            let rows = CGFloat(max(sessions.count, 1))
            let timerCard: CGFloat = timer != nil ? 58 : 0
            return CGSize(width: 460, height: min(max(nh + 100 + 44 * rows + timerCard, 140), 380))
        case .permission:
            return CGSize(width: 480, height: nh + 160)
        case .finished:
            return CGSize(width: 440, height: nh + 90)
        case .dropTarget:
            return CGSize(width: 420, height: nh + 110)
        case .ask:
            return CGSize(width: 520, height: askHeight(nh))
        }
    }

    private func askHeight(_ nh: CGFloat) -> CGFloat {
        var h = nh + 96
        if ask.needsKey { h += 64 }
        if ask.error != nil || ask.info != nil || ask.file?.note != nil { h += 22 }
        if ask.streaming || !ask.answer.isEmpty {
            // ~72 caracteres por linha na largura de 520 pt
            let lines = ask.answer.split(separator: "\n", omittingEmptySubsequences: false)
                .reduce(0) { $0 + max(1, Int(ceil(Double($1.count) / 72))) }
            h += 58 + CGFloat(max(lines, 1)) * 17
        }
        return min(max(h, nh + 140), 420)
    }

    // MARK: - Eventos dos hooks

    func handle(_ event: [String: Any], reply: HookReply) {
        let name = event["hook_event_name"] as? String ?? ""
        let sid = event["session_id"] as? String ?? "sem-id"
        let cwd = event["cwd"] as? String ?? ""
        let tool = event["tool_name"] as? String ?? ""
        let input = event["tool_input"] as? [String: Any] ?? [:]

        if name == "PermissionRequest" {
            enqueuePermission(sid: sid, cwd: cwd, tool: tool.isEmpty ? "Ferramenta" : tool, input: input, reply: reply)
            return
        }
        reply.send(Data())

        switch name {
        case "SessionStart":
            update(sid, cwd) { $0.status = .idle }
        case "UserPromptSubmit":
            resolveOrphans(sid)
            update(sid, cwd) { $0.status = .working("Pensando…") }
        case "PreToolUse":
            update(sid, cwd) { $0.status = .working(ToolSummary.short(tool, input)) }
        case "PostToolUse":
            resolveOrphans(sid, tool: tool, detail: ToolSummary.detail(tool, input))
            let waiting = hasPending(sid)
            update(sid, cwd) { $0.status = waiting ? .waitingPermission : .working(ToolSummary.short(tool, input)) }
        case "Notification":
            let type = event["notification_type"] as? String ?? ""
            if type == "permission_prompt", !hasPending(sid) {
                update(sid, cwd) { $0.status = .waitingPermission }
            } else if type == "idle_prompt" {
                update(sid, cwd) { if case .done = $0.status {} else { $0.status = .idle } }
            }
        case "Stop":
            resolveOrphans(sid)
            let message = Self.cleanMessage(event["last_assistant_message"] as? String)
            update(sid, cwd) { $0.status = .done(message) }
            showFinished(project: Self.projectName(cwd), message: message)
        case "SessionEnd":
            resolveOrphans(sid)
            sessions.removeAll { $0.id == sid }
        default:
            break
        }
    }

    private func enqueuePermission(sid: String, cwd: String, tool: String, input: [String: Any], reply: HookReply) {
        let id = UUID()
        let permission = PendingPermission(
            id: id,
            sessionID: sid,
            project: Self.projectName(cwd),
            toolName: tool,
            summary: ToolSummary.detail(tool, input),
            respond: { reply.send($0) }
        )
        update(sid, cwd) { $0.status = .waitingPermission }
        pending.append(permission)

        // O Claude Code desistiu da requisição (ex.: respondeu no terminal).
        reply.onClientGone = { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pending.removeAll { $0.id == id }
                if !self.hasPending(sid) { self.setStatus(sid, .working("Pensando…")) }
            }
        }
        // Ninguém clicou: devolve para o prompt do terminal antes do timeout de 300 s do hook.
        DispatchQueue.main.asyncAfter(deadline: .now() + 280) { [weak self] in
            MainActor.assumeIsolated { self?.resolve(id, .terminal) }
        }
    }

    func resolve(_ id: UUID, _ decision: PermissionDecision) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        let permission = pending.remove(at: index)
        permission.respond(Self.responseBody(decision))
        guard !hasPending(permission.sessionID) else { return }
        switch decision {
        case .allow: setStatus(permission.sessionID, .working(ToolSummary.displayName(permission.toolName)))
        case .deny: setStatus(permission.sessionID, .working("Pensando…"))
        case .terminal: break
        }
    }

    func resolveFront(_ decision: PermissionDecision) {
        guard let first = pending.first else { return }
        resolve(first.id, decision)
    }

    static func responseBody(_ decision: PermissionDecision) -> Data {
        let behavior: [String: Any]
        switch decision {
        case .terminal: return Data()
        case .allow: behavior = ["behavior": "allow"]
        case .deny: behavior = ["behavior": "deny", "message": "Negado pela Ilha"]
        }
        let body: [String: Any] = [
            "hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": behavior]
        ]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }

    /// Responde vazio às permissões pendentes da sessão (o usuário respondeu pelo terminal).
    /// Com `tool`, só as que batem com a ferramenta que acabou de rodar.
    private func resolveOrphans(_ sid: String, tool: String? = nil, detail: String? = nil) {
        let orphans = pending.filter {
            $0.sessionID == sid && (tool == nil || ($0.toolName == tool && $0.summary == detail))
        }
        for p in orphans { resolve(p.id, .terminal) }
    }

    private func hasPending(_ sid: String) -> Bool {
        pending.contains { $0.sessionID == sid }
    }

    // MARK: - Sessões

    private func update(_ sid: String, _ cwd: String, _ change: (inout Session) -> Void) {
        if let i = sessions.firstIndex(where: { $0.id == sid }) {
            change(&sessions[i])
            sessions[i].lastUpdate = Date()
            if !cwd.isEmpty { sessions[i].project = Self.projectName(cwd) }
        } else {
            var session = Session(id: sid, project: Self.projectName(cwd), status: .idle, lastUpdate: Date())
            change(&session)
            sessions.append(session)
        }
    }

    private func setStatus(_ sid: String, _ status: SessionStatus) {
        guard let i = sessions.firstIndex(where: { $0.id == sid }) else { return }
        sessions[i].status = status
        sessions[i].lastUpdate = Date()
    }

    private func cleanup() {
        let cutoff = Date().addingTimeInterval(-30 * 60)
        sessions.removeAll { $0.lastUpdate < cutoff && !hasPending($0.id) }
    }

    // MARK: - Concluído

    private func showFinished(project: String, message: String, sound: Bool? = nil, seconds: Double = 4) {
        let info = FinishedInfo(project: project, message: message)
        finished = info
        if sound ?? UserDefaults.standard.bool(forKey: "soundOnFinish") {
            NSSound(named: "Glass")?.play()
        }
        let id = info.id
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            MainActor.assumeIsolated {
                if self?.finished?.id == id { self?.finished = nil }
            }
        }
    }

    func dismissFinished() {
        finished = nil
    }

    // MARK: - Timer

    private func handleTimer(_ action: TimerCommand.Action) {
        switch action {
        case .start(let seconds, let label): startTimer(seconds: seconds, label: label)
        case .cancel: cancelTimer()
        }
    }

    func startTimer(seconds: TimeInterval, label: String) {
        timer = IslandTimer(label: label, duration: seconds, end: Date().addingTimeInterval(seconds))
        // Checa a cada segundo pelo relógio de parede: o Mac pode dormir no meio e o asyncAfter atrasaria.
        countdown?.invalidate()
        let countdown = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkTimer() }
        }
        RunLoop.main.add(countdown, forMode: .common)
        self.countdown = countdown
    }

    func cancelTimer() {
        countdown?.invalidate()
        countdown = nil
        timer = nil
    }

    private func checkTimer() {
        guard let timer, timer.remaining() <= 0 else { return }
        cancelTimer()
        showFinished(project: timer.label, message: "Acabou o tempo · \(IslandTimer.spoken(timer.duration))",
                     sound: true, seconds: 8)
    }

    // MARK: - Perguntar

    func openAsk() {
        hovering = false
        askActive = true
    }

    func closeAsk(restoreFocus: Bool = true) {
        restoreFocusOnClose = restoreFocus
        ask.reset()
        askActive = false
    }

    func dropFile(_ url: URL) {
        dragging = false
        askActive = true
        ask.load(url)
    }

    // MARK: - Utilidades

    static func projectName(_ cwd: String) -> String {
        guard !cwd.isEmpty else { return "Claude" }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    static func cleanMessage(_ text: String?) -> String {
        guard let text else { return "" }
        let plain = text
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "#", with: "")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return String(plain.prefix(220))
    }
}

// MARK: - Texto curto da ação

enum ToolSummary {
    /// Ex.: "Bash npm test", "Read billing.ts", "github · create_issue".
    static func short(_ tool: String, _ input: [String: Any]) -> String {
        switch tool {
        case "Bash":
            if let c = string(input, "command") { return "Bash " + clip(firstLine(c), 60) }
        case "Read", "Edit", "Write", "MultiEdit", "NotebookEdit":
            if let p = string(input, "file_path") ?? string(input, "notebook_path") {
                return "\(tool) \((p as NSString).lastPathComponent)"
            }
        case "Grep", "Glob":
            if let p = string(input, "pattern") { return "\(tool) \(clip(p, 50))" }
        case "WebFetch":
            if let u = string(input, "url"), let host = URL(string: u)?.host { return "WebFetch \(host)" }
        case "WebSearch":
            if let q = string(input, "query") { return "WebSearch \(clip(q, 50))" }
        case "Task", "Agent":
            if let d = string(input, "description") { return "\(tool) \(clip(d, 50))" }
        default:
            break
        }
        return displayName(tool)
    }

    /// Texto mostrado no cartão de permissão (comando completo, caminho etc.).
    static func detail(_ tool: String, _ input: [String: Any]) -> String {
        switch tool {
        case "Bash":
            if let c = string(input, "command") { return c }
        case "Read", "Edit", "Write", "MultiEdit":
            if let p = string(input, "file_path") { return (p as NSString).abbreviatingWithTildeInPath }
        case "NotebookEdit":
            if let p = string(input, "notebook_path") { return (p as NSString).abbreviatingWithTildeInPath }
        case "WebFetch":
            if let u = string(input, "url") { return u }
        case "WebSearch":
            if let q = string(input, "query") { return q }
        case "Grep", "Glob":
            if let p = string(input, "pattern") { return p }
        case "Task", "Agent":
            if let d = string(input, "description") { return d }
        default:
            break
        }
        if !input.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .withoutEscapingSlashes]),
           let json = String(data: data, encoding: .utf8) {
            return clip(json, 300)
        }
        return displayName(tool)
    }

    /// `mcp__server__tool` → `server · tool`
    static func displayName(_ tool: String) -> String {
        guard tool.hasPrefix("mcp__") else { return tool }
        let parts = tool.dropFirst(5).components(separatedBy: "__")
        guard parts.count >= 2 else { return parts.first ?? tool }
        return "\(parts[0]) · \(parts.dropFirst().joined(separator: "__"))"
    }

    private static func string(_ input: [String: Any], _ key: String) -> String? {
        guard let s = input[key] as? String, !s.isEmpty else { return nil }
        return s
    }

    private static func firstLine(_ s: String) -> String {
        s.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? s
    }

    private static func clip(_ s: String, _ n: Int) -> String {
        s.count > n ? String(s.prefix(n - 1)) + "…" : s
    }
}

// MARK: - Ativar o terminal

enum TerminalActivator {
    static let bundleIDs = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92",   // Cursor
        "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty",
    ]

    static func activate() {
        for id in bundleIDs {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
                app.activate(options: [.activateIgnoringOtherApps])
                return
            }
        }
    }
}
