import Foundation

// E4.5 (partial): Identifiable conformance for the identity model types.
//
// All of these are reference types, so the standard library supplies a stable
// `id` (ObjectIdentifier) automatically. Conforming lets a SwiftUI `ForEach`
// iterate them directly (e.g. tracks, instances, videos in sidebars) without
// `id: \.self`. Equality/hashing remain identity-based, so the id is stable for
// the object's lifetime.
//
// The remaining part of E4.5 — @Observable / change-notification on mutation — is
// tracked separately (issue #31).

extension Node: Identifiable {}
extension Skeleton: Identifiable {}
extension Track: Identifiable {}
extension Video: Identifiable {}
extension Instance: Identifiable {}
extension LabeledFrame: Identifiable {}
extension Labels: Identifiable {}
