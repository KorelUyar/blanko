import Foundation
import Security

struct AIRequest {
    var system: String
    var text: String
    var images: [Data]          // PNG
    var schema: [String: Any]
    var model: String
}

enum AIError: LocalizedError {
    case noSource
    case failed(String)
    case refused
    case badOutput

    var errorDescription: String? {
        switch self {
        case .noSource:
            return L("No AI source is set up. Add an Anthropic API key in Settings, or install Claude Code and sign in.",
                     "Keine KI-Quelle eingerichtet. Trage in den Einstellungen einen Anthropic-API-Key ein oder installiere Claude Code und melde dich an.")
        case .failed(let m): return m
        case .refused:
            return L("The model declined this request.", "Das Modell hat diese Anfrage abgelehnt.")
        case .badOutput:
            return L("The model's answer could not be read. Try again.", "Die Antwort des Modells war nicht lesbar. Versuch es nochmal.")
        }
    }
}

protocol AIBackend {
    /// Returns the JSON object that matches `request.schema`.
    func run(_ request: AIRequest) async throws -> [String: Any]
}

enum AI {
    /// Which source the current settings resolve to: "api", "cli" or nil.
    static func resolvedSource() -> String? {
        switch Prefs.shared.aiSource {
        case "api": return Keychain.apiKey() != nil ? "api" : nil
        case "cli": return ClaudeCodeBackend.locate() != nil ? "cli" : nil
        default:
            if Keychain.apiKey() != nil { return "api" }
            return ClaudeCodeBackend.locate() != nil ? "cli" : nil
        }
    }

    static func backend() throws -> AIBackend {
        switch resolvedSource() {
        case "api": return AnthropicBackend(apiKey: Keychain.apiKey() ?? "")
        case "cli": return ClaudeCodeBackend(executable: ClaudeCodeBackend.locate() ?? "")
        default: throw AIError.noSource
        }
    }
}

// MARK: - Anthropic API (raw HTTP: there is no official Swift SDK)

struct AnthropicBackend: AIBackend {
    let apiKey: String

    func run(_ request: AIRequest) async throws -> [String: Any] {
        // Models with safety classifiers can decline a request; "default" fallbacks re-run it server-side.
        let supportsFallback = ["claude-opus-5-5", "claude-fable-5-1", "claude-sonnet-5-5"].contains(request.model)
        do {
            return try await send(request, fallbacks: supportsFallback)
        } catch AIError.failed(let message) where supportsFallback && message.lowercased().contains("fallback") {
            return try await send(request, fallbacks: false)
        }
    }

    private func send(_ request: AIRequest, fallbacks: Bool) async throws -> [String: Any] {
        var content: [[String: Any]] = request.images.map {
            ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": $0.base64EncodedString()]]
        }
        content.append(["type": "text", "text": request.text])
        var body: [String: Any] = [
            "model": request.model,
            "max_tokens": 16000,
            "thinking": ["type": "adaptive"],
            "output_config": ["effort": "high", "format": ["type": "json_schema", "schema": request.schema]],
            "system": request.system,
            "messages": [["role": "user", "content": content]],
        ]
        if fallbacks { body["fallbacks"] = "default" }

        var http = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        http.httpMethod = "POST"
        http.timeoutInterval = 600
        http.setValue("application/json", forHTTPHeaderField: "content-type")
        http.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        http.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        if fallbacks { http.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta") }
        http.httpBody = try JSONSerialization.data(withJSONObject: body)

        var attempt = 0
        while true {
            attempt += 1
            let (data, response) = try await URLSession.shared.data(for: http)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            if status == 200 {
                return try Self.parse(json)
            }
            let message = ((json["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \(status)"
            let retryable = status == 429 || status == 408 || status >= 500
            if retryable && attempt < 3 {
                let wait = Double((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "retry-after") ?? "") ?? Double(attempt * 4)
                try await Task.sleep(nanoseconds: UInt64(min(wait, 30) * 1_000_000_000))
                continue
            }
            if status == 401 {
                throw AIError.failed(L("The API key was not accepted. Check it in Settings.",
                                       "Der API-Key wurde nicht akzeptiert. Prüfe ihn in den Einstellungen."))
            }
            throw AIError.failed("Anthropic API: \(message)")
        }
    }

    private static func parse(_ json: [String: Any]) throws -> [String: Any] {
        let stop = json["stop_reason"] as? String
        if stop == "refusal" { throw AIError.refused }
        if stop == "max_tokens" {
            throw AIError.failed(L("The answer was cut off because it got too long. Ask for a smaller part of the page.",
                                   "Die Antwort wurde abgeschnitten, weil sie zu lang wurde. Frag nach einem kleineren Teil der Seite."))
        }
        let blocks = json["content"] as? [[String: Any]] ?? []
        guard let text = blocks.last(where: { $0["type"] as? String == "text" })?["text"] as? String,
              let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
        else { throw AIError.badOutput }
        return object
    }
}

// MARK: - Claude Code (uses the person's own Claude login, no key needed)

struct ClaudeCodeBackend: AIBackend {
    let executable: String

    static func locate() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                          "\(home)/.claude/local/claude", "\(home)/.npm-global/bin/claude"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func run(_ request: AIRequest) async throws -> [String: Any] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("blanko-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var prompt = ""
        if !request.images.isEmpty {
            var names: [String] = []
            for (i, png) in request.images.enumerated() {
                let name = "image-\(i + 1).png"
                try png.write(to: dir.appendingPathComponent(name))
                names.append(dir.appendingPathComponent(name).path)
            }
            prompt += "The images for this turn are files. Read each of them with the Read tool before you answer, in this order:\n"
            prompt += names.joined(separator: "\n") + "\n\n"
        }
        prompt += request.text

        let schema = String(data: try JSONSerialization.data(withJSONObject: request.schema), encoding: .utf8) ?? "{}"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.currentDirectoryURL = dir
        process.arguments = [
            "-p", "--output-format", "json", "--json-schema", schema,
            "--model", request.model, "--effort", "high",
            "--system-prompt", request.system,
            "--tools", "Read", "--setting-sources", "", "--strict-mcp-config",
            "--no-session-persistence", "--disable-slash-commands",
        ]
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        env.removeValue(forKey: "ANTHROPIC_API_KEY")
        process.environment = env

        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        let output: Data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try process.run()
                        stdin.fileHandleForWriting.write(Data(prompt.utf8))
                        try? stdin.fileHandleForWriting.close()
                        let data = stdout.fileHandleForReading.readDataToEndOfFile()
                        let err = stderr.fileHandleForReading.readDataToEndOfFile()
                        process.waitUntilExit()
                        if data.isEmpty {
                            let text = String(data: err, encoding: .utf8) ?? ""
                            cont.resume(throwing: AIError.failed("Claude Code: " + (text.isEmpty ? "no output" : String(text.prefix(400)))))
                        } else {
                            cont.resume(returning: data)
                        }
                    } catch {
                        cont.resume(throwing: AIError.failed("Claude Code: \(error.localizedDescription)"))
                    }
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        try Task.checkCancellation()

        guard let json = (try? JSONSerialization.jsonObject(with: output)) as? [String: Any] else {
            throw AIError.failed("Claude Code: " + String((String(data: output, encoding: .utf8) ?? "").prefix(400)))
        }
        if json["is_error"] as? Bool == true {
            throw AIError.failed("Claude Code: " + String(((json["result"] as? String) ?? "error").prefix(400)))
        }
        if let object = json["structured_output"] as? [String: Any] { return object }
        if let text = json["result"] as? String,
           let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] {
            return object
        }
        throw AIError.badOutput
    }
}

// MARK: - Keychain

enum Keychain {
    private static let service = "com.koreluyar.blanko"
    private static let account = "anthropic-api-key"
    private static var cached: String??

    static func apiKey() -> String? {
        if let cached { return cached }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true]
        var item: CFTypeRef?
        var value: String?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data {
            value = String(data: data, encoding: .utf8)
        }
        if value?.isEmpty == true { value = nil }
        cached = .some(value)
        return value
    }

    static func setAPIKey(_ key: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            var add = base
            add[kSecValueData as String] = Data(trimmed.utf8)
            SecItemAdd(add as CFDictionary, nil)
        }
        cached = .some(trimmed.isEmpty ? nil : trimmed)
    }
}
