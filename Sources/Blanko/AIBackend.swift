import AppKit
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
    /// The source could not be used at all: Claude Code is signed out or its login could not be
    /// renewed, or the API key was refused or has no credit left. `source` is "cli" or "api".
    case access(String, source: String)
    case refused
    case badOutput

    var errorDescription: String? {
        switch self {
        case .noSource:
            return L("No AI source is set up yet. Use an Anthropic API key, or install Claude Code and sign in.",
                     "Noch keine KI-Quelle eingerichtet. Verwende einen Anthropic-API-Key oder installiere Claude Code und melde dich an.")
        case .failed(let m): return m
        case .access(let m, _): return m
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

    /// The chosen source, with the other one (when there is one) standing by: if the first cannot
    /// sign in, the request goes to the second instead of failing.
    static func backend() throws -> AIBackend {
        let api: AIBackend? = Keychain.apiKey().map { AnthropicBackend(apiKey: $0) }
        let cli: AIBackend? = ClaudeCodeBackend.locate().map { ClaudeCodeBackend(executable: $0) }
        switch resolvedSource() {
        case "api": return FallbackBackend(primary: api!, alternate: cli)
        case "cli": return FallbackBackend(primary: cli!, alternate: api)
        default: throw AIError.noSource
        }
    }
}

/// Runs `primary`; when it cannot be used at all (signed out, key refused), runs `alternate`.
/// After one such failure the rest of this request (other pages, the placement check) goes
/// straight to the alternate.
final class FallbackBackend: AIBackend, @unchecked Sendable {
    let primary: AIBackend
    let alternate: AIBackend?
    private let lock = NSLock()
    private var primaryDown = false

    init(primary: AIBackend, alternate: AIBackend?) {
        self.primary = primary
        self.alternate = alternate
    }

    private var skipPrimary: Bool {
        get { lock.withLock { primaryDown } }
        set { lock.withLock { primaryDown = newValue } }
    }

    func run(_ request: AIRequest) async throws -> [String: Any] {
        if skipPrimary, let alternate { return try await alternate.run(request) }
        do {
            return try await primary.run(request)
        } catch AIError.access(let message, let source) {
            guard let alternate else { throw AIError.access(message, source: source) }
            skipPrimary = true
            do {
                return try await alternate.run(request)
            } catch AIError.access {
                // Neither works: report the first one, that is the one the person chose.
                throw AIError.access(message, source: source)
            }
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
            if status == 401 || status == 403 {
                throw AIError.access(L("The API key was not accepted (\(message)).",
                                       "Der API-Key wurde nicht akzeptiert (\(message))."), source: "api")
            }
            if status == 400 && message.lowercased().contains("credit") {
                throw AIError.access(L("The API key has no credit left (\(message)).",
                                       "Auf dem API-Key ist kein Guthaben mehr (\(message))."), source: "api")
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

    /// The environment of the person's own terminal. An app started from the Dock gets none of
    /// what the shell profile sets (PATH, CLAUDE_CONFIG_DIR, tokens), and Claude Code then looks
    /// in the wrong place for its login.
    /// Read once in the background at launch (`prepare`). Never read it on the main thread:
    /// waiting for the shell there re-enters the interface and crashes it.
    private static let lock = NSLock()
    private static var loaded: [String: String]?

    private static var baseEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        // Claude Code finds its keychain entry by user name.
        if env["USER"] == nil { env["USER"] = NSUserName() }
        if env["HOME"] == nil { env["HOME"] = NSHomeDirectory() }
        return env
    }

    /// What is known right now; does not wait.
    static var shellEnvironment: [String: String] {
        lock.lock(); defer { lock.unlock() }
        return loaded ?? baseEnvironment
    }

    static func prepare() {
        DispatchQueue.global(qos: .userInitiated).async {
            let env = readShellEnvironment()
            lock.lock(); loaded = env; lock.unlock()
            DispatchQueue.main.async { Prefs.shared.objectWillChange.send() }
        }
    }

    /// Waits (off the main thread's back) until the shell has answered, at most ten seconds.
    static func readyEnvironment() async -> [String: String] {
        for _ in 0..<100 {
            lock.lock(); let env = loaded; lock.unlock()
            if let env { return env }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return baseEnvironment
    }

    private static func readShellEnvironment() -> [String: String] {
        var env = baseEnvironment
        let shell = env["SHELL"].flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil } ?? "/bin/zsh"
        let marker = "__BLANKO_ENV__"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-ilc", "printf '\(marker)'; command env -0"]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.environment = env
        let out = Pipe()
        process.standardOutput = out
        guard (try? process.run()) != nil else { return env }
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 8, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()
        guard let text = String(data: data, encoding: .utf8), let range = text.range(of: marker) else { return env }
        for entry in text[range.upperBound...].split(separator: "\0") {
            guard let eq = entry.firstIndex(of: "=") else { continue }
            env[String(entry[..<eq])] = String(entry[entry.index(after: eq)...])
        }
        return env
    }

    static func locate() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // The same `claude` the terminal would start, then the usual install places.
        // Absolute folders only: a "." or empty PATH entry would point wherever the app happens to run.
        var candidates = (shellEnvironment["PATH"] ?? "").split(separator: ":").filter { $0.hasPrefix("/") }.map { "\($0)/claude" }
        candidates += ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                       "\(home)/.claude/local/claude", "\(home)/.npm-global/bin/claude"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Whether Claude Code's answer means it could not sign in (as opposed to any other failure).
    static func isSignInProblem(_ message: String) -> Bool {
        let m = message.lowercased()
        return ["not logged in", "failed to authenticate", "authentication", "oauth", "/login", "log in",
                "invalid api key", "unauthorized", "401"].contains { m.contains($0) }
    }

    func run(_ request: AIRequest) async throws -> [String: Any] {
        // 1. As set up. 2. Once more after a moment: the login is renewed by whichever Claude Code
        // on this Mac runs first after it expires, and a fresh process reads the renewed one; two
        // renewing at the same moment is what makes "could not be refreshed" come and go.
        // 3. With the person's own Claude Code settings, where the login may come from (a key helper).
        var last = ""
        for (attempt, sources) in [(0, ""), (1, ""), (2, "user")] {
            do {
                return try await run(request, settingSources: sources)
            } catch AIError.failed(let message) where Self.isSignInProblem(message) {
                last = message.hasPrefix("Claude Code: ") ? String(message.dropFirst(13)) : message
                if attempt == 0 { try await Task.sleep(nanoseconds: 2_500_000_000) }
            }
        }
        throw AIError.access(L(
            "Claude Code could not sign in. \(last)\nSign in to Claude Code again, or use an Anthropic API key instead.",
            "Claude Code konnte sich nicht anmelden. \(last)\nMelde dich bei Claude Code neu an oder verwende stattdessen einen Anthropic-API-Key."),
            source: "cli")
    }

    /// Opens Terminal with `claude auth login`: a browser window opens for the Claude sign-in.
    @MainActor
    static func openSignIn() {
        guard let exe = locate() else { return }
        let quoted = "'" + exe.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let script = """
        #!/bin/zsh -l
        clear
        echo 'Blanko: signing in to Claude Code. A browser window opens; finish the sign-in there.'
        echo
        \(quoted) auth login
        echo
        echo 'Done. Close this window and press "Try again" in Blanko.'

        """
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Blanko sign-in.command")
        try? FileManager.default.removeItem(at: file)
        guard (try? script.write(to: file, atomically: true, encoding: .utf8)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([file], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    /// `claude auth status`: signed in, and until when. Nil when Claude Code does not answer.
    static func authStatus() async -> (loggedIn: Bool, expires: Date?)? {
        guard let exe = locate() else { return nil }
        let env = await readyEnvironment()
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: exe)
                process.arguments = ["auth", "status", "--json"]
                process.environment = env
                process.currentDirectoryURL = FileManager.default.temporaryDirectory
                process.standardInput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                let out = Pipe()
                process.standardOutput = out
                guard (try? process.run()) != nil else { return cont.resume(returning: nil) }
                let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: killer)
                let data = out.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                killer.cancel()
                guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                    return cont.resume(returning: nil)
                }
                let expires = (json["loginExpiresAt"] as? String).flatMap { s -> Date? in
                    let f = ISO8601DateFormatter()
                    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
                }
                cont.resume(returning: (json["loggedIn"] as? Bool ?? false, expires))
            }
        }
    }

    private func run(_ request: AIRequest, settingSources: String) async throws -> [String: Any] {
        // An empty folder of its own as the working directory, so nothing of the Mac is in reach.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("blanko-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // The images travel inside the message itself (stream-json input), so Claude Code needs no
        // tool at all: a PDF that tells the model to read files has nothing to read them with.
        var content: [[String: Any]] = request.images.map {
            ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": $0.base64EncodedString()]]
        }
        content.append(["type": "text", "text": request.text])
        let message: [String: Any] = ["type": "user", "message": ["role": "user", "content": content]]
        var input = try JSONSerialization.data(withJSONObject: message)
        input.append(0x0A)

        let schema = String(data: try JSONSerialization.data(withJSONObject: request.schema), encoding: .utf8) ?? "{}"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.currentDirectoryURL = dir
        process.arguments = [
            "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--json-schema", schema,
            "--model", request.model, "--effort", "high",
            "--system-prompt", request.system,
            "--tools", "", "--setting-sources", settingSources, "--strict-mcp-config",
            "--no-session-persistence", "--disable-slash-commands",
        ]
        var env = await Self.readyEnvironment()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = (env["PATH"] ?? "") + ":\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
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
                        // Read the error stream alongside, so a chatty one cannot fill its pipe and stall both sides.
                        let errBox = DataBox()
                        let errDone = DispatchSemaphore(value: 0)
                        DispatchQueue.global(qos: .utility).async {
                            errBox.data = stderr.fileHandleForReading.readDataToEndOfFile()
                            errDone.signal()
                        }
                        stdin.fileHandleForWriting.write(input)
                        try? stdin.fileHandleForWriting.close()
                        let data = stdout.fileHandleForReading.readDataToEndOfFile()
                        errDone.wait()
                        let err = errBox.data
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

        // One JSON object per line; the answer is the last line of type "result".
        let lines = output.split(separator: 0x0A)
        let result = lines.reversed().lazy
            .compactMap { (try? JSONSerialization.jsonObject(with: Data($0))) as? [String: Any] }
            .first { $0["type"] as? String == "result" }
        guard let json = result else {
            let last = lines.last.map { String(decoding: $0, as: UTF8.self) } ?? ""
            throw AIError.failed("Claude Code: " + String(last.prefix(400)))
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

/// Bytes filled in on one thread and read on another after a semaphore.
private final class DataBox: @unchecked Sendable {
    var data = Data()
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
