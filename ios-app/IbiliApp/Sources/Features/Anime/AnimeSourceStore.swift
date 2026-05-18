import Foundation

@MainActor
final class AnimeSourceStore: ObservableObject {
    static let shared = AnimeSourceStore()

    static let defaultSubscriptionURLs = AppSettings.defaultAnimeSourceSubscriptionURLs

    @Published private(set) var sources: [AnimeSourceDTO] = []
    @Published private(set) var updatedAt: Int64 = 0

    private let sourcesKey = "ibili.anime.sources"
    private let updatedAtKey = "ibili.anime.sources.updatedAt"
    private let defaultLoadedKey = "ibili.anime.sources.defaultLoaded.v2"

    init() {
        load()
    }

    func enabledSourcesJSON() throws -> String {
        let enabled = sources.filter(\.enabled)
        return try sourcesJSON(for: enabled)
    }

    func sourceJSON(forSourceID sourceID: String) throws -> String {
        let selected = sources.filter { $0.enabled && $0.id == sourceID }
        guard !selected.isEmpty else {
            throw NSError(
                domain: "AnimeSourceStore",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "未找到可用的数据源"]
            )
        }
        return try sourcesJSON(for: selected)
    }

    func sourceJSON(for source: AnimeSourceDTO) throws -> String {
        try sourcesJSON(for: [source])
    }

    private func sourcesJSON(for sources: [AnimeSourceDTO]) throws -> String {
        let mediaSources = sources.map { source -> AnyCodableValue in
            .object([
                "factoryId": .string(source.factoryID),
                "version": .number(Double(source.version)),
                "arguments": source.arguments,
            ])
        }
        let root = AnyCodableValue.object([
            "mediaSources": .array(mediaSources),
        ])
        let data = try JSONEncoder().encode(root)
        return String(data: data, encoding: .utf8) ?? "{\"mediaSources\":[]}"
    }

    func replace(with update: AnimeSourceUpdateDTO) {
        sources = mergeRemote(update.sources)
        updatedAt = update.updatedAt
        save()
    }

    func setEnabled(_ enabled: Bool, for source: AnimeSourceDTO) {
        guard let index = sources.firstIndex(where: { $0.id == source.id }) else { return }
        sources[index].enabled = enabled
        save()
    }

    func updateCookie(_ cookie: String, forSourceID sourceID: String) {
        guard let index = sources.firstIndex(where: { $0.id == sourceID }) else { return }
        sources[index] = sources[index].withVideoCookie(cookie)
        save()
    }

    func importJSON(_ text: String) async throws {
        let update = try await Task.detached(priority: .userInitiated) {
            try CoreClient.shared.animeSourceImport(jsonText: text)
        }.value
        replace(with: update)
    }

    func updateSubscription(url: String) async throws {
        let update = try await Task.detached(priority: .userInitiated) {
            try CoreClient.shared.animeSourceSubscriptionUpdate(url: url)
        }.value
        sources = mergeRemote(combined([
            update,
            AnimeSourceUpdateDTO(sources: sources, updatedAt: updatedAt),
        ]).sources)
        updatedAt = max(updatedAt, update.updatedAt)
        save()
    }

    func ensureDefaultSubscriptionsLoaded() async {
        AppSettings.shared.ensureDefaultAnimeSourceSubscriptionURLs()
        guard !UserDefaults.standard.bool(forKey: defaultLoadedKey) || sources.isEmpty else { return }
        do {
            try await refreshConfiguredSubscriptions()
            UserDefaults.standard.set(true, forKey: defaultLoadedKey)
        } catch {
            AppLog.error("anime", "默认追番规则源加载失败", error: error)
        }
    }

    func refreshConfiguredSubscriptions() async throws {
        AppSettings.shared.ensureDefaultAnimeSourceSubscriptionURLs()
        try await refreshSubscriptions(urls: AppSettings.shared.animeSourceSubscriptionURLs)
    }

    func refreshDefaultSubscriptions() async throws {
        AppSettings.shared.customAnimeSourceSubscriptionURLs = []
        try await refreshConfiguredSubscriptions()
    }

    func refreshSubscriptions(urls: [String]) async throws {
        let urls = normalizedURLs(urls)
        let updates = try await Task.detached(priority: .userInitiated) {
            try urls.map { try CoreClient.shared.animeSourceSubscriptionUpdate(url: $0) }
        }.value
        replace(with: combined(updates))
        UserDefaults.standard.set(true, forKey: defaultLoadedKey)
    }

    private func mergeRemote(_ remote: [AnimeSourceDTO]) -> [AnimeSourceDTO] {
        let enabledByID = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0.enabled) })
        return remote.map { source in
            var copy = source
            copy.enabled = enabledByID[source.id] ?? source.enabled
            return copy
        }
    }

    private func load() {
        updatedAt = Int64(UserDefaults.standard.integer(forKey: updatedAtKey))
        guard let data = UserDefaults.standard.data(forKey: sourcesKey),
              let decoded = try? JSONDecoder().decode([AnimeSourceDTO].self, from: data) else {
            sources = []
            return
        }
        sources = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(sources) {
            UserDefaults.standard.set(data, forKey: sourcesKey)
        }
        UserDefaults.standard.set(updatedAt, forKey: updatedAtKey)
    }

    private func combined(_ updates: [AnimeSourceUpdateDTO]) -> AnimeSourceUpdateDTO {
        var merged: [AnimeSourceDTO] = []
        var seen = Set<String>()
        var updatedAt: Int64 = 0
        for update in updates {
            updatedAt = max(updatedAt, update.updatedAt)
            for source in update.sources where seen.insert(source.id).inserted {
                merged.append(source)
            }
        }
        return AnimeSourceUpdateDTO(sources: merged, updatedAt: updatedAt)
    }

    private func normalizedURLs(_ urls: [String]) -> [String] {
        var seen = Set<String>()
        return urls.compactMap { raw -> String? in
            let url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty, seen.insert(url).inserted else { return nil }
            return url
        }
    }
}

private extension AnimeSourceDTO {
    func withVideoCookie(_ cookie: String) -> AnimeSourceDTO {
        var root = arguments.objectValue
        var searchConfig = root["searchConfig"]?.objectValue ?? [:]
        var matchVideo = searchConfig["matchVideo"]?.objectValue ?? [:]
        var addHeaders = matchVideo["addHeadersToVideo"]?.objectValue ?? [:]
        addHeaders["cookie"] = .string(cookie)
        matchVideo["addHeadersToVideo"] = .object(addHeaders)
        searchConfig["matchVideo"] = .object(matchVideo)
        root["searchConfig"] = .object(searchConfig)
        return AnimeSourceDTO(
            id: id,
            factoryID: factoryID,
            version: version,
            name: name,
            description: description,
            iconURL: iconURL,
            tier: tier,
            enabled: enabled,
            arguments: .object(root)
        )
    }
}
