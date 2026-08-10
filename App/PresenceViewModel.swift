import Foundation
import MediaPlayer
import UIKit
import BackgroundTasks

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
    private var syncTimer: Timer?

    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    private var lastTrackID = ""
    private var lastPlaybackState: MPMusicPlaybackState = .stopped

    // MARK: - 起動

    func start() async {

        let auth = await MPMediaLibrary.requestAuthorization()

        guard auth == .authorized else {
            musicStatus = "Apple Music 権限なし"
            return
        }

        setupDiscordCallback()
        setupMusicNotifications()
        setupApplicationNotifications()

        startCallbackTimer()
        startSyncTimer()

        syncFromMusic()
    }

    // MARK: - Discord

    private func setupDiscordCallback() {

        DiscordBridge.shared().onStatusChanged = { [weak self] ready, text in

            Task { @MainActor in

                guard let self else { return }

                self.isDiscordReady = ready
                self.discordStatus = text

                if ready {
                    self.pushCurrentTrack()
                }
            }
        }
    }

    func connectDiscord() {

        let appID = GeneratedConfig.discordApplicationID

        guard appID != 0 else {
            discordStatus = "DISCORD_APP_ID が未設定"
            return
        }

        discordStatus = "接続中"

        DiscordBridge.shared().start(
            withApplicationID: appID
        )
    }

    // MARK: - Apple Music Notifications

    private func setupMusicNotifications() {

        player.beginGeneratingPlaybackNotifications()

        observe(
            .MPMusicPlayerControllerNowPlayingItemDidChange
        ) { [weak self] in

            self?.syncFromMusic()
        }

        observe(
            .MPMusicPlayerControllerPlaybackStateDidChange
        ) { [weak self] in

            self?.syncFromMusic()
        }

        observe(
            .MPMusicPlayerControllerVolumeDidChange
        ) { [weak self] in

            self?.syncFromMusic()
        }
    }

    private func observe(
        _ name: Notification.Name,
        action: @escaping @MainActor () -> Void
    ) {

        let observer = NotificationCenter.default.addObserver(
            forName: name,
            object: player,
            queue: .main
        ) { _ in

            Task { @MainActor in
                action()
            }
        }

        observers.append(observer)
    }

    // MARK: - App Notifications

    private func setupApplicationNotifications() {

        let activeObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in

            Task { @MainActor in

                guard let self else { return }

                self.endBackgroundTask()

                self.syncFromMusic()

                if self.isDiscordReady {
                    self.pushCurrentTrack()
                }
            }
        }

        observers.append(activeObserver)

        let backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in

            Task { @MainActor in

                guard let self else { return }

                self.beginBackgroundTask()

                self.syncFromMusic()
            }
        }

        observers.append(backgroundObserver)

        let foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in

            Task { @MainActor in

                self?.syncFromMusic()
            }
        }

        observers.append(foregroundObserver)
    }

    // MARK: - Discord callbacks

    private func startCallbackTimer() {

        callbackTimer?.invalidate()

        callbackTimer = Timer.scheduledTimer(
            withTimeInterval: 0.20,
            repeats: true
        ) { _ in

            DiscordBridge.shared().runCallbacks()
        }

        if let callbackTimer {
            RunLoop.main.add(
                callbackTimer,
                forMode: .common
            )
        }
    }

    // MARK: - 自動監視

    private func startSyncTimer() {

        syncTimer?.invalidate()

        syncTimer = Timer.scheduledTimer(
            withTimeInterval: 2.0,
            repeats: true
        ) { [weak self] _ in

            Task { @MainActor in
                self?.checkForChanges()
            }
        }

        if let syncTimer {
            RunLoop.main.add(
                syncTimer,
                forMode: .common
            )
        }
    }

    private func checkForChanges() {

        let item = player.nowPlayingItem

        let currentID =
            item?.playbackStoreID.isEmpty == false
            ? item?.playbackStoreID ?? ""
            : "\(item?.title ?? "")|\(item?.artist ?? "")"

        let state = player.playbackState

        if currentID != lastTrackID ||
            state != lastPlaybackState {

            lastTrackID = currentID
            lastPlaybackState = state

            syncFromMusic()
        }
    }

    // MARK: - Apple Music同期

    func syncFromMusic() {

        switch player.playbackState {

        case .playing:
            musicStatus = "再生中"

        case .paused:
            musicStatus = "一時停止"

        case .stopped:
            musicStatus = "停止"

        case .interrupted:
            musicStatus = "中断"

        case .seekingForward:
            musicStatus = "早送り"

        case .seekingBackward:
            musicStatus = "巻き戻し"

        @unknown default:
            musicStatus = "その他"
        }

        guard let item = player.nowPlayingItem else {

            trackTitle = "再生中の曲なし"
            artist = ""

            lastTrackID = ""
            lastPlaybackState = player.playbackState

            if autoUpdate && isDiscordReady {
                clearPresence()
            }

            return
        }

        trackTitle =
            item.title
            ?? "Unknown Track"

        artist =
            item.artist
            ?? "Unknown Artist"

        if !item.playbackStoreID.isEmpty {

            lastTrackID =
                item.playbackStoreID

        } else {

            lastTrackID =
                "\(trackTitle)|\(artist)"
        }

        lastPlaybackState =
            player.playbackState

        if autoUpdate && isDiscordReady {
            pushCurrentTrack()
        }
    }

    // MARK: - Discord Presence更新

    func pushCurrentTrack() {

        guard isDiscordReady else {
            return
        }

        guard
            player.playbackState == .playing,
            let item = player.nowPlayingItem
        else {

            clearPresence()
            return
        }

        let title =
            item.title
            ?? "Unknown Track"

        let artistName =
            item.artist
            ?? "Unknown Artist"

        let album =
            item.albumTitle
            ?? ""

        let duration =
            item.playbackDuration

        let elapsed =
            max(
                0,
                player.currentPlaybackTime
            )

        let now =
            Date().timeIntervalSince1970

        let start =
            Int64(
                now - elapsed
            )

        let end: Int64

        if duration > 0 {

            end = Int64(
                now - elapsed + duration
            )

        } else {

            end = 0
        }

        // Apple Music URL

        let storeID =
            item.playbackStoreID

        let songURL: String?

        if storeID.isEmpty {

            songURL = nil

        } else {

            songURL =
                "https://music.apple.com/song/\(storeID)"
        }

        // ジャケット画像
        //
        // MPMediaItemArtwork から直接URLは取れないため、
        // 現状はnil。
        //
        // Discord側の既存の画像処理を使う場合でも
        // artworkURL 引数そのものは必要。

        let artworkURL: String? = nil

        DiscordBridge.shared().updatePresence(
            title: title,
            artist: artistName,
            album: album,
            songURL: songURL,
            artworkURL: artworkURL,
            startTimestamp: start,
            endTimestamp: end
        )
    }

    // MARK: - Presence削除

    func clearPresence() {

        guard isDiscordReady else {
            return
        }

        DiscordBridge.shared().clearPresence()
    }

    // MARK: - Background task

    private func beginBackgroundTask() {

        if backgroundTaskID != .invalid {
            return
        }

        backgroundTaskID =
            UIApplication.shared.beginBackgroundTask(
                withName: "AppleMusicDiscordPresence"
            ) { [weak self] in

                Task { @MainActor in
                    self?.endBackgroundTask()
                }
            }
    }

    private func endBackgroundTask() {

        guard backgroundTaskID != .invalid else {
            return
        }

        UIApplication.shared.endBackgroundTask(
            backgroundTaskID
        )

        backgroundTaskID = .invalid
    }

    // MARK: - Background Refreshから呼ぶ

    func performBackgroundRefresh() async {

        syncFromMusic()

        if !isDiscordReady {

            let appID =
                GeneratedConfig.discordApplicationID

            if appID != 0 {

                DiscordBridge.shared().start(
                    withApplicationID: appID
                )
            }
        }

        for _ in 0..<20 {

            DiscordBridge.shared().runCallbacks()

            try? await Task.sleep(
                nanoseconds: 100_000_000
            )
        }

        syncFromMusic()

        if isDiscordReady {
            pushCurrentTrack()
        }
    }

    // MARK: - 手動更新

    func forceRefresh() {

        syncFromMusic()

        if isDiscordReady {
            pushCurrentTrack()
        }
    }

    // MARK: - 終了処理

    deinit {

        player.endGeneratingPlaybackNotifications()

        callbackTimer?.invalidate()
        syncTimer?.invalidate()

        for observer in observers {
            NotificationCenter.default.removeObserver(
                observer
            )
        }
    }
}
