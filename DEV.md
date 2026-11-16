# Working on Blanko

SwiftUI + PDFKit, Swift Package, no dependencies. English is the source language; German sits
next to it in the code (`L("English", "Deutsch")`), chosen inside the app.

## Layout

| File | What |
|---|---|
| `Main.swift` | entry point, app scene, menus, `AppState` (open / save / leave), settings window |
| `Library.swift` | finding PDFs (Spotlight + walking the personal folders), grid, thumbnails |
| `Reader.swift` | reader window: toolbar and the chat panel |
| `ReaderModel.swift` | one open document: tool state, chat, running the assistant, saving |
| `PDFCanvas.swift` | the PDF view: form fields, text tool, selecting / moving / deleting notes |
| `Notes.swift` | text written onto a page (free-text annotations) and how it is drawn |
| `PageInspector.swift` | what the assistant is told about a page: fields, lines and blanks, text, two images |
| `Solver.swift` | prompt, answer schema, applying the actions, the placement check, undo |
| `AIBackend.swift` | Claude through Claude Code (`claude -p`) or the Anthropic API; keychain |
| `CLI.swift`, `UITest.swift` | headless modes and the in-app test driver |

## How an answer gets onto the page

1. `PageInspector.snapshot` collects form fields (F1…), horizontal rules and typed blanks
   (R1…, found in a rendering of the page and in its text), printed text lines with their boxes,
   existing notes (N1…), and renders two images: the clean page and a "map" with a coordinate
   grid and those labels.
2. The model answers with JSON: a chat `reply` and `actions` (`fill` a field, `write` on a rule
   or at x/y, `erase` a note).
3. `Solver.apply` turns them into field values and notes. If something was written by
   coordinates, the model gets the result once more and may move what sits badly.

## Things that cost time (do not undo)

- **PDFKit draws annotations into small layers at a fixed 2x** and stretches them; free text
  looked smeared or doubled. `NoteAnnotation` leaves that layer empty and `CanvasView.drawPagePost`
  draws the notes sharp. The appearance stream for the saved file is still recorded from
  `NoteAnnotation.draw`.
- **PDFKit does not save font or colour of free text**, only the drawn appearance. The size
  travels in the author tag (`Blanko AI;11`); `Notes.adopt` rebuilds notes when a file is opened.
- **Mouse clicks go to PDFKit's page views, not to `PDFView.mouseDown`.** The canvas claims
  clicks in `hitTest` and handles form fields itself.
- **Spotlight hides Desktop / Documents / Downloads from an app** until macOS has asked the
  person; it never asks by itself. Walking those folders directly triggers the question.
- **Never wait for a child process on the main thread** (`waitUntilExit` spins the run loop,
  SwiftUI re-enters the view body and the app dies in `dispatch_once`). 0.1.1 crashed on opening
  any PDF this way. The shell environment is read in the background at launch.
- **Test a release in the window before publishing it** (`open -n /Applications/Blanko.app --args
  --library-dir … --open … --uitest "ask …"`), not only with `--solve`.
- Build with `--build-system native` (see `scripts/build-app.sh`), otherwise the binary is stamped
  as a macOS 14 app once Xcode is installed.

## Testing without a person

```sh
swift build --build-system native
swift scripts/make-testdata.swift testdata            # worksheet.pdf (flat) and form.pdf (fields)

# pipeline only
.build/debug/Blanko --inspect testdata/worksheet.pdf 1 /tmp/out      # clean.png, map.png, context.txt
.build/debug/Blanko --solve testdata/worksheet.pdf /tmp/solved.pdf   # [--page N | --all] [--prompt "…"] [--no-check]
.build/debug/Blanko --render /tmp/solved.pdf 1 /tmp/solved.png

# the real window, driven by posted events, then a screenshot of the window
scripts/uitest.sh testdata/form.pdf "click 200 268; type Korel; key 48; type Uyar; key 36; save" 8 /tmp/shot.png
```

UI script steps: `tool text|pointer`, `click x y`, `dclick x y`, `drag x1 y1 x2 y2`, `type text`,
`key code`, `size pt`, `ask message`, `save`, `back`, `lang de|en`, `light`, `open path`
(window points from the top-left). `--library-dir <dir>` shows only that folder as the library,
which also keeps macOS from asking for folder access during tests.
