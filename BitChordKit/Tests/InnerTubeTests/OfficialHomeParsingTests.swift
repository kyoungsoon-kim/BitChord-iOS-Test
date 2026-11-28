import XCTest
import BitChordCore
@testable import InnerTube

final class OfficialHomeParsingTests: XCTestCase {
    func testRegionUsesTwoLettersOrFallsBackToUS() {
        XCTAssertEqual(InnerTubeClient.regionIdentifier("kr"), "KR")
        XCTAssertEqual(InnerTubeClient.regionIdentifier("GB"), "GB")
        let identifiers: [String?] = [nil, "", "K", "KOR", "419", "12", "éx", "ß", " KR", "en_US"]
        for identifier in identifiers {
            XCTAssertEqual(InnerTubeClient.regionIdentifier(identifier), "US", identifier ?? "nil")
        }
        XCTAssertEqual(InnerTubeClient.region, InnerTubeClient.regionIdentifier(Locale.current.region?.identifier))
    }

    func testHomeKeepsVideoShelvesCardsAndResponsiveRowsOnlyWhenAllowed() throws {
        let response = home(#"""
        [
          {"musicCarouselShelfRenderer":{
            "header":{"musicCarouselShelfBasicHeaderRenderer":{"title":{"runs":[{"text":"Music videos"}]}}},
            "contents":[
              {"musicTwoRowItemRenderer":{"title":{"runs":[{"text":"Wide video"}]},
                "navigationEndpoint":{"watchEndpoint":{"videoId":"wide"}},
                "thumbnailRenderer":{"musicThumbnailRenderer":{"thumbnail":{"thumbnails":[{"url":"wide.jpg","width":400,"height":225}]}}}}},
              {"musicTwoRowItemRenderer":{"title":{"runs":[{"text":"Video charts"}]},
                "navigationEndpoint":{"browseEndpoint":{"browseId":"FEmusic_charts_videos"}}}},
              {"musicResponsiveListItemRenderer":{"playlistItemData":{"videoId":"row"},
                "flexColumns":[
                  {"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Responsive video"}]}}},
                  {"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Video • Artist"}]}}}
                ]}},
              {"musicTwoRowItemRenderer":{"title":{"runs":[{"text":"Audio page"}]},
                "navigationEndpoint":{"browseEndpoint":{"browseId":"MPEDaudio"}}}},
              {"musicTwoRowItemRenderer":{"title":{"runs":[{"text":"Square video"}]},
                "navigationEndpoint":{"watchEndpoint":{"videoId":"square",
                  "watchEndpointMusicSupportedConfigs":{"watchEndpointMusicConfig":{"musicVideoType":"MUSIC_VIDEO_TYPE_OMV"}}}}}}
            ]}},
          {"musicShelfRenderer":{"title":{"runs":[{"text":"More videos"}]},"contents":[
            {"musicResponsiveListItemRenderer":{"playlistItemData":{"videoId":"plain"},
              "flexColumns":[
                {"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Plain video"}]}}},
                {"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Video • Artist"}]}}}
              ]}}
          ]}}
        ]
        """#)
        let shelves = InnerTubeParser.parseHome(response, allowVideos: true)
        XCTAssertEqual(shelves.map(\.title), ["Music videos", "More videos"])
        XCTAssertEqual(shelves[0].items.compactMap(\.videoId), ["wide", "row", "audio", "square"])
        XCTAssertEqual(shelves[0].items[0].isVideo, true)
        XCTAssertEqual(shelves[0].items[1].browseId, "FEmusic_charts_videos")
        XCTAssertEqual(shelves[0].items[2].isVideo, true)
        XCTAssertNil(shelves[0].items[3].browseId)
        XCTAssertEqual(shelves[0].items[4].isVideo, true)
        XCTAssertEqual(shelves[1].items.first?.videoId, "plain")
        XCTAssertEqual(shelves[1].items.first?.isVideo, true)
        XCTAssertTrue(InnerTubeParser.parseHome(response).isEmpty, "non-Home callers keep filtering videos")
        XCTAssertEqual(InnerTubeParser.parseHomeContinuation(response, allowVideos: true), shelves)
        XCTAssertTrue(InnerTubeParser.parseHomeContinuation(response).isEmpty)
    }

    func testImmersiveCarouselAndPodcastEpisodesKeepTheirOrderOnBothPages() throws {
        let response = home(#"""
        [
          {"musicImmersiveCarouselShelfRenderer":{
            "header":{"musicCarouselShelfBasicHeaderRenderer":{
              "title":{"runs":[{"text":"For the evening"}]},"strapline":{"runs":[{"text":"Made for you"}]}}},
            "contents":[
              {"musicTwoRowItemRenderer":{"title":{"runs":[{"text":"A mix"}]},
                "navigationEndpoint":{"browseEndpoint":{"browseId":"VLRDmix"}}}},
              {"musicMultiRowListItemRenderer":{"title":{"runs":[{"text":"Episode "},{"text":"one"}]},
                "subtitle":{"runs":[{"text":"Podcast • Host"}]},
                "navigationEndpoint":{"watchEndpoint":{"videoId":"episode1"}},
                "thumbnail":{"musicThumbnailRenderer":{"thumbnail":{"thumbnails":[{"url":"episode.jpg","width":200,"height":200}]}}}}},
              {"musicMultiRowListItemRenderer":{"title":{"runs":[{"text":"No playable endpoint"}]}}}
            ]}},
          {"musicTastebuilderShelfRenderer":{"title":{"runs":[{"text":"Pick artists"}]},"contents":[
            {"musicCarouselShelfRenderer":{
              "header":{"musicCarouselShelfBasicHeaderRenderer":{"title":{"runs":[{"text":"Hidden tastebuilder shelf"}]}}},
              "contents":[{"musicTwoRowItemRenderer":{"title":{"runs":[{"text":"Hidden track"}]},
                "navigationEndpoint":{"watchEndpoint":{"videoId":"hidden"}}}}]}}
          ]}},
          {"musicCarouselShelfRenderer":{
            "header":{"musicCarouselShelfBasicHeaderRenderer":{"title":{"runs":[{"text":"Next shelf"}]}}},
            "contents":[{"musicTwoRowItemRenderer":{"title":{"runs":[{"text":"Track"}]},
              "navigationEndpoint":{"watchEndpoint":{"videoId":"track"}}}}]}}
        ]
        """#)
        let shelves = InnerTubeParser.parseHome(response, allowVideos: true)
        XCTAssertEqual(shelves.map(\.title), ["For the evening", "Next shelf"])
        XCTAssertEqual(shelves[0].subtitle, "Made for you")
        XCTAssertEqual(shelves[0].layout, .cards)
        XCTAssertNil(shelves[0].rowsPerColumn)
        XCTAssertEqual(shelves[0].items.map(\.title), ["A mix", "Episode one"])
        let episode = try XCTUnwrap(shelves[0].items.last)
        XCTAssertEqual(episode.videoId, "episode1")
        XCTAssertNil(episode.browseId)
        XCTAssertEqual(episode.subtitle, "Podcast • Host")
        XCTAssertEqual(episode.thumbnailUrl, "episode.jpg")
        // Continuations use another envelope; walking must preserve renderer order there too.
        let sections = response.o("contents").o("singleColumnBrowseResultsRenderer").a("tabs")?.first
            .o("tabRenderer").o("content").o("sectionListRenderer").a("contents") ?? []
        let continuation: InnerTubeJSON = ["continuationContents": ["sectionListContinuation": ["contents": .array(sections)]]]
        XCTAssertEqual(InnerTubeParser.parseHomeContinuation(continuation, allowVideos: true), shelves)
        XCTAssertEqual(InnerTubeParser.parseHome(response).map(\.title), ["Next shelf"])
    }

    func testChipsKeepTitlesBrowseParamsAndSelectedState() {
        let response = home("[]", header: #"""
        {"chipCloudRenderer":{"chips":[
          {"chipCloudChipRenderer":{"text":{"runs":[{"text":"Feel "},{"text":"good"}]},
            "navigationEndpoint":{"browseEndpoint":{"browseId":"FEmusic_home","params":"FEEL_GOOD"}},"isSelected":true}},
          {"chipCloudChipRenderer":{"text":{"runs":[{"text":"Focus"}]},
            "navigationEndpoint":{"browseEndpoint":{"browseId":"FEfocus"}}}},
          {"chipCloudChipRenderer":{"text":{"runs":[{"text":"Missing target"}]}}},
          {"chipCloudChipRenderer":{"text":{"runs":[]},"navigationEndpoint":{"browseEndpoint":{"browseId":"ignored"}}}}
        ]}}
        """#)
        XCTAssertEqual(InnerTubeParser.parseHomeChips(response), [
            HomeChip(title: "Feel good", browseId: "FEmusic_home", params: "FEEL_GOOD", isSelected: true),
            HomeChip(title: "Focus", browseId: "FEfocus"),
        ])
        XCTAssertTrue(InnerTubeParser.parseHomeChips(home("[]")).isEmpty)
    }

    func testOldCachedFeedsAndCardsDecodeWithoutNewFields() throws {
        let old = Data(#"{"shelves":[{"title":"Mix","items":[{"title":"Song","subtitle":"Artist","videoId":"v"}],"subtitle":""}]}"#.utf8)
        let feed = try JSONDecoder().decode(HomeFeed.self, from: old)
        XCTAssertEqual(feed.chips, [])
        XCTAssertNil(feed.shelves.first?.items.first?.isVideo)
        XCTAssertNil(feed.shelves.first?.items.first?.artist)
        let updated = HomeFeed(shelves: feed.shelves, continuation: "next", chips: [HomeChip(title: "Focus", browseId: "FEfocus")])
        XCTAssertEqual(try JSONDecoder().decode(HomeFeed.self, from: JSONEncoder().encode(updated)), updated)
    }

    func testHomeListLayoutPreservesDisplayColumnsAndPlayAllWithoutChangingOtherPages() throws {
        let response = home(#"""
        [{"musicCarouselShelfRenderer":{
          "numItemsPerColumn":"3",
          "header":{"musicCarouselShelfBasicHeaderRenderer":{
            "title":{"runs":[{"text":"Quick picks"}]},
            "moreContentButton":{"buttonRenderer":{"navigationEndpoint":{
              "watchPlaylistEndpoint":{"playlistId":"RDquick","params":"PLAY_ALL"}
            }}}
          }},
          "contents":[{"musicResponsiveListItemRenderer":{
            "playlistItemData":{"videoId":"track"},
            "flexColumns":[
              {"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Track title"}]}}},
              {"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[
                {"text":"Dua Lipa","navigationEndpoint":{"browseEndpoint":{"browseId":"UCdua",
                  "browseEndpointContextSupportedConfigs":{"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_ARTIST"}}}}},
                {"text":" 및 "},
                {"text":"Grand Theft Auto VI","navigationEndpoint":{"browseEndpoint":{"browseId":"UCgta",
                  "browseEndpointContextSupportedConfigs":{"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_ARTIST"}}}}}
              ]}}},
              {"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"819만회 "},{"text":"재생"}]}}},
              {"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":" "}]}}}
            ]
          }}]
        }}]
        """#)
        let shelves = InnerTubeParser.parseHome(response, allowVideos: true)
        let shelf = try XCTUnwrap(shelves.first)
        XCTAssertEqual(shelf.layout, .list)
        XCTAssertEqual(shelf.rowsPerColumn, 3)
        XCTAssertEqual(shelf.playAllPlaylistId, "RDquick")
        XCTAssertEqual(shelf.playAllParams, "PLAY_ALL")
        XCTAssertEqual(shelf.items.first?.subtitle, "Dua Lipa 및 Grand Theft Auto VI • 819만회 재생")
        XCTAssertEqual(shelf.items.first?.artist, "Dua Lipa, Grand Theft Auto VI")
        XCTAssertEqual(InnerTubeParser.artistFromSubtitle(try XCTUnwrap(shelf.items.first?.subtitle)), "Dua Lipa 및 Grand Theft Auto VI")
        XCTAssertEqual(InnerTubeParser.parseHomeContinuation(response, allowVideos: true), shelves)

        let otherPage = try XCTUnwrap(InnerTubeParser.parseHome(response).first)
        XCTAssertEqual(otherPage.layout, .cards)
        XCTAssertNil(otherPage.rowsPerColumn)
        XCTAssertNil(otherPage.playAllPlaylistId)
        XCTAssertNil(otherPage.playAllParams)
        XCTAssertNil(otherPage.items.first?.artist)
        XCTAssertEqual(otherPage.items.first?.subtitle, "Dua Lipa, Grand Theft Auto VI")
    }

    func testHomeListLayoutAcceptsNumericColumnCountsAndWatchEndpoint() throws {
        let row = #"""
        {"musicResponsiveListItemRenderer":{"playlistItemData":{"videoId":"track"},
          "flexColumns":[
            {"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Track"}]}}},
            {"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Artist"}]}}},
            {"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"1M plays"}]}}}
          ]}}
        """#
        let response = home(#"""
        [
          {"musicCarouselShelfRenderer":{"numItemsPerColumn":2,
            "header":{"musicCarouselShelfBasicHeaderRenderer":{
              "title":{"runs":[{"text":"Two rows"}]},
              "moreContentButton":{"buttonRenderer":{"navigationEndpoint":{
                "watchEndpoint":{"playlistId":"RDtwo","params":"TWO"}
              }}}
            }},
            "contents":[{"musicTwoRowItemRenderer":{"title":{"runs":[{"text":"Card"}]},
              "navigationEndpoint":{"watchEndpoint":{"videoId":"card"}}}}]}},
          {"musicCarouselShelfRenderer":{"contents":[\#(row)]}},
          {"musicShelfRenderer":{"title":{"runs":[{"text":"Plain list"}]},"contents":[\#(row)]}},
          {"musicCarouselShelfRenderer":{"numItemsPerColumn":0,"contents":[\#(row)]}}
        ]
        """#)
        let shelves = InnerTubeParser.parseHome(response, allowVideos: true)
        XCTAssertEqual(shelves.map(\.layout), [.list, .list, .list, .list])
        XCTAssertEqual(shelves.map(\.rowsPerColumn), [2, 4, 4, 4])
        XCTAssertEqual(shelves[0].playAllPlaylistId, "RDtwo")
        XCTAssertEqual(shelves[0].playAllParams, "TWO")
        XCTAssertEqual(shelves[2].items.first?.subtitle, "Artist • 1M plays")
        XCTAssertEqual(shelves[2].items.first?.artist, "Artist")
        let otherPage = InnerTubeParser.parseHome(response)
        XCTAssertTrue(otherPage.allSatisfy { $0.layout == .cards && $0.rowsPerColumn == nil })
    }

    func testOldHomeShelfDefaultsToCardsAndNewFieldsRoundTrip() throws {
        let old = Data(#"{"title":"Listen again","items":[],"subtitle":"For you","moreBrowseId":"VLmix","moreParams":"MORE"}"#.utf8)
        var shelf = try JSONDecoder().decode(HomeShelf.self, from: old)
        XCTAssertEqual(shelf.layout, .cards)
        XCTAssertNil(shelf.rowsPerColumn)
        XCTAssertNil(shelf.playAllPlaylistId)
        XCTAssertNil(shelf.playAllParams)
        XCTAssertEqual(shelf.moreBrowseId, "VLmix")
        XCTAssertEqual(shelf.moreParams, "MORE")
        shelf.layout = .list
        shelf.rowsPerColumn = 3
        shelf.playAllPlaylistId = "RDmix"
        shelf.playAllParams = "PLAY"
        XCTAssertEqual(try JSONDecoder().decode(HomeShelf.self, from: JSONEncoder().encode(shelf)), shelf)
    }

    private func home(_ contents: String, header: String = "{}") -> InnerTubeJSON {
        json(#"{"contents":{"singleColumnBrowseResultsRenderer":{"tabs":[{"tabRenderer":{"content":{"sectionListRenderer":{"header":\#(header),"contents":\#(contents)}}}}]}}}"#)
    }
}
