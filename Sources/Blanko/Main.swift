import PDFKit
import SwiftUI
import UniformTypeIdentifiers

@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        if CLI.handle(args) { return }
        // Launch options for testing: --library-dir <dir>, --open <pdf>, --ask "<message>"
        if let i = args.firstIndex(of: "--library-dir"), i + 1 < args.count {
            LibraryStore.overrideDirectory = URL(fileURLWithPath: args[i + 1])
        }
        if let i = args.firstIndex(of: "--library-extra"), i + 1 < args.count {
            LibraryStore.extraDirectory = URL(fileURLWithPath: args[i + 1])
        }
        BlankoApp.main()
    }
}

struct BlankoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var app = AppState.shared
    @StateObject private var prefs = Prefs.shared

    var body: some Scene {
        Window("Blanko", id: "main") {
            RootView()
                .environmentObject(app)
                .environmentObject(prefs)
                .frame(minWidth: 860, minHeight: 560)
        }
        .defaultSize(width: 1240, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L("Open…", "Öffnen…")) { app.openPanel() }.keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button(L("Save", "Sichern")) { app.save() }
                    .keyboardShortcut("s").disabled(app.reader == nil)
                Button(L("Save a Copy…", "Kopie sichern…")) { app.saveCopy() }
                    .keyboardShortcut("s", modifiers: [.command, .shift]).disabled(app.reader == nil)
                Divider()
                Button(L("Back to Library", "Zurück zur Bibliothek")) { app.closeReader() }
                    .keyboardShortcut("w").disabled(app.reader == nil)
            }
            CommandMenu(L("Tools", "Werkzeuge")) {
                Button(L("Pointer", "Zeiger")) { app.reader?.tool = .pointer }.keyboardShortcut("1")
                Button(L("Write Text", "Text schreiben")) { app.reader?.tool = .text }.keyboardShortcut("2")
            }
        }

        SwiftUI.Settings {
            SettingsView().environmentObject(prefs)
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()
    @Published var reader: ReaderModel?
    let library = LibraryStore()

    func open(_ url: URL) {
        if reader?.url == url { return }
        guard confirmLeaving() else { return }
        guard let document = PDFDocument(url: url) else {
            alert(L("This file could not be opened as a PDF.", "Diese Datei liess sich nicht als PDF öffnen."), url.lastPathComponent)
            return
        }
        if document.isLocked {
            alert(L("This PDF is protected with a password.", "Dieses PDF ist mit einem Passwort geschützt."),
                  L("Password-protected PDFs are not supported yet.", "Passwortgeschützte PDFs werden noch nicht unterstützt."))
            return
        }
        library.noteOpened(url)
        reader = ReaderModel(url: url, document: document)
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func closeReader() {
        guard confirmLeaving() else { return }
        reader = nil
    }

    func save() {
        guard let reader else { return }
        if !reader.save() {
            alert(L("The PDF could not be saved.", "Das PDF liess sich nicht sichern."),
                  L("Try \"Save a Copy…\" to write it somewhere else.", "Versuch «Kopie sichern…», um es woanders abzulegen."))
        }
    }

    func saveCopy() {
        guard let reader else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = reader.url.deletingPathExtension().lastPathComponent + L(" (filled in)", " (ausgefüllt)") + ".pdf"
        panel.directoryURL = reader.url.deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url, !reader.saveCopy(to: url) {
            alert(L("The copy could not be saved.", "Die Kopie liess sich nicht sichern."), url.path)
        }
    }

    /// Asks what to do with unsaved answers. Returns false when the person cancels.
    func confirmLeaving() -> Bool {
        guard let reader, reader.dirty else { return true }
        let a = NSAlert()
        a.messageText = L("Save the changes to \"\(reader.name)\"?", "Änderungen an «\(reader.name)» sichern?")
        a.informativeText = L("Otherwise what was filled in is lost.", "Sonst geht das Ausgefüllte verloren.")
        a.addButton(withTitle: L("Save", "Sichern"))
        a.addButton(withTitle: L("Cancel", "Abbrechen"))
        a.addButton(withTitle: L("Don't Save", "Nicht sichern"))
        switch a.runModal() {
        case .alertFirstButtonReturn: return reader.save()
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    private func alert(_ title: String, _ detail: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = detail
        a.runModal()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--open"), i + 1 < args.count {
            AppState.shared.open(URL(fileURLWithPath: args[i + 1]))
            if let j = args.firstIndex(of: "--ask"), j + 1 < args.count {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { AppState.shared.reader?.send(args[j + 1]) }
            }
        }
        if let i = args.firstIndex(of: "--uitest"), i + 1 < args.count {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { UITest.run(args[i + 1]) }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first(where: { $0.pathExtension.lowercased() == "pdf" }) { AppState.shared.open(url) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppState.shared.confirmLeaving() ? .terminateNow : .terminateCancel
    }
}

struct RootView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var prefs: Prefs

    var body: some View {
        Group {
            if let reader = app.reader {
                ReaderView(model: reader).id(reader.url)
            } else {
                LibraryView(store: app.library)
            }
        }
        .id(prefs.lang)
        .tint(Ink.accent)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var prefs: Prefs
    @State private var key = ""
    @State private var hasKey = Keychain.apiKey() != nil

    var body: some View {
        Form {
            Section {
                Picker(L("Language", "Sprache"), selection: $prefs.lang) {
                    Text("English").tag("en")
                    Text("Deutsch").tag("de")
                }
            }
            Section(L("Assistant", "Assistent")) {
                Picker(L("Runs through", "Läuft über"), selection: $prefs.aiSource) {
                    Text(L("Automatic", "Automatisch")).tag("auto")
                    Text("Claude Code").tag("cli")
                    Text(L("Anthropic API key", "Anthropic-API-Key")).tag("api")
                }
                LabeledContent("Claude Code") {
                    Text(ClaudeCodeBackend.locate() != nil
                         ? L("Found. Uses your Claude login, no key needed.", "Gefunden. Nutzt dein Claude-Login, kein Key nötig.")
                         : L("Not installed on this Mac.", "Auf diesem Mac nicht installiert."))
                        .foregroundStyle(.secondary)
                }
                LabeledContent(L("API key", "API-Key")) {
                    HStack {
                        SecureField(hasKey ? L("Saved in the keychain", "Im Schlüsselbund gesichert") : "sk-ant-…", text: $key)
                            .textFieldStyle(.roundedBorder).frame(width: 220)
                        Button(L("Save", "Sichern")) {
                            Keychain.setAPIKey(key)
                            key = ""
                            hasKey = Keychain.apiKey() != nil
                            prefs.objectWillChange.send()
                        }
                        .disabled(key.isEmpty)
                        if hasKey {
                            Button(L("Remove", "Entfernen")) {
                                Keychain.setAPIKey("")
                                hasKey = false
                                prefs.objectWillChange.send()
                            }
                        }
                    }
                }
                Picker(L("Model", "Modell"), selection: $prefs.aiModel) {
                    ForEach(Prefs.models, id: \.id) { Text($0.name).tag($0.id) }
                }
                Toggle(L("Check the placement after writing (slower, tidier)",
                         "Platzierung nach dem Schreiben prüfen (langsamer, sauberer)"), isOn: $prefs.doubleCheck)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .id(prefs.lang)
    }
}
