import Foundation

extension LiveUpdater {
    /// Posted on the main queue, with the updater as the object, whenever `foldersInProgress` changes.
    public static let activityDidChange = Notification.Name("Hoard.LiveUpdater.activityDidChange")

    /// Folders of the batch being applied that are not done yet; 0 when the updater is idle. Main queue only.
    public var foldersInProgress: Int { activeFolders }
}
