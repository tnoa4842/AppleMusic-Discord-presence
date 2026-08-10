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

    // Discord SDK の callback を回す
    private var callbackTimer: Timer?

    // 曲変更通知を取りこぼした場合の保険
    private var musicPollTimer: Timer?

    // バックグラウンドに入った直後の猶予時間を利用
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    private var lastTrackKey = ""
    private var lastPlaybackState: MPMusicPlaybackState = .stopped

    private var hasStarted = false

    // MARK: - Start

    func start() async {

        guard !hasStarted else {
            syncFromMusic(force: true)
            return
        }

        hasStarted = true

        let auth = await MPMediaLibrary.requestAuthorization()

        guard auth == .authorized else {
            musicStatus = "Apple Music 権限なし"
            return
        }

        setupDiscordCallback()

        player.beginGeneratingPlaybackNotifications()

        setupMusicNotifications()
        setupApplicationNotifications()
        setupBackgroundRefreshNotification()

        startForegroundTimers()

        syncFromMusic(force: true)

        BackgroundRefreshManager.schedule()
    }

    // MARK: - Discord

    private func setupDiscordCallback() {

        DiscordBridge.shared().onStatusChanged = { [weak self] ready, text in

            Task { @MainActor in

                guard let self else { return }

                self.isDiscordReady = ready
                self.discordStatus = text

                if ready {
                    self.pushCurrentTrack(force: true)
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

        discordStatus = "Discord 接続中"

        DiscordBridge.shared().start(
            withApplicationID: appID
        )
    }

    // MARK: - Music Notifications

    private func setupMusicNotifications() {

        observe(
            .MPMusicPlayerControllerNowPlayingItemDidChange
        ) { [weak self] in

            guard let self else { return }

            self.syncFromMusic(force: true)
        }

        observe(
            .MPMusicPlayerControllerPlaybackStateDidChange
        ) { [weak self] in

            guard let self else { return }

            self.syncFromMusic(force: true)
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

        observers.append(

            NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in

                Task { @MainActor in

                    guard let self else { return }

                    self.endBackgroundTask()

                    self.startForegroundTimers()

                    self.syncFromMusic(force: true)

                    BackgroundRefreshManager.schedule()
                }
            }
        )

        observers.append(

            NotificationCenter.default.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in

                Task { @MainActor in
                    self?.syncFromMusic(force: true)
                }
            }
        )

        observers.append(

            NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in

                Task { @MainActor in

                    guard let self else { return }

                    self.beginBackgroundTask()

                    self.syncFromMusic(force: true)

                    BackgroundRefreshManager.schedule()
                }
            }
        )

        observers.append(

            NotificationCenter.default.addObserver(
                forName: UIApplication.willResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in

                Task { @MainActor in
                    self?.syncFromMusic(force: true)
                }
            }
        )
    }

    // MARK: - BGTask Notification

    private func setupBackgroundRefreshNotification() {

        observers.append(

            NotificationCenter.default.addObserver(
                forName: .appleMusicDiscordBackgroundRefresh,
                object: nil,
                queue: .main
            ) { [weak self] _ in

                Task { @MainActor in

                    guard let self else { return }

                    self.runBackgroundRefresh()
                }
            }
        )
    }

    func runBackgroundRefresh() {

        // Discord SDK callback を何回か処理
        DiscordBridge.shared().runCallbacks()

        syncFromMusic(force: true)

        BackgroundRefreshManager.schedule()
    }

    // MARK: - Foreground Timers

    private func startForegroundTimers() {

        callbackTimer?.invalidate()
        musicPollTimer?.invalidate()

        // Discord SDK callback
        callbackTimer = Timer.scheduledTimer(
            withTimeInterval: 0.20,
            repeats: true
        ) { _ in

            DiscordBridge.shared().runCallbacks()
        }

        // MusicPlayer の通知取りこぼし対策
        musicPollTimer = Timer.scheduledTimer(
            withTimeInterval: 2.0,
            repeats: true
        ) { [weak self] _ in

            Task { @MainActor in
                self?.syncFromMusic(force: false)
            }
        }
    }

    // MARK: - Background Grace Period

    private func beginBackgroundTask() {

        endBackgroundTask()

        backgroundTask = UIApplication.shared.beginBackgroundTask(
            withName: "AppleMusicDiscordPresence"
        ) { [weak self] in

            Task { @MainActor in
                self?.endBackgroundTask()
            }
        }

        // バックグラウンドへ移行した直後は
        // iOSが許す間だけ監視を継続する。
        startBackgroundPolling()
    }

    private func startBackgroundPolling() {

        musicPollTimer?.invalidate()

        musicPollTimer = Timer.scheduledTimer(
            withTimeInterval: 2.0,
            repeats: true
        ) { [weak self] _ in

            Task { @MainActor in

                guard let self else { return }

                DiscordBridge.shared().runCallbacks()

                self.syncFromMusic(force: false)
            }
        }
    }

    private func endBackgroundTask() {

        guard backgroundTask != .invalid else {
            return
        }

        UIApplication.shared.endBackgroundTask(
            backgroundTask
        )

        backgroundTask = .invalid
    }

    // MARK: - Sync Music

    func syncFromMusic(force: Bool = false) {

        let playbackState = player.playbackState

        switch playbackState {

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

            let stateChanged =
                playbackState != lastPlaybackState

            lastPlaybackState = playbackState

            if autoUpdate &&
                isDiscordReady &&
                (force || stateChanged) {

                clearPresence()
            }

            lastTrackKey = ""

            return
        }

        let title = item.title ?? "Unknown Track"
        let artistName = item.artist ?? "Unknown Artist"
        let album = item.albumTitle ?? ""

        let storeID = item.playbackStoreID

        let persistentID =
            String(item.persistentID)

        let trackKey =
            "\(storeID)|\(persistentID)|\(title)|\(artistName)|\(album)"

        let trackChanged =
            trackKey != lastTrackKey

        let stateChanged =
            playbackState != lastPlaybackState

        trackTitle = title
        artist = artistName

        lastTrackKey = trackKey
        lastPlaybackState = playbackState

        guard autoUpdate else {
            return
        }

        guard isDiscordReady else {
            return
        }

        if force || trackChanged || stateChanged {

            if playbackState == .playing {

                pushCurrentTrack(
                    force: true
                )

            } else {

                clearPresence()
            }
        }
    }

    // MARK: - Push Presence

    func pushCurrentTrack(force: Bool = false) {

        guard isDiscordReady else {
            return
        }

        guard player.playbackState == .playing else {

            clearPresence()

            return
        }

        guard let item = player.nowPlayingItem else {

            clearPresence()

            return
        }

        let title =
            item.title ?? "Unknown Track"

        let artistName =
            item.artist ?? "Unknown Artist"

        let album =
            item.albumTitle ?? ""

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

        let storeID =
            item.playbackStoreID

        let songURL: String?

        if storeID.isEmpty {

            songURL = nil

        } else {

            songURL =
                "https://music.apple.com/song/\(storeID)"
        }

        DiscordBridge.shared().updatePresence(
            title: title,
            artist: artistName,
            album: album,
            songURL: songURL,
            startTimestamp: start,
            endTimestamp: end
        )

        // SDKによってはUpdateRichPresence後も
        // callback処理が必要なので即回す
        DiscordBridge.shared().runCallbacks()
    }

    // MARK: - Clear

    func clearPresence() {

        guard isDiscordReady else {
            return
        }

        DiscordBridge.shared().clearPresence()

        DiscordBridge.shared().runCallbacks()
    }

    // MARK: - Manual Refresh

    func refreshNow() {

        DiscordBridge.shared().runCallbacks()

        syncFromMusic(force: true)
    }

    // MARK: - Cleanup

    deinit {

        player.endGeneratingPlaybackNotifications()

        callbackTimer?.invalidate()
        musicPollTimer?.invalidate()

        for observer in observers {

            NotificationCenter.default.removeObserver(
                observer
            )
        }

        if backgroundTask != .invalid {

            UIApplication.shared.endBackgroundTask(
                backgroundTask
            )
        }
    }
}
