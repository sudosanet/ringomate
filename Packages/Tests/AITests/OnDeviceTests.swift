import Testing
@testable import AI

@Test func firstUsableLineSkipsToolText() {
    #expect(OnDevice.firstLine("**Move**  \n手を振って、鑑定士の元へ") == "手を振って、鑑定士の元へ")
    #expect(OnDevice.firstLine("**[sit]**\n\n窓の上、静かに…") == "窓の上、静かに…")
    #expect(OnDevice.firstLine("**gesture** {value:<ctrl46>bow<ctrl46>}") == "")
    #expect(OnDevice.firstLine("おかえり、鑑定士。\n二行目") == "おかえり、鑑定士。")
}

@Test func trimmingKeepsQuotesThatDoNotWrapTheLine() {
    #expect(OnDevice.trimmed("「NEW KAWAII」、ちょっと眠い…できるかな？") == "「NEW KAWAII」、ちょっと眠い…できるかな？")
    #expect(OnDevice.trimmed(" 「おかえり、鑑定士」 ") == "おかえり、鑑定士")
    #expect(OnDevice.trimmed("\"Special♡Spell\"は、いい曲") == "\"Special♡Spell\"は、いい曲")
    #expect(OnDevice.trimmed("🎶「NEW KAWAII」、いいね") == "「NEW KAWAII」、いいね")
    #expect(OnDevice.trimmed("おめでとう！がんばったね！」}") == "おめでとう！がんばったね！")
    #expect(OnDevice.trimmed("おはようございます。」}```json  ```日本語:おはよう") == "おはようございます。")
    #expect(OnDevice.trimmed("ゆっくりしてください。」}<ctrl46>") == "ゆっくりしてください。")
}

@Test func japaneseClipStopsAtAPause() {
    let j = SpeechLanguage.japanese
    #expect(j.clip("うーん、この曲は…眠い感じだよ「Special♡Spell」……レクイエム、バレるよ。", 39)
        == "うーん、この曲は…眠い感じだよ「Special♡Spell」……")
    #expect(j.clip("「Special♡Spell」、少し眠そうに聴こえるな…レクイエム、もうちょっと待ってて。", 39)
        == "「Special♡Spell」、少し眠そうに聴こえるな…")
    #expect(j.clip("鑑定士、Ghostty、動かないよ。ちょっと休んでみて。「レクイエム」で、任せて。", 39) == "鑑定士、Ghostty、動かないよ。ちょっと休んでみて。")
    #expect(j.clip("短い文", 39) == "短い文")
}
