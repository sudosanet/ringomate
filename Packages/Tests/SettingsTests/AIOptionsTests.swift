import Foundation
import SwiftUI
import Testing
@testable import Settings

@Test func quietHoursWrapPastMidnight() {
    #expect(isQuietHour(23, from: 23, to: 7))
    #expect(isQuietHour(3, from: 23, to: 7))
    #expect(!isQuietHour(7, from: 23, to: 7))
    #expect(isQuietHour(13, from: 12, to: 14))
    #expect(!isQuietHour(5, from: 5, to: 5))
}

@Test func permissionKindsAndPersona() throws {
    #expect(PermissionKind(tool: "Bash") == .bash)
    #expect(PermissionKind(tool: "NotebookEdit") == .edit)
    #expect(PermissionKind(tool: "mcp__x__y") == nil)
    let d = try #require(UserDefaults(suiteName: "ringomate.test.\(UUID())"))
    #expect(PermissionKind.allowed(d) == Set(PermissionKind.allCases))
    d.set("edit,web", forKey: SettingsKey.permissionKinds)
    #expect(PermissionKind.allowed(d) == [.edit, .web])
    d.set("custom", forKey: SettingsKey.persona)
    #expect(PersonaPreset.resolved(d) == PersonaPreset.gentle.text)
    d.set(String(repeating: "あ", count: 999), forKey: SettingsKey.personaCustom)
    #expect(PersonaPreset.resolved(d).count == PersonaPreset.maxCustomLength)
}

@Test func quotedExampleLinesAreDetected() {
    #expect(PersonaPreset.hasQuotedLines("眠たげに話す。「レクイエム、できる。」「ミントを…いじめないで。」"))
    #expect(!PersonaPreset.hasQuotedLines("眠たげに話す。「〜できる」「〜ないよ」のように区切る。"))
    #expect(!PersonaPreset.hasQuotedLines(PersonaPreset.gentle.text))
}

@Test func registeredDefaultsAreReadWithoutFallbacks() throws {
    let d = try #require(UserDefaults(suiteName: "ringomate.test.\(UUID())"))
    SettingsKey.registerDefaults(d)
    #expect(d.double(forKey: SettingsKey.bloomStrength) == 0.8)
    #expect(d.integer(forKey: SettingsKey.antialiasing) == 4)
    #expect(d.bool(forKey: SettingsKey.chatter) && !d.bool(forKey: SettingsKey.readNotifications))
    d.set(false, forKey: SettingsKey.chatter)
    #expect(!d.bool(forKey: SettingsKey.chatter))
}

@Test func commaListMember() {
    nonisolated(unsafe) var s = "b,a"
    let list = Binding(get: { s }, set: { s = $0 })
    list.member("c").wrappedValue = true
    #expect(s == "a,b,c")
    list.member("a", present: false).wrappedValue = true
    #expect(s == "b,c")
    list.member("a", order: ["c", "a", "b"]).wrappedValue = true
    #expect(s == "c,a,b")
}
