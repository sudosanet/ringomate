import CoreGraphics
import Foundation
import Testing
@testable import AI
import FoundationModels

@MainActor
@Test func chatterReturnsShortLine() async {
    let c = Chatter()
    guard c.available else { return }
    let line = await c.line(for: "The coding task your owner asked for just finished. Thank them for the work")
    print("CHATTER:", line ?? "nil")
    #expect(line.map { !$0.isEmpty && (SpeechLanguage.isCJK($0) ? $0.count <= 28 : $0.split(separator: " ").count <= 14) } == true)
}

@MainActor
@Test func conversationRepliesWithActingAndRemembers() async throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "ringomate-memory-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let c = Conversation(memoryURL: url)
    guard c.available else { return }
    var face: [String: Float]?
    defer { print("LASTERROR:", c.lastError ?? "none") }
    let r = try #require(await c.reply(to: "テストが全部通ったよ！", context: "It is 14:00. standing and waiting") { face = $0 })
    print("REPLY:", r.text, r.expressionWeights, face ?? [:])
    #expect(!r.text.isEmpty && (SpeechLanguage.isCJK(r.text) ? r.text.count <= 40 : r.text.split(separator: " ").count <= 20))
    #expect(face != nil)
    #expect(r.expressionWeights.values.allSatisfy { (0...1).contains($0) })
    #expect(Conversation(memoryURL: url).memory.turns.count == 1)
}

@Test func actionUnitsMapToCommonExpressions() {
    let smile = Conversation.Reply.expressionWeights(au6: 0.8, au12: 0.9, au1: 0, au4: 0, au15: 0, au26: 0, blush: 0)
    #expect(smile["smile"] == 0.9 && smile["angry"] == nil)
    let angry = Conversation.Reply.expressionWeights(au6: 0, au12: 0, au1: 0, au4: 2, au15: 0, au26: 0, blush: nil)
    #expect(angry["angry"] == 1)
}

@MainActor
@Test func composerReturnsKeyframes() async throws {
    let c = Composer()
    guard c.available else { return }
    let json = try #require(await c.compose("両手を上げて喜ぶ"))
    print("COMPOSED:", json)
    let keys = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
    #expect(!keys.isEmpty)
    for k in keys {
        for m in k["commands"] as? [[String: Any]] ?? [] {
            #expect(Composer.moves.contains(m["move"] as? String ?? ""))
        }
    }
}

@MainActor
@Test func boneAssistSuggestsFromTheList() async {
    let a = BoneAssist()
    guard a.available else { return }
    let bones = ["全ての親", "センター", "上半身", "首", "头", "左肩", "左臂", "左肘", "左手腕", "右肩", "右臂", "右肘", "右手腕"]
    let s = await a.suggest(missing: ["左ひじ", "右ひじ", "頭"], bones: bones)
    print("SUGGEST:", s)
    #expect(s.allSatisfy { bones.contains($0.candidate) })
    #expect(!s.isEmpty)
}

@MainActor
@Test func conversationUsesTools() async throws {
    var called = 0
    for _ in 0..<3 {
        let url = FileManager.default.temporaryDirectory.appending(path: "ringomate-memory-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let c = Conversation(memoryURL: url)
        guard c.available else { return }
        let calls = Calls()
        c.tools = { [GestureTool(calls: calls)] }
        let r = try #require(await c.reply(to: "こっちに向かって手を振って！", context: "It is 14:00. standing and waiting"))
        print("REPLY:", r.text, "TOOLS:", await calls.list)
        if await calls.list.contains("wave") { called += 1 }
        if called > 0 { break }
    }
    #expect(called > 0)
}

private actor Calls {
    var list: [String] = []
    func add(_ s: String) { list.append(s) }
}

private struct GestureTool: Tool {
    let name = "gesture"
    let description = "Make the character do a body gesture."
    let calls: Calls
    @Generable struct Arguments {
        @Guide(.anyOf(["wave", "bow", "nod", "dance"])) var value: String
    }
    func call(arguments: Arguments) async throws -> String {
        await calls.add(arguments.value)
        return "done"
    }
}

@MainActor
@Test func chatterLooksAtTheScreen() async throws {
    let c = Chatter()
    guard c.canSee else { return }
    let ctx = try #require(CGContext(data: nil, width: 512, height: 320, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    ctx.setFillColor(CGColor(red: 0.4, green: 0.7, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 512, height: 320))
    ctx.setFillColor(CGColor(red: 0.2, green: 0.7, blue: 0.3, alpha: 1)); ctx.fillEllipse(in: CGRect(x: -100, y: -200, width: 700, height: 360))
    ctx.setFillColor(CGColor(red: 1, green: 0.9, blue: 0.2, alpha: 1)); ctx.fillEllipse(in: CGRect(x: 400, y: 230, width: 60, height: 60))
    let image = try #require(ctx.makeImage())
    let line = await c.line(for: "Your owner opened an image. It is 14:00", image: image)
    print("SEE:", line ?? "nil")
    #expect(line.map { !$0.isEmpty } == true)
}

@MainActor
@Test func namesAnObject() async throws {
    guard SystemLanguageModel.default.capabilities.contains(.vision) else { return }
    let ctx = try #require(CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
    ctx.setFillColor(CGColor(red: 0.85, green: 0.1, blue: 0.1, alpha: 1)); ctx.fillEllipse(in: CGRect(x: 48, y: 30, width: 160, height: 160))
    ctx.setFillColor(CGColor(red: 0.4, green: 0.25, blue: 0.1, alpha: 1)); ctx.fill(CGRect(x: 124, y: 180, width: 8, height: 40))
    ctx.setFillColor(CGColor(red: 0.2, green: 0.7, blue: 0.2, alpha: 1)); ctx.fillEllipse(in: CGRect(x: 132, y: 195, width: 40, height: 20))
    let d = await ObjectNamer.describe(try #require(ctx.makeImage()))
    print("NAME:", d.map { "\($0.name) \($0.sittable) \($0.comment)" } ?? "nil")
    #expect(d != nil)
}

@Test func similarLinesAreDetected() {
    #expect(Chatter.similar("画面の光が広がって、少しずつ進んでるね", "画面の光が広がって少しずつ進んでるね。"))
    #expect(Chatter.similar("Safariの光が静かに広がってるよ", "Safariの光が静かに広がってるね、土曜の夜だね"))
    #expect(!Chatter.similar("夜のSafariで何か見つけているみたいだよ", "Safariで海を見ているみたいだね"))
    #expect(!Chatter.similar("テスト全部通ったね", "お昼ごはん何にする？"))
    #expect(Chatter.similar("The light is spreading across the screen", "The light is spreading across the screen now!"))
    #expect(!Chatter.similar("All the tests passed, nice work", "What do you want for lunch today?"))
}

@Test func lengthFollowsTheSpeechLanguage() {
    #expect(SpeechLanguage.japanese.clip("あいうえおかきくけこ", 4) == "あいうえ")
    #expect(SpeechLanguage.english.clip("one two three four five", 4) == "one two")
    #expect(SpeechLanguage.english.limit(20) == "in at most 10 words")
    #expect(SpeechLanguage.isCJK("テストOK") && !SpeechLanguage.isCJK("Tests OK"))
    #expect(SpeechLanguage.readingSeconds(String(repeating: "あ", count: 80)) == 10)
    #expect(SpeechLanguage.readingSeconds(String(repeating: "a", count: 180)) == 10)
}

@Test func clipEndsAtSentence() {
    #expect(SpeechLanguage.japanese.clip("今日は晴れ。お散歩しようよ、どこか", 10) == "今日は晴れ。")
    #expect(SpeechLanguage.japanese.clip("短い。", 10) == "短い。")
    #expect(SpeechLanguage.japanese.matches("こんにちは"))
    #expect(!SpeechLanguage.japanese.matches("Hello there"))
    #expect(SpeechLanguage.english.matches("Hello there"))
}
