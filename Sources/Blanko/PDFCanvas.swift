import AppKit
import PDFKit
import SwiftUI

/// The PDF view. PDFKit itself handles real form fields (click, type, tick), exactly like a
/// browser; on top of that this adds free text anywhere on the page: place, edit, move, delete.
final class CanvasView: PDFView, NSTextFieldDelegate {
    weak var model: ReaderModel?
    var tool: Tool = .pointer

    private(set) var selected: PDFAnnotation?
    private var editor: NSTextField?
    private var editing: (page: PDFPage, note: PDFAnnotation?, x: CGFloat, baseline: CGFloat, size: CGFloat, wrap: CGFloat?)?
    private var observers: [NSObjectProtocol] = []

    func startObserving() {
        let nc = NotificationCenter.default
        // Typing into a form field happens in PDFKit's own text views.
        for name in [NSControl.textDidChangeNotification, NSText.didChangeNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self, self.editor == nil, let view = note.object as? NSView, view.isDescendant(of: self) else { return }
                MainActor.assumeIsolated { self.model?.dirty = true }
            })
        }
        observers.append(nc.addObserver(forName: .PDFViewPageChanged, object: self, queue: .main) { [weak self] _ in
            guard let self, let page = self.currentPage, let doc = self.document else { return }
            MainActor.assumeIsolated { self.model?.pageIndex = doc.index(for: page) }
        })
        observers.append(nc.addObserver(forName: .PDFViewScaleChanged, object: self, queue: .main) { [weak self] _ in
            self?.commitEditing()
            self?.sharpenSoon()
        })
        observers.append(nc.addObserver(forName: .PDFViewVisiblePagesChanged, object: self, queue: .main) { [weak self] _ in
            self?.sharpenSoon()
        })
        sharpenSoon()
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    override var acceptsFirstResponder: Bool { true }

    /// PDFKit rasterises form fields into layers at a fixed 2x, whatever the zoom, so their text
    /// looks soft. Give those layers the resolution they are actually shown at.
    func sharpenFieldLayers() {
        guard let root = documentView?.layer else { return }
        let wanted = max(2, scaleFactor * (window?.backingScaleFactor ?? 2))
        func walk(_ layer: CALayer, _ depth: Int) {
            if String(describing: type(of: layer)).contains("AnnotationEffect") {
                if abs(layer.contentsScale - wanted) > 0.01 {
                    layer.contentsScale = wanted
                    layer.setNeedsDisplay()
                }
                return
            }
            if depth < 8 { layer.sublayers?.forEach { walk($0, depth + 1) } }
        }
        walk(root, 0)
    }

    private func sharpenSoon() {
        for delay in [0.05, 0.4, 1.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.sharpenFieldLayers() }
        }
    }

    func refresh() {
        guard let doc = document else { return }
        for page in visiblePages { annotationsChanged(on: page) }
        if let s = selected, s.page == nil || doc.index(for: s.page!) == NSNotFound { select(nil) }
        needsDisplay = true
        sharpenSoon()
    }

    // MARK: Mouse

    /// PDFKit's page views take the mouse themselves (text selection, links). The canvas claims
    /// a click where it has something to do: a form field, one of our notes, or the text tool.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if let editor, hit === editor || hit.isDescendant(of: editor) { return hit }
        if hit is NSScroller { return hit }
        let local = superview.map { convert(point, from: $0) } ?? point
        guard let page = page(for: local, nearest: false) else { return hit }
        let onPage = convert(local, to: page)
        if tool == .text || selected != nil || editor != nil { return self }
        if note(at: onPage, on: page) != nil || widget(at: onPage, on: page) != nil { return self }
        return hit
    }

    private func note(at point: CGPoint, on page: PDFPage) -> PDFAnnotation? {
        page.annotations.last { Notes.isNote($0) && $0.bounds.contains(point) }
    }

    private func widget(at point: CGPoint, on page: PDFPage) -> PDFAnnotation? {
        page.annotations.last {
            $0.type == "Widget" && !$0.isReadOnly && $0.shouldDisplay && $0.bounds.contains(point)
                && [.text, .button, .choice].contains($0.widgetFieldType)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if editor != nil {
            commitEditing()
            if tool == .text { return }
        }
        guard let page = page(for: point, nearest: false) else {
            select(nil)
            super.mouseDown(with: event)
            return
        }
        let onPage = convert(point, to: page)
        let hit = note(at: onPage, on: page)

        if hit == nil, let field = widget(at: onPage, on: page) {
            select(nil)
            activate(field, on: page, at: point)
            return
        }
        if tool == .text {
            beginEditing(page: page, note: hit, at: onPage)
            return
        }
        guard let note = hit else {
            select(nil)
            return
        }
        select(note)
        if event.clickCount == 2 {
            beginEditing(page: page, note: note, at: onPage)
            return
        }
        window?.makeFirstResponder(self)
        drag(note, on: page, from: onPage)
    }

    private func drag(_ note: PDFAnnotation, on page: PDFPage, from start: CGPoint) {
        let origin = note.bounds.origin
        var moved = false
        while let event = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if event.type == .leftMouseUp { break }
            let now = convert(convert(event.locationInWindow, from: nil), to: page)
            let dx = now.x - start.x, dy = now.y - start.y
            if !moved && abs(dx) < 2 && abs(dy) < 2 { continue }
            moved = true
            var b = note.bounds
            b.origin = CGPoint(x: origin.x + dx, y: origin.y + dy)
            note.bounds = b
            needsDisplay = true
        }
        if moved { MainActor.assumeIsolated { model?.dirty = true } }
    }

    private func select(_ note: PDFAnnotation?) {
        guard selected !== note else { return }
        selected = note
        needsDisplay = true
        let size = note?.font?.pointSize
        MainActor.assumeIsolated {
            model?.hasSelection = note != nil
            if let size { model?.textSize = size }
        }
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        if let note = selected, editor == nil, [51, 117].contains(Int(event.keyCode)) {
            note.page?.removeAnnotation(note)
            select(nil)
            MainActor.assumeIsolated { model?.dirty = true }
            return
        }
        if event.keyCode == 53, selected != nil {
            select(nil)
            return
        }
        super.keyDown(with: event)
    }

    /// Applies a font size to the selected note (toolbar A- / A+).
    func setSelectedSize(_ size: CGFloat) {
        guard let note = selected else { return }
        let o = Notes.origin(of: note)
        let text = note.contents ?? ""
        let wrapped = text.contains("\n") == false && note.bounds.height > o.size * 2.4
        let width = note.bounds.width
        Notes.style(note, text: text, size: size, byAI: Notes.isAI(note))
        note.bounds = Notes.bounds(text: text, size: size, x: o.x, baseline: o.baseline, wrap: wrapped ? width - 4 : nil)
        needsDisplay = true
        MainActor.assumeIsolated { model?.dirty = true }
    }

    // MARK: Selection frame

    override func drawPagePost(_ page: PDFPage, to context: CGContext) {
        super.drawPagePost(page, to: context)
        for case let note as NoteAnnotation in page.annotations { note.render(in: context) }
        guard let note = selected, note.page === page else { return }
        context.saveGState()
        context.setStrokeColor(Ink.ai.withAlphaComponent(0.9).cgColor)
        context.setLineWidth(0.8)
        context.setLineDash(phase: 0, lengths: [3, 2])
        context.stroke(note.bounds.insetBy(dx: -1, dy: -1))
        context.restoreGState()
    }

    // MARK: Text editing

    private func beginEditing(page: PDFPage, note: PDFAnnotation?, at point: CGPoint) {
        let x: CGFloat, baseline: CGFloat, size: CGFloat
        var wrap: CGFloat?
        var text = ""
        if let note {
            let o = Notes.origin(of: note)
            (x, baseline, size) = (o.x, o.baseline, o.size)
            text = note.contents ?? ""
            if note.bounds.height > size * 2.4 && !text.contains("\n") { wrap = note.bounds.width - 2 * Notes.padLeft }
            note.shouldDisplay = false
            annotationsChanged(on: page)
        } else {
            size = MainActor.assumeIsolated { model?.textSize ?? 12 }
            x = point.x
            baseline = point.y - size * 0.32
        }
        select(nil)
        editing = (page, note, x, baseline, size, wrap)

        let scaled = Notes.font(size * scaleFactor)
        let field = makeEditor(text: text, font: scaled, color: note?.fontColor ?? Ink.user)
        field.cell?.isScrollable = wrap == nil

        let at = convert(CGPoint(x: x, y: baseline), from: page)
        let lines = CGFloat(max(1, text.split(separator: "\n", omittingEmptySubsequences: false).count))
        let lineHeight = ceil((scaled.ascender - scaled.descender + scaled.leading) * 1.22)
        var frame = CGRect(x: at.x - 2, y: at.y + scaled.descender - 1, width: 0, height: lineHeight * lines + 2)
        if let wrap, let note {
            frame.size = CGSize(width: wrap * scaleFactor + 6, height: note.bounds.height * scaleFactor)
            frame.origin.y = at.y + scaled.ascender + 1 - frame.height
        } else {
            frame.size.width = max(140, Notes.textWidth(text, size: size) * scaleFactor + 40)
            frame.origin.y = at.y + scaled.ascender + 1 - frame.height
        }
        field.frame = frame
        addSubview(field)
        editor = field
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = NSRange(location: (text as NSString).length, length: 0)
    }

    private func makeEditor(text: String, font: NSFont, color: NSColor) -> NSTextField {
        let field = NSTextField(string: text)
        field.font = font
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = NSColor.white.withAlphaComponent(0.96)
        field.textColor = color
        field.focusRingType = .none
        field.wantsLayer = true
        field.layer?.borderColor = Ink.ai.cgColor
        field.layer?.borderWidth = 1
        field.layer?.cornerRadius = 2
        field.delegate = self
        field.cell?.wraps = true
        field.cell?.usesSingleLineMode = false
        return field
    }

    // MARK: Form fields

    private var formEditing: (field: PDFAnnotation, page: PDFPage)?

    private func activate(_ field: PDFAnnotation, on page: PDFPage, at viewPoint: CGPoint) {
        switch field.widgetFieldType {
        case .button:
            switch field.widgetControlType {
            case .checkBoxControl:
                field.buttonWidgetState = field.buttonWidgetState == .onState ? .offState : .onState
            case .radioButtonControl:
                Forms.selectRadio(field)
            default:
                return
            }
            annotationsChanged(on: page)
            needsDisplay = true
            MainActor.assumeIsolated { model?.dirty = true }
        case .choice:
            let menu = NSMenu()
            for choice in field.choices ?? [] {
                let item = menu.addItem(withTitle: choice, action: #selector(choose(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = field
                item.state = choice == field.widgetStringValue ? .on : .off
            }
            menu.popUp(positioning: nil, at: viewPoint, in: self)
        case .text:
            beginFormEditing(field, on: page)
        default:
            break
        }
    }

    @objc private func choose(_ item: NSMenuItem) {
        guard let field = item.representedObject as? PDFAnnotation, let page = field.page else { return }
        field.widgetStringValue = item.title
        annotationsChanged(on: page)
        needsDisplay = true
        MainActor.assumeIsolated { model?.dirty = true }
    }

    private func beginFormEditing(_ field: PDFAnnotation, on page: PDFPage) {
        formEditing = (field, page)
        let own = field.font?.pointSize ?? 0
        let size = field.isMultiline ? (own > 0 ? own : 11) : (own > 0 ? own : min(12, max(7, field.bounds.height * 0.62)))
        let font = Notes.font(size * scaleFactor)
        let editor = makeEditor(text: field.widgetStringValue ?? "", font: font, color: .black)
        editor.cell?.isScrollable = !field.isMultiline
        var frame = convert(field.bounds, from: page).insetBy(dx: -1, dy: -1)
        let needed = ceil((font.ascender - font.descender + font.leading) * 1.22) + 2
        if frame.height < needed { frame = frame.insetBy(dx: 0, dy: (frame.height - needed) / 2) }
        editor.frame = frame
        addSubview(editor)
        self.editor = editor
        window?.makeFirstResponder(editor)
    }

    /// Tab order: top to bottom, left to right.
    private func neighbour(of field: PDFAnnotation, on page: PDFPage, forward: Bool) -> PDFAnnotation? {
        let fields = page.annotations
            .filter { $0.type == "Widget" && $0.widgetFieldType == .text && !$0.isReadOnly && $0.shouldDisplay }
            .sorted { abs($0.bounds.midY - $1.bounds.midY) > 4 ? $0.bounds.midY > $1.bounds.midY : $0.bounds.minX < $1.bounds.minX }
        guard let i = fields.firstIndex(where: { $0 === field }) else { return nil }
        let j = i + (forward ? 1 : -1)
        return fields.indices.contains(j) ? fields[j] : nil
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = editor, let e = editing, e.wrap == nil else { return }
        let needed = Notes.textWidth(field.stringValue, size: e.size) * scaleFactor + 40
        if needed > field.frame.width { field.frame.size.width = needed }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            let newline = NSEvent.modifierFlags.contains(.option) || NSEvent.modifierFlags.contains(.shift)
            if newline, let form = formEditing {
                if form.field.isMultiline { textView.insertNewlineIgnoringFieldEditor(nil) }
                return true
            }
            if newline {
                textView.insertNewlineIgnoringFieldEditor(nil)
                if let field = editor {
                    let lines = CGFloat(field.stringValue.split(separator: "\n", omittingEmptySubsequences: false).count)
                    let f = field.font ?? Notes.font(12)
                    let h = ceil((f.ascender - f.descender + f.leading) * 1.22) * max(lines, 1) + 2
                    field.frame = CGRect(x: field.frame.minX, y: field.frame.maxY - h, width: field.frame.width, height: h)
                }
                return true
            }
            commitEditing()
            return true
        }
        if let form = formEditing,
           selector == #selector(NSResponder.insertTab(_:)) || selector == #selector(NSResponder.insertBacktab(_:)) {
            commitEditing()
            if let next = neighbour(of: form.field, on: form.page, forward: selector == #selector(NSResponder.insertTab(_:))) {
                beginFormEditing(next, on: form.page)
            }
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            cancelEditing()
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        commitEditing()
    }

    func commitEditing() {
        if let field = editor, let form = formEditing {
            editor = nil
            formEditing = nil
            var text = field.stringValue
            let limit = form.field.maximumLength
            if limit > 0, text.count > limit { text = String(text.prefix(limit)) }
            field.removeFromSuperview()
            if text != (form.field.widgetStringValue ?? "") {
                form.field.widgetStringValue = text
                annotationsChanged(on: form.page)
                needsDisplay = true
                sharpenSoon()
                MainActor.assumeIsolated { model?.dirty = true }
            }
            window?.makeFirstResponder(self)
            return
        }
        guard let field = editor, let e = editing else { return }
        editor = nil
        editing = nil
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.removeFromSuperview()
        if let note = e.note {
            note.shouldDisplay = true
            if text.isEmpty {
                e.page.removeAnnotation(note)
            } else if text != note.contents {
                note.contents = text
                note.bounds = Notes.bounds(text: text, size: e.size, x: e.x, baseline: e.baseline, wrap: e.wrap)
            }
        } else if !text.isEmpty {
            e.page.addAnnotation(Notes.make(text: text, size: e.size, x: e.x, baseline: e.baseline, wrap: nil, byAI: false))
        }
        annotationsChanged(on: e.page)
        if e.note != nil || !text.isEmpty { MainActor.assumeIsolated { model?.dirty = true } }
        window?.makeFirstResponder(self)
    }

    private func cancelEditing() {
        if let field = editor, formEditing != nil {
            editor = nil
            formEditing = nil
            field.removeFromSuperview()
            window?.makeFirstResponder(self)
            return
        }
        guard let field = editor, let e = editing else { return }
        editor = nil
        editing = nil
        field.removeFromSuperview()
        e.note?.shouldDisplay = true
        annotationsChanged(on: e.page)
        window?.makeFirstResponder(self)
    }
}

struct PDFCanvas: NSViewRepresentable {
    @ObservedObject var model: ReaderModel

    func makeNSView(context: Context) -> CanvasView {
        let view = CanvasView()
        view.model = model
        view.document = model.document
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.autoScales = true
        view.backgroundColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 0.13, alpha: 1) : NSColor(srgbRed: 0.925, green: 0.92, blue: 0.905, alpha: 1)
        }
        view.startObserving()
        model.canvas = view
        return view
    }

    func updateNSView(_ view: CanvasView, context: Context) {
        if view.tool != model.tool {
            view.commitEditing()
            view.tool = model.tool
        }
    }
}
