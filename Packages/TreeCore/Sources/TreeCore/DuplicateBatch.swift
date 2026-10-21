extension DuplicateGroup {
    /// The copy 只留一份 keeps: the first member, in path order, that can stay.
    public func keeper(remains: (DuplicateMember) -> Bool) -> DuplicateMember? {
        members.first(where: remains)
    }

    /// Splits the picked copies into those that go and those that stay. nil when copies are picked but
    /// no unpicked copy can stay, since that would take the last copy.
    public func trashPlan(picked: Set<NodeID>, remains: (DuplicateMember) -> Bool)
        -> (trash: [DuplicateMember], kept: [DuplicateMember])? {
        let trash = members.filter { picked.contains($0.node) }
        let kept = members.filter { !picked.contains($0.node) && remains($0) }
        return trash.isEmpty || !kept.isEmpty ? (trash, kept) : nil
    }
}
