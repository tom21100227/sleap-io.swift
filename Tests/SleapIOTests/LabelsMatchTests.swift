import XCTest
@testable import SleapIO

/// Tests for ``Labels/match(_:matchVideos:matchSkeletons:matchTracks:)``: pure
/// correspondence matching that never mutates either collection.
final class LabelsMatchTests: XCTestCase {
    private func makeSelf() -> (Labels, Video, Skeleton, Track) {
        let v = Video(filename: "a.mp4")
        let s = Skeleton(name: "s1", nodes: [Node(name: "head"), Node(name: "thorax")])
        let t = Track(name: "1")
        let labels = Labels(
            frameStore: EagerFrameStore(frames: []),
            videos: [v], skeletons: [s], tracks: [t])
        return (labels, v, s, t)
    }

    func testMatchBuildsCorrespondenceMaps() {
        let (selfLabels, v1, s1, t1) = makeSelf()

        let v2 = Video(filename: "a.mp4")   // same path -> matches v1
        let vx = Video(filename: "z.mp4")   // no match
        let s2 = Skeleton(name: "s2", nodes: [Node(name: "head"), Node(name: "thorax")])  // matches s1
        let sx = Skeleton(name: "sx", nodes: [Node(name: "wing"), Node(name: "leg")])     // no match
        let t2 = Track(name: "1")           // matches t1 by name
        let tx = Track(name: "9")           // no match
        let other = Labels(
            frameStore: EagerFrameStore(frames: []),
            videos: [v2, vx], skeletons: [s2, sx], tracks: [t2, tx])

        let result = selfLabels.match(other)

        XCTAssertTrue(result.videoMap[v2]! === v1)
        XCTAssertNil(result.videoMap[vx]!)
        XCTAssertTrue(result.skeletonMap[s2]! === s1)
        XCTAssertNil(result.skeletonMap[sx]!)
        XCTAssertTrue(result.trackMap[t2]! === t1)
        XCTAssertNil(result.trackMap[tx]!)

        XCTAssertEqual(result.nVideosMatched, 1)
        XCTAssertEqual(result.nSkeletonsMatched, 1)
        XCTAssertEqual(result.nTracksMatched, 1)
        XCTAssertFalse(result.allVideosMatched)
        XCTAssertFalse(result.allSkeletonsMatched)
        XCTAssertFalse(result.allTracksMatched)
        XCTAssertEqual(
            result.unmatchedVideos.map { ObjectIdentifier($0) }, [ObjectIdentifier(vx)])
        XCTAssertEqual(
            result.unmatchedSkeletons.map { ObjectIdentifier($0) }, [ObjectIdentifier(sx)])
        XCTAssertEqual(
            result.unmatchedTracks.map { ObjectIdentifier($0) }, [ObjectIdentifier(tx)])
    }

    func testMatchAllMatched() {
        let (selfLabels, v1, s1, t1) = makeSelf()
        let v2 = Video(filename: "a.mp4")
        let s2 = Skeleton(name: "s2", nodes: [Node(name: "head"), Node(name: "thorax")])
        let t2 = Track(name: "1")
        let other = Labels(
            frameStore: EagerFrameStore(frames: []),
            videos: [v2], skeletons: [s2], tracks: [t2])

        let result = selfLabels.match(other)

        XCTAssertTrue(result.allVideosMatched)
        XCTAssertTrue(result.allSkeletonsMatched)
        XCTAssertTrue(result.allTracksMatched)
        XCTAssertTrue(result.videoMap[v2]! === v1)
        XCTAssertTrue(result.skeletonMap[s2]! === s1)
        XCTAssertTrue(result.trackMap[t2]! === t1)
    }

    func testMatchDoesNotMutateEitherCollection() {
        let (selfLabels, _, _, _) = makeSelf()
        let v2 = Video(filename: "a.mp4")
        let s2 = Skeleton(name: "s2", nodes: [Node(name: "head"), Node(name: "thorax")])
        let t2 = Track(name: "1")
        let other = Labels(
            frameStore: EagerFrameStore(frames: []),
            videos: [v2], skeletons: [s2], tracks: [t2])

        let selfVideos = selfLabels.videos.count
        let selfSkeletons = selfLabels.skeletons.count
        let selfTracks = selfLabels.tracks.count
        let otherVideos = other.videos.count
        let otherSkeletons = other.skeletons.count

        _ = selfLabels.match(other)

        XCTAssertEqual(selfLabels.videos.count, selfVideos)
        XCTAssertEqual(selfLabels.skeletons.count, selfSkeletons)
        XCTAssertEqual(selfLabels.tracks.count, selfTracks)
        XCTAssertEqual(other.videos.count, otherVideos)
        XCTAssertEqual(other.skeletons.count, otherSkeletons)
        // match() records no provenance history (unlike merge()).
        XCTAssertNil(selfLabels.provenance["merge_history"])
    }

    func testMatchRespectsCustomMatchers() {
        let (selfLabels, _, _, _) = makeSelf()
        // A track that would match by name but not by identity.
        let t2 = Track(name: "1")
        let other = Labels(
            frameStore: EagerFrameStore(frames: []),
            videos: [], skeletons: [], tracks: [t2])

        let byName = selfLabels.match(other, matchTracks: TrackMatcher(method: .name))
        XCTAssertEqual(byName.nTracksMatched, 1)

        let byIdentity = selfLabels.match(other, matchTracks: TrackMatcher(method: .identity))
        XCTAssertEqual(byIdentity.nTracksMatched, 0)
    }
}
