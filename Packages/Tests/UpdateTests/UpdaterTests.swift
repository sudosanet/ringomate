import Foundation
import Testing
@testable import Update

private func latest(_ tag: String, _ assets: [String]) throws -> Updater.Latest {
    let list = assets.map { #"{"name":"\#($0)","browser_download_url":"https://example.com/\#($0)"}"# }.joined(separator: ",")
    let json = #"{"tag_name":"\#(tag)","html_url":"https://example.com/r","assets":[\#(list)]}"#
    return try JSONDecoder().decode(Updater.Latest.self, from: Data(json.utf8))
}

@Test func picksOnlyNewerReleasesWithADmg() throws {
    #expect(Updater.newer(try latest("v0.0.10", ["RingoMate.dmg", "ringomate-claude-plugin-0.0.10.zip"]), than: "0.0.9")?.dmg.lastPathComponent == "RingoMate.dmg")
    #expect(Updater.newer(try latest("v0.0.9", ["RingoMate.dmg"]), than: "0.0.9") == nil)
    #expect(Updater.newer(try latest("v0.0.8", ["RingoMate.dmg"]), than: "0.0.9") == nil)
    #expect(Updater.newer(try latest("v0.1.0", ["ringomate-claude-plugin-0.1.0.zip"]), than: "0.0.9") == nil)
}

@Test func rejectsAppsFromOtherTeams() {
    #expect(throws: (any Error).self) { try Updater.verify(URL(filePath: "/System/Applications/Calculator.app")) }
}
