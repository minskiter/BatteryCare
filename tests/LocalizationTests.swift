// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

@main struct LocalizationTests {
    @MainActor static func main() throws {
        let original = L10n.language
        defer { L10n.setLanguage(original, persist: false) }
        let keys = Set(L10n.catalogs[.english]?.keys.map { $0 } ?? [])
        precondition(keys.count >= 80, "Missing localization resources")
        for language in AppLanguage.allCases {
            let entries = L10n.catalogs[language]!
            precondition(Set(entries.keys) == keys, "Incomplete catalog: \(language)")
            precondition(entries.values.allSatisfy { !$0.isEmpty })
            for key in keys {
                let baseCount = L10n.catalogs[.english]![key]!.components(separatedBy: "%@").count
                precondition(entries[key]!.components(separatedBy: "%@").count == baseCount, "Format mismatch: \(key)")
            }
            L10n.setLanguage(language, persist: false)
            precondition(L10n.format("battery.cycles", "42").contains("42"))
            precondition(L10n.format("temperature.limit", "80").contains("80"))
            let composite = L10n.text("电源控制助手：permission denied")
            precondition(composite.hasSuffix("permission denied"))
            precondition(composite.hasPrefix(entries["电源控制助手："]!))
        }
        for (identifiers, expected) in [
            (["en-US"], AppLanguage.english), (["zh-CN"], .simplifiedChinese),
            (["zh-Hans-TW"], .simplifiedChinese), (["zh-TW"], .traditionalChinese),
            (["zh_HK"], .traditionalChinese), (["zh-MO"], .traditionalChinese),
            (["zh-Hant-CN"], .traditionalChinese), (["ja-JP"], .japanese),
            (["fr-FR", "ja"], .japanese), (["de"], .english), ([], .english)
        ] { precondition(AppLanguage.preferred(from: identifiers) == expected) }
        let suite = "BatteryCare.LocalizationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        precondition(L10n.selectedLanguage(defaults: defaults, preferred: ["ja"]) == .japanese)
        defaults.set("zh-Hant", forKey: L10n.preferenceKey)
        precondition(L10n.selectedLanguage(defaults: defaults, preferred: ["en"]) == .traditionalChinese)
        defaults.set("invalid", forKey: L10n.preferenceKey)
        precondition(L10n.selectedLanguage(defaults: defaults, preferred: ["ja"]) == .japanese)
        let model = BatteryModel(poll: false)
        var updates = 0
        model.onUpdate = { updates += 1 }
        for language in AppLanguage.allCases {
            model.setLanguage(language, persist: false)
            precondition(model.language == language && L10n.language == language)
            precondition(model.chargingDescription == L10n.catalogs[language]!["充电状态未知"])
            precondition(L10n.text("运行参数超出安全范围。") == L10n.catalogs[language]!["运行参数超出安全范围。"])
        }
        precondition(updates == 4)
        print("PASS four complete catalogs, placeholders, composite errors, system language detection, saved preference and live model switching")
    }
}
