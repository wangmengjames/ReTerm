import Foundation

/// The language ReTerm shows: the system's, or one picked in its settings.
enum AppLanguage: String, CaseIterable {
    case system, english, chinese
}

enum Lang {
    static let key = "language"

    static var setting: AppLanguage {
        get { AppLanguage(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    /// Set by the command line for one run; never saved.
    static var override: AppLanguage?

    static var isChinese: Bool {
        switch override ?? setting {
        case .english: return false
        case .chinese: return true
        case .system: return Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
        }
    }

    static var locale: Locale { Locale(identifier: isChinese ? "zh-Hans" : "en") }
}

/// The text in ReTerm's current language.
func L(_ english: String, _ chinese: String) -> String {
    Lang.isChinese ? chinese : english
}
