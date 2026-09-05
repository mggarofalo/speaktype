import Foundation

/// A published SpeakType source tag that is newer than the installed app.
struct AppVersion: Equatable {
    let version: String
    let tagName: String
    let sourceURL: URL

    init?(tagName: String) {
        guard let semanticVersion = SemanticVersion(tagName), semanticVersion.isStable,
              let sourceURL = Self.sourceURL(for: tagName)
        else {
            return nil
        }

        self.version = semanticVersion.displayVersion
        self.tagName = tagName
        self.sourceURL = sourceURL
    }

    /// Compare stable or prerelease semantic versions. Invalid values are never newer.
    static func isNewerVersion(_ newVersion: String, than currentVersion: String) -> Bool {
        guard let newVersion = SemanticVersion(newVersion),
              let currentVersion = SemanticVersion(currentVersion)
        else {
            return false
        }
        return newVersion > currentVersion
    }

    /// Choose the highest stable semantic-version tag, independent of API ordering.
    static func latestStable(from tags: [GitHubTag]) -> AppVersion? {
        tags.compactMap { AppVersion(tagName: $0.name) }
            .max {
                guard let lhs = SemanticVersion($0.version),
                      let rhs = SemanticVersion($1.version)
                else {
                    return $0.tagName < $1.tagName
                }

                if lhs == rhs {
                    return $0.tagName < $1.tagName
                }
                return lhs < rhs
            }
    }

    /// Get current app version from bundle.
    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    private static func sourceURL(for tagName: String) -> URL? {
        // AppVersion accepts only strict SemVer tags, so the path component cannot
        // redirect to another host or escape this repository's source tree.
        URL(string: "https://github.com/mggarofalo/speaktype/tree/")?
            .appendingPathComponent(tagName)
    }
}

/// The subset of GitHub's repository-tags response used by the updater.
struct GitHubTag: Codable, Equatable {
    let name: String
}

/// Strict SemVer 2.0 precedence, with an optional lowercase `v` tag prefix.
private struct SemanticVersion: Comparable {
    let displayVersion: String
    let major: String
    let minor: String
    let patch: String
    let prerelease: [String]

    var isStable: Bool { prerelease.isEmpty }

    init?(_ value: String) {
        let corePattern = #"^(?:v)?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"#
        let suffixPattern = #"(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$"#
        let pattern = corePattern + suffixPattern
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: value,
                range: NSRange(value.startIndex..., in: value)
              ),
              match.range == NSRange(value.startIndex..., in: value),
              let majorRange = Range(match.range(at: 1), in: value),
              let minorRange = Range(match.range(at: 2), in: value),
              let patchRange = Range(match.range(at: 3), in: value)
        else {
            return nil
        }

        let prerelease: [String]
        if let range = Range(match.range(at: 4), in: value) {
            prerelease = value[range].split(separator: ".").map(String.init)
            guard prerelease.allSatisfy({ identifier in
                !identifier.allSatisfy(\.isNumber)
                    || identifier == "0"
                    || !identifier.hasPrefix("0")
            }) else {
                return nil
            }
        } else {
            prerelease = []
        }

        self.displayVersion = value.hasPrefix("v") ? String(value.dropFirst()) : value
        self.major = String(value[majorRange])
        self.minor = String(value[minorRange])
        self.patch = String(value[patchRange])
        self.prerelease = prerelease
    }

    static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        compareNumeric(lhs.major, rhs.major) == 0
            && compareNumeric(lhs.minor, rhs.minor) == 0
            && compareNumeric(lhs.patch, rhs.patch) == 0
            && comparePrerelease(lhs.prerelease, rhs.prerelease) == 0
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        for (left, right) in [
            (lhs.major, rhs.major),
            (lhs.minor, rhs.minor),
            (lhs.patch, rhs.patch)
        ] {
            let comparison = compareNumeric(left, right)
            if comparison != 0 { return comparison < 0 }
        }
        return comparePrerelease(lhs.prerelease, rhs.prerelease) < 0
    }

    /// Compare arbitrary-size, leading-zero-free decimal identifiers.
    private static func compareNumeric(_ lhs: String, _ rhs: String) -> Int {
        if lhs.count != rhs.count { return lhs.count < rhs.count ? -1 : 1 }
        if lhs == rhs { return 0 }
        return lhs < rhs ? -1 : 1
    }

    private static func comparePrerelease(_ lhs: [String], _ rhs: [String]) -> Int {
        if lhs.isEmpty || rhs.isEmpty {
            if lhs.isEmpty && rhs.isEmpty { return 0 }
            return lhs.isEmpty ? 1 : -1
        }

        for index in 0..<min(lhs.count, rhs.count) {
            let left = lhs[index]
            let right = rhs[index]
            if left == right { continue }

            let leftIsNumeric = left.allSatisfy(\.isNumber)
            let rightIsNumeric = right.allSatisfy(\.isNumber)
            if leftIsNumeric && rightIsNumeric { return compareNumeric(left, right) }
            if leftIsNumeric != rightIsNumeric { return leftIsNumeric ? -1 : 1 }
            return left < right ? -1 : 1
        }

        if lhs.count == rhs.count { return 0 }
        return lhs.count < rhs.count ? -1 : 1
    }
}

// MARK: - Mock Data (for Previews)

extension AppVersion {
    static var mockUpdate: AppVersion {
        guard let update = AppVersion(tagName: "v1.1.0") else {
            preconditionFailure("The preview tag must be valid SemVer")
        }

        return update
    }
}
