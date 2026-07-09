import XCTest
@testable import SleapIO

/// Negative-frame semantics: frame classification (``LabeledFrame/kind``) and the
/// propagation of ``LabeledFrame/isNegative`` through the merge cascade and
/// ``Labels/clean``.
///
/// Mirrors sleap-io's `is_negative` handling: a negative frame merged with a
/// populated one becomes non-negative; two negatives stay negative; `clean`
/// preserves negatives.
final class NegativeFrameTests: XCTestCase {

    // MARK: - Helpers

    private let skeleton = Skeleton(name: "fly", nodes: [Node(name: "body")])
    private let video = Video(filename: "neg.mp4")

    /// A user (non-predicted) instance with a single visible point.
    private func user(_ x: Float = 10, _ y: Float = 10, track: Track? = nil) -> Instance {
        Instance.from(numpy: [[x, y]], skeleton: skeleton, track: track)
    }

    /// A predicted instance with a single visible point.
    private func pred(_ x: Float = 10, _ y: Float = 10, score: Float = 0.9) -> PredictedInstance {
        PredictedInstance.from(numpy: [[x, y]], skeleton: skeleton, score: score)
    }

    /// A frame carrying the given user instances (empty by default).
    private func frame(_ instances: [Instance] = [],
                       negative: Bool = false,
                       index: Int = 3) -> LabeledFrame {
        LabeledFrame(video: video, frameIndex: index, instances: instances,
                     isNegative: negative)
    }

    /// A prediction-only frame (optionally negative).
    private func predictionFrame(negative: Bool = false, index: Int = 3) -> LabeledFrame {
        let f = frame(negative: negative, index: index)
        f.instances.append(pred())
        return f
    }

    /// Whether a conflict list reports that a negative marking was cleared.
    private func hasNegativeConflict(_ conflicts: [ConflictResolution]) -> Bool {
        conflicts.contains { $0.conflictType == .other("negativeFrame") }
    }

    // MARK: - Classification: kind / classify()

    func testKindIsUserForFrameWithUserInstances() {
        let f = frame([user()])
        XCTAssertEqual(f.kind, .user)
        XCTAssertEqual(f.classify(), .user)
    }

    func testKindIsNegativeForEmptyNegativeFrame() {
        let f = frame(negative: true)
        XCTAssertEqual(f.kind, .negative)
        XCTAssertEqual(f.classify(), .negative)
    }

    func testKindIsEmptyForTrulyEmptyFrame() {
        let f = frame()
        XCTAssertEqual(f.kind, .empty)
        XCTAssertEqual(f.classify(), .empty)
    }

    func testKindIsEmptyForPredictionOnlyFrame() {
        // Predictions alone do not make a frame user-labeled.
        let f = predictionFrame()
        XCTAssertFalse(f.hasUserInstances)
        XCTAssertEqual(f.kind, .empty)
    }

    func testKindIsNegativeForPredictionOnlyNegativeFrame() {
        // With no user instances, an explicit negative marking classifies the
        // frame as negative even if predictions are present.
        let f = predictionFrame(negative: true)
        XCTAssertEqual(f.kind, .negative)
    }

    func testKindUserWinsOverInconsistentNegativeMarking() {
        // Malformed input: marked negative yet carrying user instances. Presence
        // of user instances wins, matching the merge/clean invariant.
        let f = frame([user()], negative: true)
        XCTAssertEqual(f.kind, .user)
    }

    func testKindHasExactlyThreeCases() {
        XCTAssertEqual(Set(LabeledFrame.Kind.allCases), [.user, .negative, .empty])
    }

    // MARK: - merge: .auto

    func testAutoNegativePlusPopulatedBecomesNonNegative() throws {
        let base = frame(negative: true)
        let conflicts = try base.merge(from: frame([user()]), strategy: .auto)

        XCTAssertFalse(base.isNegative)
        XCTAssertEqual(base.instances.count, 1)
        XCTAssertEqual(base.kind, .user)
        XCTAssertTrue(hasNegativeConflict(conflicts))
    }

    func testAutoNegativePlusNegativeStaysNegative() throws {
        let base = frame(negative: true)
        let conflicts = try base.merge(from: frame(negative: true), strategy: .auto)

        XCTAssertTrue(base.isNegative)
        XCTAssertTrue(base.instances.isEmpty)
        XCTAssertEqual(base.kind, .negative)
        XCTAssertTrue(conflicts.isEmpty)
    }

    func testAutoPopulatedPlusNegativeClearsIncomingNegativeAssertion() throws {
        let base = frame([user()])
        let conflicts = try base.merge(from: frame(negative: true), strategy: .auto)

        XCTAssertFalse(base.isNegative)
        XCTAssertEqual(base.instances.count, 1)
        XCTAssertEqual(base.kind, .user)
        XCTAssertTrue(hasNegativeConflict(conflicts))
    }

    // MARK: - merge: .keepOriginal

    func testKeepOriginalPreservesBaseNegativeIgnoringPopulatedIncoming() throws {
        let base = frame(negative: true)
        let conflicts = try base.merge(from: frame([user()]), strategy: .keepOriginal)

        XCTAssertTrue(base.isNegative)
        XCTAssertTrue(base.instances.isEmpty)
        XCTAssertEqual(base.kind, .negative)
        XCTAssertTrue(conflicts.isEmpty)
    }

    func testKeepOriginalNegativePlusNegativeStaysNegative() throws {
        let base = frame(negative: true)
        let conflicts = try base.merge(from: frame(negative: true), strategy: .keepOriginal)

        XCTAssertTrue(base.isNegative)
        XCTAssertEqual(base.kind, .negative)
        XCTAssertTrue(conflicts.isEmpty)
    }

    func testKeepOriginalPopulatedIgnoresIncomingNegative() throws {
        let base = frame([user()])
        let conflicts = try base.merge(from: frame(negative: true), strategy: .keepOriginal)

        XCTAssertFalse(base.isNegative)
        XCTAssertEqual(base.instances.count, 1)
        XCTAssertEqual(base.kind, .user)
        XCTAssertTrue(conflicts.isEmpty)
    }

    // MARK: - merge: .keepNew

    func testKeepNewTakesIncomingPopulatedOverNegativeBase() throws {
        let base = frame(negative: true)
        let conflicts = try base.merge(from: frame([user()]), strategy: .keepNew)

        XCTAssertFalse(base.isNegative)
        XCTAssertEqual(base.instances.count, 1)
        XCTAssertEqual(base.kind, .user)
        XCTAssertTrue(conflicts.isEmpty)
    }

    func testKeepNewTakesIncomingNegativeOverPopulatedBase() throws {
        let base = frame([user()])
        let conflicts = try base.merge(from: frame(negative: true), strategy: .keepNew)

        XCTAssertTrue(base.isNegative)
        XCTAssertTrue(base.instances.isEmpty)
        XCTAssertEqual(base.kind, .negative)
        XCTAssertTrue(conflicts.isEmpty)
    }

    func testKeepNewNegativePlusNegativeStaysNegative() throws {
        let base = frame(negative: true)
        let conflicts = try base.merge(from: frame(negative: true), strategy: .keepNew)

        XCTAssertTrue(base.isNegative)
        XCTAssertEqual(base.kind, .negative)
        XCTAssertTrue(conflicts.isEmpty)
    }

    // MARK: - merge: .keepBoth

    func testKeepBothNegativePlusPopulatedBecomesNonNegative() throws {
        let base = frame(negative: true)
        let conflicts = try base.merge(from: frame([user()]), strategy: .keepBoth)

        XCTAssertFalse(base.isNegative)
        XCTAssertEqual(base.instances.count, 1)
        XCTAssertEqual(base.kind, .user)
        XCTAssertTrue(hasNegativeConflict(conflicts))
    }

    func testKeepBothNegativePlusNegativeStaysNegative() throws {
        let base = frame(negative: true)
        let conflicts = try base.merge(from: frame(negative: true), strategy: .keepBoth)

        XCTAssertTrue(base.isNegative)
        XCTAssertTrue(base.instances.isEmpty)
        XCTAssertEqual(base.kind, .negative)
        XCTAssertTrue(conflicts.isEmpty)
    }

    func testKeepBothPopulatedPlusNegativeClearsIncomingNegative() throws {
        let base = frame([user()])
        let conflicts = try base.merge(from: frame(negative: true), strategy: .keepBoth)

        XCTAssertFalse(base.isNegative)
        XCTAssertEqual(base.instances.count, 1)
        XCTAssertEqual(base.kind, .user)
        XCTAssertTrue(hasNegativeConflict(conflicts))
    }

    // MARK: - merge: .updateTracks

    func testUpdateTracksNegativePlusPopulatedStaysNegativeSinceNoInstancesAdded() throws {
        // updateTracks never adds instances, so the frame stays empty and the
        // negative marking legitimately survives.
        let base = frame(negative: true)
        let conflicts = try base.merge(from: frame([user()]), strategy: .updateTracks)

        XCTAssertTrue(base.isNegative)
        XCTAssertTrue(base.instances.isEmpty)
        XCTAssertEqual(base.kind, .negative)
        XCTAssertTrue(conflicts.isEmpty)
    }

    func testUpdateTracksNegativePlusNegativeStaysNegative() throws {
        let base = frame(negative: true)
        let conflicts = try base.merge(from: frame(negative: true), strategy: .updateTracks)

        XCTAssertTrue(base.isNegative)
        XCTAssertEqual(base.kind, .negative)
        XCTAssertTrue(conflicts.isEmpty)
    }

    func testUpdateTracksPopulatedPlusNegativeClearsIncomingNegative() throws {
        let base = frame([user()])
        let conflicts = try base.merge(from: frame(negative: true), strategy: .updateTracks)

        XCTAssertFalse(base.isNegative)
        XCTAssertEqual(base.instances.count, 1)
        XCTAssertEqual(base.kind, .user)
        XCTAssertTrue(hasNegativeConflict(conflicts))
    }

    // MARK: - merge: .replacePredictions

    func testReplacePredictionsNegativePlusPredictionBecomesNonNegative() throws {
        let base = frame(negative: true)
        let conflicts = try base.merge(from: predictionFrame(), strategy: .replacePredictions)

        XCTAssertFalse(base.isNegative)
        XCTAssertEqual(base.instances.count, 1)
        // Prediction-only: populated but not user-labeled.
        XCTAssertEqual(base.kind, .empty)
        XCTAssertTrue(hasNegativeConflict(conflicts))
    }

    func testReplacePredictionsNegativePlusUserOnlyStaysNegativeSinceNoPredictionsAdded() throws {
        // replacePredictions only adds incoming *predictions*; an incoming user
        // instance is dropped, so the empty negative frame stays negative.
        let base = frame(negative: true)
        let conflicts = try base.merge(from: frame([user()]), strategy: .replacePredictions)

        XCTAssertTrue(base.isNegative)
        XCTAssertTrue(base.instances.isEmpty)
        XCTAssertEqual(base.kind, .negative)
        XCTAssertTrue(conflicts.isEmpty)
    }

    func testReplacePredictionsNegativePlusNegativeStaysNegative() throws {
        let base = frame(negative: true)
        let conflicts = try base.merge(from: frame(negative: true), strategy: .replacePredictions)

        XCTAssertTrue(base.isNegative)
        XCTAssertTrue(base.instances.isEmpty)
        XCTAssertEqual(base.kind, .negative)
        XCTAssertTrue(conflicts.isEmpty)
    }

    func testReplacePredictionsPopulatedUserPlusNegativeClearsIncomingNegative() throws {
        let base = frame([user()])
        let conflicts = try base.merge(from: frame(negative: true), strategy: .replacePredictions)

        XCTAssertFalse(base.isNegative)
        XCTAssertEqual(base.userInstances.count, 1)
        XCTAssertEqual(base.kind, .user)
        XCTAssertTrue(hasNegativeConflict(conflicts))
    }

    // MARK: - clean: negatives preserved, prediction-only kept, empty pruned

    func testCleanPreservesNegativesAndPredictionsWhileRemovingEmptyFrames() throws {
        let userFrame = frame([user()], index: 0)          // .user  -> kept
        let emptyFrame = frame(index: 1)                    // .empty (no instances) -> removed
        let negativeFrame = frame(negative: true, index: 2) // .negative -> kept
        let predFrame = predictionFrame(index: 3)           // .empty but has an instance -> kept

        let labels = Labels(
            frameStore: EagerFrameStore(
                frames: [userFrame, emptyFrame, negativeFrame, predFrame]),
            videos: [video],
            skeletons: [skeleton],
            tracks: []
        )

        try labels.clean()

        XCTAssertEqual(labels.map { $0.frameIndex }.sorted(), [0, 2, 3])
        XCTAssertNil(labels.frame(for: video, at: 1))

        let survivingNegative = try XCTUnwrap(labels.frame(for: video, at: 2))
        XCTAssertTrue(survivingNegative.isNegative)
        XCTAssertEqual(survivingNegative.kind, .negative)

        let survivingPrediction = try XCTUnwrap(labels.frame(for: video, at: 3))
        XCTAssertEqual(survivingPrediction.instances.count, 1)
        XCTAssertEqual(survivingPrediction.kind, .empty)
    }
}
