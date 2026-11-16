import AppKit
import PDFKit

// Everything the assistant is told about one page, in "page space": PDF points with the origin at
// the top-left corner of the visible page (x to the right, y down).

struct FieldInfo {
    let id: String
    let annotation: PDFAnnotation
    let kind: String            // text | checkbox | radio | choice
    let name: String
    let value: String
    let options: [String]
    let rect: CGRect
}

struct LineInfo {
    let text: String
    let rect: CGRect
}

/// A horizontal line or blank on the page: a place where one would write by hand.
struct RuleInfo {
    var id: String
    var x1: CGFloat
    var x2: CGFloat
    var y: CGFloat
}

struct NoteInfo {
    let id: String
    let annotation: PDFAnnotation
    let text: String
    let rect: CGRect
    let byAI: Bool
}

struct PageSnapshot {
    let pageIndex: Int
    let size: CGSize
    let fields: [FieldInfo]
    let lines: [LineInfo]
    let rules: [RuleInfo]
    let notes: [NoteInfo]
    let cleanPNG: Data
    let mapPNG: Data
}

enum PageInspector {

    static func box(_ page: PDFPage) -> CGRect { page.bounds(for: .cropBox) }

    /// PDF coordinates (origin bottom-left of the media box) -> page space.
    static func toPageSpace(_ r: CGRect, _ page: PDFPage) -> CGRect {
        let b = box(page)
        return CGRect(x: r.minX - b.minX, y: b.maxY - r.maxY, width: r.width, height: r.height)
    }

    static func toPDF(x: CGFloat, y: CGFloat, _ page: PDFPage) -> CGPoint {
        let b = box(page)
        return CGPoint(x: x + b.minX, y: b.maxY - y)
    }

    // MARK: Snapshot

    static func snapshot(_ page: PDFPage, index: Int) -> PageSnapshot {
        let b = box(page)
        let fields = self.fields(page)
        let lines = self.lines(page)
        let notes = self.notes(page)
        let rules = self.rules(page, lines: lines)
        let scale = min(2.6, 1568 / max(b.width, b.height))
        let clean = render(page, scale: scale, overlay: nil)
        let map = render(page, scale: scale) { drawMap(b.size, fields: fields, rules: rules) }
        return PageSnapshot(pageIndex: index, size: b.size, fields: fields, lines: lines,
                            rules: rules, notes: notes, cleanPNG: clean, mapPNG: map)
    }

    // MARK: Form fields

    static func fields(_ page: PDFPage) -> [FieldInfo] {
        var out: [FieldInfo] = []
        for a in page.annotations where a.type == "Widget" && !a.isReadOnly && a.shouldDisplay {
            let kind: String
            var value = ""
            var options: [String] = []
            switch a.widgetFieldType {
            case .text:
                kind = "text"
                value = a.widgetStringValue ?? ""
            case .button:
                switch a.widgetControlType {
                case .checkBoxControl:
                    kind = "checkbox"
                    value = a.buttonWidgetState == .onState ? "yes" : "no"
                case .radioButtonControl:
                    kind = "radio"
                    value = a.buttonWidgetState == .onState ? "yes" : "no"
                    options = [a.buttonWidgetStateString]
                default:
                    continue
                }
            case .choice:
                kind = "choice"
                value = a.widgetStringValue ?? ""
                options = a.choices ?? []
            default:
                continue
            }
            out.append(FieldInfo(id: "F\(out.count + 1)", annotation: a, kind: kind,
                                 name: a.fieldName ?? "", value: value, options: options,
                                 rect: toPageSpace(a.bounds, page)))
        }
        return out
    }

    // MARK: Notes (text written by Blanko: the person or the assistant)

    static func notes(_ page: PDFPage) -> [NoteInfo] {
        var out: [NoteInfo] = []
        for a in page.annotations where Notes.isNote(a) {
            out.append(NoteInfo(id: "N\(out.count + 1)", annotation: a, text: a.contents ?? "",
                                rect: toPageSpace(a.bounds, page), byAI: Notes.isAI(a)))
        }
        return out
    }

    // MARK: Printed text

    static func lines(_ page: PDFPage) -> [LineInfo] {
        guard let all = page.selection(for: box(page)) else { return [] }
        var out: [LineInfo] = []
        for line in all.selectionsByLine() {
            let text = (line.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let r = line.bounds(for: page)
            guard r.width > 0, r.height > 0 else { continue }
            out.append(LineInfo(text: text, rect: toPageSpace(r, page)))
            if out.count >= 500 { break }
        }
        return out
    }

    // MARK: Rules and blanks

    static func rules(_ page: PDFPage, lines: [LineInfo]) -> [RuleInfo] {
        var found = drawnRules(page)

        // Lines that only underline printed text are not places to write.
        found.removeAll { rule in
            lines.contains { line in
                let overlap = min(line.rect.maxX, rule.x2) - max(line.rect.minX, rule.x1)
                let below = rule.y - line.rect.maxY
                let isBlank = line.text.allSatisfy { "_.… ".contains($0) }
                return !isBlank && overlap > 0.6 * (rule.x2 - rule.x1) && below > -3 && below < 2.5
            }
        }

        // Blanks typed as text: "Name: ________" or "........".
        for blank in typedBlanks(page) {
            let duplicate = found.contains { abs($0.y - blank.y) < 5 && min($0.x2, blank.x2) - max($0.x1, blank.x1) > 0 }
            if !duplicate { found.append(blank) }
        }

        found.sort { abs($0.y - $1.y) > 3 ? $0.y < $1.y : $0.x1 < $1.x1 }
        if found.count > 140 { found = Array(found.prefix(140)) }
        for i in found.indices { found[i].id = "R\(i + 1)" }
        return found
    }

    /// Thin horizontal lines drawn on the page, found in a greyscale rendering.
    private static func drawnRules(_ page: PDFPage) -> [RuleInfo] {
        let b = box(page)
        let s: CGFloat = 2
        let w = Int(b.width * s), h = Int(b.height * s)
        guard w > 0, h > 0, w < 8000, h < 12000,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return [] }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: s, y: s)
        ctx.translateBy(x: -b.minX, y: -b.minY)
        let hidden = page.annotations.filter { Notes.isNote($0) && $0.shouldDisplay }
        hidden.forEach { $0.shouldDisplay = false }
        page.draw(with: .cropBox, to: ctx)
        hidden.forEach { $0.shouldDisplay = true }
        guard let data = ctx.data else { return [] }
        let px = data.bindMemory(to: UInt8.self, capacity: w * h)

        struct Band { var x1: Int; var x2: Int; var top: Int; var bottom: Int }
        var bands: [Band] = []
        var open: [Int] = []                 // indices into bands that reached the previous row
        let minLen = Int(26 * s)

        for y in 0..<h {
            var next: [Int] = []
            var x = 0
            let row = px + y * w
            while x < w {
                if row[x] < 150 {
                    let start = x
                    while x < w && row[x] < 150 { x += 1 }
                    if x - start >= minLen {
                        var merged = false
                        for i in open {
                            let o = min(bands[i].x2, x) - max(bands[i].x1, start)
                            if o > Int(0.7 * Double(max(bands[i].x2 - bands[i].x1, x - start))) {
                                bands[i].bottom = y
                                bands[i].x1 = min(bands[i].x1, start)
                                bands[i].x2 = max(bands[i].x2, x)
                                next.append(i)
                                merged = true
                                break
                            }
                        }
                        if !merged {
                            bands.append(Band(x1: start, x2: x, top: y, bottom: y))
                            next.append(bands.count - 1)
                        }
                    }
                } else {
                    x += 1
                }
            }
            open = next
        }

        return bands.compactMap { band in
            let thickness = CGFloat(band.bottom - band.top + 1) / s
            guard thickness <= 3 else { return nil }
            return RuleInfo(id: "", x1: CGFloat(band.x1) / s, x2: CGFloat(band.x2) / s,
                            y: CGFloat(band.top) / s)
        }
    }

    private static func typedBlanks(_ page: PDFPage) -> [RuleInfo] {
        guard let text = page.string,
              let regex = try? NSRegularExpression(pattern: "_{3,}|\\.{5,}|…{2,}") else { return [] }
        let ns = text as NSString
        var out: [RuleInfo] = []
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let sel = page.selection(for: m.range) else { continue }
            let b = sel.bounds(for: page)
            guard b.height > 0, b.width > 12 else { continue }
            let r = toPageSpace(b, page)
            out.append(RuleInfo(id: "", x1: r.minX, x2: r.maxX, y: r.maxY - r.height * 0.18))
        }
        return out
    }

    // MARK: Rendering

    /// Renders the page; `overlay` draws in page space (y down) on top of it.
    static func render(_ page: PDFPage, scale: CGFloat, overlay: (() -> Void)?) -> Data {
        let b = box(page)
        let w = max(1, Int(b.width * scale)), h = max(1, Int(b.height * scale))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let g = NSGraphicsContext(bitmapImageRep: rep) else { return Data() }
        let cg = g.cgContext
        cg.setFillColor(CGColor.white)
        cg.fill(CGRect(x: 0, y: 0, width: w, height: h))
        cg.saveGState()
        cg.scaleBy(x: scale, y: scale)
        cg.translateBy(x: -b.minX, y: -b.minY)
        page.draw(with: .cropBox, to: cg)
        cg.restoreGState()
        if let overlay {
            cg.saveGState()
            cg.translateBy(x: 0, y: CGFloat(h))
            cg.scaleBy(x: scale, y: -scale)
            let flipped = NSGraphicsContext(cgContext: cg, flipped: true)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = flipped
            overlay()
            NSGraphicsContext.restoreGraphicsState()
            cg.restoreGState()
        }
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }

    private static func tag(_ text: String, at p: CGPoint, size: CGFloat, fg: NSColor, bg: NSColor) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: size), .foregroundColor: fg]
        let s = text as NSString
        let sz = s.size(withAttributes: attrs)
        bg.setFill()
        NSBezierPath(rect: CGRect(x: p.x - 1, y: p.y, width: sz.width + 2, height: sz.height)).fill()
        s.draw(at: p, withAttributes: attrs)
    }

    private static func tagWidth(_ text: String, size: CGFloat) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: NSFont.boldSystemFont(ofSize: size)]).width + 2
    }

    private static func drawMap(_ size: CGSize, fields: [FieldInfo], rules: [RuleInfo]) {
        // Grid every 50 pt, numbers every 100 pt along all four edges.
        let grid = NSColor(srgbRed: 0, green: 0.55, blue: 0.9, alpha: 0.22)
        let strong = NSColor(srgbRed: 0, green: 0.55, blue: 0.9, alpha: 0.42)
        let label = NSColor(srgbRed: 0, green: 0.35, blue: 0.7, alpha: 1)
        var x: CGFloat = 50
        while x < size.width {
            let major = Int(x) % 100 == 0
            (major ? strong : grid).setStroke()
            let p = NSBezierPath(); p.lineWidth = 0.4
            p.move(to: CGPoint(x: x, y: 0)); p.line(to: CGPoint(x: x, y: size.height)); p.stroke()
            if major {
                tag("\(Int(x))", at: CGPoint(x: x + 1, y: 1), size: 6, fg: label, bg: .white)
                tag("\(Int(x))", at: CGPoint(x: x + 1, y: size.height - 9), size: 6, fg: label, bg: .white)
            }
            x += 50
        }
        var y: CGFloat = 50
        while y < size.height {
            let major = Int(y) % 100 == 0
            (major ? strong : grid).setStroke()
            let p = NSBezierPath(); p.lineWidth = 0.4
            p.move(to: CGPoint(x: 0, y: y)); p.line(to: CGPoint(x: size.width, y: y)); p.stroke()
            if major {
                tag("\(Int(y))", at: CGPoint(x: 1, y: y + 1), size: 6, fg: label, bg: .white)
                tag("\(Int(y))", at: CGPoint(x: size.width - 16, y: y + 1), size: 6, fg: label, bg: .white)
            }
            y += 50
        }

        let orange = NSColor(srgbRed: 0.95, green: 0.45, blue: 0, alpha: 1)
        for r in rules {
            orange.setStroke()
            let p = NSBezierPath(); p.lineWidth = 1.2
            p.move(to: CGPoint(x: r.x1, y: r.y + 0.5)); p.line(to: CGPoint(x: r.x2, y: r.y + 0.5)); p.stroke()
            let tw = tagWidth(r.id, size: 5.5)
            let at = r.x1 > tw + 3 ? CGPoint(x: r.x1 - tw - 1, y: r.y - 6) : CGPoint(x: r.x1, y: r.y + 1.5)
            tag(r.id, at: at, size: 5.5, fg: .black, bg: NSColor(srgbRed: 1, green: 0.85, blue: 0.2, alpha: 1))
        }

        let magenta = NSColor(srgbRed: 0.85, green: 0, blue: 0.6, alpha: 1)
        for f in fields {
            magenta.setStroke()
            let p = NSBezierPath(rect: f.rect.insetBy(dx: -0.5, dy: -0.5)); p.lineWidth = 1; p.stroke()
            let above = f.rect.minY > 9
            tag(f.id, at: CGPoint(x: f.rect.minX, y: above ? f.rect.minY - 8.5 : f.rect.maxY + 0.5),
                size: 6, fg: .white, bg: magenta)
        }
    }

    // MARK: Text description for the model

    static func describe(_ s: PageSnapshot) -> String {
        func n(_ v: CGFloat) -> String { String(Int(v.rounded())) }
        func boxText(_ r: CGRect) -> String { "[\(n(r.minX)),\(n(r.minY)),\(n(r.maxX)),\(n(r.maxY))]" }
        var out = "Page size: \(n(s.size.width)) x \(n(s.size.height)) pt. Boxes are [left,top,right,bottom].\n"

        out += "<fields>\n"
        for f in s.fields {
            var line = "\(f.id) \(f.kind) box=\(boxText(f.rect))"
            if !f.name.isEmpty { line += " name=\"\(f.name)\"" }
            if !f.options.isEmpty { line += " options=\(f.options)" }
            line += " value=\"\(f.value)\""
            out += line + "\n"
        }
        if s.fields.isEmpty { out += "(none: this page has no form fields)\n" }
        out += "</fields>\n<rules>\n"
        for r in s.rules { out += "\(r.id) x=\(n(r.x1))..\(n(r.x2)) y=\(n(r.y))\n" }
        if s.rules.isEmpty { out += "(none found)\n" }
        out += "</rules>\n<notes>\n"
        for note in s.notes {
            out += "\(note.id) \(note.byAI ? "by you" : "by the user") box=\(boxText(note.rect)) text=\"\(note.text)\"\n"
        }
        if s.notes.isEmpty { out += "(none)\n" }
        out += "</notes>\n<printed_text>\n"
        for l in s.lines { out += "\(boxText(l.rect)) \(l.text)\n" }
        if s.lines.isEmpty { out += "(no text layer: this page is probably a scan, read it from the image)\n" }
        out += "</printed_text>"
        return out
    }
}
