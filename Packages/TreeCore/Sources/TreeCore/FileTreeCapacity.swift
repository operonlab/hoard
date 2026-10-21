import Foundation

extension FileTree {
    /// Reserves room for `count` nodes in the stored array, so a bulk build of a known size does not
    /// pay for the doubling copies (and the old + new buffer peak they cause). A count not above the
    /// current node count does nothing.
    public func reserveCapacity(nodes count: Int) {
        guard count > nodes.count else { return }
        nodes.reserveCapacity(count)
    }
}
