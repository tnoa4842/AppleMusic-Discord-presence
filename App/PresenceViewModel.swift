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

    // 最後に検出した曲
    private var lastTrackID = ""

    // 最後に検出した再生状態
    private var lastPlaybackState: MPMusicPlaybackState = .stopped

    // 最後にDiscordへ送った曲
    private var lastSentTrackID = ""

    // 最後にDiscordへ送った再生状態
    private var lastSentPlaybackState: MPMusicPlaybackState = .stopped

    // デバウンス用
    private var pendingPresenceTask: Task<Void, Never>?

    // 連続スキップ時の待ち時間
    private let presenceDebounceNanoseconds: UInt64 = 700_000_000

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

        syncFromMusic(
            forcePresenceUpdate: false
        )
    }

    // MARK: - Discord

    private func setupDiscordCallback() {

        DiscordBridge.shared().onStatusChanged = { [weak self] ready, text in

            Task { @MainActor in

                guard let self else {
                    return
                }

                self.isDiscordReady = ready
                self.discordStatus = text

                if ready {

                    // Discord接続直後は現在曲を強制送信
                    self.schedulePresenceUpdate(
                        force: true
                    )
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

            guard let self else {
                return
            }

            // 曲変更
            self.syncFromMusic(
                forcePresenceUpdate: false
            )

            // 最新曲だけ送る
            self.schedulePresenceUpdate(
                force: false
            )
        }

        observe(
            .MPMusicPlayerControllerPlaybackStateDidChange
        ) { [weak self] in

            guard let self else {
                return
            }

            self.syncFromMusic(
                forcePresenceUpdate: false
            )

            self.schedulePresenceUpdate(
                force: false
            )
        }

        observe(
            .MPMusicPlayerControllerVolumeDidChange
        ) { [weak self] in

            guard let self else {
                return
            }

            self.syncFromMusic(
                forcePresenceUpdate: false
            )
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

                guard let self else {
                    return
                }

                self.endBackgroundTask()

                self.syncFromMusic(
                    forcePresenceUpdate: false
                )

                self.schedulePresenceUpdate(
                    force: true
                )
            }
        }

        observers.append(activeObserver)

        let backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in

            Task { @MainActor in

                guard let self else {
                    return
                }

                self.beginBackgroundTask()

                self.syncFromMusic(
                    forcePresenceUpdate: false
                )

                self.schedulePresenceUpdate(
                    force: false
                )
            }
        }

        observers.append(backgroundObserver)

        let foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in

            Task { @MainActor in

                guard let self else {
                    return
                }

                self.syncFromMusic(
                    forcePresenceUpdate: false
                )
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
            withTimeInterval: 1.0,
            repeats: true
        ) { [weak self] _ in

            Task { @MainActor in

                guard let self else {
                    return
                }

                self.checkForChanges()
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

        let currentTrackID =
            makeTrackID(
                from: player.nowPlayingItem
            )

        let state =
            player.playbackState

        let trackChanged =
            currentTrackID != lastTrackID

        let stateChanged =
            state != lastPlaybackState

        guard trackChanged || stateChanged else {
            return
        }

        lastTrackID =
            currentTrackID

        lastPlaybackState =
            state

        syncFromMusic(
            forcePresenceUpdate: false
        )

        schedulePresenceUpdate(
            force: false
        )
    }

    // MARK: - Apple Music同期

    func syncFromMusic(
        forcePresenceUpdate: Bool = false
    ) {

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

            if autoUpdate &&
                isDiscordReady &&
                forcePresenceUpdate {

                schedulePresenceUpdate(
                    force: true
                )
            }

            return
        }

        trackTitle =
            item.title
            ?? "Unknown Track"

        artist =
            item.artist
            ?? "Unknown Artist"

        lastTrackID =
            makeTrackID(
                from: item
            )

        lastPlaybackState =
            player.playbackState

        if autoUpdate &&
            isDiscordReady &&
            forcePresenceUpdate {

            schedulePresenceUpdate(
                force: true
            )
        }
    }

    // MARK: - Track ID

    private func makeTrackID(
        from item: MPMediaItem?
    ) -> String {

        guard let item else {
            return ""
        }

        if !item.playbackStoreID.isEmpty {

            return item.playbackStoreID
        }

        let title =
            item.title
            ?? ""

        let artist =
            item.artist
            ?? ""

        let album =
            item.albumTitle
            ?? ""

        return "\(title)|\(artist)|\(album)"
    }

    // MARK: - デバウンス

    private func schedulePresenceUpdate(
        force: Bool
    ) {

        guard autoUpdate else {
            return
        }

        guard isDiscordReady else {
            return
        }

        // まだ待機中の古い更新は破棄
        pendingPresenceTask?.cancel()

        pendingPresenceTask = Task { [weak self] in

            do {

                try await Task.sleep(
                    nanoseconds: self?.presenceDebounceNanoseconds
                        ?? 700_000_000
                )

            } catch {

                return
            }

            guard !Task.isCancelled else {
                return
            }

            guard let self else {
                return
            }

            self.performLatestPresenceUpdate(
                force: force
            )
        }
    }

    // MARK: - 最新状態だけ反映

    private func performLatestPresenceUpdate(
        force: Bool
    ) {

        guard isDiscordReady else {
            return
        }

        let state =
            player.playbackState

        guard
            state == .playing,
            let item = player.nowPlayingItem
        else {

            if force ||
                lastSentPlaybackState != state ||
                !lastSentTrackID.isEmpty {

                clearPresence()

                lastSentTrackID = ""
                lastSentPlaybackState = state
            }

            return
        }

        let currentTrackID =
            makeTrackID(
                from: item
            )

        // 同じ曲 + 同じ状態なら送らない
        if !force &&
            currentTrackID == lastSentTrackID &&
            state == lastSentPlaybackState {

            return
        }

        pushCurrentTrack()

        lastSentTrackID =
            currentTrackID

        lastSentPlaybackState =
            state
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

        // 現在はDiscord側の既存画像処理に任せる
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

        DiscordBridge.shared().runCallbacks()
    }

    // MARK: - Presence削除

    func clearPresence() {

        guard isDiscordReady else {
            return
        }

        DiscordBridge.shared().clearPresence()

        DiscordBridge.shared().runCallbacks()
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

        syncFromMusic(
            forcePresenceUpdate: false
        )

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

        syncFromMusic(
            forcePresenceUpdate: false
        )

        if isDiscordReady {

            // BG refresh時は待たずに即反映
            performLatestPresenceUpdate(
                force: true
            )
        }
    }

    // MARK: - 手動更新

    func forceRefresh() {

        syncFromMusic(
            forcePresenceUpdate: false
        )

        pendingPresenceTask?.cancel()

        performLatestPresenceUpdate(
            force: true
        )
    }

    // MARK: - 終了処理

    deinit {

        player.endGeneratingPlaybackNotifications()

        callbackTimer?.invalidate()
        syncTimer?.invalidate()

        pendingPresenceTask?.cancel()

        for observer in observers {

            NotificationCenter.default.removeObserver(
                observer
            )
        }
    }
}
