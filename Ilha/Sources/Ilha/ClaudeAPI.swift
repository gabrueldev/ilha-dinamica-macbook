import Foundation

enum ClaudeAPI {
    static let defaultModel = "claude-sonnet-5-5"
    static let systemPrompt = "Você é um assistente direto. Responda em português do Brasil, de forma curta, salvo se pedirem detalhes."

    enum APIError: LocalizedError {
        case http(Int, String)
        var errorDescription: String? {
            switch self {
            case .http(let status, let message): return status > 0 ? "Erro \(status): \(message)" : message
            }
        }
    }

    static var model: String {
        let saved = UserDefaults.standard.string(forKey: "model")?.trimmingCharacters(in: .whitespaces) ?? ""
        return saved.isEmpty ? defaultModel : saved
    }

    /// Faz a pergunta em streaming; `onText` recebe cada pedaço da resposta na main thread.
    static func stream(
        apiKey: String,
        model: String,
        file: LoadedFile?,
        question: String,
        onText: @escaping @MainActor (String) -> Void
    ) async throws {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        var content: [[String: Any]] = []
        if let file { content.append(file.block) }
        content.append(["type": "text", "text": question])
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 2048,
            "stream": true,
            "system": systemPrompt,
            "messages": [["role": "user", "content": content]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status != 200 {
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            throw APIError.http(status, errorMessage(data))
        }

        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let data = payload.data(using: .utf8),
                  let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { continue }

            switch event["type"] as? String {
            case "content_block_delta":
                if let delta = event["delta"] as? [String: Any],
                   delta["type"] as? String == "text_delta",
                   let text = delta["text"] as? String {
                    await onText(text)
                }
            case "error":
                let error = event["error"] as? [String: Any]
                throw APIError.http(0, error?["message"] as? String ?? "Erro na resposta da API.")
            default:
                break
            }
        }
    }

    private static func errorMessage(_ data: Data) -> String {
        if let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "Sem detalhes." : String(text.prefix(200))
    }
}

/// Estado do modo "ask": arquivo, pergunta e resposta em streaming.
@MainActor
final class AskModel: ObservableObject {
    @Published var file: LoadedFile?
    @Published var loadingFile = false
    @Published var question = ""
    @Published var lastQuestion = ""
    @Published var answer = ""
    @Published var error: String?
    @Published var streaming = false
    @Published var needsKey = false
    @Published var keyDraft = ""
    @Published var info: String?

    /// Fecha a ilha; `false` = não devolver o foco ao app anterior (acabamos de abrir outro).
    var onClose: ((Bool) -> Void)?
    var onTimer: ((TimerCommand.Action) -> Void)?
    private var task: Task<Void, Never>?

    func load(_ url: URL) {
        stop()
        file = nil
        error = nil
        answer = ""
        lastQuestion = ""
        loadingFile = true
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Result { try FileLoader.load(url) }
            await self?.finishLoading(result)
        }
    }

    private func finishLoading(_ result: Result<LoadedFile, Error>) {
        loadingFile = false
        switch result {
        case .success(let file): self.file = file
        case .failure(let error): self.error = error.localizedDescription
        }
    }

    func removeFile() {
        file = nil
    }

    func send() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !streaming, !loadingFile else { return }

        // "pomodoro", "timer 25" etc. também não precisam da API.
        if file == nil, let action = TimerCommand.parse(q) {
            onTimer?(action)
            question = ""
            error = nil
            if case .start(let seconds, let label) = action {
                info = "\(label) de \(IslandTimer.spoken(seconds)) iniciado"
            } else {
                info = "Timer cancelado"
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                MainActor.assumeIsolated { self?.onClose?(true) }
            }
            return
        }

        // "abrir {coisa}" e links soltos não precisam da API.
        if file == nil && Launcher.looksLikeCommand(q) {
            error = nil
            info = "Procurando…"
            Task.detached(priority: .userInitiated) { [weak self] in
                let outcome = Launcher.run(q)
                await self?.finishCommand(outcome, question: q)
            }
            return
        }
        ask(q)
    }

    private func finishCommand(_ outcome: Launcher.Outcome, question q: String) {
        switch outcome {
        case .notCommand:
            info = nil
            ask(q)
        case .opened(let what):
            question = ""
            error = nil
            info = "Abrindo \(what)…"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                MainActor.assumeIsolated { self?.onClose?(false) }
            }
        case .failed(let why):
            info = nil
            error = why
        }
    }

    private func ask(_ q: String) {
        guard let key = Keychain.apiKey() else {
            needsKey = true
            return
        }
        lastQuestion = q
        question = ""
        answer = ""
        error = nil
        streaming = true
        let file = self.file
        task = Task { [weak self] in
            do {
                try await ClaudeAPI.stream(apiKey: key, model: ClaudeAPI.model, file: file, question: q) { chunk in
                    self?.answer += chunk
                }
            } catch is CancellationError {
            } catch let error as URLError where error.code == .cancelled {
            } catch {
                self?.error = error.localizedDescription
            }
            self?.streaming = false
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        streaming = false
    }

    func saveKey() {
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        Keychain.save(key)
        keyDraft = ""
        needsKey = false
        if !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { send() }
    }

    func reset() {
        stop()
        file = nil
        loadingFile = false
        question = ""
        lastQuestion = ""
        answer = ""
        error = nil
        info = nil
        needsKey = false
        keyDraft = ""
    }
}
