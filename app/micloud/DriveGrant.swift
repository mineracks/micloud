import AppKit

/// Sandbox folder access for the Documents/Drive source. The sandbox only lets us watch a folder the
/// user explicitly grants via an `NSOpenPanel` (powerbox); we persist a **security-scoped bookmark** so
/// later launches resolve it silently instead of re-prompting.
enum DriveGrant {
    private static let key = "micloud.drive.bookmark"

    /// Is a grant on file? (Cheap status check — does NOT start accessing the resource, so it is safe to poll.)
    static var hasSaved: Bool { UserDefaults.standard.data(forKey: key) != nil }

    /// Resolve a previously-granted folder (and begin accessing it). Nil if none saved / stale.
    static func saved() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope],
                                 relativeTo: nil, bookmarkDataIsStale: &stale), !stale else { return nil }
        return url.startAccessingSecurityScopedResource() ? url : nil
    }

    /// Prompt for a folder (main thread), persist a security-scoped bookmark, begin accessing. Nil if cancelled.
    @MainActor static func prompt(suggested: URL? = nil) -> URL? {
        let panel = NSOpenPanel()
        if let suggested { panel.directoryURL = suggested }
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        // Default = the whole iCloud Drive (Desktop + Documents live inside it when Apple's sync is on):
        // the panel opens there and the button names it, so "just click the orange button" is the whole task.
        panel.prompt = suggested == nil ? "Mirror this folder" : "Mirror iCloud Drive"
        panel.title = "Your iCloud Drive is selected"
        panel.message = "Click “Mirror iCloud Drive” to back up all of it — Desktop and Documents included. Or open a single folder and mirror just that. One-way: micloud never writes back."
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        if let data = try? url.bookmarkData(options: [.withSecurityScope],
                                            includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: key)
        }
        _ = url.startAccessingSecurityScopedResource()
        return url
    }
}
