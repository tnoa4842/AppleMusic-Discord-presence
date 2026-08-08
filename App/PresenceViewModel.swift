import Foundation
import MediaPlayer
import UIKit

@MainActor
final class PresenceViewModel: ObservableObject {
    @Published var trackTitle = "未取得"
    @Published var artist = "未取得"
    @Published var musicStatus = "停止"
    @Published var discordStatus = "未接続"
    @Published var isDiscordReady = false
    @Published var autoUpdate = true

    private let player = MPMusicPlayerController.systemMusicPlayer
    private var observers: [NSObjectProtocol] = []
    private var callbackTimer: Timer?

    func start() async {
        let auth = await MPMediaLibrary.requestAuthorization()
        guard auth == .authorized else {
            musicStatus = "Apple Music 権限なし"
            return
        }

        DiscordBridge.shared().onStatusChanged = { [weak self] ready, text in
            Task { @MainActor in
                self?.isDiscordReady = ready
                self?.discordStatus = text
                if ready { self?.pushCurrentTrack() }
            }
        }

        player.beginGeneratingPlaybackNotifications()

        observe(.MPMusicPlayerControllerNowPlayingItemDidChange) { [weak self] in
            self?.syncFromMusic()
        }

        observe(.MPMusicPlayerControllerPlaybackStateDidChange) { [weak self] in
            self?.syncFromMusic()
        }

        observers.append(
            NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.syncFromMusic()
                }
            }
        )

        callbackTimer = Timer.scheduledTimer(withTimeInterval: 0.20, repeats: true) { _ in
            DiscordBridge.shared().runCallbacks()
        }

        syncFromMusic()
    }

    private func observe(_ name: Notification.Name, action: @escaping @MainActor () -> Void) {
        observers.append(
            NotificationCenter.default.addObserver(
                forName: name,
                object: player,
                queue: .main
            ) { _ in
                Task { @MainActor in action() }
            }
        )
    }

    func connectDiscord() {
        let appID = GeneratedConfig.discordApplicationID
        guard appID != 0 else {
            discordStatus = "DISCORD_APP_ID が未設定"
            return
        }
        DiscordBridge.shared().start(withApplicationID: appID)
    }

    func syncFromMusic() {
        switch player.playbackState {
        case .playing: musicStatus = "再生中"
        case .paused:  musicStatus = "一時停止"
        case .stopped: musicStatus = "停止"
        default:       musicStatus = "その他"
        }

        guard let item = player.nowPlayingItem else {
            trackTitle = "再生中の曲なし"
            artist = ""
            if autoUpdate && isDiscordReady { clearPresence() }
            return
        }

        trackTitle = item.title ?? "Unknown Track"
        artist = item.artist ?? "Unknown Artist"

        if autoUpdate && isDiscordReady {
            pushCurrentTrack()
        }
    }

    func pushCurrentTrack() {
        guard isDiscordReady else { return }

        guard player.playbackState == .playing, let item = player.nowPlayingItem else {
            clearPresence()
            return
        }

        let title = item.title ?? "Unknown Track"
        let artistName = item.artist ?? "Unknown Artist"
        let album = item.albumTitle ?? ""
        let duration = item.playbackDuration
        let elapsed = max(0, player.currentPlaybackTime)
        let now = Date().timeIntervalSince1970

        let start = Int64(now - elapsed)
        let end = duration > 0 ? Int64(now - elapsed + duration) : 0

        let storeID = item.playbackStoreID
        let url = storeID.isEmpty ? nil : "https://music.apple.com/song/\(storeID)"

        DiscordBridge.shared().updatePresence(
            title: title,
            artist: artistName,
            album: album,
            songURL: url,
            startTimestamp: start,
            endTimestamp: end
        )
    }

    func clearPresence() {
        DiscordBridge.shared().clearPresence()
    }

    deinit {
        player.endGeneratingPlaybackNotifications()
        callbackTimer?.invalidate()
        for o in observers { NotificationCenter.default.removeObserver(o) }
    }
}
