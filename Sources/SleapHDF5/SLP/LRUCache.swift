/// Generic LRU (Least Recently Used) cache with O(1) lookup, insert, and eviction.
///
/// Uses a dictionary for fast lookup and a doubly-linked list for eviction ordering.
/// When capacity is exceeded, the least recently used entry is evicted.
///
/// **Identity stability note:** Within capacity, cached values are stable.
/// Evicted entries are lost and will be re-created on next access.
final class LRUCache<Key: Hashable, Value> {
    private final class Node {
        let key: Key
        var value: Value
        var prev: Node?
        var next: Node?

        init(key: Key, value: Value) {
            self.key = key
            self.value = value
        }
    }

    private var map: [Key: Node] = [:]
    private var head: Node?  // most recently used
    private var tail: Node?  // least recently used
    let capacity: Int

    var count: Int { map.count }

    init(capacity: Int) {
        precondition(capacity > 0, "LRU cache capacity must be positive")
        self.capacity = capacity
    }

    /// Retrieve value for key, promoting it to most-recently-used.
    func get(_ key: Key) -> Value? {
        guard let node = map[key] else { return nil }
        moveToHead(node)
        return node.value
    }

    /// Check if a key exists without promoting it (no side effects on ordering).
    func contains(_ key: Key) -> Bool {
        map[key] != nil
    }

    /// Insert or update a value, promoting it to most-recently-used.
    /// Evicts the least-recently-used entry if over capacity.
    func set(_ key: Key, value: Value) {
        if let existing = map[key] {
            existing.value = value
            moveToHead(existing)
            return
        }

        let node = Node(key: key, value: value)
        map[key] = node
        addToHead(node)

        if map.count > capacity {
            evictTail()
        }
    }

    /// All cached keys (unordered).
    var keys: [Key] { Array(map.keys) }

    // MARK: - Linked list operations

    private func addToHead(_ node: Node) {
        node.prev = nil
        node.next = head
        head?.prev = node
        head = node
        if tail == nil { tail = node }
    }

    private func removeNode(_ node: Node) {
        let prev = node.prev
        let next = node.next
        prev?.next = next
        next?.prev = prev
        if head === node { head = next }
        if tail === node { tail = prev }
        node.prev = nil
        node.next = nil
    }

    private func moveToHead(_ node: Node) {
        guard head !== node else { return }
        removeNode(node)
        addToHead(node)
    }

    private func evictTail() {
        guard let tailNode = tail else { return }
        map.removeValue(forKey: tailNode.key)
        removeNode(tailNode)
    }
}
