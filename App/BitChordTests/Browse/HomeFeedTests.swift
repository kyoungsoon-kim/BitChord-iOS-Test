import BitChordCore
import InnerTube
import PlaybackQueue
import SwiftUI
import XCTest
@testable import BitChord

/// Home preserves the official feed order, supports chips and pages, and plays track cards.
@MainActor
final class HomeFeedTests: XCTestCase {
    // MARK: - Against the real InnerTube client over recorded answers

    /// The regression for "Home stays on its skeletons forever": the model must reach .success
    /// from a real InnerTubeClient + YTMusicRepository answering FEmusic_home.
    func testHomeReachesSuccessAgainstAStubbedInnerTube() async throws {
        let repository = makeStubbedRepository()
        let feed = HomeFeedModel()

        await feed.load(repository, listener: nil, signedIn: false)

        let shelves = try XCTUnwrap(feed.state.value, "state: \(feed.state)")
        XCTAssertFalse(shelves.isEmpty)
        XCTAssertTrue(shelves.contains { $0.title.contains("biggest hits") }, shelves.map(\.title).description)
        XCTAssertNotNil(feed.continuation, "FEmusic_home's own continuation is kept for paging")
        XCTAssertFalse(feed.loadingMore, "every first-page request settled")
        let requested = InnerTubeStub.requests.joined(separator: "\n")
        XCTAssertTrue(requested.contains("FEmusic_home"))
        XCTAssertFalse(requested.contains("FEmusic_new_releases"))
        XCTAssertFalse(requested.contains("FEmusic_explore"))
        XCTAssertFalse(requested.contains("FEmusic_history"), "signed out: no Recents request")
        // Titles are unique within the official feed.
        let titles = shelves.map { $0.title.lowercased() }
        XCTAssertEqual(titles.count, Set(titles).count)
    }

    func testMoreShelvesAreAppendedFromTheContinuation() async throws {
        let repository = makeStubbedRepository()
        let feed = HomeFeedModel()
        await feed.load(repository, listener: nil, signedIn: false)
        let before = try XCTUnwrap(feed.state.value).count

        await feed.loadMore(repository)

        let after = try XCTUnwrap(feed.state.value)
        XCTAssertGreaterThan(after.count, before, "the continuation page's shelves land at the tail")
        XCTAssertTrue(InnerTubeStub.requests.contains { $0.hasSuffix("/browse ") }, "a continuation request was made")
    }

    func testAFailingHomeShowsAFriendlyErrorAndRetryRecovers() async throws {
        let offline = [InnerTubeStub.Route]() // every request fails as "no connection"
        let failing = makeStubbedRepository(routes: offline)
        let feed = HomeFeedModel()
        await feed.load(failing, listener: nil, signedIn: false)
        XCTAssertEqual(feed.state.errorMessage, L10n.noInternetConnection)

        let working = makeStubbedRepository()
        await feed.load(working, listener: nil, signedIn: false)
        XCTAssertNotNil(feed.state.value)
    }

    // MARK: - Feed rules (scripted)

    func testSignedInHomeKeepsServerOrderAndNeverFetchesRecentsOrSupplements() async throws {
        let catalog = ScriptedCatalog()
        catalog.homeAnswer = {
            HomeFeed(shelves: [shelf("Quick picks", ["a"]), shelf("recents", ["old"]),
                               shelf("QUICK PICKS", ["duplicate"])], continuation: nil)
        }
        let feed = HomeFeedModel()
        await feed.load(catalog, listener: "account-1", signedIn: true)
        XCTAssertEqual(feed.state.value?.map(\.title), ["Quick picks", "recents"])
        XCTAssertEqual(catalog.calls, ["home"])
        XCTAssertTrue(feed.isLoaded(for: "account-1"))
        XCTAssertFalse(feed.isLoaded(for: nil))

        await feed.refresh(catalog, listener: "account-1", signedIn: true)
        XCTAssertEqual(catalog.calls, ["home", "home"])
    }

    func testPagingStopsWhenAPageAddsNothingNew() async throws {
        let catalog = ScriptedCatalog()
        catalog.homeAnswer = { HomeFeed(shelves: [shelf("Quick picks", ["a"])], continuation: "t1") }
        catalog.moreAnswer = { token in
            token == "t1"
                ? HomeFeed(shelves: [shelf("Mixed for you", ["m"])], continuation: "t2")
                : HomeFeed(shelves: [shelf("Quick picks", ["a"])], continuation: "t3")
        }
        let feed = HomeFeedModel()
        await feed.load(catalog, listener: nil, signedIn: false)

        await feed.loadMore(catalog)
        XCTAssertEqual(feed.state.value?.map(\.title), ["Quick picks", "Mixed for you"])
        XCTAssertEqual(feed.continuation, "t2")

        await feed.loadMore(catalog)
        XCTAssertNil(feed.continuation, "a page of repeats means the feed looped: stop, don't spin")
        await feed.loadMore(catalog)
        XCTAssertEqual(catalog.calls.filter { $0.hasPrefix("more:") }, ["more:t1", "more:t2"])
    }

    func testPullToRefreshKeepsTheFeedOnScreenAndSwapsItInPlace() async throws {
        let catalog = ScriptedCatalog()
        var round = 0
        catalog.homeAnswer = {
            round += 1
            return HomeFeed(shelves: [shelf("Round \(round)", ["a"])], continuation: nil)
        }
        let feed = HomeFeedModel()
        await feed.load(catalog, listener: nil, signedIn: false)
        XCTAssertEqual(feed.state.value?.map(\.title), ["Round 1"])

        catalog.homeAnswer = {
            try await Task.sleep(for: .milliseconds(50))
            return HomeFeed(shelves: [shelf("Round 2", ["b"])], continuation: nil)
        }
        let refresh = Task { await feed.refresh(catalog, listener: nil, signedIn: false) }
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertTrue(feed.refreshing)
        XCTAssertEqual(feed.state.value?.map(\.title), ["Round 1"], "no skeleton during a refresh")
        await refresh.value
        XCTAssertEqual(feed.state.value?.map(\.title), ["Round 2"])
        XCTAssertFalse(feed.refreshing)
    }

    func testARefreshFinishesWhenTheTaskThatAskedForItIsCancelled() async throws {
        let catalog = ScriptedCatalog()
        catalog.homeAnswer = { HomeFeed(shelves: [shelf("Round 1", ["a"])], continuation: nil) }
        let feed = HomeFeedModel()
        await feed.load(catalog, listener: nil, signedIn: false)

        catalog.homeAnswer = {
            try await Task.sleep(for: .milliseconds(50))
            return HomeFeed(shelves: [shelf("Round 2", ["b"])], continuation: nil)
        }
        let pull = Task { await feed.refresh(catalog, listener: nil, signedIn: false) }
        try await Task.sleep(for: .milliseconds(10))
        pull.cancel()
        await pull.value
        XCTAssertEqual(feed.state.value?.map(\.title), ["Round 2"])
        XCTAssertFalse(feed.refreshing)
    }

    func testAnOlderLoadCannotOverwriteANewerOne() async throws {
        let catalog = ScriptedCatalog()
        catalog.homeAnswer = {
            try await Task.sleep(for: .milliseconds(150))
            return HomeFeed(shelves: [shelf("Old account", ["a"])], continuation: nil)
        }
        let feed = HomeFeedModel()
        let first = Task { await feed.load(catalog, listener: "old", signedIn: false) }
        try await Task.sleep(for: .milliseconds(20))
        catalog.homeAnswer = { HomeFeed(shelves: [shelf("New account", ["b"])], continuation: nil) }
        await feed.load(catalog, listener: "new", signedIn: false)
        await first.value
        XCTAssertEqual(feed.state.value?.map(\.title), ["New account"])
    }

    // MARK: - Listener snapshots and filter generations

    func testSnapshotIsReplacedInFreshServerOrder() async throws {
        let catalog = ScriptedCatalog()
        let feed = HomeFeedModel()
        catalog.homeAnswer = { HomeFeed(shelves: [shelf("Old mix", ["o"]), shelf("Quick picks", ["a"])], continuation: nil) }
        await feed.load(catalog, listener: "A", signedIn: true)
        catalog.homeAnswer = { HomeFeed(shelves: [shelf("B picks", ["b"])], continuation: nil) }
        await feed.load(catalog, listener: "B", signedIn: true)
        let gate = AsyncGate()
        catalog.homeAnswer = {
            await gate.wait()
            return HomeFeed(shelves: [shelf("Quick picks", ["a2"]), shelf("New mix", ["n"])], continuation: nil)
        }
        let load = Task { await feed.load(catalog, listener: "A", signedIn: true) }
        await waitUntil("snapshot restored") { catalog.calls.filter { $0 == "home" }.count == 3 }
        XCTAssertEqual(feed.state.value?.map(\.title), ["Old mix", "Quick picks"])
        await gate.open()
        await load.value
        XCTAssertEqual(feed.state.value?.map(\.title), ["Quick picks", "New mix"])
    }

    func testSigningOutDropsSnapshots() async throws {
        let catalog = ScriptedCatalog()
        let feed = HomeFeedModel()
        catalog.homeAnswer = { HomeFeed(shelves: [shelf("A", ["a"])], continuation: nil) }
        await feed.load(catalog, listener: "A", signedIn: true)
        await feed.load(catalog, listener: "B", signedIn: true)
        await feed.load(catalog, listener: nil, signedIn: false)
        let gate = AsyncGate()
        catalog.homeAnswer = {
            await gate.wait()
            return HomeFeed(shelves: [], continuation: nil)
        }
        let load = Task { await feed.load(catalog, listener: "A", signedIn: true) }
        await waitUntil("fresh sign-in started") { catalog.calls.filter { $0 == "home" }.count == 4 }
        XCTAssertTrue(feed.state.isLoading)
        await gate.open()
        await load.value
        XCTAssertEqual(feed.state.value, [])
    }

    func testChipSelectionPagesRefreshesAndClears() async throws {
        let catalog = ScriptedCatalog()
        let chip = HomeChip(title: "Relax", browseId: "FEmusic_home", params: "RELAX")
        var selected = chip
        selected.isSelected = true
        selected.params = nil // The selected server chip points to the plain Home (deselect).
        catalog.homeAnswer = { HomeFeed(shelves: [shelf("All", ["a"])], continuation: "plain", chips: [chip]) }
        catalog.chipAnswer = { target in
            XCTAssertEqual(target?.params, "RELAX")
            XCTAssertEqual(target?.isSelected, false, "refresh keeps the filter instead of clearing it")
            return HomeFeed(shelves: [shelf("Relax mixes", ["r"])], continuation: "relax-page", chips: [selected])
        }
        catalog.moreAnswer = { token in
            XCTAssertEqual(token, "relax-page")
            return HomeFeed(shelves: [shelf("More relax", ["m"])], continuation: nil)
        }
        let feed = HomeFeedModel()
        await feed.load(catalog, listener: "A", signedIn: true)
        XCTAssertEqual(feed.chips, [chip])
        await feed.selectChip(chip, catalog: catalog, listener: "A")
        XCTAssertEqual(feed.selectedChip, chip)
        XCTAssertEqual(feed.chips, [selected], "server selection flags remain available for display")
        await feed.loadMore(catalog)
        XCTAssertEqual(feed.state.value?.map(\.title), ["Relax mixes", "More relax"])
        XCTAssertEqual(feed.selectedChip, chip)
        await feed.refresh(catalog, listener: "A", signedIn: true)
        XCTAssertEqual(feed.continuation, "relax-page")
        XCTAssertEqual(feed.selectedChip, chip)
        XCTAssertEqual(catalog.calls, ["home", "chip:FEmusic_home:RELAX", "more:relax-page", "chip:FEmusic_home:RELAX"])
        await feed.selectChip(selected, catalog: catalog, listener: "A")
        XCTAssertNil(feed.selectedChip)
        XCTAssertEqual(feed.continuation, "plain")
        XCTAssertEqual(catalog.calls.last, "home", "tapping the server-selected chip clears")
        await feed.selectChip(chip, catalog: catalog, listener: "A")
        await feed.selectChip(chip, catalog: catalog, listener: "A")
        XCTAssertNil(feed.selectedChip)
        XCTAssertEqual(catalog.calls.last, "home", "tapping the original request target also clears")
        await feed.selectChip(chip, catalog: catalog, listener: "A")
        await feed.selectChip(nil, catalog: catalog, listener: "A")
        XCTAssertNil(feed.selectedChip)
        XCTAssertEqual(feed.state.value?.map(\.title), ["All"])
        XCTAssertEqual(catalog.calls.last, "home", "the clear button returns to plain Home")
    }

    func testOnlyANonPlainServerSelectionCanSeedTheSelectedChip() async throws {
        let catalog = ScriptedCatalog()
        let plain = HomeChip(title: "All", browseId: "FEmusic_home", isSelected: true)
        catalog.homeAnswer = { HomeFeed(shelves: [], continuation: nil, chips: [plain]) }
        let feed = HomeFeedModel()
        await feed.load(catalog, listener: "A", signedIn: true)
        XCTAssertNil(feed.selectedChip)
        XCTAssertEqual(feed.chips, [plain])

        let filtered = HomeChip(title: "Focus", browseId: "FEmusic_home", params: "FOCUS", isSelected: true)
        catalog.homeAnswer = { HomeFeed(shelves: [], continuation: nil, chips: [filtered]) }
        await feed.load(catalog, listener: "A", signedIn: true)
        var target = filtered
        target.isSelected = false
        XCTAssertEqual(feed.selectedChip, target)
        XCTAssertEqual(feed.chips, [filtered])
    }

    func testChipChangeInvalidatesOldContinuationAndFirstPage() async throws {
        let catalog = ScriptedCatalog()
        catalog.homeAnswer = { HomeFeed(shelves: [shelf("All", ["a"])], continuation: "old-page") }
        let feed = HomeFeedModel()
        await feed.load(catalog, listener: "A", signedIn: true)
        let gate = AsyncGate()
        catalog.moreAnswer = { _ in
            await gate.wait()
            return HomeFeed(shelves: [shelf("Stale page", ["x"])], continuation: "stale")
        }
        let paging = Task { await feed.loadMore(catalog) }
        await waitUntil("old continuation requested") { catalog.calls.contains("more:old-page") }
        let chip = HomeChip(title: "Focus", browseId: "FEmusic_home", params: "FOCUS")
        catalog.chipAnswer = { _ in HomeFeed(shelves: [shelf("Focus", ["f"])], continuation: "focus-page") }
        await feed.selectChip(chip, catalog: catalog, listener: "A")
        await gate.open()
        await paging.value
        XCTAssertEqual(feed.state.value?.map(\.title), ["Focus"])
        XCTAssertEqual(feed.continuation, "focus-page")

        let firstGate = AsyncGate()
        catalog.chipAnswer = { _ in
            await firstGate.wait()
            return HomeFeed(shelves: [shelf("Stale first page", ["x"])], continuation: "stale")
        }
        let oldLoad = Task { await feed.selectChip(HomeChip(title: "Sleep", browseId: "FEmusic_home", params: "SLEEP"), catalog: catalog, listener: "A") }
        await waitUntil("old chip requested") { catalog.calls.contains("chip:FEmusic_home:SLEEP") }
        await feed.selectChip(nil, catalog: catalog, listener: "A")
        await firstGate.open()
        await oldLoad.value
        XCTAssertEqual(feed.state.value?.map(\.title), ["All"])
        XCTAssertNil(feed.selectedChip)
    }

    // MARK: - Cards

    func testASongCardIsCreditedToItsArtistAndACollectionOpensByItsBrowseId() {
        let song = ShelfItem(title: "Crush", subtitle: "Song • Chelsea Wolfe • 2.1M plays", thumbnailUrl: nil, videoId: "v1", browseId: nil)
        XCTAssertEqual(song.shelfSong?.artist, "Chelsea Wolfe")
        XCTAssertNil(song.shelfBrowseItem)

        let album = ShelfItem(title: "Birth of Violence", subtitle: "Album • Chelsea Wolfe", thumbnailUrl: nil, videoId: nil, browseId: "MPREb_x")
        XCTAssertNil(album.shelfSong)
        XCTAssertEqual(album.shelfBrowseItem?.type, .album)
        XCTAssertEqual(ShelfItem(title: "A", subtitle: "", thumbnailUrl: nil, videoId: nil, browseId: "UCabc").shelfBrowseItem?.type, .artist)
    }

    func testVideoCardPlaysItsVideoIdInsteadOfOpeningItsBrowseTarget() {
        let app = makeBrowseTestApp()
        let card = ShelfItem(title: "Video", subtitle: "Video • Artist", thumbnailUrl: nil,
                             videoId: "video-id", browseId: "MPEDvideo-id", isVideo: true)
        XCTAssertEqual(card.shelfSong?.isVideo, true)
        XCTAssertEqual(card.shelfSong?.isVideoOrigin, true)
        BrowseNavigator(app: app).openCard(card, source: QueueSource(title: "Music videos", type: .home))
        XCTAssertEqual(app.player.currentSong?.videoId, "video-id")
        XCTAssertEqual(app.player.currentSong?.isVideo, true)
        XCTAssertTrue(app.router.path(for: app.router.selectedTab).isEmpty)
        app.player.engine.shutdown()
    }

    func testTappingASongCardStartsAOneOffFromIt() async throws {
        let harness = PlayerHarness(test: self)
        let queued = try harness.song("q1")
        harness.player.play([queued], source: QueueSource(title: "Album", type: .browse))
        let card = try harness.song("card1")
        let item = ShelfItem(title: card.title, subtitle: "Song • \(card.artist)", thumbnailUrl: nil, videoId: card.videoId, browseId: nil)

        // What HomeScreen.openItem does for a song card.
        harness.player.playSong(try XCTUnwrap(item.shelfSong), source: QueueSource(title: "Quick picks", type: .home))

        await waitUntil("the card plays") { harness.player.currentSong?.videoId == "card1" }
        XCTAssertEqual(harness.player.playingFrom?.caption.isEmpty, false)
    }

    func testTappingAnAlbumCardOpensItAndHoldingItOpensItsMenu() throws {
        let app = makeBrowseTestApp()
        let navigator = BrowseNavigator(app: app)
        let album = ShelfItem(title: "Discovery", subtitle: "Album • Daft Punk", thumbnailUrl: nil, videoId: nil, browseId: "MPREb_discovery")

        navigator.openCard(album, source: QueueSource(title: "New releases", type: .home))
        guard case .album(let browseId, _)? = app.router.path(for: app.router.selectedTab).last else {
            return XCTFail("expected the album page, got \(app.router.path(for: app.router.selectedTab))")
        }
        XCTAssertEqual(browseId, "MPREb_discovery")

        navigator.openCardMenu(album)
        XCTAssertEqual(app.router.sheet, .browseActions(try XCTUnwrap(album.shelfBrowseItem)))
        app.router.dismissSheet()
        navigator.openCardMenu(ShelfItem(title: "Daft Punk", subtitle: "Artist", thumbnailUrl: nil, videoId: nil, browseId: "UCabc"))
        XCTAssertNil(app.router.sheet, "holding an artist does nothing")
        let song = ShelfItem(title: "One More Time", subtitle: "Song • Daft Punk", thumbnailUrl: nil, videoId: "v1", browseId: nil)
        navigator.openCardMenu(song)
        XCTAssertEqual(app.router.sheet, .songActions(try XCTUnwrap(song.shelfSong)))
    }

    // MARK: - Rendering

    func testHomeRendersItsShelvesFromAStubbedInnerTube() async throws {
        let app = makeBrowseTestApp()
        await host(HomeScreen(), app: app, timeout: 5) {
            InnerTubeStub.requests.contains { $0.contains("FEmusic_home") }
        }
        XCTAssertTrue(InnerTubeStub.requests.contains { $0.contains("FEmusic_home") }, "Home's .task asked for the feed")
        // Landscape, light mode and the largest accessibility text size lay out too.
        await host(HomeScreen(), app: app, size: CGSize(width: 852, height: 393), timeout: 1)
        await host(HomeScreen().environment(\.dynamicTypeSize, .accessibility3), app: app, colorScheme: .light, timeout: 1)
    }
}

extension HomeFeedTests {
    private static func continuationRequests() -> Int {
        InnerTubeStub.requests.filter { $0.hasSuffix("/browse ") }.count
    }

    /// Review fix: the screen used to ask for the next page every time a page settled, wherever
    /// the reader was, so opening Home walked the whole continuation chain with the list at the
    /// top. HomeScreen.kt only pages while one of the last three shelves is on screen.
    ///
    /// The recorded first page is short (two shelves, the tail on screen), so it legitimately
    /// asks for page two once. That page adds two shelves and pushes the tail below the fold: no
    /// further request may follow while the reader stays at the top.
    func testHomeDoesNotPageWhileTheTailIsOffScreen() async throws {
        let app = makeBrowseTestApp()
        await host(HomeScreen(), app: app, timeout: 5) { Self.continuationRequests() > 0 }
        // Let page two land and the page settle: the count must hold still for a stretch long
        // enough that a further request, if Home still walked the chain, would have shown up.
        var seen = Self.continuationRequests()
        var quietSince = Date()
        let giveUp = Date().addingTimeInterval(20)
        while Date().timeIntervalSince(quietSince) < 1.5, Date() < giveUp {
            try await Task.sleep(for: .milliseconds(100))
            let now = Self.continuationRequests()
            if now != seen { seen = now; quietSince = Date() }
        }
        XCTAssertEqual(Self.continuationRequests(), 1, InnerTubeStub.requests.joined(separator: "\n"))
    }

    /// With the whole feed on screen (a very tall window), the real shelves' rows appear — so the
    /// success branch drew its shelves rather than the skeleton — and the next page is asked for.
    func testHomePagesOnceItsLastShelvesAreOnScreen() async throws {
        let app = makeBrowseTestApp()
        await host(HomeScreen(), app: app, size: CGSize(width: 393, height: 20_000), timeout: 8) {
            Self.continuationRequests() > 0
        }
        XCTAssertGreaterThan(Self.continuationRequests(), 0, InnerTubeStub.requests.joined(separator: "\n"))
    }
}

/// A one-shot latch for ordering async test steps.
actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}
