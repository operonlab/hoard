// Prints the CGWindowID of the frontmost on-screen window owned by the named app (default Hoard),
// for `screencapture -l`. Exit 1 when the app has no on-screen window.
import CoreGraphics
import Foundation

let owner = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Hoard"
let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
for w in info where (w[kCGWindowOwnerName as String] as? String) == owner && (w[kCGWindowLayer as String] as? Int) == 0 {
    if let id = w[kCGWindowNumber as String] as? Int { print(id); exit(0) }
}
FileHandle.standardError.write("no on-screen window for \(owner)\n".data(using: .utf8)!)
exit(1)
