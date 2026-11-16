import PDFKit
import SwiftUI

struct ReaderView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var model: ReaderModel
    @AppStorage("showChat") private var showChat = true

    var body: some View {
        HStack(spacing: 0) {
            PDFCanvas(model: model)
                .frame(minWidth: 380)
                .allowsHitTesting(!model.saving)
            if showChat {
                Divider()
                ChatPanel(model: model)
                    .frame(width: 350)
                    .transition(.move(edge: .trailing))
            }
        }
        .navigationTitle(model.name)
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { app.closeReader() } label: { Label(L("Library", "Bibliothek"), systemImage: "chevron.left") }
                    .help(L("Back to all PDFs", "Zurück zu allen PDFs"))
            }
            ToolbarItemGroup {
                Picker(L("Tool", "Werkzeug"), selection: $model.tool) {
                    Image(systemName: "cursorarrow").tag(Tool.pointer)
                        .help(L("Fill in fields, select and move text", "Felder ausfüllen, Text auswählen und verschieben"))
                    Image(systemName: "character.cursor.ibeam").tag(Tool.text)
                        .help(L("Click anywhere on the page to write", "Irgendwo auf die Seite klicken und schreiben"))
                }
                .pickerStyle(.segmented)

                ControlGroup {
                    Button { resize(-1) } label: { Label(L("Smaller text", "Text kleiner"), systemImage: "textformat.size.smaller") }
                    Button { resize(1) } label: { Label(L("Larger text", "Text grösser"), systemImage: "textformat.size.larger") }
                }
                .help(L("Text size: \(Int(model.textSize)) pt", "Textgrösse: \(Int(model.textSize)) pt"))

                ControlGroup {
                    Button { model.canvas?.zoomOut(nil) } label: { Label(L("Zoom out", "Verkleinern"), systemImage: "minus.magnifyingglass") }
                    Button { model.canvas?.zoomIn(nil) } label: { Label(L("Zoom in", "Vergrössern"), systemImage: "plus.magnifyingglass") }
                }

                Button { app.save() } label: { Label(L("Save", "Sichern"), systemImage: "square.and.arrow.down") }
                    .disabled(!model.dirty || model.saving)
                    .help(L("Save the answers into the PDF (⌘S)", "Antworten ins PDF sichern (⌘S)"))

                Button { withAnimation(.easeOut(duration: 0.18)) { showChat.toggle() } } label: {
                    Label(L("Assistant", "Assistent"), systemImage: "sidebar.right")
                }
                .help(L("Show or hide the assistant", "Assistent ein- oder ausblenden"))
            }
        }
    }

    private var subtitle: String {
        let page = L("Page \(model.pageIndex + 1) of \(model.document.pageCount)",
                     "Seite \(model.pageIndex + 1) von \(model.document.pageCount)")
        if model.saving { return page + " · " + L("saving…", "sichert…") }
        return model.dirty ? page + " · " + L("not saved", "nicht gesichert") : page
    }

    private func resize(_ step: CGFloat) {
        model.textSize = min(48, max(6, model.textSize + step))
        model.canvas?.setSelectedSize(model.textSize)
    }
}

// MARK: - Chat

struct ChatPanel: View {
    @ObservedObject var model: ReaderModel
    @EnvironmentObject var prefs: Prefs
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if model.messages.isEmpty { starter } else { thread }
            Divider()
            composer
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var starter: some View {
        VStack(alignment: .leading, spacing: 14) {
            Spacer()
            Text(L("What should happen on this page?", "Was soll auf dieser Seite passieren?"))
                .font(.title3.weight(.semibold))
            Text(L("The answers are written into the PDF itself, not only here.",
                   "Die Antworten landen im PDF selbst, nicht nur hier."))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 8) {
                suggestion(L("Solve this page", "Löse diese Seite"), "pencil.line") {
                    model.send(L("Solve this page.", "Löse diese Seite."))
                }
                if model.document.pageCount > 1 {
                    suggestion(L("Solve the whole PDF", "Löse das ganze PDF"), "doc.on.doc") {
                        model.send(L("Solve this page.", "Löse diese Seite."), wholeDocument: true)
                    }
                }
                suggestion(L("Explain this page to me", "Erklär mir diese Seite"), "lightbulb") {
                    model.send(L("Explain what this page asks for and how to approach it. Do not fill anything in.",
                                 "Erklär mir, was auf dieser Seite verlangt wird und wie man es angeht. Füll nichts aus."))
                }
            }
            .padding(.top, 4)
            if AI.resolvedSource() == nil {
                Label(L("No AI source yet. Open Settings (⌘,) to add one.",
                        "Noch keine KI-Quelle. Öffne die Einstellungen (⌘,), um eine einzurichten."),
                      systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func suggestion(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).frame(width: 18).foregroundStyle(Ink.accent)
                Text(title)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.busy)
    }

    private var thread: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(model.messages) { message in
                        MessageRow(message: message, model: model).id(message.id)
                    }
                    if model.busy {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(model.status).font(.callout).foregroundStyle(.secondary)
                        }
                        .id("busy")
                    }
                }
                .padding(16)
            }
            .onChange(of: model.messages.count) { _, _ in
                if let last = model.messages.last {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .onAppear { if let last = model.messages.last { proxy.scrollTo(last.id, anchor: .bottom) } }
        }
    }

    private var composer: some View {
        VStack(spacing: 8) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField(L("Ask, or say what to fill in…", "Frag etwas oder sag, was ausgefüllt werden soll…"),
                          text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .focused($focused)
                    .onSubmit(submit)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.13)))
                if model.busy {
                    Button(action: model.stop) {
                        Image(systemName: "stop.circle.fill").font(.system(size: 24))
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help(L("Stop", "Abbrechen"))
                } else {
                    Button(action: submit) {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 24))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(draft.trimmingCharacters(in: .whitespaces).isEmpty ? Color.secondary.opacity(0.5) : Ink.accent)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help(L("Send (Return)", "Senden (Eingabetaste)"))
                }
            }
            HStack {
                Text(sourceLabel).font(.caption).foregroundStyle(.tertiary)
                Spacer()
                if !model.messages.isEmpty && !model.busy {
                    Button(L("Clear chat", "Chat leeren")) { model.clearChat() }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
    }

    private var sourceLabel: String {
        let model = Prefs.models.first { $0.id == prefs.aiModel }?.name ?? prefs.aiModel
        switch AI.resolvedSource() {
        case "api": return model + " · API"
        case "cli": return model + " · Claude Code"
        default: return L("No AI source", "Keine KI-Quelle")
        }
    }

    private func submit() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !model.busy else { return }
        draft = ""
        model.send(text)
    }
}

private struct MessageRow: View {
    let message: ChatMessage
    @ObservedObject var model: ReaderModel

    var body: some View {
        switch message.role {
        case "user":
            HStack {
                Spacer(minLength: 40)
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 11).padding(.vertical, 7)
                    .background(Ink.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 11))
            }
        case "error":
            Label(message.text, systemImage: "exclamationmark.triangle")
                .font(.callout).foregroundStyle(.red)
                .textSelection(.enabled)
        default:
            VStack(alignment: .leading, spacing: 7) {
                Text(rendered).textSelection(.enabled).lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if message.summary != nil || model.undoable.contains(message.id) {
                    HStack(spacing: 8) {
                        if let page = message.page, let summary = message.summary {
                            Button {
                                if let p = model.document.page(at: page) { model.canvas?.go(to: p) }
                            } label: {
                                Label(L("Page \(page + 1)", "Seite \(page + 1)") + ": " + summary, systemImage: "checkmark.circle")
                            }
                            .buttonStyle(.plain)
                            .help(L("Go to this page", "Zu dieser Seite springen"))
                        }
                        Spacer()
                        if model.undoable.contains(message.id) {
                            Button(L("Undo", "Rückgängig")) { model.undo(message.id) }
                                .buttonStyle(.link)
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var rendered: AttributedString {
        (try? AttributedString(markdown: message.text,
                               options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(message.text)
    }
}
