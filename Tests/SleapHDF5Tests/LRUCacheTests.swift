import XCTest
@testable import SleapHDF5

/// Tests for the internal LRU cache used by LazyFrameList.
final class LRUCacheTests: XCTestCase {

    // MARK: - Basic get/set

    func testBasicGetSet() {
        let cache = LRUCache<String, Int>(capacity: 5)
        cache.set("a", value: 1)
        cache.set("b", value: 2)

        XCTAssertEqual(cache.get("a"), 1)
        XCTAssertEqual(cache.get("b"), 2)
    }

    // MARK: - Returns nil for missing key

    func testReturnsNilForMissingKey() {
        let cache = LRUCache<String, Int>(capacity: 5)
        cache.set("a", value: 1)

        XCTAssertNil(cache.get("missing"))
    }

    // MARK: - Contains without promoting

    func testContainsWithoutPromoting() {
        let cache = LRUCache<Int, String>(capacity: 2)
        cache.set(1, value: "a")
        cache.set(2, value: "b")

        // contains should report presence without side effects
        XCTAssertTrue(cache.contains(1))
        XCTAssertTrue(cache.contains(2))
        XCTAssertFalse(cache.contains(3))

        // Insert a third element. If contains had promoted key 1, it would evict key 2.
        // Since contains does NOT promote, key 1 remains the LRU and gets evicted.
        cache.set(3, value: "c")

        XCTAssertNil(cache.get(1), "Key 1 should have been evicted as LRU since contains does not promote")
        XCTAssertEqual(cache.get(2), "b")
        XCTAssertEqual(cache.get(3), "c")
    }

    // MARK: - Evicts LRU when over capacity

    func testEvictsLRUWhenOverCapacity() {
        let cache = LRUCache<Int, String>(capacity: 2)
        cache.set(1, value: "a")
        cache.set(2, value: "b")
        cache.set(3, value: "c")  // should evict key 1

        XCTAssertNil(cache.get(1), "LRU entry should be evicted")
        XCTAssertEqual(cache.get(2), "b")
        XCTAssertEqual(cache.get(3), "c")
    }

    // MARK: - Access promotes and prevents eviction

    func testAccessPromotesAndPreventsEviction() {
        let cache = LRUCache<Int, String>(capacity: 2)
        cache.set(1, value: "a")
        cache.set(2, value: "b")

        // Access key 1 to promote it to most-recently-used
        _ = cache.get(1)

        // Insert key 3 — should evict key 2 (now LRU), not key 1
        cache.set(3, value: "c")

        XCTAssertEqual(cache.get(1), "a", "Promoted key should not be evicted")
        XCTAssertNil(cache.get(2), "Un-promoted key should be evicted")
        XCTAssertEqual(cache.get(3), "c")
    }

    // MARK: - Update existing key

    func testUpdateExistingKey() {
        let cache = LRUCache<String, Int>(capacity: 3)
        cache.set("x", value: 10)
        cache.set("x", value: 20)

        XCTAssertEqual(cache.get("x"), 20, "Value should be updated")
        XCTAssertEqual(cache.count, 1, "Updating should not add a new entry")
    }

    // MARK: - Keys reflects current state

    func testKeysReflectsCurrentState() {
        let cache = LRUCache<Int, String>(capacity: 3)
        cache.set(1, value: "a")
        cache.set(2, value: "b")
        cache.set(3, value: "c")

        let keys = Set(cache.keys)
        XCTAssertEqual(keys, [1, 2, 3])

        // Evict key 1
        cache.set(4, value: "d")
        let keysAfterEviction = Set(cache.keys)
        XCTAssertEqual(keysAfterEviction, [2, 3, 4])
        XCTAssertFalse(keysAfterEviction.contains(1))
    }

    // MARK: - Capacity of 1 works

    func testCapacityOfOneWorks() {
        let cache = LRUCache<Int, String>(capacity: 1)

        cache.set(1, value: "a")
        XCTAssertEqual(cache.get(1), "a")
        XCTAssertEqual(cache.count, 1)

        cache.set(2, value: "b")
        XCTAssertNil(cache.get(1), "Previous entry should be evicted at capacity 1")
        XCTAssertEqual(cache.get(2), "b")
        XCTAssertEqual(cache.count, 1)
    }

    // MARK: - Count tracks correctly

    func testCountTracksCorrectly() {
        let cache = LRUCache<Int, String>(capacity: 5)
        XCTAssertEqual(cache.count, 0)

        cache.set(1, value: "a")
        XCTAssertEqual(cache.count, 1)

        cache.set(2, value: "b")
        XCTAssertEqual(cache.count, 2)

        // Update does not increase count
        cache.set(1, value: "updated")
        XCTAssertEqual(cache.count, 2)
    }

    // MARK: - Eviction order is correct (oldest first)

    func testEvictionOrderIsOldestFirst() {
        let cache = LRUCache<Int, String>(capacity: 3)
        cache.set(1, value: "a")
        cache.set(2, value: "b")
        cache.set(3, value: "c")

        // Evict in insertion order: 1 is oldest, so inserting 4 evicts 1
        cache.set(4, value: "d")
        XCTAssertFalse(cache.contains(1), "Oldest entry (1) should be evicted first")
        XCTAssertTrue(cache.contains(2))

        // Now 2 is oldest (contains does not promote), so inserting 5 evicts 2
        cache.set(5, value: "e")
        XCTAssertFalse(cache.contains(2), "Next oldest (2) should be evicted second")
        XCTAssertTrue(cache.contains(3))
        XCTAssertTrue(cache.contains(4))
        XCTAssertTrue(cache.contains(5))
    }
}
