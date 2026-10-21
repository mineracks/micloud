import Foundation
import SwiftUI

/// The UI language: follow the OS, or force one. Persisted so the choice survives relaunch.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, en, fr, es, pt, de, it, nl, ru, ja, ko, zhHans, zhHant, tr, pl, hi, ar
    var id: String { rawValue }

    /// The `.lproj` resource folder for this language.
    var lproj: String {
        switch self {
        case .system, .en: return "en"
        case .fr: return "fr"; case .es: return "es"; case .pt: return "pt"; case .de: return "de"
        case .it: return "it"; case .nl: return "nl"; case .ru: return "ru"; case .ja: return "ja"
        case .ko: return "ko"; case .zhHans: return "zh-Hans"; case .zhHant: return "zh-Hant"
        case .tr: return "tr"; case .pl: return "pl"; case .hi: return "hi"; case .ar: return "ar"
        }
    }
    var nativeName: String {
        switch self {
        case .system: return "System"; case .en: return "English"; case .fr: return "Français"
        case .es: return "Español"; case .pt: return "Português"; case .de: return "Deutsch"
        case .it: return "Italiano"; case .nl: return "Nederlands"; case .ru: return "Русский"
        case .ja: return "日本語"; case .ko: return "한국어"; case .zhHans: return "简体中文"
        case .zhHant: return "繁體中文"; case .tr: return "Türkçe"; case .pl: return "Polski"
        case .hi: return "हिन्दी"; case .ar: return "العربية"
        }
    }
    /// Short code shown on the header pill.
    var code: String {
        switch self {
        case .system: return "Auto"; case .en: return "EN"; case .fr: return "FR"; case .es: return "ES"
        case .pt: return "PT"; case .de: return "DE"; case .it: return "IT"; case .nl: return "NL"
        case .ru: return "RU"; case .ja: return "JA"; case .ko: return "KO"; case .zhHans: return "简"
        case .zhHant: return "繁"; case .tr: return "TR"; case .pl: return "PL"; case .hi: return "HI"; case .ar: return "AR"
        }
    }
    /// Flag emoji for the picker (globe for "follow the system").
    var flag: String {
        switch self {
        case .system: return "🌐"; case .en: return "🇬🇧"; case .fr: return "🇫🇷"; case .es: return "🇪🇸"
        case .pt: return "🇵🇹"; case .de: return "🇩🇪"; case .it: return "🇮🇹"; case .nl: return "🇳🇱"
        case .ru: return "🇷🇺"; case .ja: return "🇯🇵"; case .ko: return "🇰🇷"; case .zhHans: return "🇨🇳"
        case .zhHant: return "🇹🇼"; case .tr: return "🇹🇷"; case .pl: return "🇵🇱"; case .hi: return "🇮🇳"; case .ar: return "🇸🇦"
        }
    }
    var isRTL: Bool { self == .ar }
}

/// Best-practice localization for a runtime-switchable app: strings live in `<lang>.lproj/Localizable.strings`
/// (standard Apple `.strings` tables), and this resolves the active bundle — the user's override, or the OS
/// default among the languages we ship. Because it's an `ObservableObject`, changing the language re-renders
/// the whole UI live (no relaunch). Every on-screen label goes through `t(_:)`.
final class Localizer: ObservableObject {
    @Published var language: AppLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: Self.key) }
    }
    private static let key = "micloud.language"

    init() {
        language = UserDefaults.standard.string(forKey: Self.key).flatMap(AppLanguage.init(rawValue:)) ?? .system
    }

    /// The language actually in effect (resolving `.system` against the OS preference among our translations).
    var effective: AppLanguage {
        if language != .system { return language }
        let pref = (Bundle.main.preferredLocalizations.first ?? "en").lowercased()
        if pref.hasPrefix("zh-hant") || pref.hasPrefix("zh-tw") || pref.hasPrefix("zh-hk") || pref.hasPrefix("zh-mo") { return .zhHant }
        if pref.hasPrefix("zh") { return .zhHans }
        // match a 2-letter prefix against every shipped language
        for lang in AppLanguage.allCases where lang != .system && lang != .zhHans && lang != .zhHant {
            if pref.hasPrefix(lang.lproj.prefix(2)) { return lang }
        }
        return .en
    }

    private var activeBundle: Bundle {
        if let p = Bundle.main.path(forResource: effective.lproj, ofType: "lproj"), let b = Bundle(path: p) { return b }
        return .main
    }
    /// The English table — the fallback when a key hasn't been translated into the active language yet.
    private var enBundle: Bundle {
        if let p = Bundle.main.path(forResource: "en", ofType: "lproj"), let b = Bundle(path: p) { return b }
        return .main
    }
    private static let missing = "\u{0}MISSING\u{0}"   // sentinel: a value no real string equals

    /// Look up `key` in the active table; if untranslated there, fall back to **English**, then to the key
    /// itself. So a language we haven't fully translated degrades to English rather than showing raw keys.
    func t(_ key: String, _ args: CVarArg...) -> String {
        var fmt = activeBundle.localizedString(forKey: key, value: Self.missing, table: nil)
        if fmt == Self.missing { fmt = enBundle.localizedString(forKey: key, value: key, table: nil) }
        return args.isEmpty ? fmt : String(format: fmt, locale: Locale.current, arguments: args)
    }
}
