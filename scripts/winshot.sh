#!/bin/zsh
# Screenshot of the Blanko window only: scripts/winshot.sh out.png
ID=$(swift -e 'import CoreGraphics
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
for w in list where (w["kCGWindowOwnerName"] as? String) == "Blanko" && (w["kCGWindowLayer"] as? Int) == 0 {
  if let b = w["kCGWindowBounds"] as? [String: Any], (b["Height"] as? Double ?? 0) > 200 { print(w["kCGWindowNumber"] as! Int); break }
}' 2>/dev/null)
[[ -n "$ID" ]] || { echo "no Blanko window" >&2; exit 1; }
screencapture -x -o -l "$ID" "$1"
