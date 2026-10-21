import Foundation

/// Folders whose insides belong to the folder: removing one file from them breaks a library, a disk
/// image, a repository or a code signature. The package as a whole can still go to the Trash; what is
/// inside it is never offered.
public enum Packages {
    public static let extensions: Set<String> = [
        // code bundles (signed)
        "action", "app", "appex", "bundle", "component", "dext", "dsym", "framework", "kext", "mdimporter", "mpkg",
        "osax", "plugin", "prefpane", "qlgenerator", "saver", "systemextension", "vst", "vst3", "workflow", "xpc",
        // media libraries and projects
        "aplibrary", "backupbundle", "band", "dtbase2", "fcpbundle", "imovielibrary", "logicx", "lrdata", "lrlibrary", "musiclibrary",
        "photolibrary", "photoslibrary", "tvlibrary",
        // documents and images stored as folders
        "graffle", "key", "numbers", "oo3", "pages", "playground", "rtfd", "scriv", "scptd", "sparsebundle", "xcarchive", "xcodeproj", "xcworkspace"]
    public static let names: Set<String> = [".git"]

    public static func isPackage(name: String) -> Bool {
        // Any case: the default volume is case-insensitive, so `.GIT` is the same folder.
        names.contains(name.lowercased()) || extensions.contains(FileTree.fileExtension(name))
    }

    /// The innermost package `path` lies inside, not counting `path` itself.
    public static func enclosing(_ path: String) -> String? {
        path.split(separator: "/").dropLast().last { isPackage(name: String($0)) }.map(String.init)
    }
}
