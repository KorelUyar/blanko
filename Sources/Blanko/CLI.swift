import AppKit
import PDFKit

/// Headless modes, used to test the pipeline without the window:
///   Blanko --inspect <pdf> <page> <outdir>        writes clean.png, map.png, context.txt
///   Blanko --solve <pdf> <out.pdf> [--page N | --all] [--prompt "..."] [--no-check]
///   Blanko --render <pdf> <page> <out.png>
enum CLI {
    static func handle(_ args: [String]) -> Bool {
        guard args.count > 1, ["--inspect", "--solve", "--render"].contains(args[1]) else { return false }
        Task { @MainActor in
            do {
                try await run(Array(args.dropFirst()))
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        RunLoop.main.run()
        return true
    }

    @MainActor
    private static func run(_ a: [String]) async throws {
        func fail(_ m: String) -> Error { AIError.failed(m) }
        switch a[0] {
        case "--inspect":
            guard a.count >= 4, let doc = PDFDocument(url: URL(fileURLWithPath: a[1])),
                  let n = Int(a[2]), let page = doc.page(at: n - 1) else { throw fail("usage") }
            let out = URL(fileURLWithPath: a[3])
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let snap = PageInspector.snapshot(page, index: n - 1)
            try snap.cleanPNG.write(to: out.appendingPathComponent("clean.png"))
            try snap.mapPNG.write(to: out.appendingPathComponent("map.png"))
            try PageInspector.describe(snap).write(to: out.appendingPathComponent("context.txt"), atomically: true, encoding: .utf8)
            print("fields \(snap.fields.count), rules \(snap.rules.count), lines \(snap.lines.count), notes \(snap.notes.count)")
        case "--render":
            guard a.count >= 4, let doc = PDFDocument(url: URL(fileURLWithPath: a[1])),
                  let n = Int(a[2]), let page = doc.page(at: n - 1) else { throw fail("usage") }
            try PageInspector.render(page, scale: 2, overlay: nil).write(to: URL(fileURLWithPath: a[3]))
        case "--solve":
            guard a.count >= 3, let doc = PDFDocument(url: URL(fileURLWithPath: a[1])) else { throw fail("usage") }
            Notes.adopt(doc)
            var pages = [0]
            var prompt = "Solve this page."
            var check = true
            var i = 3
            while i < a.count {
                switch a[i] {
                case "--page": pages = [(Int(a[i + 1]) ?? 1) - 1]; i += 1
                case "--all": pages = Array(0..<doc.pageCount)
                case "--prompt": prompt = a[i + 1]; i += 1
                case "--no-check": check = false
                default: break
                }
                i += 1
            }
            _ = await ClaudeCodeBackend.readyEnvironment()
            let backend = try AI.backend()
            for p in pages {
                let start = Date()
                let r = try await Solver.run(document: doc, pageIndex: p, name: URL(fileURLWithPath: a[1]).lastPathComponent,
                                             userText: prompt, history: "", backend: backend,
                                             model: Prefs.shared.aiModel, doubleCheck: check, onApplied: {})
                print("page \(p + 1): filled \(r.filled), written \(r.written), erased \(r.erased), changes \(r.changes.count), \(Int(Date().timeIntervalSince(start)))s")
                print(r.reply)
            }
            guard doc.write(to: URL(fileURLWithPath: a[2])) else { throw fail("could not write \(a[2])") }
        default:
            throw fail("usage")
        }
    }
}
