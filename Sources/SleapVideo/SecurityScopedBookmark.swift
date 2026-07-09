import Foundation
import SleapIO

// MARK: - Security-scoped bookmark relocation (M4 / #63)
//
// On sandboxed platforms (iPadOS, and macOS with the App Sandbox) a plain file
// path is not enough to reopen a user-selected video across launches: the app
// must persist a *security-scoped bookmark* and re-acquire access on open. This
// mirrors the permanent-relocation strategy in HDF5_IPADOS_STRATEGY.md.
//
// The bookmark ``Data`` is persisted *alongside* ``Video/persistedFilename`` by
// stashing a base64 string in ``Video/backendMetadata`` (which round-trips
// through SLP save/load), so relocation survives a reopen. Resolving a bookmark
// can *refresh* the persisted path (permanent relocation), which is distinct
// from a purely in-memory ``Video/replaceFilename(_:keepOpen:)`` (temporary
// relocation) that carries no bookmark.

/// A security-scoped bookmark to a video file, wrapping the opaque bookmark
/// ``Data`` produced by `URL.bookmarkData` with resolve/refresh helpers.
public struct SecurityScopedBookmark: Sendable, Equatable {
    /// The opaque bookmark blob.
    public let data: Data

    public init(data: Data) {
        self.data = data
    }

    /// Reconstruct a bookmark from its base64 persistence form; `nil` if the
    /// string is not valid base64.
    public init?(base64: String) {
        guard let decoded = Data(base64Encoded: base64) else { return nil }
        self.data = decoded
    }

    /// The bookmark serialized as base64, for persistence in a JSON metadata map.
    public var base64: String { data.base64EncodedString() }

    // On macOS, security-scoped bookmarks require the explicit option; on
    // iOS/iPadOS the option does not exist (document-picker URLs are already
    // scoped), so an empty option set is used.
    #if os(macOS)
    private static let creationOptions: URL.BookmarkCreationOptions = [.withSecurityScope]
    private static let resolutionOptions: URL.BookmarkResolutionOptions = [.withSecurityScope]
    #else
    private static let creationOptions: URL.BookmarkCreationOptions = []
    private static let resolutionOptions: URL.BookmarkResolutionOptions = []
    #endif

    /// Create a security-scoped bookmark for `url`.
    ///
    /// - Note: On sandboxed macOS the process must currently hold access to
    ///   `url` (e.g. via a user open-panel selection) for creation to succeed.
    public static func create(for url: URL) throws -> SecurityScopedBookmark {
        let data = try url.bookmarkData(
            options: creationOptions,
            includingResourceValuesForKeys: nil,
            relativeTo: nil)
        return SecurityScopedBookmark(data: data)
    }

    /// The outcome of resolving a bookmark: the file URL and whether the bookmark
    /// is stale (the file moved and the bookmark should be re-created).
    public struct Resolved: Sendable, Equatable {
        public let url: URL
        public let isStale: Bool
    }

    /// Resolve the bookmark to a file URL, reporting staleness.
    public func resolve() throws -> Resolved {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: Self.resolutionOptions,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale)
        return Resolved(url: url, isStale: isStale)
    }
}

// MARK: - Video relocation bookmark helpers

extension Video {
    /// Metadata key under which the security-scoped bookmark (base64) is
    /// persisted in ``backendMetadata`` so it survives save/load.
    static let bookmarkMetadataKey = "bookmark"

    /// The persisted security-scoped bookmark for this video, if any.
    ///
    /// Backed by ``backendMetadata`` (`"bookmark"` key, stored as base64 so it is
    /// JSON-serializable). Assigning `nil` removes it.
    public var securityScopedBookmark: SecurityScopedBookmark? {
        get {
            if let b64 = backendMetadata[Video.bookmarkMetadataKey] as? String {
                return SecurityScopedBookmark(base64: b64)
            }
            if let data = backendMetadata[Video.bookmarkMetadataKey] as? Data {
                return SecurityScopedBookmark(data: data)
            }
            return nil
        }
        set {
            if let newValue {
                backendMetadata[Video.bookmarkMetadataKey] = newValue.base64
            } else {
                backendMetadata.removeValue(forKey: Video.bookmarkMetadataKey)
            }
        }
    }

    /// The file URL for the current effective ``filename`` (stripping a `file://`
    /// scheme if present).
    private var fileURL: URL {
        if filename.hasPrefix("file://"), let url = URL(string: filename) {
            return url
        }
        return URL(fileURLWithPath: filename)
    }

    /// Create and persist a security-scoped bookmark for the current
    /// ``filename``, enabling permanent relocation across app launches.
    ///
    /// - Returns: The created bookmark (also stored in ``securityScopedBookmark``).
    @discardableResult
    public func persistSecurityScopedBookmark() throws -> SecurityScopedBookmark {
        let bookmark = try SecurityScopedBookmark.create(for: fileURL)
        securityScopedBookmark = bookmark
        return bookmark
    }

    /// Resolve the persisted bookmark to a file URL, optionally refreshing the
    /// stored path/bookmark (permanent relocation).
    ///
    /// When `refresh` is `true` and the resolved path differs from the current
    /// ``filename``, ``replaceFilename(_:keepOpen:)`` records the relocation; if
    /// the bookmark reported itself stale, a fresh bookmark is re-persisted.
    ///
    /// - Returns: The resolved file URL, or `nil` when no bookmark is persisted or
    ///   resolution fails (e.g. the file no longer exists).
    @discardableResult
    public func resolveRelocatedURL(refresh: Bool = true) -> URL? {
        guard let bookmark = securityScopedBookmark,
              let resolved = try? bookmark.resolve() else {
            return nil
        }
        if refresh {
            if resolved.url.path != fileURL.path {
                replaceFilename(resolved.url.path, keepOpen: false)
            }
            if resolved.isStale,
               let fresh = try? SecurityScopedBookmark.create(for: resolved.url) {
                securityScopedBookmark = fresh
            }
        }
        return resolved.url
    }

    /// Run `body` with security-scoped access to the video's resource.
    ///
    /// When a bookmark is persisted, it is resolved and
    /// `startAccessingSecurityScopedResource()` is called for the duration of
    /// `body` (balanced by a `stopAccessingSecurityScopedResource()` on return).
    /// When no bookmark is present, `body` runs against the plain ``filename``
    /// URL without scoping.
    public func withSecurityScopedAccess<T>(_ body: (URL) throws -> T) throws -> T {
        guard let bookmark = securityScopedBookmark else {
            return try body(fileURL)
        }
        let resolved = try bookmark.resolve()
        let didStart = resolved.url.startAccessingSecurityScopedResource()
        defer {
            if didStart { resolved.url.stopAccessingSecurityScopedResource() }
        }
        return try body(resolved.url)
    }
}
