import Combine
import Foundation

/// Side-effect boundary for GitHub's repository-tags endpoint.
protocol TagFetching {
    func fetchTags(page: Int, perPage: Int) async throws -> [GitHubTag]
}

/// Checks source tags for newer stable versions and manages update preferences.
class UpdateService: ObservableObject {
    static let shared = UpdateService()

    static let tagsPerPage = 100
    static let maximumTagPages = 10

    enum CheckStatus: Equatable {
        case updateAvailable(version: String)
        case upToDate(version: String)
        case failed

        var message: String {
            switch self {
            case .updateAvailable(let version):
                return "SpeakType \(version) is available."
            case .upToDate(let version):
                return "SpeakType \(version) is up to date."
            case .failed:
                return "Unable to check for updates. Try again later."
            }
        }

        var isError: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    @Published var availableUpdate: AppVersion?
    @Published var isCheckingForUpdates = false
    @Published var lastCheckDate: Date?
    @Published private(set) var checkStatus: CheckStatus?

    /// Requests presentation of the informational update window.
    let showUpdateWindowPublisher = PassthroughSubject<AppVersion, Never>()

    private let lastCheckDateKey = "lastUpdateCheckDate"
    private let skippedVersionKey = "skippedVersion"
    private let automaticCheckKey = "autoUpdate"
    private let lastReminderDateKey = "lastUpdateReminderDate"

    private let tagFetcher: TagFetching
    private let defaults: UserDefaults
    private let currentVersion: () -> String
    private let now: () -> Date

    init(
        tagFetcher: TagFetching = GitHubTagFetcher(),
        defaults: UserDefaults = .standard,
        currentVersion: @escaping () -> String = { AppVersion.currentVersion },
        now: @escaping () -> Date = Date.init
    ) {
        self.tagFetcher = tagFetcher
        self.defaults = defaults
        self.currentVersion = currentVersion
        self.now = now
        self.lastCheckDate = defaults.object(forKey: lastCheckDateKey) as? Date
    }

    // The target defaults to MainActor isolation. This type has no isolated
    // teardown work, so avoid a back-deployed main-actor deinit hop in tests.
    nonisolated deinit {}

    // MARK: - Update Checking

    enum UpdateDecision: Equatable {
        case none
        case surface(AppVersion)
    }

    /// A skipped version is suppressed only during a background check. A manual
    /// check always reports the latest stable tag.
    static func decideUpdate(
        releaseVersion: AppVersion,
        currentVersion: String,
        skippedVersion: String?,
        silent: Bool
    ) -> UpdateDecision {
        guard AppVersion.isNewerVersion(releaseVersion.version, than: currentVersion) else {
            return .none
        }
        if silent && skippedVersion == releaseVersion.version {
            return .none
        }
        return .surface(releaseVersion)
    }

    func checkForUpdates(silent: Bool = false) async {
        guard !isCheckingForUpdates else {
            return
        }

        isCheckingForUpdates = true
        if !silent { checkStatus = nil }

        do {
            let tags = try await fetchTagPages()
            let installedVersion = currentVersion()
            guard let latestVersion = AppVersion.latestStable(from: tags) else {
                throw GitHubTagError.noStableTags
            }

            let decision = Self.decideUpdate(
                releaseVersion: latestVersion,
                currentVersion: installedVersion,
                skippedVersion: defaults.string(forKey: skippedVersionKey),
                silent: silent
            )

            switch decision {
            case .surface(let version):
                availableUpdate = version
                if !silent {
                    checkStatus = .updateAvailable(version: version.version)
                    showUpdateWindowPublisher.send(version)
                } else if shouldShowReminder() {
                    showUpdateWindowPublisher.send(version)
                }
            case .none:
                availableUpdate = nil
                if !silent { checkStatus = .upToDate(version: installedVersion) }
            }

            lastCheckDate = now()
            defaults.set(lastCheckDate, forKey: lastCheckDateKey)
            isCheckingForUpdates = false
        } catch {
            AppLogger.error("Failed to check GitHub tags", error: error)
            if !silent { checkStatus = .failed }
            isCheckingForUpdates = false
        }
    }

    private func fetchTagPages() async throws -> [GitHubTag] {
        var allTags: [GitHubTag] = []

        for page in 1...Self.maximumTagPages {
            let tags = try await tagFetcher.fetchTags(page: page, perPage: Self.tagsPerPage)
            allTags.append(contentsOf: tags)
            if tags.count < Self.tagsPerPage { break }
            if page == Self.maximumTagPages {
                // A complete final page means more tags may exist. Refuse to make
                // a version claim from a deliberately truncated repository scan.
                throw GitHubTagError.pageLimitReached
            }
        }

        return allTags
    }

    /// Background checks run at most once every 24 hours.
    func shouldCheckForUpdates() -> Bool {
        guard let lastCheckDate else {
            return true
        }

        return now().timeIntervalSince(lastCheckDate) >= 24 * 60 * 60
    }

    /// Available updates are reminded at most once every 24 hours.
    func shouldShowReminder() -> Bool {
        guard availableUpdate != nil else {
            return false
        }

        guard let lastReminder = defaults.object(forKey: lastReminderDateKey) as? Date else {
            return true
        }

        return now().timeIntervalSince(lastReminder) >= 24 * 60 * 60
    }

    // MARK: - Version Management

    func skipVersion(_ version: String) {
        defaults.set(version, forKey: skippedVersionKey)
        availableUpdate = nil
        checkStatus = nil
    }

    func markReminderShown() {
        defaults.set(now(), forKey: lastReminderDateKey)
    }

    func clearSkippedVersion() {
        defaults.removeObject(forKey: skippedVersionKey)
    }

    // MARK: - Automatic Checks

    /// This preference is false until the user explicitly enables it.
    var isAutomaticCheckEnabled: Bool {
        get { defaults.bool(forKey: automaticCheckKey) }
        set { defaults.set(newValue, forKey: automaticCheckKey) }
    }
}

// MARK: - Tag Fetching

struct GitHubTagFetcher: TagFetching {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchTags(page: Int, perPage: Int) async throws -> [GitHubTag] {
        guard var components = URLComponents(
            string: "https://api.github.com/repos/mggarofalo/speaktype/tags"
        ) else {
            throw GitHubTagError.invalidRequest
        }

        components.queryItems = [
            URLQueryItem(name: "per_page", value: String(perPage)),
            URLQueryItem(name: "page", value: String(page))
        ]
        guard let url = components.url else {
            throw GitHubTagError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("SpeakType", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GitHubTagError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw GitHubTagError.httpStatus(httpResponse.statusCode)
        }
        return try JSONDecoder().decode([GitHubTag].self, from: data)
    }
}

enum GitHubTagError: LocalizedError {
    case invalidRequest
    case invalidResponse
    case httpStatus(Int)
    case noStableTags
    case pageLimitReached

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            return "The tag request could not be created."
        case .invalidResponse:
            return "GitHub returned an invalid response."
        case .httpStatus(let statusCode):
            return "GitHub returned HTTP \(statusCode)."
        case .noStableTags:
            return "GitHub returned no stable version tags."
        case .pageLimitReached:
            return "The repository has more tags than the update check can safely inspect."
        }
    }
}
