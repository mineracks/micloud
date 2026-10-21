import Foundation

// iOS localization helper. Unlike the Mac app (which has a runtime language switcher), the iOS companion
// simply follows the OS language: iOS resolves the bundled <lang>.lproj automatically. `L` wraps
// NSLocalizedString + String(format:) for the interpolated strings, with English as the base table — and
// falls back to the English table for a key a language's table doesn't carry yet, so a new string shows in
// English rather than as its raw key.

private let enBundle: Bundle? = Bundle.main.path(forResource: "en", ofType: "lproj").flatMap { Bundle(path: $0) }
private let missing = "\u{1}"

func L(_ key: String, _ args: CVarArg...) -> String {
    var fmt = Bundle.main.localizedString(forKey: key, value: missing, table: nil)
    if fmt == missing { fmt = enBundle?.localizedString(forKey: key, value: key, table: nil) ?? key }
    return args.isEmpty ? fmt : String(format: fmt, locale: .current, arguments: args)
}

/// Localized display name for a source (mirrors the Mac app's source.* keys).
func sourceName(_ id: SourceID) -> String {
    switch id {
    case .photos: return L("source.photos"); case .documents: return L("source.documents")
    case .calendars: return L("source.calendars"); case .contacts: return L("source.contacts")
    case .reminders: return L("source.reminders"); case .notes: return L("source.notes")
    case .bookmarks: return L("source.bookmarks"); case .mail: return L("source.mail")
    case .health: return L("source.health"); case .messages: return L("source.messages")
    }
}
