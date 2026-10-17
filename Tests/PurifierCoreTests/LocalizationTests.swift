// Check of the table from disk: the test bundle does not get the app's resources.
import Foundation
import Testing

private var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func ukrainianLocalization(table: String = "Localizable") throws -> [String: String] {
    let url = repositoryRoot.appendingPathComponent("Resources/Localization/uk.lproj/\(table).strings")
    let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
    return try #require(plist as? [String: String])
}

/// Sorting keeps duplicates; the position of the argument does not change its type.
private func formatSpecifiers(in text: String) throws -> [String] {
    let pattern = #"%%|%(?:[0-9]+\$)?[-+ #0]*[0-9]*(?:\.[0-9]+)?(?:hh|ll|h|l|j|z|t|L)?[@diuoxXfFeEgGaAcCsSp]"#
    let regex = try NSRegularExpression(pattern: pattern)
    return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        .compactMap { match -> String? in
            guard let range = Range(match.range, in: text) else { return nil }
            let specifier = String(text[range])
            return specifier.replacingOccurrences(of: #"^%[0-9]+\$"#, with: "%", options: .regularExpression)
        }
        .sorted()
}

@Test(arguments: ["Localizable", "EditMenu", "Schedule", "InfoPlist"])
func ukrainianLocalizationIsValid(table: String) throws {
    let strings = try ukrainianLocalization(table: table)
    #expect(!strings.isEmpty)
    for (key, value) in strings {
        #expect(!value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Empty translation: \(key)")
        #expect(key.range(of: #"\p{Cyrillic}"#, options: .regularExpression) == nil,
                "Cyrillic in key: \(key)")
        #expect(try formatSpecifiers(in: key) == formatSpecifiers(in: value),
                "Different format specifiers: \(key)")
    }
}

@Test func boostLocalizationKeysArePresent() throws {
    let strings = try ukrainianLocalization()
    let keys = [
        "Boost after: %lld min",
        "Stop boost after: %lld min",
        "After a manual command, boost waits until PM2.5 falls to or below the threshold.",
        "If PM2.5 stays above the threshold for %lld min, boost turns on. After %lld min at or below it, boost stops and the previous mode returns.",
    ]
    for key in keys {
        #expect(strings[key] != nil, "Missing boost key: \(key)")
    }
}

@Test func formatSpecifierNormalizationPreservesTypesAndCounts() throws {
    #expect(try formatSpecifiers(in: "%2$@ %1$lld %% %3$.1f %4$lld") == ["%%", "%.1f", "%@", "%lld", "%lld"])
    #expect(try formatSpecifiers(in: "%d %f %lf") == ["%d", "%f", "%lf"])
}

@Test func filterWithoutDaysHasUkrainianLocalization() throws {
    #expect(try ukrainianLocalization()["%lld %%"] == "%lld %%")
}

@Test func sourcesContainNoCyrillic() throws {
    let sources = repositoryRoot.appendingPathComponent("Sources")
    let files = try #require(FileManager.default.enumerator(
        at: sources, includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles], errorHandler: { _, _ in false }
    ))
    var swiftFileCount = 0
    for case let url as URL in files where url.pathExtension == "swift" {
        swiftFileCount += 1
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.range(of: #"\p{Cyrillic}"#, options: .regularExpression) == nil,
                "Cyrillic in source: \(url.path)")
    }
    #expect(swiftFileCount > 0)
}

@Test func ambiguousTranslationsUseSeparateTables() throws {
    #expect(try ukrainianLocalization(table: "Localizable")["No change"] == "Без змін")
    #expect(try ukrainianLocalization(table: "Schedule")["No change"] == "Не змінювати")
    #expect(try ukrainianLocalization(table: "EditMenu")["Redo"] == "Повторити")
    #expect(try ukrainianLocalization(table: "Localizable")["Retry"] == "Повторити")
}
