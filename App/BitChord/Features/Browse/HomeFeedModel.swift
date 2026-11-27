import BitChordCore
import Foundation

/// YouTube Music's Home shelves in server order, de-duplicated by title.
/// A newer request or listener invalidates every older answer, including pagination.
@MainActor
@Observable
final class HomeFeedModel {
    private(set) var state: LoadState<[HomeShelf]> = .loading
    private(set) var chips: [HomeChip] = []
    private(set) var selectedChip: HomeChip?
    private(set) var refreshing = false
    private(set) var loadedFor: String??
    private(set) var continuation: String?
    var loadingMore: Bool { pagingMore || loadingFirstPage }

    private struct Snapshot {
        var shelves: [HomeShelf]
        var chips: [HomeChip]
        var selectedChip: HomeChip?
    }

    private var snapshots: [String: Snapshot] = [:]
    private var pagingMore = false
    private var loadingFirstPage = false
    private var seenTitles: Set<String> = []
    private var generation = 0

    func isLoaded(for listener: String?) -> Bool { loadedFor == .some(listener) }

    /// Restore only this listener's page while fetching its fresh replacement.
    func load(_ catalog: BrowseCatalog, listener: String?, signedIn: Bool) async {
        let sameListener = isLoaded(for: listener)
        if listener == nil {
            snapshots.removeAll()
        } else if case .some(.some(let leaving)) = loadedFor, leaving != listener, let shelves = state.value {
            snapshots[leaving] = Snapshot(shelves: shelves, chips: chips, selectedChip: selectedChip)
        }
        let snapshot = listener.flatMap { snapshots.removeValue(forKey: $0) }
        if !sameListener {
            chips = snapshot?.chips ?? []
            selectedChip = snapshot?.selectedChip
        }
        state = snapshot.map { LoadState.success($0.shelves) } ?? .loading
        loadedFor = .some(listener)
        await loadFirstPage(catalog, listener: listener)
    }

    /// Re-tapping the selected chip (or clearing it) returns to the unfiltered Home.
    func selectChip(_ chip: HomeChip?, catalog: BrowseCatalog, listener: String?) async {
        guard isLoaded(for: listener) else { return }
        if let chip, !chip.isSelected, !matchesSelection(chip) {
            var target = chip
            target.isSelected = false
            selectedChip = target
        } else {
            selectedChip = nil
        }
        chips = chips.map { entry in
            var entry = entry
            entry.isSelected = matchesSelection(entry)
            return entry
        }
        state = .loading
        await loadFirstPage(catalog, listener: listener)
    }

    private func matchesSelection(_ chip: HomeChip) -> Bool {
        guard let selectedChip else { return false }
        return chip.browseId == selectedChip.browseId && chip.params == selectedChip.params
    }

    private func loadFirstPage(_ catalog: BrowseCatalog, listener: String?) async {
        generation += 1
        let mine = generation
        continuation = nil
        pagingMore = false
        refreshing = false
        loadingFirstPage = true
        defer { if generation == mine { loadingFirstPage = false } }
        do {
            let feed = try await catalog.home(chip: selectedChip)
            guard generation == mine, isLoaded(for: listener) else { return }
            apply(feed)
        } catch {
            guard generation == mine, isLoaded(for: listener), state.value == nil else { return }
            if error is CancellationError { return }
            state = .error(BrowseErrorText.friendly(error))
        }
    }

    /// Keep the page visible, fetching independently of SwiftUI's cancelled refresh task.
    func refresh(_ catalog: BrowseCatalog, listener: String?, signedIn: Bool) async {
        await Task { await fetchRefresh(catalog, listener: listener) }.value
    }

    private func fetchRefresh(_ catalog: BrowseCatalog, listener: String?) async {
        guard !refreshing, !loadingFirstPage, isLoaded(for: listener) else { return }
        generation += 1
        let mine = generation
        refreshing = true
        pagingMore = false
        defer { if generation == mine { refreshing = false } }
        if let feed = try? await catalog.home(chip: selectedChip), generation == mine, isLoaded(for: listener) {
            apply(feed)
        }
    }

    private func apply(_ feed: HomeFeed) {
        seenTitles.removeAll()
        state = .success(feed.shelves.filter { seenTitles.insert($0.feedKey).inserted })
        continuation = feed.continuation
        chips = feed.chips
        // Preserve the user's request target: a selected server chip can point to deselection.
        if selectedChip == nil, var selected = chips.first(where: {
            $0.isSelected && ($0.browseId != "FEmusic_home" || $0.params != nil)
        }) {
            // The repository interprets a selected request target as clear.
            selected.isSelected = false
            selectedChip = selected
        }
    }

    /// Continuation tokens belong to the current chip page; stale pages never append.
    func loadMore(_ catalog: BrowseCatalog) async {
        guard let token = continuation, !pagingMore, !loadingFirstPage, !refreshing else { return }
        let mine = generation
        let listener = loadedFor
        pagingMore = true
        defer { if generation == mine { pagingMore = false } }
        guard let feed = try? await catalog.moreHome(token: token), generation == mine, loadedFor == listener else { return }
        let added = feed.shelves.filter { seenTitles.insert($0.feedKey).inserted }
        continuation = added.isEmpty ? nil : feed.continuation
        if !added.isEmpty { state = .success((state.value ?? []) + added) }
    }
}
