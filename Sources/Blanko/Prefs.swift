import SwiftUI

/// App-wide preferences. English is the default language; German is a choice inside the app.
final class Prefs: ObservableObject {
    static let shared = Prefs()

    @AppStorage("lang") var lang: String = "en" { willSet { objectWillChange.send() } }
    @AppStorage("aiSource") var aiSource: String = "auto" { willSet { objectWillChange.send() } }
    @AppStorage("aiModel") var aiModel: String = "claude-opus-5-5" { willSet { objectWillChange.send() } }
    @AppStorage("doubleCheck") var doubleCheck: Bool = true { willSet { objectWillChange.send() } }

    static let models: [(id: String, name: String)] = [
        ("claude-opus-5-5", "Claude Opus 5.5"),
        ("claude-fable-5-1", "Claude Fable 5.1"),
        ("claude-sonnet-5-5", "Claude Sonnet 5.5"),
        ("claude-haiku-5-5", "Claude Haiku 5.5"),
    ]
}

/// Inline localisation: every string carries both languages where it is used.
func L(_ en: String, _ de: String) -> String {
    Prefs.shared.lang == "de" ? de : en
}

enum Ink {
    /// Answers written by the assistant: pen blue, so they read as "filled in".
    static let ai = NSColor(srgbRed: 0.11, green: 0.25, blue: 0.75, alpha: 1)
    /// Text typed by the person.
    static let user = NSColor(srgbRed: 0.07, green: 0.07, blue: 0.09, alpha: 1)
    /// Interface accent: the pen blue, lifted on dark backgrounds so it stays readable.
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.50, green: 0.64, blue: 1.0, alpha: 1) : ai
    })
}
