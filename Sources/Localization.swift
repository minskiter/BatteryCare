// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en", simplifiedChinese = "zh-Hans", traditionalChinese = "zh-Hant", japanese = "ja"
    var id: String { rawValue }
    // Autonyms make the language selector usable regardless of the current language.
    var displayName: String {
        switch self {
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        case .traditionalChinese: return "繁體中文"
        case .japanese: return "日本語"
        }
    }
    static func preferred(from identifiers: [String]) -> AppLanguage {
        for identifier in identifiers {
            let parts = identifier.replacingOccurrences(of: "_", with: "-").lowercased().split(separator: "-").map(String.init)
            guard let first = parts.first else { continue }
            if first == "en" { return .english }
            if first == "ja" { return .japanese }
            if first == "zh" {
                if parts.contains("hant") { return .traditionalChinese }
                if parts.contains("hans") { return .simplifiedChinese }
                return parts.contains(where: { ["tw", "hk", "mo"].contains($0) }) ? .traditionalChinese : .simplifiedChinese
            }
        }
        return .english
    }
}

// Localization is shared by AppKit and SwiftUI. Only the selection is mutable;
// protect it because diagnostics may also be presented from async engine tasks.
enum L10n {
    static let preferenceKey = "BatteryCare.language"
    private static let lock = NSLock()
    private static var selection = selectedLanguage(defaults: .standard, preferred: Locale.preferredLanguages)
    static var language: AppLanguage { lock.lock(); defer { lock.unlock() }; return selection }
    static func selectedLanguage(defaults: UserDefaults, preferred: [String]) -> AppLanguage {
        if let value = defaults.string(forKey: preferenceKey), let language = AppLanguage(rawValue: value) { return language }
        return AppLanguage.preferred(from: preferred)
    }
    static func setLanguage(_ language: AppLanguage, persist: Bool = true) {
        lock.lock(); selection = language; lock.unlock()
        if persist { UserDefaults.standard.set(language.rawValue, forKey: preferenceKey) }
    }
    static let catalogDirectory: URL = {
        #if BATTERYBAR_TESTING
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Localizations")
        #else
        return Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Localizations")
        #endif
    }()
    static let catalogs: [AppLanguage: [String: String]] = {
        var result: [AppLanguage: [String: String]] = [:]
        for language in AppLanguage.allCases {
            let path = catalogDirectory.appendingPathComponent(language.rawValue + ".json")
            if let data = try? Data(contentsOf: path), let entries = try? JSONDecoder().decode([String: String].self, from: data) {
                result[language] = entries
            }
        }
        return result
    }()
    // Stored engine errors retain source keys, not a translation from an old
    // selection. Translate at presentation so existing errors switch instantly.
    private static let sourcePattern: NSRegularExpression = {
        let keys = (catalogs[.english] ?? [:]).keys.filter { $0.range(of: "[\\p{Han}]", options: .regularExpression) != nil }
        let escaped = keys.sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern(for:))
        return try! NSRegularExpression(pattern: escaped.isEmpty ? "(?!)" : escaped.joined(separator: "|"))
    }()
    static func text(_ key: String, language: AppLanguage? = nil) -> String {
        let language = language ?? self.language
        let entries = catalogs[language] ?? catalogs[.english] ?? [:]
        if let value = entries[key] { return value }
        var result = key
        for match in sourcePattern.matches(in: key, range: NSRange(key.startIndex..., in: key)).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let original = String(result[range])
            if let value = entries[original] { result.replaceSubrange(range, with: value) }
        }
        return result
    }
    static func format(_ key: String, _ value: String) -> String {
        String(format: text(key), locale: Locale(identifier: language.rawValue), value)
    }
}
