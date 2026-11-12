import Foundation
import Testing
@testable import LightsCore

/// The app model's part, without the app.
@MainActor
final class FakeControl: PrismControl {
    let rig = Rig.hope
    var show = Show.bundledDefault()
    var liveCueID: String?
    var outputEnabled = true
    var followsScreens = true
    var wentTo: [(id: String, fade: Double?)] = []

    func status() -> PrismStatus {
        PrismStatus(midiInputs: ["Screens"], otherSourcesSending: [], networks: ["en0 10.0.0.2"],
                    screensColor: nil, screensProblem: nil)
    }

    func go(cueID: String, fade: Double?) {
        liveCueID = cueID
        wentTo.append((cueID, fade))
    }

    func editShow(_ change: (inout Show) -> Void) { change(&show) }

    func deleteCue(_ id: String) -> Bool {
        guard id != liveCueID else { return false }
        return show.delete(id)
    }
}

@MainActor
struct MCPToolTests {
    let control = FakeControl()
    var server: MCPServer { PrismTools.server(control: control, version: "test") }

    /// Calls a tool the way Claude does and hands back the reply's result.
    func call(_ name: String, _ arguments: JSONValue = [:]) async throws -> (text: String, isError: Bool, structured: JSONValue?) {
        let request: JSONValue = ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                  "params": ["name": .string(name), "arguments": arguments]]
        let (status, body) = await server.handle(body: request.encoded())
        #expect(status == 200)
        let reply = try JSONDecoder().decode(JSONValue.self, from: body)
        let result = try #require(reply["result"])
        let text = result["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
        return (text, result["isError"]?.boolValue ?? false, result["structuredContent"])
    }

    @Test func initializeAndList() async throws {
        let (_, body) = await server.handle(body: JSONValue.object([
            "jsonrpc": "2.0", "id": "a", "method": "initialize",
            "params": ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "t", "version": "1"]],
        ]).encoded())
        let reply = try JSONDecoder().decode(JSONValue.self, from: body)
        #expect(reply["id"] == "a")
        #expect(reply["result"]?["protocolVersion"] == "2025-06-18")
        #expect(reply["result"]?["serverInfo"]?["name"] == "prism")

        let (_, listed) = await server.handle(body: JSONValue.object(["jsonrpc": "2.0", "id": 2, "method": "tools/list"]).encoded())
        let names = try JSONDecoder().decode(JSONValue.self, from: listed)["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue }
        #expect(names?.contains("go_cue") == true)
        #expect(names?.contains("set_look") == true)
        #expect(names?.count == Set(names ?? []).count)

        let notification = await server.handle(body: JSONValue.object(["jsonrpc": "2.0", "method": "notifications/initialized"]).encoded())
        #expect(notification.status == 202 && notification.body.isEmpty)
        let garbage = await server.handle(body: Data("{nope".utf8))
        #expect(String(decoding: garbage.body, as: UTF8.self).contains("-32700"))
    }

    @Test func goCueByNameWithItsFade() async throws {
        let result = try await call("go_cue", ["cue": "song 1"])
        #expect(!result.isError)
        #expect(control.liveCueID == "song1")
        #expect(control.wentTo.last?.fade == nil)
        _ = try await call("go_cue", ["cue": "Blackout", "fade_seconds": 0])
        #expect(control.wentTo.last?.id == "blackout" && control.wentTo.last?.fade == 0)
        let unknown = try await call("go_cue", ["cue": "Song 9"])
        #expect(unknown.isError && unknown.text.contains("Walk-in"))
    }

    @Test func setLookOnSlimparsKeepsOtherGroups() async throws {
        let before = try #require(control.show.cue("song2"))
        let result = try await call("set_look", ["cue": "Song 2", "groups": ["slimpars"], "color": "#8000ff", "brightness": 80])
        #expect(!result.isError)
        let after = try #require(control.show.cue("song2"))
        for group in control.rig.groups {
            if group.isSlimpar {
                #expect(after.look(for: group).color?.hex == "#8000FF")
                #expect(after.look(for: group).level == 0.8)
            } else {
                #expect(after.look(for: group) == before.look(for: group))
            }
        }
        #expect(result.structured?["looks"] != nil)
    }

    @Test func setLookTakesNamedColoursAndSkipsColourOnDimmerGroups() async throws {
        let result = try await call("set_look", ["cue": "Message", "groups": ["Front Wash", "wallWash"], "color": "warm white"])
        #expect(!result.isError)
        #expect(result.text.contains("Front Wash only take a brightness"))
        let cue = try #require(control.show.cue("message"))
        #expect(cue.look(for: try #require(control.rig.group("wallWash"))).color?.hex == "#FFF1B9")
        #expect(cue.look(for: try #require(control.rig.group("frontWash"))).color == nil)
    }

    @Test func setLookRefusesBadInput() async throws {
        #expect(try await call("set_look", ["cue": "Song 1", "groups": ["lasers"], "brightness": 10]).isError)
        #expect(try await call("set_look", ["cue": "Song 1", "groups": ["all"], "brightness": 150]).isError)
        #expect(try await call("set_look", ["cue": "Song 1", "groups": ["all"], "color": "chartreuse-ish"]).isError)
        #expect(try await call("set_look", ["cue": "Song 1", "groups": ["all"]]).isError)
        #expect(control.show == Show.bundledDefault())
    }

    @Test func updateCueMovesANoteAndRenames() async throws {
        let result = try await call("update_cue", ["cue": "Recognition", "screens_note": 62, "fade_seconds": 3, "name": "Dedications"])
        #expect(!result.isError)
        #expect(result.text.contains("Song 1 no longer has a Screens note"))
        let cue = try #require(control.show.cue("custom:Recognition"))
        #expect(cue.name == "Dedications" && cue.note == 62 && cue.fade == 3)
        #expect(control.show.cue("song1")?.note == nil)

        _ = try await call("update_cue", ["cue": "Dedications", "screens_note": .null])
        #expect(control.show.cue("custom:Recognition")?.note == nil)
        #expect(try await call("update_cue", ["cue": "Dedications", "match_screens_background": true]).isError)
        #expect(control.show.cue("custom:Recognition")?.followsScreensBackground == false)
        #expect(!(try await call("update_cue", ["cue": "Song 2", "match_screens_background": false]).isError))
        #expect(control.show.cue("song2")?.followsScreensBackground == false)
        #expect(try await call("update_cue", ["cue": "Dedications", "name": "song 2"]).isError)
    }

    @Test func addDuplicateMoveAndDelete() async throws {
        let added = try await call("add_cue", ["name": "Easter Opener", "based_on": "Song 1"])
        #expect(!added.isError)
        let cue = try #require(control.show.cues.first { $0.name == "Easter Opener" })
        #expect(cue.looks == control.show.cue("song1")?.looks)
        #expect(cue.note == 74)
        #expect(control.show.cues.last?.id == "blackout")
        #expect(try await call("add_cue", ["name": "easter opener"]).isError)

        _ = try await call("duplicate_cue", ["cue": "Easter Opener"])
        #expect(control.show.cues.contains { $0.name == "Easter Opener copy" && $0.note == 75 })

        _ = try await call("move_cue", ["cue": "Easter Opener", "position": 1])
        #expect(control.show.cues.first?.name == "Easter Opener")

        let asked = try await call("delete_cue", ["cue": "Easter Opener"])
        #expect(!asked.isError && asked.text.contains("confirm"))
        #expect(control.show.cues.contains { $0.name == "Easter Opener" })
        _ = try await call("delete_cue", ["cue": "Easter Opener", "confirm": true])
        #expect(!control.show.cues.contains { $0.name == "Easter Opener" })

        control.liveCueID = "song1"
        #expect(try await call("delete_cue", ["cue": "Song 1", "confirm": true]).isError)
        #expect(control.show.cue("song1") != nil)

        // The Blackout button and ⇧⌘B go to it by id.
        #expect(try await call("delete_cue", ["cue": "Blackout", "confirm": true]).isError)
        #expect(control.show.cue("blackout") != nil)
    }

    @Test func statusAndOptions() async throws {
        control.liveCueID = "walkIn"
        let status = try await call("get_status")
        #expect(status.structured?["live_cue"] == "Walk-in")
        #expect(status.structured?["midi_inputs"] == .array(["Screens"]))
        _ = try await call("set_options", ["sending_to_lights": false, "follow_screens": false])
        #expect(!control.outputEnabled && !control.followsScreens)
        let off = try await call("go_cue", ["cue": "Song 1"])
        #expect(off.text.contains("sending to the lights is off"))
    }

    @Test func cueReportShowsBlindersAtOnePercent() async throws {
        let result = try await call("get_cue", ["cue": "Song 3"])
        let looks = try #require(result.structured?["looks"]?.arrayValue)
        let blinders = try #require(looks.first { $0["group"] == "blinders" })
        #expect(blinders["brightness"]?.doubleValue == 1)
        let list = try await call("list_cues")
        #expect(list.structured?["cues"]?.arrayValue?.count == control.show.cues.count)
    }
}

struct BlinderFloorTests {
    @Test func everyCueButBlackoutHasBlindersAtOnePercent() {
        let show = Show.bundledDefault()
        let blinders = Rig.hope.group("blinders")!
        for cue in show.cues {
            #expect(cue.look(for: blinders).level == (cue.id == "blackout" ? 0 : 0.01), "\(cue.name)")
        }
    }

    @Test func liftingAnOldShowKeepsBrighterBlindersAndBlackout() {
        var show = Show.bundledDefault()
        for index in show.cues.indices { show.cues[index].looks["blinders"] = .off }
        show.cues[2].looks["blinders"] = GroupLook(level: 0.6)
        show.cues[3].looks["blinders"] = nil
        show.liftBlindersToFloor()
        #expect(show.cues[0].looks["blinders"]?.level == 0.01)
        #expect(show.cues[2].looks["blinders"]?.level == 0.6)
        #expect(show.cues[3].looks["blinders"]?.level == 0.01)
        #expect(show.cue("blackout")?.looks["blinders"]?.level == 0)
    }

    @Test func onePercentReachesTheBlinders() {
        let frame = Renderer.frame(for: Show.bundledDefault().cue("song1")!, rig: .hope)
        let address = Rig.hope.fixture("BL1")!.address
        #expect(frame.universes[1]?[address - 1] == 3)
    }
}

struct MCPHostTests {
    @Test func parsesRequestsAndWaitsForTheBody() {
        let head = "POST /mcp?x=1 HTTP/1.1\r\nHost: a\r\nContent-Length: 5\r\nAuthorization: Bearer k\r\n\r\n"
        #expect(HTTPServer.parse(Data(head.utf8)) == .incomplete)
        guard case .complete(let request) = HTTPServer.parse(Data((head + "hello").utf8)) else {
            Issue.record("didn't parse")
            return
        }
        #expect(request.method == "POST" && request.path == "/mcp")
        #expect(request.headers["authorization"] == "Bearer k")
        #expect(request.body == Data("hello".utf8))
        #expect(HTTPServer.parse(Data("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)) == .bad(411))
        #expect(HTTPServer.parse(Data("POST /mcp HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n".utf8)) == .bad(413))
        #expect(HTTPServer.parse(Data("nonsense\r\n\r\n".utf8)) == .bad(400))
        #expect(HTTPServer.parse(Data(repeating: 65, count: 20_000)) == .bad(431))
    }

    @Test func keyComparison() {
        #expect(MCPHost.matches("prism_abc", "prism_abc"))
        #expect(!MCPHost.matches("prism_abd", "prism_abc"))
        #expect(!MCPHost.matches("prism_ab", "prism_abc"))
        #expect(!MCPHost.matches("", ""))
    }

    /// The whole path Claude Code takes: HTTP on a real socket, the key, the
    /// JSON-RPC, a tool, the show.
    @Test func overTheNetwork() async throws {
        let control = await FakeControl()
        let server = await PrismTools.server(control: control, version: "test")
        let host = MCPHost(server: server, key: "prism_secret")
        let ready = AsyncStream<HTTPServer.State>.makeStream()
        host.start(port: 0) { ready.continuation.yield($0) }
        var iterator = ready.stream.makeAsyncIterator()
        guard case .ready(let port)? = await iterator.next() else {
            Issue.record("didn't listen")
            return
        }
        defer { host.stop() }
        let url = URL(string: "http://127.0.0.1:\(port)/mcp")!

        func post(_ message: JSONValue, key: String?) async throws -> (Int, JSONValue?) {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            if let key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
            request.httpBody = message.encoded()
            let (data, response) = try await URLSession.shared.data(for: request)
            return ((response as! HTTPURLResponse).statusCode, try? JSONDecoder().decode(JSONValue.self, from: data))
        }

        let call: JSONValue = ["jsonrpc": "2.0", "id": 7, "method": "tools/call",
                               "params": ["name": "go_cue", "arguments": ["cue": "Communion"]]]
        #expect(try await post(call, key: nil).0 == 401)
        #expect(try await post(call, key: "prism_wrong!").0 == 401)
        #expect(await control.liveCueID == nil)

        let (status, reply) = try await post(call, key: "prism_secret")
        #expect(status == 200)
        #expect(reply?["id"] == 7)
        #expect(await control.liveCueID == "communion")

        var get = URLRequest(url: url)
        get.setValue("Bearer prism_secret", forHTTPHeaderField: "Authorization")
        let (_, getResponse) = try await URLSession.shared.data(for: get)
        #expect((getResponse as! HTTPURLResponse).statusCode == 405)

        host.setKey("prism_new")
        #expect(try await post(call, key: "prism_secret").0 == 401)
        #expect(try await post(call, key: "prism_new").0 == 200)
    }
}

struct SongSlimparTests {
    @Test func songsStartWithSlimparsAtTenPercent() {
        let show = Show.bundledDefault()
        for cue in show.cues where cue.isSong {
            for group in Rig.hope.groups where group.isSlimpar {
                #expect(cue.look(for: group).level == 0.1, "\(cue.name) \(group.name)")
            }
        }
        #expect(show.cue("closing")?.looks["screenSlimpars"]?.level == 0.5)
    }

    @Test func aSavedShowDimsOnlyTheOldLevel() {
        var show = Show.bundledDefault()
        for index in show.cues.indices {
            for id in ["screenSlimpars", "ceilingSlimpars", "floorSlimpars"] {
                show.cues[index].looks[id]?.level = 0.25
            }
        }
        show.cues[show.cues.firstIndex { $0.id == "song2" }!].looks["floorSlimpars"]?.level = 0.6
        show.dimSongSlimpars(rig: .hope)
        #expect(show.cue("song1")?.looks["screenSlimpars"]?.level == 0.1)
        #expect(show.cue("song2")?.looks["floorSlimpars"]?.level == 0.6)
        #expect(show.cue("walkIn")?.looks["screenSlimpars"]?.level == 0.25)
    }
}

struct MatchingDefaultTests {
    @Test func songsAndCountdownMatchScreensAndNothingElse() {
        var shows = [Show.bundledDefault()]
        var saved = Show.bundledDefault()
        for index in saved.cues.indices { saved.cues[index].matchesScreens = index % 2 == 0 }
        saved.applyMatchingDefaults()
        shows.append(saved)
        for show in shows {
            for cue in show.cues {
                let wanted = cue.isSong || cue.id == "countdown"
                #expect(cue.followsScreensBackground == wanted, "\(cue.name)")
            }
        }
    }
}

struct ScreensSignatureTests {
    @Test func changesWithTheSlideAndTheMediaOnly() {
        let base: [String: Any] = [
            "liveSlide": ["presentationId": "p", "slideId": "s1", "text": "Verse"],
            "mediaLayers": ["background": ["mediaId": "m1"], "foreground": ["mediaId": "m2"]],
            "nextSlideText": "a",
        ]
        var sameButText = base
        sameButText["nextSlideText"] = "b"
        var nextSlide = base
        nextSlide["liveSlide"] = ["presentationId": "p", "slideId": "s2"]
        var newVideo = base
        newVideo["mediaLayers"] = ["background": ["mediaId": "m9"], "foreground": ["mediaId": "m2"]]
        let a = ScreensAPI.signature(of: base)
        #expect(a == ScreensAPI.signature(of: sameButText))
        #expect(a != ScreensAPI.signature(of: nextSlide))
        #expect(a != ScreensAPI.signature(of: newVideo))
        #expect(ScreensAPI.signature(of: [:]) == "/|")
    }
}

/// Screens as the follower sees it: a script of what's live on each read.
final class ScriptedScreens: @unchecked Sendable {
    let lock = NSLock()
    var signatures: [Result<String, ScreensAPI.Failure>]
    var backgrounds: [String: Result<Data, ScreensAPI.Failure>]
    var current = "old"
    var backgroundReads = 0
    var reads = 0

    init(_ signatures: [Result<String, ScreensAPI.Failure>], _ backgrounds: [String: Result<Data, ScreensAPI.Failure>]) {
        self.signatures = signatures
        self.backgrounds = backgrounds
    }

    func follower() -> ScreensFollower {
        ScreensFollower(
            signature: { self.lock.withLock {
                self.reads += 1
                let next = self.signatures.isEmpty ? .success(self.current) : self.signatures.removeFirst()
                if case .success(let s) = next { self.current = s }
                return next
            } },
            background: { self.lock.withLock {
                self.backgroundReads += 1
                return self.backgrounds[self.current] ?? .failure(.noBackground)
            } },
            pause: { _ in await Task.yield() },
            color: { data in LightColor(hex: String(decoding: data, as: UTF8.self)) })
    }
}

@MainActor
struct ScreensFollowerTests {
    func run(_ screens: ScriptedScreens, stale: String?, reads: Int) async -> [ScreensFollower.Event] {
        var events: [ScreensFollower.Event] = []
        await screens.follower().run(
            stale: stale,
            stillLive: { screens.lock.withLock { screens.reads < reads } },
            followed: { _ in },
            send: { if case .color = $0 { events.append($0) } })
        return events
    }

    @Test func waitsForTheNewSlideInsteadOfTheOldOne() async {
        // The note lands while the old song's slide is still up.
        let screens = ScriptedScreens(
            [.success("old"), .success("old"), .success("new")],
            ["old": .success(Data("#00FF00".utf8)), "new": .success(Data("#8000FF".utf8))])
        let events = await run(screens, stale: "old", reads: 6)
        #expect(events == [.color(LightColor(hex: "#8000FF"))])
    }

    @Test func followsABackgroundThatChangesMidSong() async {
        let screens = ScriptedScreens(
            [.success("a"), .success("a"), .success("b"), .success("b"), .success("c")],
            ["a": .success(Data("#FF0000".utf8)), "b": .success(Data("#0000FF".utf8)), "c": .success(Data("#0000FF".utf8))])
        let events = await run(screens, stale: nil, reads: 8)
        #expect(events == [.color(LightColor(hex: "#FF0000")), .color(LightColor(hex: "#0000FF"))])
        // Asked again only when the slide changed: a, b, c.
        #expect(screens.backgroundReads == 3)
    }

    @Test func aSlideWithoutABackgroundKeepsTheColour() async {
        let screens = ScriptedScreens(
            [.success("a"), .success("blank")],
            ["a": .success(Data("#FF0000".utf8))])
        let events = await run(screens, stale: nil, reads: 5)
        #expect(events == [.color(LightColor(hex: "#FF0000"))])
    }

    @Test func aDarkBackgroundHandsBackTheCuesColour() async {
        let screens = ScriptedScreens(
            [.success("a"), .success("dark")],
            ["a": .success(Data("#FF0000".utf8)), "dark": .success(Data("not a colour".utf8))])
        let events = await run(screens, stale: nil, reads: 5)
        #expect(events == [.color(LightColor(hex: "#FF0000")), .color(nil)])
    }

    @Test func theOldSlideCountsAfterItsGrace() async {
        // Screens really is still on the slide that was up: after the grace
        // period it's taken, rather than leaving the cue unmatched.
        let screens = ScriptedScreens([], ["old": .success(Data("#00FF00".utf8))])
        let events = await run(screens, stale: "old", reads: 20)
        #expect(events == [.color(LightColor(hex: "#00FF00"))])
    }

    @Test func watchingOnlyNotesTheSlide() async {
        // Walk-in doesn't match, but the countdown after it needs to know
        // the walk-in slide was up when its note came.
        let screens = ScriptedScreens(
            [.success("walkIn"), .failure(.unreachable), .success("walkIn2")],
            ["walkIn": .success(Data("#00FF00".utf8))])
        var seen: [String] = []
        await screens.follower().watch(
            stillLive: { screens.lock.withLock { screens.reads < 4 } },
            followed: { seen.append($0) })
        #expect(seen == ["walkIn", "walkIn2"])
        #expect(screens.backgroundReads == 0)
    }

    @Test func theSlideBeforeANonMatchingCueIsStale() async {
        // The countdown's note lands while walk-in's slide is still up; the
        // watch during walk-in recorded it, so it isn't taken.
        let screens = ScriptedScreens([.success("walkIn")], ["walkIn": .success(Data("#00FF00".utf8)), "countdown": .success(Data("#8000FF".utf8))])
        var last: String?
        await screens.follower().watch(
            stillLive: { screens.lock.withLock { screens.reads < 2 } },
            followed: { last = $0 })
        #expect(last == "walkIn")
        screens.lock.withLock {
            screens.reads = 0
            screens.signatures = [.success("walkIn"), .success("countdown")]
        }
        let events = await run(screens, stale: last, reads: 5)
        #expect(events == [.color(LightColor(hex: "#8000FF"))])
    }

    @Test func editsToTheLiveCue() {
        let song = Show.bundledDefault().cue("song1")!
        let rig = Rig.hope
        var off = song
        off.matchesScreens = false
        var purple = song
        purple.looks["screenSlimpars"] = GroupLook(color: LightColor(hex: "#8000FF")!, level: 0.1)
        var dimmer = song
        dimmer.looks["frontWash"] = GroupLook(level: 0.1)

        // The switch takes effect on the live cue at once.
        #expect(ScreensFollower.change(editing: song, to: off, rig: rig, following: true) == .stop)
        #expect(ScreensFollower.change(editing: off, to: song, rig: rig, following: false) == .start)
        // Off after a colour was picked by hand: nothing is following.
        #expect(ScreensFollower.change(editing: song, to: off, rig: rig, following: false) == .none)
        // A SlimPAR colour picked by hand wins; other edits leave matching alone.
        #expect(ScreensFollower.change(editing: song, to: purple, rig: rig, following: true) == .stop)
        #expect(ScreensFollower.change(editing: song, to: purple, rig: rig, following: false) == .none)
        #expect(ScreensFollower.change(editing: song, to: dimmer, rig: rig, following: true) == .none)
    }

    @Test func goOnTheFollowingCueKeepsFollowing() {
        #expect(ScreensFollower.keepsFollowing(firing: "song1", liveCueID: "song1", followingCueID: "song1"))
        #expect(!ScreensFollower.keepsFollowing(firing: "song2", liveCueID: "song1", followingCueID: "song1"))
        #expect(!ScreensFollower.keepsFollowing(firing: "song1", liveCueID: "song1", followingCueID: nil))
        #expect(!ScreensFollower.keepsFollowing(firing: "song1", liveCueID: nil, followingCueID: nil))
    }
}
