import Foundation

/// The folder Hoard keeps its data under: ~/Library/Caches/<name> (snapshots) and
/// ~/Library/Application Support/<name> (history, protection store). A development build sets it to
/// "Hoard Dev" at launch, before anything reads it, so its test runs never touch the owner's data.
public enum HoardStorage {
    private static let lock = NSLock()
    private static var name = "Hoard"

    public static var folderName: String {
        get { lock.lock(); defer { lock.unlock() }; return name }
        set { lock.lock(); name = newValue; lock.unlock() }
    }
}
