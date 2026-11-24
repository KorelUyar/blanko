import AppKit

/// Test driver: `--uitest "tool text; click 230 205; type Hello; key 36; drag 200 200 260 240"`.
/// Posts real events into the app's own queue, so the window, hit-testing and the responder chain
/// behave as with a person. Coordinates are window points from the top-left corner.
@MainActor
enum UITest {
    static func run(_ script: String) {
        if ProcessInfo.processInfo.environment["BLANKO_TRACE"] != nil {
            NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { e in
                let hit = e.type == .leftMouseDown ? e.window?.contentView?.superview?.hitTest(e.locationInWindow) : nil
                FileHandle.standardError.write(Data("event \(e.type.rawValue) \(e.locationInWindow) win=\(e.window != nil) hit=\(String(describing: hit.map { type(of: $0) })) first=\(String(describing: e.window?.firstResponder.map { type(of: $0) }))\n".utf8))
                return e
            }
        }
        let steps = script.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        Task { @MainActor in
            for step in steps {
                try? await Task.sleep(nanoseconds: 350_000_000)
                if step.hasPrefix("wait ") {          // wait <seconds>
                    try? await Task.sleep(nanoseconds: UInt64((Double(step.dropFirst(5)) ?? 1) * 1_000_000_000))
                } else if step == "idle" {             // until the assistant has finished (at most 10 minutes)
                    for _ in 0..<1200 where AppState.shared.reader?.busy == true {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                    }
                } else {
                    perform(step)
                }
            }
        }
    }

    private static func perform(_ step: String) {
        let parts = step.split(separator: " ", maxSplits: 1).map(String.init)
        guard let command = parts.first, let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.height > 200 }) else { return }
        let rest = parts.count > 1 ? parts[1] : ""
        let nums = rest.split(separator: " ").compactMap { Double($0) }
        func point(_ i: Int) -> CGPoint { CGPoint(x: nums[i], y: window.frame.height - nums[i + 1]) }
        func mouse(_ type: NSEvent.EventType, _ p: CGPoint, clicks: Int = 1) {
            if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1) {
                NSApp.postEvent(e, atStart: false)
            }
        }
        func key(_ code: UInt16, _ chars: String, flags: NSEvent.ModifierFlags = []) {
            for down in [true, false] {
                if let e = NSEvent.keyEvent(with: down ? .keyDown : .keyUp, location: .zero, modifierFlags: flags,
                                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                            context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
                    NSApp.postEvent(e, atStart: false)
                }
            }
        }
        switch command {
        case "tool": AppState.shared.reader?.tool = rest == "text" ? .text : .pointer
        case "click": mouse(.leftMouseDown, point(0)); mouse(.leftMouseUp, point(0))
        case "dclick":
            mouse(.leftMouseDown, point(0)); mouse(.leftMouseUp, point(0))
            mouse(.leftMouseDown, point(0), clicks: 2); mouse(.leftMouseUp, point(0), clicks: 2)
        case "drag":
            let a = point(0), b = point(2)
            mouse(.leftMouseDown, a)
            for i in 1...6 { let f = Double(i) / 6; mouse(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)) }
            mouse(.leftMouseUp, b)
        case "type": for ch in rest { key(0, String(ch)) }
        case "key": key(UInt16(nums.first ?? 36), nums.first == 36 ? "\r" : (nums.first == 51 ? "\u{7f}" : ""))
        case "focus":
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            FileHandle.standardError.write(Data("focus active=\(NSApp.isActive) key=\(window.isKeyWindow)\n".utf8))
        case "layers":
            func dump(_ l: CALayer, _ depth: Int) {
                if depth > 7 { return }
                FileHandle.standardError.write(Data("L\(String(repeating: " ", count: depth))\(type(of: l)) \(l.frame.integral) scale=\(l.contentsScale) delegate=\(String(describing: l.delegate.map { type(of: $0) })) subs=\(l.sublayers?.count ?? 0)\n".utf8))
                for s in (l.sublayers ?? []).prefix(12) { dump(s, depth + 1) }
            }
            if let root = AppState.shared.reader?.canvas?.documentView?.layer { dump(root, 0) }
        case "save": AppState.shared.save()
        case "back": AppState.shared.reader?.dirty = false; AppState.shared.closeReader()
        case "size": if let r = AppState.shared.reader { r.textSize = CGFloat(nums.first ?? 12); r.canvas?.setSelectedSize(r.textSize) }
        case "ask": AppState.shared.reader?.send(rest)
        case "lang": Prefs.shared.lang = rest
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "resize": if nums.count >= 2 { window.setContentSize(NSSize(width: nums[0], height: nums[1])) }
        case "shot": shot(window, to: URL(fileURLWithPath: rest))
        case "keysheet": AppState.shared.reader?.showKeySheet = true
        case "sheetshot": if let sheet = window.attachedSheet { shot(sheet, to: URL(fileURLWithPath: rest)) }
        case "clear": AppState.shared.reader?.clearChat()
        case "chattop":
            // The chat's scroll view: every scroll view right of the PDF.
            guard let canvas = AppState.shared.reader?.canvas, let root = window.contentView else { break }
            let edge = canvas.convert(canvas.bounds, to: nil).maxX
            func walk(_ v: NSView) {
                if let s = v as? NSScrollView, s !== canvas.enclosingScrollView, s.convert(s.bounds, to: nil).minX >= edge - 1,
                   let doc = s.documentView {
                    let top = doc.isFlipped ? 0 : max(0, doc.bounds.height - s.contentView.bounds.height)
                    s.contentView.scroll(to: NSPoint(x: 0, y: top - s.contentInsets.top))
                    s.reflectScrolledClipView(s.contentView)
                }
                v.subviews.forEach(walk)
            }
            walk(root)
        case "quit": AppState.shared.reader?.dirty = false; NSApp.terminate(nil)
        case "open": AppState.shared.open(URL(fileURLWithPath: rest))
        default: break
        }
    }

    /// `shot <file.png>`: the whole window (title bar included) drawn at 2x, with rounded corners and
    /// a soft shadow on a clear backdrop, the way the pictures on the download page look. The screen
    /// of a headless Mac is 1x, so a screen capture would be blurry.
    private static func shot(_ window: NSWindow, to url: URL) {
        let scale: CGFloat = 2
        guard let frame = window.contentView?.superview else { return }
        let b = frame.bounds
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(b.width * scale), pixelsHigh: Int(b.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = b.size
        frame.cacheDisplay(in: b, to: rep)
        // Two things a window snapshot leaves out are drawn in by hand: the PDF pages (PDFKit
        // renders them in layers of its own) and the rows of the sidebar list.
        if let g = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = g
            window.effectiveAppearance.performAsCurrentDrawingAppearance {
                drawPages(in: window, frame: frame, cg: g.cgContext)
                drawSidebarLists(in: frame, cg: g.cgContext)
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        let picture = NSImage(size: b.size)
        picture.addRepresentation(rep)

        let dark = window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let pad: CGFloat = 40, radius: CGFloat = 12
        let size = NSSize(width: b.width + pad * 2, height: b.height + pad * 2)
        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        out.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        let rect = NSRect(x: pad, y: pad, width: b.width, height: b.height)
        let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 24
        shadow.shadowOffset = NSSize(width: 0, height: -12)
        shadow.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.6 : 0.32)
        shadow.set()
        (dark ? NSColor(white: 0.2, alpha: 1) : NSColor.white).setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        picture.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.restoreGraphicsState()
        try? out.representation(using: .png, properties: [:])?.write(to: url)
        FileHandle.standardError.write(Data("shot \(url.path) \(Int(size.width * scale))x\(Int(size.height * scale))\n".utf8))
    }

    private static func drawPages(in window: NSWindow, frame: NSView, cg: CGContext) {
        guard let canvas = AppState.shared.reader?.canvas, canvas.window === window else { return }
        let area = canvas.convert(canvas.bounds, to: frame)
        cg.saveGState()
        cg.clip(to: area)
        (canvas.backgroundColor).setFill()
        area.fill()
        for page in canvas.visiblePages {
            let box = page.bounds(for: canvas.displayBox)
            let r = frame.convert(canvas.convert(box, from: page), from: canvas)
            cg.saveGState()
            cg.setShadow(offset: CGSize(width: 0, height: -1), blur: 6, color: NSColor.black.withAlphaComponent(0.25).cgColor)
            cg.setFillColor(CGColor.white)
            cg.fill(r)
            cg.restoreGState()
            cg.saveGState()
            cg.clip(to: r)
            cg.translateBy(x: r.minX, y: r.minY)
            cg.scaleBy(x: r.width / box.width, y: r.height / box.height)
            cg.translateBy(x: -box.minX, y: -box.minY)
            page.draw(with: canvas.displayBox, to: cg)
            cg.restoreGState()
        }
        cg.restoreGState()
    }

    private static func drawSidebarLists(in frame: NSView, cg: CGContext) {
        func find(_ v: NSView, _ out: inout [NSOutlineView]) {
            if let o = v as? NSOutlineView { out.append(o) }
            for s in v.subviews { find(s, &out) }
        }
        var lists: [NSOutlineView] = []
        find(frame, &lists)
        for list in lists {
            let visible = list.visibleRect
            let r = frame.convert(visible, from: list)
            guard r.width > 20, r.height > 20,
                  let sub = list.bitmapImageRepForCachingDisplay(in: visible) else { continue }
            let hi = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(visible.width * 2), pixelsHigh: Int(visible.height * 2),
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) ?? sub
            hi.size = visible.size
            // The selection is drawn with the window's vibrancy, which a snapshot turns black:
            // leave it out of the snapshot and draw the inactive-window look underneath instead.
            for row in list.selectedRowIndexes {
                let rr = frame.convert(list.rect(ofRow: row).insetBy(dx: 10, dy: 0), from: list)
                NSColor.labelColor.withAlphaComponent(0.09).setFill()
                NSBezierPath(roundedRect: rr, xRadius: 6, yRadius: 6).fill()
            }
            let style = list.selectionHighlightStyle
            list.selectionHighlightStyle = .none
            list.cacheDisplay(in: visible, to: hi)
            list.selectionHighlightStyle = style
            let image = NSImage(size: visible.size)
            image.addRepresentation(hi)
            image.draw(in: r)
        }
    }
}
