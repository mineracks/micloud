import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// gitignore-style exclusions: files and folders micloud should never back up or forward-sync. A **single
/// shared filter**, consulted both at backfill enumeration and by the live watcher, so an excluded path is
/// invisible to both paths — no wasted transfer, and user control over what leaves their Mac.
///
/// Pattern rules (deliberately small and predictable, gitignore-flavoured):
///   • no `/`            → matches the **filename** (last path component): `*.tmp`, `.DS_Store`
///   • trailing `/`      → matches a **directory** name and everything under it: `node_modules/`, `.git/`
///   • contains `/`      → matches the **whole relative path**: `Library/Caches/*`, `*/Caches/*`
///   • `*` is a wildcard (via `fnmatch`); matching is **case-insensitive** (macOS filesystems are).
public struct ExclusionRules: Sendable, Equatable {
    public private(set) var patterns: [String]

    /// System/junk defaults every install starts with — noise you never want in a sovereign copy.
    public static let defaults: [String] = [
        ".DS_Store", ".localized", ".Spotlight-V100", ".Trashes", ".fseventsd", ".TemporaryItems",
        "Thumbs.db", "desktop.ini",
        "*.tmp", "*.temp", "*.swp", "*.crdownload", "*.part", "*.download",
        ".git/", "node_modules/", ".Trash/", "*/Caches/*", "*.photoslibrary/",
    ]

    public init(_ patterns: [String] = ExclusionRules.defaults) { self.patterns = patterns }

    public mutating func add(_ pattern: String) {
        let p = pattern.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty, !patterns.contains(p) else { return }
        patterns.append(p)
    }
    public mutating func remove(_ pattern: String) { patterns.removeAll { $0 == pattern } }

    /// True if `relativePath` (source-relative, `/`-separated, no leading slash) matches any exclusion.
    public func excludes(_ relativePath: String) -> Bool {
        let path = relativePath.hasPrefix("/") ? String(relativePath.dropFirst()) : relativePath
        guard !path.isEmpty else { return false }
        let comps = path.split(separator: "/").map(String.init)
        let name = comps.last ?? path

        for raw in patterns {
            if raw.hasSuffix("/") {                                   // directory pattern
                let dir = String(raw.dropLast())
                // exclude anything *under* a matching directory (check ancestor components)
                if comps.dropLast().contains(where: { Self.match(dir, $0) }) { return true }
                // …and the directory itself if it's the whole path
                if comps.count == 1 && Self.match(dir, name) { return true }
            } else if raw.contains("/") {                            // whole-path pattern (`*` spans slashes)
                if Self.match(raw, path) { return true }
            } else {                                                 // filename pattern
                if Self.match(raw, name) { return true }
            }
        }
        return false
    }

    /// Count of paths that survive the filter — handy for tests / a settings preview.
    public func kept<S: Sequence>(_ paths: S) -> Int where S.Element == String {
        paths.reduce(0) { $0 + (excludes($1) ? 0 : 1) }
    }

    private static func match(_ pattern: String, _ str: String) -> Bool {
        fnmatch(pattern, str, Int32(FNM_CASEFOLD)) == 0
    }
}
