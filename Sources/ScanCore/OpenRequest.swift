import Foundation

public enum OpenRequest: Equatable, Sendable {
    case folder(String)
    case app(String)
    case ignored

    public static func route(_ url: URL) -> OpenRequest {
        guard url.isFileURL else { return .ignored }
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        guard let values = try? resolved.resourceValues(forKeys: [.isDirectoryKey]),
              values.isDirectory == true else { return .ignored }
        // An App keeps the path it was given: a link to /Applications/X.app names the link, and its
        // uninstall plan must never become X.app's.
        if resolved.pathExtension.lowercased() == "app" { return .app(normalized(url.path)) }
        // Other packages (a Photos library, an .rtfd) open as folders: seeing inside them is the point.
        return .folder(PathForms.systemPath(resolved.path))
    }

    /// Standardized, in the `/` form rather than `/System/Volumes/Data`; symlinks are not followed.
    public static func normalized(_ path: String) -> String {
        PathForms.systemPath(URL(fileURLWithPath: path).standardizedFileURL.path)
    }

    public static func isInAppFolders(_ path: String, roots: [String]) -> Bool {
        let path = normalized(path)
        return roots.map(normalized).contains { path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }

    /// The App whose own path is `path`, never one a link points to.
    public static func app(at path: String, in apps: [AppFootprint]) -> AppFootprint? {
        let wanted = normalized(path)
        return apps.first { normalized($0.appPath) == wanted }
    }

    public static func first(of urls: [URL]) -> OpenRequest {
        for url in urls {
            let request = route(url)
            if request != .ignored { return request }
        }
        return .ignored
    }
}
