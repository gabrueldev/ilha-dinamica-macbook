import Foundation
import Network

/// Servidor HTTP mínimo, só em loopback, que recebe os hooks do Claude Code.
final class HookServer {
    static let port: UInt16 = 47821

    /// Chamado na main thread para cada `POST /hook` com JSON válido.
    var onEvent: (([String: Any], HookReply) -> Void)?
    /// Chamado na main thread: `nil` = ativo, texto = erro.
    var onStatus: ((String?) -> Void)?

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "app.ilha.hookserver")

    func start() {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
            let listener = try NWListener(using: params)
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.report(nil)
                case .failed(let error):
                    listener.cancel()
                    self?.report(Self.describe(error))
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            report(error.localizedDescription)
        }
    }

    private func report(_ error: String?) {
        DispatchQueue.main.async { self.onStatus?(error) }
    }

    private static func describe(_ error: NWError) -> String {
        if case .posix(let code) = error, code == .EADDRINUSE {
            return "porta \(port) ocupada"
        }
        return error.localizedDescription
    }

    // MARK: - Conexões

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = HTTPRequest.parse(buffer) {
                self.handle(request, connection)
            } else if isComplete || error != nil || buffer.count > 50_000_000 {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    private func handle(_ request: HTTPRequest, _ connection: NWConnection) {
        let reply = HookReply(connection: connection)
        switch (request.method, request.path) {
        case ("GET", "/health"):
            reply.send(Data("ok".utf8), contentType: "text/plain")
        case ("POST", "/hook"):
            guard let json = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] else {
                reply.send(Data())
                return
            }
            reply.watchForClose()
            DispatchQueue.main.async { [weak self] in
                guard let onEvent = self?.onEvent else { return reply.send(Data()) }
                onEvent(json, reply)
            }
        default:
            reply.send(Data("not found".utf8), contentType: "text/plain", status: "404 Not Found")
        }
    }
}

/// A resposta de uma requisição. Pode ficar guardada (PermissionRequest) até o usuário decidir.
final class HookReply {
    private let connection: NWConnection
    private let lock = NSLock()
    private var sent = false

    /// Chamado na main thread se o cliente fechar a conexão antes da resposta.
    var onClientGone: (() -> Void)?

    init(connection: NWConnection) {
        self.connection = connection
    }

    var isSent: Bool {
        lock.lock(); defer { lock.unlock() }
        return sent
    }

    func send(_ body: Data, contentType: String = "application/json", status: String = "200 OK") {
        lock.lock()
        if sent { lock.unlock(); return }
        sent = true
        lock.unlock()

        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(body)
        let connection = self.connection
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }

    /// Fica lendo a conexão só para perceber quando o Claude Code desiste dela.
    func watchForClose() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] _, _, isComplete, error in
            guard let self, !self.isSent else { return }
            if isComplete || error != nil {
                DispatchQueue.main.async { self.onClientGone?() }
            } else {
                self.watchForClose()
            }
        }
    }
}

struct HTTPRequest {
    let method: String
    let path: String
    let body: Data

    /// `nil` enquanto a requisição ainda não chegou inteira.
    static func parse(_ buffer: Data) -> HTTPRequest? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: buffer[buffer.startIndex..<headerEnd.lowerBound], encoding: .utf8)
        else { return nil }

        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        guard requestLine.count >= 2 else { return nil }
        let method = String(requestLine[0]).uppercased()
        let path = String(requestLine[1].split(separator: "?").first ?? "")

        var length = 0
        var chunked = false
        for line in lines.dropFirst() {
            let kv = line.split(separator: ":", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let key = kv[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = kv[1].trimmingCharacters(in: .whitespaces)
            if key == "content-length" { length = Int(value) ?? 0 }
            if key == "transfer-encoding", value.lowercased().contains("chunked") { chunked = true }
        }

        let rest = buffer.subdata(in: headerEnd.upperBound..<buffer.endIndex)
        if chunked {
            guard let body = decodeChunked(rest) else { return nil }
            return HTTPRequest(method: method, path: path, body: body)
        }
        guard rest.count >= length else { return nil }
        return HTTPRequest(method: method, path: path, body: rest.prefix(length))
    }

    private static func decodeChunked(_ data: Data) -> Data? {
        var body = Data()
        var index = data.startIndex
        let crlf = Data("\r\n".utf8)
        while true {
            guard let lineEnd = data.range(of: crlf, in: index..<data.endIndex),
                  let sizeLine = String(data: data[index..<lineEnd.lowerBound], encoding: .utf8),
                  let size = Int(sizeLine.split(separator: ";").first ?? "", radix: 16)
            else { return nil }
            let start = lineEnd.upperBound
            if size == 0 { return body }
            guard data.endIndex - start >= size + 2 else { return nil }
            body.append(data[start..<(start + size)])
            index = start + size + 2
        }
    }
}
