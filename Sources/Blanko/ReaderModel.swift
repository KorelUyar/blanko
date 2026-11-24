import AppKit
import CryptoKit
import PDFKit

enum Tool: String {
    case pointer, text
}

struct ChatMessage: Identifiable, Codable, Equatable {
    var id = UUID()
    var role: String            // user | assistant | error
    var text: String
    var page: Int?              // page the assistant worked on (0-based)
    var summary: String?        // what was changed on the page
    var fix: String?            // error only: which way out to offer: "cli" (sign in again), "api" (the key), "none" (no source)
}

/// One open PDF: the document, the tool state and its chat.
@MainActor
final class ReaderModel: ObservableObject {
    let url: URL
    let document: PDFDocument

    @Published var tool: Tool = .pointer
    @Published var textSize: CGFloat = 12
    @Published var dirty = false
    @Published var pageIndex = 0
    @Published var messages: [ChatMessage] = []
    @Published var busy = false
    @Published var status = ""
    @Published var undoable: Set<UUID> = []
    @Published var hasSelection = false
    @Published var saving = false
    @Published var savingSince = Date()

    /// The sheet for entering an Anthropic API key, opened from an error in the chat.
    @Published var showKeySheet = false

    weak var canvas: CanvasView?
    private var changes: [UUID: [Change]] = [:]
    private var task: Task<Void, Never>?
    private var lastRequest: (text: String, wholeDocument: Bool, page: Int)?

    var name: String { url.lastPathComponent }

    init(url: URL, document: PDFDocument) {
        self.url = url
        self.document = document
        Notes.adopt(document)
        messages = Self.loadChat(for: url)
    }

    // MARK: Chat

    func send(_ text: String, wholeDocument: Bool = false, page: Int? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !busy else { return }
        canvas?.commitEditing()
        let history = historyText()
        messages.append(ChatMessage(role: "user", text: trimmed))
        busy = true
        lastRequest = (trimmed, wholeDocument, page ?? pageIndex)

        let pages = wholeDocument ? Array(0..<document.pageCount) : [lastRequest!.page]
        task = Task { [weak self] in
            guard let self else { return }
            do {
                _ = await ClaudeCodeBackend.readyEnvironment()
                let backend = try AI.backend()
                let model = Prefs.shared.aiModel
                let check = Prefs.shared.doubleCheck
                var next = 0
                var done = 0
                var firstError: Error?
                self.status = self.statusText(done: 0, of: pages.count, page: pages[0])

                // Up to three pages at a time; each page is its own request.
                await withTaskGroup(of: Void.self) { group in
                    for _ in 0..<min(3, pages.count) {
                        group.addTask { @MainActor in
                            while next < pages.count, !Task.isCancelled, firstError == nil {
                                let page = pages[next]
                                next += 1
                                do {
                                    let result = try await Solver.run(
                                        document: self.document, pageIndex: page, name: self.name, userText: trimmed,
                                        history: history, backend: backend, model: model, doubleCheck: check,
                                        wholeDocument: pages.count > 1,
                                        onApplied: { self.pageChanged() })
                                    self.finish(result, page: page, showPage: pages.count > 1)
                                } catch is CancellationError {
                                    return
                                } catch {
                                    if firstError == nil { firstError = error }
                                }
                                done += 1
                                if done < pages.count {
                                    self.status = self.statusText(done: done, of: pages.count, page: pages[min(next, pages.count - 1)])
                                }
                            }
                        }
                    }
                }
                if let firstError, !Task.isCancelled {
                    self.messages.append(Self.errorMessage(firstError))
                }
            } catch {
                self.messages.append(Self.errorMessage(error))
            }
            self.busy = false
            self.status = ""
            self.saveChat()
        }
    }

    func stop() {
        task?.cancel()
        busy = false
        status = ""
    }

    /// An error for the chat, with the way out the buttons under it offer.
    private static func errorMessage(_ error: Error) -> ChatMessage {
        var message = ChatMessage(role: "error", text: error.localizedDescription)
        switch error {
        case AIError.access(_, let source): message.fix = source
        case AIError.noSource: message.fix = "none"
        default: break
        }
        return message
    }

    /// Sends the last request again, in place of the error it ended with.
    func retry() {
        guard !busy else { return }
        let request = lastRequest
            ?? messages.last(where: { $0.role == "user" }).map { ($0.text, false, pageIndex) }
        guard let request else { return }
        // Drop the failed attempt: the error and the question it answered.
        while let last = messages.last, last.role == "error" { messages.removeLast() }
        if let last = messages.last, last.role == "user", last.text == request.text { messages.removeLast() }
        if !request.wholeDocument, let page = document.page(at: request.page) { canvas?.go(to: page) }
        send(request.text, wholeDocument: request.wholeDocument, page: request.page)
    }

    private func statusText(done: Int, of total: Int, page: Int) -> String {
        if total == 1 { return L("Working on page \(page + 1)…", "Arbeite an Seite \(page + 1)…") }
        return L("Working through the document: \(done) of \(total) pages done…",
                 "Arbeite das Dokument durch: \(done) von \(total) Seiten fertig…")
    }

    private func finish(_ result: SolveResult, page: Int, showPage: Bool) {
        var parts: [String] = []
        if result.filled > 0 { parts.append(L("\(result.filled) fields filled", "\(result.filled) Felder ausgefüllt")) }
        if result.written > 0 { parts.append(L("\(result.written) answers written", "\(result.written) Antworten geschrieben")) }
        if result.erased > 0 { parts.append(L("\(result.erased) removed", "\(result.erased) entfernt")) }
        var message = ChatMessage(role: "assistant", text: result.reply.isEmpty ? L("Done.", "Erledigt.") : result.reply,
                                  page: page, summary: parts.isEmpty ? nil : parts.joined(separator: ", "))
        if showPage && parts.isEmpty && result.reply.isEmpty { message.text = L("Nothing to do on this page.", "Auf dieser Seite gab es nichts zu tun.") }
        messages.append(message)
        if !result.changes.isEmpty {
            changes[message.id] = result.changes
            undoable.insert(message.id)
            dirty = true
        }
        pageChanged()
    }

    func undo(_ id: UUID) {
        guard let list = changes[id] else { return }
        Solver.undo(list)
        changes[id] = nil
        undoable.remove(id)
        dirty = true
        pageChanged()
    }

    private func historyText() -> String {
        messages.suffix(8).filter { $0.role != "error" }.map { m in
            var line = (m.role == "user" ? "Person: " : "You: ") + m.text
            if let s = m.summary, let p = m.page { line += " [on page \(p + 1): \(s)]" }
            return line
        }.joined(separator: "\n")
    }

    func clearChat() {
        messages = []
        saveChat()
    }

    /// The page content changed underneath the view.
    func pageChanged() {
        canvas?.refresh()
    }

    // MARK: Saving

    func save() -> Bool {
        canvas?.commitEditing()
        canvas?.window?.makeFirstResponder(canvas)
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).pdf")
        guard document.write(to: temp) else {
            try? FileManager.default.removeItem(at: temp)
            return false
        }
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
            dirty = false
            return true
        } catch {
            try? FileManager.default.removeItem(at: temp)
            return false
        }
    }

    /// Saves without holding up the window: the writing happens off the main thread, the page is
    /// locked against edits meanwhile.
    func saveInBackground(_ done: @escaping (Bool) -> Void) {
        guard !saving else { return }
        canvas?.commitEditing()
        canvas?.window?.makeFirstResponder(canvas)
        saving = true
        savingSince = Date()
        dirty = false
        let document = self.document, url = self.url
        DispatchQueue.global(qos: .userInitiated).async {
            let temp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).pdf")
            var ok = document.write(to: temp)
            if ok {
                ok = (try? FileManager.default.replaceItemAt(url, withItemAt: temp)) != nil
            }
            if !ok { try? FileManager.default.removeItem(at: temp) }
            let result = ok
            DispatchQueue.main.async {
                self.saving = false
                if !result { self.dirty = true }
                done(result)
            }
        }
    }

    func saveCopy(to target: URL) -> Bool {
        canvas?.commitEditing()
        canvas?.window?.makeFirstResponder(canvas)
        return document.write(to: target)
    }

    // MARK: Chat storage (one small file per document, next to the app's other data)

    private static func chatFile(for url: URL) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Blanko/chats", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let hash = SHA256.hash(data: Data(url.path.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent("\(hash).json")
    }

    private static func loadChat(for url: URL) -> [ChatMessage] {
        guard let data = try? Data(contentsOf: chatFile(for: url)) else { return [] }
        return (try? JSONDecoder().decode([ChatMessage].self, from: data)) ?? []
    }

    private func saveChat() {
        let file = Self.chatFile(for: url)
        if messages.isEmpty {
            try? FileManager.default.removeItem(at: file)
        } else if let data = try? JSONEncoder().encode(messages.suffix(200)) {
            try? data.write(to: file, options: .atomic)
        }
    }
}
