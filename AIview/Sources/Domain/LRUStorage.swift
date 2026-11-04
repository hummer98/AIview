import AppKit
import Foundation

private struct LRUNode<Key: Hashable, Value> {
    let key: Key
    let value: Value
    let cost: Int
    var previous: Key?
    var next: Key?
}

extension LRUNode: Sendable where Key: Sendable, Value: Sendable {}

/// Cost-bounded least-recently-used storage.
///
/// This value deliberately provides no synchronization. Its owner must serialize every
/// operation so the dictionary, linked list, and total cost change as one transaction.
/// Links use keys rather than reference nodes, so a lock can own the complete mutable graph
/// as one checked-Sendable value in Swift 6.
struct LRUStorage<Key: Hashable, Value> {
    private var nodes: [Key: LRUNode<Key, Value>] = [:]
    private var head: Key?
    private var tail: Key?

    let maxCost: Int
    private(set) var totalCost = 0

    var count: Int {
        nodes.count
    }

    init(maxCost: Int) {
        self.maxCost = max(0, maxCost)
    }

    /// Returns and promotes an entry to most-recently-used.
    mutating func value(forKey key: Key) -> Value? {
        guard let node = nodes[key] else { return nil }
        moveToHead(key)
        return node.value
    }

    /// Checks membership without changing recency.
    func contains(_ key: Key) -> Bool {
        nodes[key] != nil
    }

    /// Inserts or replaces an entry and returns entries removed to remain within `maxCost`.
    @discardableResult
    mutating func insert(_ value: Value, forKey key: Key, cost: Int) -> [Key] {
        let normalizedCost = max(0, cost)

        if let existing = nodes[key] {
            unlinkNode(forKey: key, node: existing)
            _ = nodes.removeValue(forKey: key)
            totalCost -= existing.cost
        }

        guard normalizedCost <= maxCost else {
            return [key]
        }

        var evictedKeys: [Key] = []
        let availableCost = maxCost - normalizedCost
        while totalCost > availableCost, let leastRecentKey = tail {
            evictedKeys.append(leastRecentKey)
            removeNodeAndAccounting(forKey: leastRecentKey)
        }

        let node = LRUNode(key: key, value: value, cost: normalizedCost)
        nodes[key] = node
        addToHead(key)
        // `totalCost <= maxCost - normalizedCost` above guarantees no overflow here.
        totalCost += normalizedCost
        return evictedKeys
    }

    @discardableResult
    mutating func removeValue(forKey key: Key) -> Value? {
        guard let node = nodes[key] else { return nil }
        let value = node.value
        removeNodeAndAccounting(forKey: key)
        return value
    }

    /// Evicts least-recently-used entries until the requested cost is reached.
    @discardableResult
    mutating func trim(toCost targetCost: Int) -> [Key] {
        let normalizedTarget = min(max(0, targetCost), maxCost)
        var evictedKeys: [Key] = []
        while totalCost > normalizedTarget, let leastRecentKey = tail {
            evictedKeys.append(leastRecentKey)
            removeNodeAndAccounting(forKey: leastRecentKey)
        }
        return evictedKeys
    }

    /// Breaks every link explicitly before releasing the dictionary.
    mutating func clear() {
        nodes.removeAll(keepingCapacity: false)
        head = nil
        tail = nil
        totalCost = 0
    }

    /// Internal ordering snapshot used by focused invariant tests.
    var keysMostRecentFirst: [Key] {
        var keys: [Key] = []
        keys.reserveCapacity(nodes.count)
        var current = head
        while let key = current, let node = nodes[key] {
            keys.append(key)
            current = node.next
        }
        return keys
    }

    private mutating func addToHead(_ key: Key) {
        guard var node = nodes[key] else { return }
        node.previous = nil
        node.next = head
        nodes[key] = node
        if let currentHead = head {
            nodes[currentHead]?.previous = key
        }
        head = key
        if tail == nil {
            tail = key
        }
    }

    private mutating func unlinkNode(forKey key: Key, node: LRUNode<Key, Value>) {
        if let previous = node.previous {
            nodes[previous]?.next = node.next
        } else {
            head = node.next
        }

        if let next = node.next {
            nodes[next]?.previous = node.previous
        } else {
            tail = node.previous
        }
    }

    private mutating func removeNodeAndAccounting(forKey key: Key) {
        guard let node = nodes[key] else { return }
        unlinkNode(forKey: key, node: node)
        nodes.removeValue(forKey: key)
        totalCost -= node.cost
    }

    private mutating func moveToHead(_ key: Key) {
        guard key != head, let node = nodes[key] else { return }
        unlinkNode(forKey: key, node: node)
        addToHead(key)
    }
}

extension LRUStorage: Sendable where Key: Sendable, Value: Sendable {}

/// Computes the decoded memory retained by an `NSImage` without overflowing `Int`.
enum ImageMemoryCost {
    static func estimatedSize(of image: NSImage) -> Int {
        var proposedRect = NSRect(origin: .zero, size: image.size)
        if let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) {
            let cost = byteCount(bytesPerRow: cgImage.bytesPerRow, height: cgImage.height)
            if cost > 0 {
                return cost
            }
        }

        return fallbackRepresentationSize(image.representations)
    }

    static func fallbackRepresentationSize(_ representations: [NSImageRep]) -> Int {
        var total = 0
        for representation in representations {
            let cost: Int
            if let bitmap = representation as? NSBitmapImageRep {
                cost = byteCount(bytesPerRow: bitmap.bytesPerRow, height: bitmap.pixelsHigh)
            } else {
                cost = pixelCost(
                    width: representation.pixelsWide,
                    height: representation.pixelsHigh,
                    bytesPerPixel: 4
                )
            }

            let (sum, overflow) = total.addingReportingOverflow(cost)
            if overflow {
                return Int.max
            }
            total = sum
        }
        return total
    }

    static func byteCount(bytesPerRow: Int, height: Int) -> Int {
        guard bytesPerRow > 0, height > 0 else { return 0 }
        let (cost, overflow) = bytesPerRow.multipliedReportingOverflow(by: height)
        return overflow ? Int.max : cost
    }

    static func pixelCost(width: Int, height: Int, bytesPerPixel: Int) -> Int {
        guard width > 0, height > 0, bytesPerPixel > 0 else { return 0 }
        let (pixels, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        guard !pixelOverflow else { return Int.max }
        let (cost, byteOverflow) = pixels.multipliedReportingOverflow(by: bytesPerPixel)
        return byteOverflow ? Int.max : cost
    }
}
