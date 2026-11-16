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
                perform(step)
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
        case "open": AppState.shared.open(URL(fileURLWithPath: rest))
        default: break
        }
    }
}
