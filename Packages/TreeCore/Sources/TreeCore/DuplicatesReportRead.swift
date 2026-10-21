extension DuplicateReport {
    /// True when nothing was read and `detail` says why: a run that could not turn off iCloud downloads.
    /// Placeholders skipped by the scan carry their own detail, so one of them must not hide the refusal.
    public func nothingRead(because detail: String) -> Bool {
        bytesRead == 0 && skipped.contains { $0.detail == detail }
    }
}
