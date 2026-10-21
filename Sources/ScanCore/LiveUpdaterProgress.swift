import Foundation

extension LiveUpdater {
    /// How long a replay's batches are held waiting for HistoryDone before they are applied anyway.
    public static var historyHoldLimit: TimeInterval { historyWait }

    /// The share of a replay's history FSEvents has delivered so far (0…1); nil when the updater was
    /// not started from a snapshot's event id. Delivery alone can take longer than a full scan: 9 hours
    /// of ~/workshop history took 14–18 s to arrive, at a near-constant rate, against a 4 s scan.
    /// Main queue only.
    public var historyProgress: Double? {
        guard historyTo > historyFrom else { return historyFrom == 0 ? nil : 1 }
        if historyComplete { return 1 }
        return min(1, Double(historySeen - min(historySeen, historyFrom)) / Double(historyTo - historyFrom))
    }
}
