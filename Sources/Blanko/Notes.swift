import AppKit
import PDFKit

/// Text written onto a page by Blanko. Stored as ordinary free-text annotations, so every PDF
/// viewer shows them; the author tag tells ours apart from other people's annotations.
enum Notes {
    static let userTag = "Blanko"
    static let aiTag = "Blanko AI"

    // PDFKit insets free text by these amounts inside the annotation's box (measured).
    static let padLeft: CGFloat = 2
    static let padTop: CGFloat = 3.2
    static let lineSpacing: CGFloat = 1.2

    static func isNote(_ a: PDFAnnotation) -> Bool {
        a.type == "FreeText" && (a.userName ?? "").hasPrefix(userTag)
    }

    static func font(_ size: CGFloat) -> NSFont {
        NSFont(name: "Helvetica", size: size) ?? .systemFont(ofSize: size)
    }

    static func textWidth(_ text: String, size: CGFloat) -> CGFloat {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { (String($0) as NSString).size(withAttributes: [.font: font(size)]).width }
            .max() ?? 0
    }

    /// Box for `text` whose first line starts at `x` and sits on `baseline` (PDF coordinates).
    static func bounds(text: String, size: CGFloat, x: CGFloat, baseline: CGFloat, wrap: CGFloat?) -> CGRect {
        let f = font(size)
        let width: CGFloat
        let inner: CGSize
        if let wrap, wrap > 20 {
            width = wrap + 2 * padLeft
            let attributed = NSAttributedString(string: text, attributes: [.font: f])
            let typesetter = CTTypesetterCreateWithAttributedString(attributed)
            var start = 0, lines = 0
            while start < attributed.length {
                start += max(1, CTTypesetterSuggestLineBreak(typesetter, start, Double(wrap)))
                lines += 1
            }
            inner = CGSize(width: wrap, height: CGFloat(max(lines, 1)) * size * lineSpacing)
        } else {
            let lines = max(1, text.split(separator: "\n", omittingEmptySubsequences: false).count)
            inner = CGSize(width: textWidth(text, size: size), height: CGFloat(lines) * size * lineSpacing)
            width = inner.width + 2 * padLeft + 6
        }
        let height = max(inner.height, size * 1.2) + padTop + 4
        let top = baseline + f.ascender + padTop
        return CGRect(x: x - padLeft, y: top - height, width: width, height: height)
    }

    static func make(text: String, size: CGFloat, x: CGFloat, baseline: CGFloat, wrap: CGFloat?, byAI: Bool) -> PDFAnnotation {
        let a = NoteAnnotation(bounds: bounds(text: text, size: size, x: x, baseline: baseline, wrap: wrap),
                               forType: .freeText, withProperties: nil)
        style(a, text: text, size: size, byAI: byAI)
        return a
    }

    static func style(_ a: PDFAnnotation, text: String, size: CGFloat, byAI: Bool) {
        a.contents = text
        a.font = font(size)
        a.fontColor = byAI ? Ink.ai : Ink.user
        a.color = .clear
        a.alignment = .left
        let border = PDFBorder()
        border.lineWidth = 0
        a.border = border
        // PDFKit does not write font or colour of free text into the file (only the drawn
        // appearance), so the author tag carries the size: "Blanko AI;11".
        a.userName = (byAI ? aiTag : userTag) + ";" + String(format: "%g", Double(size))
    }

    static func isAI(_ a: PDFAnnotation) -> Bool { (a.userName ?? "").hasPrefix(aiTag) }

    static func storedSize(_ a: PDFAnnotation) -> CGFloat {
        let parts = (a.userName ?? "").split(separator: ";")
        return parts.count > 1 ? CGFloat(Double(parts[1]) ?? 11) : 11
    }

    /// Where the first baseline of an existing note is (PDF coordinates).
    static func origin(of a: PDFAnnotation) -> (x: CGFloat, baseline: CGFloat, size: CGFloat) {
        let size = a.font?.pointSize ?? 11
        return (a.bounds.minX + padLeft, a.bounds.maxY - padTop - font(size).ascender, size)
    }
}

/// Draws its own text; the saved file still gets a standard free-text annotation that every
/// viewer understands.
final class NoteAnnotation: PDFAnnotation {
    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        // PDFView draws each annotation into a small layer of its own at 1x and stretches it to
        // the zoom level, which leaves the text smeared. That layer stays empty; CanvasView draws
        // the notes itself on top of the page, sharp. The page rendering used for the assistant
        // and the appearance recorded for the saved file come through here as usual.
        if (CFCopyDescription(context) as String?)?.contains("CoreAnimation") == true { return }
        render(in: context)
    }

    func render(in context: CGContext) {
        guard shouldDisplay, let text = contents, !text.isEmpty else { return }
        let size = font?.pointSize ?? 11
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font ?? Notes.font(size), .foregroundColor: fontColor ?? Ink.user,
        ])
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        let width = Double(max(bounds.width - 2 * Notes.padLeft, 10))
        let length = attributed.length
        var start = 0
        var baseline = bounds.maxY - Notes.padTop - Notes.font(size).ascender
        context.saveGState()
        context.textMatrix = .identity
        while start < length {
            let count = max(1, CTTypesetterSuggestLineBreak(typesetter, start, width))
            let line = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count))
            context.textPosition = CGPoint(x: bounds.minX + Notes.padLeft, y: baseline)
            CTLineDraw(line, context)
            start += count
            baseline -= size * Notes.lineSpacing
        }
        context.restoreGState()
    }
}

extension Notes {
    /// Swaps notes loaded from a file for the self-drawing kind.
    static func adopt(_ document: PDFDocument) {
        for i in 0..<document.pageCount {
            guard let page = document.page(at: i) else { continue }
            for old in page.annotations where isNote(old) && !(old is NoteAnnotation) {
                let note = NoteAnnotation(bounds: old.bounds, forType: .freeText, withProperties: nil)
                style(note, text: old.contents ?? "", size: storedSize(old), byAI: isAI(old))
                page.removeAnnotation(old)
                page.addAnnotation(note)
            }
        }
    }
}

enum Forms {
    /// Switches one radio button on and the others of its group off.
    /// Returns the buttons it switched off, with the state they had.
    @discardableResult
    static func selectRadio(_ field: PDFAnnotation) -> [PDFAnnotation] {
        var switchedOff: [PDFAnnotation] = []
        if let name = field.fieldName, let document = field.page?.document {
            for p in 0..<document.pageCount {
                for other in document.page(at: p)?.annotations ?? []
                where other !== field && other.type == "Widget" && other.fieldName == name && other.buttonWidgetState == .onState {
                    other.buttonWidgetState = .offState
                    switchedOff.append(other)
                }
            }
        }
        field.buttonWidgetState = .onState
        return switchedOff
    }
}
