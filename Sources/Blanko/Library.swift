import AppKit
import QuickLookThumbnailing
import SwiftUI

struct PDFItem: Identifiable, Hashable {
    let url: URL
    let name: String
    let folder: String          // bucket shown in the sidebar: Downloads, Documents, iCloud Drive, …
    let modified: Date
    var id: String { url.path }
}

/// Finds every PDF in the person's home folder through Spotlight and keeps the list current.
@MainActor
final class LibraryStore: NSObject, ObservableObject {
    @Published var items: [PDFItem] = []
    @Published var loading = true
    @Published var recents: [String] = UserDefaults.standard.stringArray(forKey: "recents") ?? []

    private let query = NSMetadataQuery()
    private var started = false
    private var indexed: [PDFItem] = []      // from Spotlight
    private var walked: [PDFItem] = []       // from looking through folders directly
    private var walkedOnce = false
    /// Test hooks: `--library-dir <dir>` lists only that folder; `--library-extra <dir>` stands
    /// in for the personal folders that are walked directly.
    static var overrideDirectory: URL?
    static var extraDirectory: URL?

    func start() {
        guard !started else { return }
        started = true
        if let dir = Self.overrideDirectory {
            walk([dir])
            return
        }
        query.predicate = NSPredicate(format: "kMDItemContentTypeTree == 'com.adobe.pdf'")
        query.searchScopes = [NSMetadataQueryUserHomeScope]
        query.notificationBatchingInterval = 2
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(gathered), name: .NSMetadataQueryDidFinishGathering, object: query)
        nc.addObserver(self, selector: #selector(gathered), name: .NSMetadataQueryDidUpdate, object: query)
        nc.addObserver(self, selector: #selector(walkPersonalFolders), name: NSApplication.didBecomeActiveNotification, object: nil)
        query.start()
        walkPersonalFolders()
    }

    /// Spotlight leaves Desktop, Documents and Downloads out of an app's results until the person
    /// has allowed the app into them, and it never asks. Looking into the folders directly is
    /// what makes macOS ask, and it also covers a Mac where Spotlight is switched off.
    @objc private func walkPersonalFolders() {
        if let extra = Self.extraDirectory {
            walk([extra])
            return
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        walk(["Desktop", "Documents", "Downloads", "Library/Mobile Documents/com~apple~CloudDocs"]
            .map { home.appendingPathComponent($0) })
    }

    @objc private func gathered() {
        query.disableUpdates()
        var found: [PDFItem] = []
        found.reserveCapacity(query.resultCount)
        for i in 0..<query.resultCount {
            guard let item = query.result(at: i) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                  Self.wanted(path) else { continue }
            let date = (item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date) ?? .distantPast
            found.append(Self.item(path: path, modified: date))
        }
        query.enableUpdates()
        indexed = found
        merge()
    }

    private func walk(_ roots: [URL]) {
        Task.detached(priority: .userInitiated) {
            var found: [PDFItem] = []
            for root in roots {
                guard let walker = FileManager.default.enumerator(
                    at: root, includingPropertiesForKeys: [.contentModificationDateKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
                while let url = walker.nextObject() as? URL {
                    guard url.pathExtension.lowercased() == "pdf", Self.wanted(url.path) else { continue }
                    let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    found.append(Self.item(path: url.path, modified: date ?? .distantPast))
                    if found.count >= 20_000 { break }
                }
            }
            let result = found
            await MainActor.run {
                self.walked = result
                self.walkedOnce = true
                self.merge()
            }
        }
    }

    private func merge() {
        var seen = Set<String>()
        var all: [PDFItem] = []
        for item in walked + indexed where seen.insert(item.url.path).inserted { all.append(item) }
        if all != items { items = all }
        if walkedOnce { loading = false }
    }

    /// Leaves out PDFs that belong to software rather than to the person.
    nonisolated private static func wanted(_ path: String) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home + "/Library/") {
            return path.hasPrefix(home + "/Library/Mobile Documents/") || path.hasPrefix(home + "/Library/CloudStorage/")
        }
        // Icons and build output inside code projects are PDFs too, but nobody wants to fill them in.
        for part in ["/.", "/node_modules/", ".app/", "/site-packages/", "/Pods/", ".bundle/", ".framework/",
                     "/vendor/", "/venv/", "/DerivedData/", ".photoslibrary/", ".xcassets/", ".imageset/",
                     "/build/", "/target/"] where path.contains(part) {
            return false
        }
        return true
    }

    nonisolated private static func item(path: String, modified: Date) -> PDFItem {
        let url = URL(fileURLWithPath: path)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var folder = url.deletingLastPathComponent().lastPathComponent
        if path.hasPrefix(home + "/Library/Mobile Documents/") || path.hasPrefix(home + "/Library/CloudStorage/") {
            folder = "iCloud Drive"
        } else if path.hasPrefix(home + "/") {
            let rest = path.dropFirst(home.count + 1).split(separator: "/")
            folder = rest.count > 1 ? String(rest[0]) : L("Home", "Benutzerordner")
        }
        return PDFItem(url: url, name: url.deletingPathExtension().lastPathComponent, folder: folder, modified: modified)
    }

    func noteOpened(_ url: URL) {
        recents.removeAll { $0 == url.path }
        recents.insert(url.path, at: 0)
        if recents.count > 40 { recents = Array(recents.prefix(40)) }
        UserDefaults.standard.set(recents, forKey: "recents")
    }

    var folders: [(name: String, count: Int)] {
        Dictionary(grouping: items, by: \.folder).map { ($0.key, $0.value.count) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
    }
}

// MARK: - Thumbnails

@MainActor
final class Thumbnails {
    static let shared = Thumbnails()
    private let cache = NSCache<NSString, NSImage>()

    func image(for url: URL) async -> NSImage? {
        if let hit = cache.object(forKey: url.path as NSString) { return hit }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 220, height: 290),
                                                   scale: 2, representationTypes: .thumbnail)
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return nil }
        let image = rep.nsImage
        cache.setObject(image, forKey: url.path as NSString)
        return image
    }
}

// MARK: - Views

struct LibraryView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var prefs: Prefs
    @ObservedObject var store: LibraryStore
    @State private var selection: String? = "all"
    @State private var search = ""
    @AppStorage("sortByName") private var sortByName = false

    private var shown: [PDFItem] {
        var list = store.items
        switch selection {
        case "all", nil: break
        case "recent":
            let order = Dictionary(uniqueKeysWithValues: store.recents.enumerated().map { ($1, $0) })
            var recent = list.filter { order[$0.url.path] != nil }
            // Files opened from outside the indexed folders are still "recent".
            let known = Set(recent.map(\.url.path))
            for path in store.recents where !known.contains(path) && FileManager.default.fileExists(atPath: path) {
                let url = URL(fileURLWithPath: path)
                recent.append(PDFItem(url: url, name: url.deletingPathExtension().lastPathComponent,
                                      folder: url.deletingLastPathComponent().lastPathComponent, modified: .distantPast))
            }
            list = recent.sorted { (order[$0.url.path] ?? 0) < (order[$1.url.path] ?? 0) }
        case let folder?: list = list.filter { "folder:" + $0.folder == folder }
        }
        if !search.isEmpty { list = list.filter { $0.name.localizedCaseInsensitiveContains(search) } }
        if selection != "recent" {
            list.sort { sortByName ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : $0.modified > $1.modified }
        }
        return list
    }

    private var title: String {
        switch selection {
        case "recent": return L("Recently opened", "Zuletzt geöffnet")
        case let s? where s.hasPrefix("folder:"): return String(s.dropFirst(7))
        default: return L("All PDFs", "Alle PDFs")
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    Label(L("All PDFs", "Alle PDFs"), systemImage: "doc.on.doc")
                        .badge(store.items.count).tag("all")
                    Label(L("Recently opened", "Zuletzt geöffnet"), systemImage: "clock").tag("recent")
                }
                Section(L("Folders", "Ordner")) {
                    ForEach(store.folders.prefix(14), id: \.name) { folder in
                        Label(folder.name, systemImage: folder.name == "iCloud Drive" ? "icloud" : "folder")
                            .badge(folder.count).tag("folder:" + folder.name)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 215, max: 280)
            .safeAreaInset(edge: .bottom) {
                Picker("", selection: $prefs.lang) {
                    Text("English").tag("en")
                    Text("Deutsch").tag("de")
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small)
                .padding(12)
            }
        } detail: {
            content
                .navigationTitle(title)
                .navigationSubtitle(store.loading ? "" : L("\(shown.count) PDFs", "\(shown.count) PDFs"))
                .searchable(text: $search, prompt: L("Search by name", "Nach Namen suchen"))
                .toolbar {
                    ToolbarItem {
                        Menu {
                            Picker(L("Sort", "Sortierung"), selection: $sortByName) {
                                Text(L("Newest first", "Neueste zuerst")).tag(false)
                                Text(L("By name", "Nach Name")).tag(true)
                            }
                            .pickerStyle(.inline)
                        } label: {
                            Label(L("Sort", "Sortierung"), systemImage: "arrow.up.arrow.down")
                        }
                        .help(L("Sort order", "Sortierung"))
                    }
                    ToolbarItem {
                        Button { app.openPanel() } label: { Label(L("Open…", "Öffnen…"), systemImage: "folder") }
                            .help(L("Open a PDF from anywhere", "Ein PDF von irgendwo öffnen"))
                    }
                }
        }
        .onAppear { store.start() }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.pathExtension.lowercased() == "pdf" else { return }
                DispatchQueue.main.async { app.open(url) }
            }
            return true
        }
    }

    @ViewBuilder private var content: some View {
        if store.loading {
            VStack(spacing: 12) {
                ProgressView()
                Text(L("Looking for your PDFs…", "Suche deine PDFs…")).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if shown.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "doc.text.magnifyingglass").font(.system(size: 38, weight: .light)).foregroundStyle(.tertiary)
                Text(search.isEmpty ? L("No PDFs here yet", "Hier sind noch keine PDFs")
                                    : L("No PDF is called that", "Kein PDF heisst so"))
                    .font(.title3)
                Text(L("Drop a PDF onto this window or use Open.", "Zieh ein PDF auf dieses Fenster oder nimm Öffnen."))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 26, alignment: .top)], spacing: 30) {
                    ForEach(shown) { item in
                        PDFCard(item: item) { app.open(item.url) }
                    }
                }
                .padding(.horizontal, 30)
                .padding(.vertical, 26)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }
}

private struct PDFCard: View {
    let item: PDFItem
    let open: () -> Void
    @State private var image: NSImage?
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            VStack(spacing: 10) {
                ZStack {
                    if let image {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                            .overlay(Rectangle().strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5))
                            .shadow(color: .black.opacity(hovering ? 0.26 : 0.14), radius: hovering ? 12 : 5, y: hovering ? 7 : 3)
                    } else {
                        Rectangle().fill(Color.primary.opacity(0.05))
                            .aspectRatio(0.707, contentMode: .fit)
                    }
                }
                .frame(height: 200, alignment: .bottom)
                .offset(y: hovering ? -3 : 0)

                VStack(spacing: 2) {
                    Text(item.name).font(.callout.weight(.medium)).lineLimit(2).multilineTextAlignment(.center)
                    Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.16), value: hovering)
        .onHover { hovering = $0 }
        .task(id: item.id) { image = await Thumbnails.shared.image(for: item.url) }
        .contextMenu {
            Button(L("Open", "Öffnen"), action: open)
            Button(L("Show in Finder", "Im Finder zeigen")) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        }
        .help(item.url.path)
    }

    private var caption: String {
        guard item.modified > .distantPast else { return item.folder }
        if Date().timeIntervalSince(item.modified) < 90 { return item.folder + " · " + L("just now", "gerade eben") }
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: Prefs.shared.lang)
        f.unitsStyle = .short
        return item.folder + " · " + f.localizedString(for: item.modified, relativeTo: Date())
    }
}
