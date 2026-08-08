import Foundation

enum AppConfig {
    static var discordApplicationID: UInt64 {
        guard
            let raw = Bundle.main.object(forInfoDictionaryKey: "DiscordApplicationID") as? String,
            let value = UInt64(raw)
        else {
            // Build script also generates Config.generated.swift, so this is just fallback.
            return GeneratedConfig.discordApplicationID
        }
        return value
    }
}

enum GeneratedConfig {
    static let discordApplicationID: UInt64 = 0
}
