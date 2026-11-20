import Foundation
import Testing
@testable import LightsCore

struct MatchingPositionTests {
    @Test func onlySongsOneToFiveAndTheCountdownCanMatch() {
        for position in ["song1", "song2", "song3", "song4", "song5", "countdown"] {
            #expect(Cue(name: position, screensPosition: position).canMatchScreens, "\(position)")
        }
        for position in ["song6", "walkIn", "message", "announcements", "custom:Song 1 copy"] {
            var cue = Cue(name: position, screensPosition: position)
            cue.matchesScreens = true
            #expect(!cue.canMatchScreens, "\(position)")
            #expect(!cue.followsScreensBackground, "\(position)")
        }
        #expect(!Cue(name: "Blackout").canMatchScreens)
    }
}

struct LightingBackgroundsTests {
    @Test func readsScreensAnswer() throws {
        let json = """
        {"serviceId":"s1","serviceName":"Sunday","positions":[
          {"position":"countdown","itemId":"i0","itemName":"Countdown","mediaId":"m0"},
          {"position":"song1","itemId":"i1","itemName":"Holy Forever","mediaId":null}]}
        """
        let plan = try JSONDecoder().decode(LightingBackgrounds.self, from: Data(json.utf8))
        #expect(plan.serviceName == "Sunday")
        #expect(plan.positions.map(\.position) == ["countdown", "song1"])
        #expect(plan.positions[1].mediaId == nil)
    }

    @Test func noPlanOpen() throws {
        let json = #"{"serviceId":null,"serviceName":null,"positions":[]}"#
        let plan = try JSONDecoder().decode(LightingBackgrounds.self, from: Data(json.utf8))
        #expect(plan.positions.isEmpty)
    }
}

struct ScreensBackgroundSyncTests {
    let red = LightColor(red: 1, green: 0, blue: 0)

    private func sync(
        _ positions: [LightingBackgrounds.Position], missing: Set<String> = [], asked: Asked = Asked()
    ) -> ScreensBackgroundSync {
        let plan = LightingBackgrounds(serviceId: "s", serviceName: "Sunday", positions: positions)
        let red = red
        return ScreensBackgroundSync(
            plan: { .success(plan) },
            poster: { id in
                asked.add(id)
                return missing.contains(id) ? .failure(.noBackground) : .success(Data(id.utf8))
            },
            color: { String(decoding: $0, as: UTF8.self) == "dark" ? nil : red })
    }

    final class Asked: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [String] = []
        func add(_ id: String) { lock.withLock { ids.append(id) } }
        var all: [String] { lock.withLock { ids } }
    }

    @Test func aChangedBackgroundIsFetchedAndAnUnchangedOneIsNot() async throws {
        let asked = Asked()
        let result = try await sync([
            .init(position: "song1", mediaId: "new"),
            .init(position: "song2", mediaId: "same"),
        ], asked: asked).check(positions: ["song1", "song2"], seen: ["song1": "old", "song2": "same"]).get()
        #expect(result.updates.map(\.position) == ["song1"])
        #expect(result.updates.first?.mediaID == "new")
        #expect(result.updates.first?.color == red)
        #expect(asked.all == ["new"])
        #expect(result.planName == "Sunday")
    }

    @Test func positionsNoCueWantsAreLeftAlone() async throws {
        let result = try await sync([
            .init(position: "walkIn", mediaId: "w"),
            .init(position: "song6", mediaId: "s6"),
            .init(position: "countdown", mediaId: "c"),
        ]).check(positions: ["countdown"], seen: [:]).get()
        #expect(result.updates.map(\.position) == ["countdown"])
    }

    @Test func anItemWithoutABackgroundKeepsTheCueAsItIs() async throws {
        let result = try await sync([.init(position: "song1", mediaId: nil)])
            .check(positions: ["song1"], seen: ["song1": "old"]).get()
        #expect(result.updates.isEmpty)
        #expect(result.failed.isEmpty)
    }

    @Test func aDarkBackgroundComesBackWithoutAColour() async throws {
        let result = try await sync([.init(position: "song3", mediaId: "dark")])
            .check(positions: ["song3"], seen: [:]).get()
        #expect(result.updates.count == 1)
        #expect(result.updates.first?.color == nil)
    }

    @Test func aPictureThatCantBeFetchedIsTriedAgainNextTime() async throws {
        let result = try await sync([.init(position: "song1", mediaId: "gone")], missing: ["gone"])
            .check(positions: ["song1"], seen: [:]).get()
        #expect(result.updates.isEmpty)
        #expect(result.failed == ["song1"])
    }

    @Test func theFirstItemOnAPositionWins() async throws {
        let result = try await sync([
            .init(position: "song1", mediaId: "first"),
            .init(position: "song1", mediaId: "second"),
        ]).check(positions: ["song1"], seen: [:]).get()
        #expect(result.updates.map(\.mediaID) == ["first"])
    }

    @Test func screensWithoutTheRouteSaysToUpdate() async {
        #expect(ScreensAPI.Failure.outdated.message.contains("Update Screens"))
        let failing = ScreensBackgroundSync(
            plan: { .failure(.outdated) }, poster: { _ in .failure(.noBackground) }, color: { _ in nil })
        let result = await failing.check(positions: ["song1"], seen: [:])
        #expect(throws: ScreensAPI.Failure.outdated) { try result.get() }
    }
}

struct ReleaseHistoryTests {
    @Test func listsOlderInstallableReleasesNewestFirst() {
        let releases: [ReleaseHistory.Listing] = [
            .init(tag: "v0.3.10"), .init(tag: "v0.3.8"), .init(tag: "v0.3.9"),
            .init(tag: "v0.3.7", draft: true), .init(tag: "v0.3.6", prerelease: true),
            .init(tag: "v0.3.5", hasDMG: false), .init(tag: "v0.3.0"), .init(tag: "0.3.0"),
            .init(tag: "v0.2.1"), .init(tag: "v0.1.0"),
        ]
        #expect(ReleaseHistory.earlier(releases, than: "0.3.9").map(\.version) == ["0.3.8", "0.3.0"])
        #expect(ReleaseHistory.earlier(releases, than: "0.3.0").isEmpty)
    }
}
