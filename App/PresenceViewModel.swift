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

    // MARK: - 曲監視

    private var lastTrackID = ""
    private var lastPlaybackState: MPMusicPlaybackState = .stopped

    // MARK: - Discord送信済み状態

    private var lastSentTrackID = ""
    private var lastSentPlaybackState: MPMusicPlaybackState = .stopped

    // MARK: - デバウンス

    private var pendingPresenceTask: Task<Void, Never>?

    // 0.7秒
    private let presenceDebounceNanoseconds: UInt64 = 700_000_000

    // MARK: - Artwork

    // 曲ID -> Artwork URL
    private var artworkCache: [String: String] = [:]

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

            self.syncFromMusic(
                forcePresenceUpdate: false
            )

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

        // 前の予約をキャンセル
        //
        // A → B → C と高速スキップされた場合、
        // A/BはDiscordへ送らずCだけ送る。

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

            await self.performLatestPresenceUpdate(
                force: force
            )
        }
    }

    // MARK: - 最新曲をDiscordへ反映

    private func performLatestPresenceUpdate(
        force: Bool
    ) async {

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

        if !force &&
            currentTrackID == lastSentTrackID &&
            state == lastSentPlaybackState {

            return
        }

        // この時点の曲情報を保存
        //
        // Artwork取得中に曲が変わっても
        // 古い曲をDiscordへ送らないために使う。

        let expectedTrackID =
            currentTrackID

        await pushCurrentTrack(
            expectedTrackID: expectedTrackID
        )

        // 通信中に曲が変わった可能性があるので再確認

        let latestTrackID =
            makeTrackID(
                from: player.nowPlayingItem
            )

        guard latestTrackID == expectedTrackID else {

            // 曲が変わっていたら最新曲を改めて予約

            schedulePresenceUpdate(
                force: false
            )

            return
        }

        lastSentTrackID =
            expectedTrackID

        lastSentPlaybackState =
            player.playbackState
    }

    // MARK: - Discord Presence更新

    private func pushCurrentTrack(
        expectedTrackID: String
    ) async {

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

        // MARK: Apple Music URL

        let storeID =
            item.playbackStoreID

        let songURL: String?

        if storeID.isEmpty {

            songURL = nil

        } else {

            songURL =
                "https://music.apple.com/song/\(storeID)"
        }

        // MARK: Artwork URL取得

        let artworkURL =
            await getArtworkURL(
                title: title,
                artist: artistName,
                album: album,
                trackID: expectedTrackID
            )

        // Artwork取得中に曲が変わっていないか確認

        guard
            makeTrackID(
                from: player.nowPlayingItem
            ) == expectedTrackID
        else {

            return
        }

        guard player.playbackState == .playing else {
            return
        }

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

    // MARK: - Artwork取得

    private func getArtworkURL(
        title: String,
        artist: String,
        album: String,
        trackID: String
    ) async -> String? {

        // キャッシュ済みなら通信しない

        if let cached =
            artworkCache[trackID] {

            return cached
        }

        // 曲名 + アーティストで検索
        //
        // albumまで入れると検索に失敗する曲があるので、
        // 基本は曲名とアーティストを使用。

        let searchTerm =
            "\(title) \(artist)"

        guard let encoded =
            searchTerm.addingPercentEncoding(
                withAllowedCharacters: .urlQueryAllowed
            )
        else {

            return nil
        }

        let urlString =
            "https://itunes.apple.com/search?term=\(encoded)&entity=song&limit=10&country=JP"

        guard let url =
            URL(
                string: urlString
            )
        else {

            return nil
        }

        do {

            let (data, response) =
                try await URLSession.shared.data(
                    from: url
                )

            if let http =
                response as? HTTPURLResponse {

                guard
                    (200...299).contains(
                        http.statusCode
                    )
                else {

                    return nil
                }
            }

            let result =
                try JSONDecoder().decode(
                    ITunesSearchResponse.self,
                    from: data
                )

            guard !result.results.isEmpty else {
                return nil
            }

            // MARK: 一番近い結果を探す

            let normalizedTitle =
                normalize(title)

            let normalizedArtist =
                normalize(artist)

            let normalizedAlbum =
                normalize(album)

            var bestResult: ITunesTrack?
            var bestScore = -1

            for candidate in result.results {

                var score = 0

                let candidateTitle =
                    normalize(
                        candidate.trackName ?? ""
                    )

                let candidateArtist =
                    normalize(
                        candidate.artistName ?? ""
                    )

                let candidateAlbum =
                    normalize(
                        candidate.collectionName ?? ""
                    )

                // 曲名完全一致を最優先

                if candidateTitle == normalizedTitle {

                    score += 100

                } else if
                    candidateTitle.contains(
                        normalizedTitle
                    ) ||
                    normalizedTitle.contains(
                        candidateTitle
                    ) {

                    score += 40
                }

                // アーティスト

                if candidateArtist == normalizedArtist {

                    score += 50

                } else if
                    candidateArtist.contains(
                        normalizedArtist
                    ) ||
                    normalizedArtist.contains(
                        candidateArtist
                    ) {

                    score += 20
                }

                // アルバム

                if !normalizedAlbum.isEmpty {

                    if candidateAlbum == normalizedAlbum {

                        score += 30

                    } else if
                        candidateAlbum.contains(
                            normalizedAlbum
                        ) ||
                        normalizedAlbum.contains(
                            candidateAlbum
                        ) {

                        score += 10
                    }
                }

                if score > bestScore {

                    bestScore =
                        score

                    bestResult =
                        candidate
                }
            }

            guard
                let artwork =
                    bestResult?.artworkUrl100
            else {

                return nil
            }

            // iTunes APIの100x100画像を
            // Discord用に高解像度へ変更

            let highResolutionArtwork =
                artwork
                    .replacingOccurrences(
                        of: "100x100bb",
                        with: "600x600bb"
                    )
                    .replacingOccurrences(
                        of: "100x100",
                        with: "600x600"
                    )

            artworkCache[trackID] =
                highResolutionArtwork

            return highResolutionArtwork

        } catch {

            print(
                "Artwork取得失敗:",
                error
            )

            return nil
        }
    }

    // MARK: - 検索文字列正規化

    private func normalize(
        _ text: String
    ) -> String {

        return text
            .folding(
                options: [
                    .diacriticInsensitive,
                    .caseInsensitive,
                    .widthInsensitive
                ],
                locale: .current
            )
            .lowercased()
            .replacingOccurrences(
                of: " ",
                with: ""
            )
            .replacingOccurrences(
                of: "　",
                with: ""
            )
    }

    // MARK: - Presence削除

    func clearPresence() {

        guard isDiscordReady else {
            return
        }

        DiscordBridge.shared().clearPresence()

        DiscordBridge.shared().runCallbacks()
    }

    // MARK: - Background Task

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

    // MARK: - Background Refresh

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

        // Discord SDK callbacksを処理

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

            await performLatestPresenceUpdate(
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

        pendingPresenceTask = Task { [weak self] in

            guard let self else {
                return
            }

            await self.performLatestPresenceUpdate(
                force: true
            )
        }
    }

    // MARK: - iTunes API structs

    private struct ITunesSearchResponse: Decodable {

        let resultCount: Int
        let results: [ITunesTrack]
    }

    private struct ITunesTrack: Decodable {

        let trackName: String?
        let artistName: String?
        let collectionName: String?
        let artworkUrl100: String?
        let trackId: Int64?
    }

    // MARK: - 終了

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
