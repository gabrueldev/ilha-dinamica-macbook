import AppKit

/// Um arquivo pronto para virar bloco de conteúdo da Messages API.
struct LoadedFile: @unchecked Sendable {
    let name: String
    let symbol: String          // SF Symbol do chip
    let block: [String: Any]
    let note: String?           // aviso (ex.: texto cortado)
}

enum FileLoaderError: LocalizedError {
    case tooBig, unsupported, folder, unreadable(String)

    var errorDescription: String? {
        switch self {
        case .tooBig: return "Arquivo grande demais (máx. 30 MB)."
        case .unsupported: return "Tipo de arquivo não suportado."
        case .folder: return "Pastas não são suportadas. Solte um arquivo."
        case .unreadable(let why): return why
        }
    }
}

enum FileLoader {
    static let maxBytes = 30 * 1024 * 1024
    static let maxChars = 400_000
    /// Limite de imagem da API (~5 MB em base64).
    static let maxImageBytes = 3_700_000

    static let imageTypes = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp"]
    static let convertibleImages: Set<String> = ["heic", "heif", "tiff", "tif", "bmp"]
    static let richDocuments: Set<String> = ["doc", "docx", "rtf", "odt", "html", "htm", "webarchive"]

    static func load(_ url: URL) throws -> LoadedFile {
        let name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        if values?.isDirectory == true { throw FileLoaderError.folder }
        if (values?.fileSize ?? 0) > maxBytes { throw FileLoaderError.tooBig }

        if ext == "pdf" {
            let data = try Data(contentsOf: url)
            return LoadedFile(name: name, symbol: "doc.richtext", block: [
                "type": "document",
                "source": ["type": "base64", "media_type": "application/pdf", "data": data.base64EncodedString()],
            ], note: nil)
        }

        if let mediaType = imageTypes[ext] {
            return try image(name: name, data: Data(contentsOf: url), mediaType: mediaType)
        }

        if convertibleImages.contains(ext) {
            guard let image = NSImage(contentsOf: url),
                  let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
            else { throw FileLoaderError.unreadable("Não consegui abrir essa imagem.") }
            return try self.image(name: name, data: png, mediaType: "image/png")
        }

        if richDocuments.contains(ext) {
            return text(name: name, content: try textutil(url), symbol: "doc.plaintext")
        }

        guard let data = try? Data(contentsOf: url) else {
            throw FileLoaderError.unreadable("Não consegui ler o arquivo.")
        }
        guard !data.contains(0), let content = String(data: data, encoding: .utf8) else {
            throw FileLoaderError.unsupported
        }
        return text(name: name, content: content, symbol: "doc.text")
    }

    private static func image(name: String, data: Data, mediaType: String) throws -> LoadedFile {
        var data = data
        var mediaType = mediaType
        if data.count > maxImageBytes {
            guard let smaller = shrink(data) else { throw FileLoaderError.unreadable("Imagem grande demais.") }
            data = smaller
            mediaType = "image/jpeg"
        }
        return LoadedFile(name: name, symbol: "photo", block: [
            "type": "image",
            "source": ["type": "base64", "media_type": mediaType, "data": data.base64EncodedString()],
        ], note: nil)
    }

    /// Reduz para no máx. 2000 px e recomprime em JPEG.
    private static func shrink(_ data: Data) -> Data? {
        guard let image = NSImage(data: data),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = min(1, 2000 / CGFloat(max(cg.width, cg.height)))
        let width = Int(CGFloat(cg.width) * scale)
        let height = Int(CGFloat(cg.height) * scale)
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let output = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: output).representation(using: .jpeg, properties: [.compressionFactor: 0.82])
    }

    private static func text(name: String, content: String, symbol: String) -> LoadedFile {
        var content = content
        var note: String?
        if content.count > maxChars {
            content = String(content.prefix(maxChars))
            note = "Arquivo grande: enviei só os primeiros 400 mil caracteres."
        }
        return LoadedFile(name: name, symbol: symbol, block: [
            "type": "text",
            "text": "<arquivo nome=\"\(name)\">\n\(content)\n</arquivo>",
        ], note: note)
    }

    private static func textutil(_ url: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        process.arguments = ["-convert", "txt", "-stdout", url.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw FileLoaderError.unreadable("Não consegui extrair o texto do documento.") }
        return text
    }
}
