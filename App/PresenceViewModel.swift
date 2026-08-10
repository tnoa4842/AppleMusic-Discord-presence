import Foundation
import MediaPlayer
import UIKit
import BackgroundTasks

@MainActor
final class PresenceViewModel: ObservableObject {

    // MARK: - UI

    @Published var trackTitle = "未取得"
    @Published var artist = "未取得"
    @Published var musicStatus = "停止"
    @Published var discordStatus = "未接続"
    @Published var isDiscordReady = false
    @Published var autoUpdate = true

    // MARK: - Apple Music

    private let player =
        MPMusicPlayerController.systemMusicPlayer

    // MARK: - Notifications

    private var observers: [NSObjectProtocol] = []

    // MARK: - Timers

    private var callbackTimer: Timer?
    private var healthTimer: Timer?

    // MARK: - Presence update task

    private var trackUpdateTask: Task<Void, Never>?

    // MARK: - Generation

    /*
     高速スキップ時に古いArtwork検索結果が
     新しい曲へ上書きされるのを防ぐ。
     */
    private var generation: UInt64 = 0

    // MARK: - Track state

    private var lastObservedTrackIdentity = ""
    private var lastSuccessfullySentTrackIdentity = ""

    // MARK: - Artwork cache

    /*
     曲ごとのArtwork
     */
    private var artworkByTrack:
        [String: String] = [:]

    /*
     アルバムごとのArtwork

     同じアルバムの曲が連続した際に、
     次の曲のArtwork取得が一瞬失敗しても
     SDKのデフォルト画像へ戻さないために使う。
     */
    private var artworkByAlbum:
        [String: String] = [:]

    /*
     直前に正常取得できたArtwork
     */
    private var lastArtworkURL: String?
    private var lastArtworkAlbumKey: String?

    // MARK: - Store cache

    private var storeResultByTrack:
        [String: StoreTrack] = [:]

    // MARK: - Reconnect

    private var lastReconnectAttempt =
        Date.distantPast

    private let reconnectCooldown:
        TimeInterval = 4.0

    // MARK: - Background task

    private var backgroundTask:
        UIBackgroundTaskIdentifier = .invalid

    // MARK: - Debounce

    /*
     0.45秒以内の連続スキップは最後の曲だけ送る。
     */
    private let trackDebounceNanoseconds:
        UInt64 = 450_000_000

    // MARK: =====================================
    // MARK: Start
    // MARK: =====================================

    func start() async {

        let authorization =
            await MPMediaLibrary.requestAuthorization()

        guard authorization == .authorized else {

            musicStatus =
                "Apple Music 権限なし"

            return
        }

        configureDiscordCallback()

        player.beginGeneratingPlaybackNotifications()

        observe(
            .MPMusicPlayerControllerNowPlayingItemDidChange
        ) { [weak self] in

            guard let self else {
                return
            }

            self.handlePossibleTrackChange(
                immediate: false
            )
        }

        observe(
            .MPMusicPlayerControllerPlaybackStateDidChange
        ) { [weak self] in

            guard let self else {
                return
            }

            self.handlePossibleTrackChange(
                immediate: true
            )
        }

        /*
         アプリがActiveになった時
         */
        let activeObserver =
            NotificationCenter.default.addObserver(
                forName:
                    UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in

                Task { @MainActor in

                    guard let self else {
                        return
                    }

                    self.startShortBackgroundWindow()

                    DiscordBridge
                        .shared()
                        .reconnectIfNeeded()

                    self.handlePossibleTrackChange(
                        immediate: true,
                        forceSend: true
                    )
                }
            }

        observers.append(
            activeObserver
        )

        /*
         バックグラウンドから前景へ戻る直前
         */
        let foregroundObserver =
            NotificationCenter.default.addObserver(
                forName:
                    UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in

                Task { @MainActor in

                    guard let self else {
                        return
                    }

                    DiscordBridge
                        .shared()
                        .reconnectIfNeeded()

                    self.handlePossibleTrackChange(
                        immediate: true
                    )
                }
            }

        observers.append(
            foregroundObserver
        )

        /*
         バックグラウンドへ入った時
         */
        let backgroundObserver =
            NotificationCenter.default.addObserver(
                forName:
                    UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in

                Task { @MainActor in

                    guard let self else {
                        return
                    }

                    self.startShortBackgroundWindow()

                    self.handlePossibleTrackChange(
                        immediate: true
                    )
                }
            }

        observers.append(
            backgroundObserver
        )

        startCallbackTimer()

        startHealthTimer()

        syncFromMusic(
            forcePresenceUpdate: false
        )
    }

    // MARK: =====================================
    // MARK: Discord
    // MARK: =====================================

    private func configureDiscordCallback() {

        DiscordBridge.shared().onStatusChanged = {
            [weak self]
            ready,
            text in

            Task { @MainActor in

                guard let self else {
                    return
                }

                let wasReady =
                    self.isDiscordReady

                self.isDiscordReady =
                    ready

                self.discordStatus =
                    text

                /*
                 Discordが切断状態からReadyへ戻ったら
                 現在曲を必ず再送する。

                 Discord側からPresenceだけ消えた場合にも効く。
                 */
                if ready {

                    self.lastReconnectAttempt =
                        Date.distantPast

                    if !wasReady {

                        self.lastSuccessfullySentTrackIdentity =
                            ""
                    }

                    self.handlePossibleTrackChange(
                        immediate: true,
                        forceSend: true
                    )
                }
            }
        }
    }

    func connectDiscord() {

        let appID =
            GeneratedConfig.discordApplicationID

        guard appID != 0 else {

            discordStatus =
                "DISCORD_APP_ID が未設定"

            return
        }

        discordStatus =
            "接続開始"

        startShortBackgroundWindow()

        DiscordBridge
            .shared()
            .start(
                withApplicationID: appID
            )
    }

    // MARK: =====================================
    // MARK: Discord callback timer
    // MARK: =====================================

    private func startCallbackTimer() {

        callbackTimer?.invalidate()

        callbackTimer =
            Timer.scheduledTimer(
                withTimeInterval: 0.20,
                repeats: true
            ) { _ in

                DiscordBridge
                    .shared()
                    .runCallbacks()
            }

        if let callbackTimer {

            RunLoop.main.add(
                callbackTimer,
                forMode: .common
            )
        }
    }

    // MARK: =====================================
    // MARK: Health monitor
    // MARK: =====================================

    private func startHealthTimer() {

        healthTimer?.invalidate()

        healthTimer =
            Timer.scheduledTimer(
                withTimeInterval: 3.0,
                repeats: true
            ) { [weak self] _ in

                Task { @MainActor in

                    guard let self else {
                        return
                    }

                    /*
                     SDK callbacksの保険
                     */
                    DiscordBridge
                        .shared()
                        .runCallbacks()

                    /*
                     Discordが切れていれば
                     数秒ごとに再接続を試す。
                     */
                    self.reconnectDiscordIfNeeded()

                    /*
                     Apple Music通知を取りこぼした時の保険。
                     */
                    self.handlePossibleTrackChange(
                        immediate: false
                    )
                }
            }

        if let healthTimer {

            RunLoop.main.add(
                healthTimer,
                forMode: .common
            )
        }
    }

    private func reconnectDiscordIfNeeded() {

        guard !isDiscordReady else {
            return
        }

        let now =
            Date()

        guard
            now.timeIntervalSince(
                lastReconnectAttempt
            ) >= reconnectCooldown
        else {

            return
        }

        lastReconnectAttempt =
            now

        DiscordBridge
            .shared()
            .reconnectIfNeeded()
    }

    // MARK: =====================================
    // MARK: Notification helper
    // MARK: =====================================

    private func observe(
        _ name: Notification.Name,
        action:
            @escaping @MainActor () -> Void
    ) {

        let observer =
            NotificationCenter.default.addObserver(
                forName: name,
                object: player,
                queue: .main
            ) { _ in

                Task { @MainActor in
                    action()
                }
            }

        observers.append(
            observer
        )
    }

    // MARK: =====================================
    // MARK: Music sync
    // MARK: =====================================

    func syncFromMusic(
        forcePresenceUpdate: Bool = false
    ) {

        updatePlaybackStateText()

        handlePossibleTrackChange(
            immediate: forcePresenceUpdate,
            forceSend: forcePresenceUpdate
        )
    }

    private func updatePlaybackStateText() {

        switch player.playbackState {

        case .playing:

            musicStatus =
                "再生中"

        case .paused:

            musicStatus =
                "一時停止"

        case .stopped:

            musicStatus =
                "停止"

        case .interrupted:

            musicStatus =
                "中断"

        case .seekingForward:

            musicStatus =
                "早送り"

        case .seekingBackward:

            musicStatus =
                "巻き戻し"

        @unknown default:

            musicStatus =
                "その他"
        }
    }

    // MARK: =====================================
    // MARK: Track change
    // MARK: =====================================

    private func handlePossibleTrackChange(
        immediate: Bool,
        forceSend: Bool = false
    ) {

        updatePlaybackStateText()

        /*
         再生中の項目自体が存在しない
         */
        guard let item =
            player.nowPlayingItem else {

            trackUpdateTask?.cancel()

            generation &+= 1

            lastObservedTrackIdentity =
                ""

            lastSuccessfullySentTrackIdentity =
                ""

            trackTitle =
                "再生中の曲なし"

            artist =
                ""

            /*
             Bridge側のpending Presenceも消すため、
             Discord接続状態に関係なくclearする。

             これをしないと切断中に停止した場合、
             再接続時に古い曲が復活する可能性がある。
             */
            if autoUpdate || forceSend {

                clearPresence()
            }

            return
        }

        let identity =
            trackIdentity(
                for: item
            )

        let changed =
            identity !=
            lastObservedTrackIdentity

        if changed {

            /*
             古いArtwork取得Taskを無効化
             */
            generation &+= 1

            lastObservedTrackIdentity =
                identity

            trackTitle =
                item.title ??
                "Unknown Track"

            artist =
                item.artist ??
                "Unknown Artist"
        }

        /*
         自動更新OFFなら、
         UIだけ更新してPresenceは触らない。

         手動更新(forceSend)だけは通す。
         */
        guard autoUpdate || forceSend else {
            return
        }

        /*
         曲変更なし + 強制更新なし +
         既に送信済みなら何もしない。
         */
        if !changed &&
            !forceSend &&
            identity ==
            lastSuccessfullySentTrackIdentity {

            return
        }

        schedulePresenceUpdate(
            identity: identity,
            generation: generation,
            immediate:
                immediate || forceSend,
            forceSend: forceSend
        )
    }

    // MARK: =====================================
    // MARK: Debounce
    // MARK: =====================================

    private func schedulePresenceUpdate(
        identity: String,
        generation currentGeneration: UInt64,
        immediate: Bool,
        forceSend: Bool
    ) {

        /*
         高速スキップで前のTaskをキャンセル。
         */
        trackUpdateTask?.cancel()

        trackUpdateTask =
            Task { [weak self] in

                guard let self else {
                    return
                }

                if !immediate {

                    do {

                        try await Task.sleep(
                            nanoseconds:
                                self.trackDebounceNanoseconds
                        )

                    } catch {

                        return
                    }
                }

                guard !Task.isCancelled else {
                    return
                }

                await self.prepareAndSendPresence(
                    originalIdentity:
                        identity,
                    originalGeneration:
                        currentGeneration,
                    forceSend:
                        forceSend
                )
            }
    }

    // MARK: =====================================
    // MARK: Prepare Presence
    // MARK: =====================================

    private func prepareAndSendPresence(
        originalIdentity: String,
        originalGeneration: UInt64,
        forceSend: Bool
    ) async {

        guard autoUpdate || forceSend else {
            return
        }

        /*
         まず現在曲をもう一度取得する。

         Notification発生時のMPMediaItemを
         そのまま信用しない。
         */
        guard let item =
            player.nowPlayingItem else {

            clearPresence()
            return
        }

        let currentIdentity =
            trackIdentity(
                for: item
            )

        /*
         曲が既に変わっていれば、
         古いTaskなので終了。
         */
        guard
            currentIdentity ==
            originalIdentity
        else {

            return
        }

        guard
            originalGeneration ==
            generation
        else {

            return
        }

        /*
         再生中でなければPresence削除。

         Bridge側pendingもclearされるので、
         Discord切断中でも古い曲は復活しない。
         */
        guard
            player.playbackState ==
            .playing
        else {

            clearPresence()
            return
        }

        let title =
            item.title ??
            "Unknown Track"

        let artistName =
            item.artist ??
            "Unknown Artist"

        let album =
            item.albumTitle ??
            ""

        trackTitle =
            title

        artist =
            artistName

        let albumKey =
            makeAlbumKey(
                artist: artistName,
                album: album
            )

        // MARK: Store / Artwork解決

        let resolved =
            await resolveStoreInformation(
                item: item,
                identity:
                    currentIdentity,
                title:
                    title,
                artist:
                    artistName,
                album:
                    album,
                albumKey:
                    albumKey
            )

        /*
         HTTP通信中にキャンセルされた場合
         */
        guard !Task.isCancelled else {
            return
        }

        /*
         HTTP通信中に曲が変わった場合
         */
        guard
            originalGeneration ==
            generation
        else {

            return
        }

        guard let latestItem =
            player.nowPlayingItem
        else {

            return
        }

        guard
            trackIdentity(
                for: latestItem
            ) == currentIdentity
        else {

            return
        }

        guard
            player.playbackState ==
            .playing
        else {

            clearPresence()
            return
        }

        // MARK: Artwork fallback

        /*
         Artwork優先順位

         1. この曲から直接取得できた画像
         2. 曲IDキャッシュ
         3. 同じアルバムの画像キャッシュ
         4. 直前の同アルバム画像

         ここが
         「同じアルバムの次曲でSDK画像になる」
         対策。
         */

        var artworkURL =
            resolved.artworkURL

        if artworkURL == nil {

            artworkURL =
                artworkByTrack[
                    currentIdentity
                ]
        }

        if artworkURL == nil,
           !albumKey.isEmpty {

            artworkURL =
                artworkByAlbum[
                    albumKey
                ]
        }

        if artworkURL == nil,
           !albumKey.isEmpty,
           lastArtworkAlbumKey ==
           albumKey {

            artworkURL =
                lastArtworkURL
        }

        /*
         Artwork取得成功時は
         曲キャッシュとアルバムキャッシュ両方へ保存。
         */
        if let artworkURL {

            artworkByTrack[
                currentIdentity
            ] = artworkURL

            if !albumKey.isEmpty {

                artworkByAlbum[
                    albumKey
                ] = artworkURL

                lastArtworkAlbumKey =
                    albumKey
            }

            lastArtworkURL =
                artworkURL
        }

        // MARK: Timestamps

        let duration =
            latestItem.playbackDuration

        let elapsed =
            max(
                0,
                player.currentPlaybackTime
            )

        let now =
            Date()
                .timeIntervalSince1970

        let startTimestamp =
            Int64(
                now - elapsed
            )

        let endTimestamp:
            Int64

        if duration > 0 {

            endTimestamp =
                Int64(
                    now -
                    elapsed +
                    duration
                )

        } else {

            endTimestamp =
                0
        }

        // MARK: Apple Music URL

        let songURL =
            resolved.songURL ??
            fallbackSongURL(
                item: latestItem
            )

        /*
         重要:

         Discordが一瞬切れていても
         updatePresenceを呼ぶ。

         Bridge側で最新Presenceをpendingとして保持し、
         Readyへ戻った時に再送する。
         */
        DiscordBridge
            .shared()
            .updatePresence(
                title:
                    title,
                artist:
                    artistName,
                album:
                    album,
                songURL:
                    songURL,
                artworkURL:
                    artworkURL,
                startTimestamp:
                    startTimestamp,
                endTimestamp:
                    endTimestamp
            )

        DiscordBridge
            .shared()
            .runCallbacks()

        /*
         Ready時のみ送信済み扱い。

         切断中ならBridgeのpendingなので、
         再接続時にもう一度送る。
         */
        if isDiscordReady {

            lastSuccessfullySentTrackIdentity =
                currentIdentity
        }

        startShortBackgroundWindow()
    }

    // MARK: =====================================
    // MARK: Manual refresh
    // MARK: =====================================

    /*
     現在のContentViewから使う用。
     */
    func forceRefresh() {

        generation &+= 1

        lastSuccessfullySentTrackIdentity =
            ""

        handlePossibleTrackChange(
            immediate: true,
            forceSend: true
        )
    }

    /*
     旧ContentViewとの互換用。

     以前 model.pushCurrentTrack()
     を使っていた版でもビルドできる。
     */
    func pushCurrentTrack() {

        forceRefresh()
    }

    // MARK: =====================================
    // MARK: Store information
    // MARK: =====================================

    private func resolveStoreInformation(
        item: MPMediaItem,
        identity: String,
        title: String,
        artist: String,
        album: String,
        albumKey: String
    ) async -> ResolvedStoreInformation {

        /*
         Store検索結果キャッシュ
         */
        if let cached =
            storeResultByTrack[
                identity
            ] {

            let artwork =
                largeArtworkURL(
                    from:
                        cached.artworkUrl100
                )
                ??
                cachedAlbumArtwork(
                    albumKey:
                        albumKey
                )

            if let artwork {

                saveArtwork(
                    artwork,
                    identity:
                        identity,
                    albumKey:
                        albumKey
                )
            }

            return ResolvedStoreInformation(
                songURL:
                    cached.trackViewUrl,
                artworkURL:
                    artwork
            )
        }

        /*
         曲Artworkだけ既にキャッシュされている場合
         */
        if let cachedArtwork =
            artworkByTrack[
                identity
            ] {

            return ResolvedStoreInformation(
                songURL:
                    fallbackSongURL(
                        item: item
                    ),
                artworkURL:
                    cachedArtwork
            )
        }

        /*
         playbackStoreIDが存在するなら
         曲名検索ではなくID Lookupを最優先。

         同名曲・別バージョンへの誤爆を減らす。
         */
        let storeID =
            item.playbackStoreID

        if !storeID.isEmpty {

            if let result =
                await lookupStoreTrack(
                    storeID:
                        storeID
                ) {

                storeResultByTrack[
                    identity
                ] = result

                let artwork =
                    largeArtworkURL(
                        from:
                            result.artworkUrl100
                    )
                    ??
                    cachedAlbumArtwork(
                        albumKey:
                            albumKey
                    )

                if let artwork {

                    saveArtwork(
                        artwork,
                        identity:
                            identity,
                        albumKey:
                            albumKey
                    )
                }

                return ResolvedStoreInformation(
                    songURL:
                        result.trackViewUrl
                        ??
                        fallbackSongURL(
                            item: item
                        ),
                    artworkURL:
                        artwork
                )
            }
        }

        /*
         同じアルバムの画像が既にあるなら、
         検索失敗中でもSDK画像へ落とさず
         そのジャケットを即利用する。
         */
        if let albumArtwork =
            cachedAlbumArtwork(
                albumKey:
                    albumKey
            ) {

            return ResolvedStoreInformation(
                songURL:
                    fallbackSongURL(
                        item: item
                    ),
                artworkURL:
                    albumArtwork
            )
        }

        /*
         Store ID Lookupでも取れなかった場合のみ
         曲名 + artist検索。
         */
        if let result =
            await searchStoreTrack(
                title:
                    title,
                artist:
                    artist,
                album:
                    album
            ) {

            storeResultByTrack[
                identity
            ] = result

            let artwork =
                largeArtworkURL(
                    from:
                        result.artworkUrl100
                )

            if let artwork {

                saveArtwork(
                    artwork,
                    identity:
                        identity,
                    albumKey:
                        albumKey
                )
            }

            return ResolvedStoreInformation(
                songURL:
                    result.trackViewUrl
                    ??
                    fallbackSongURL(
                        item: item
                    ),
                artworkURL:
                    artwork
                    ??
                    cachedAlbumArtwork(
                        albumKey:
                            albumKey
                    )
            )
        }

        /*
         最終fallback
         */
        return ResolvedStoreInformation(
            songURL:
                fallbackSongURL(
                    item: item
                ),
            artworkURL:
                cachedAlbumArtwork(
                    albumKey:
                        albumKey
                )
        )
    }

    // MARK: =====================================
    // MARK: Artwork cache helpers
    // MARK: =====================================

    private func saveArtwork(
        _ artwork: String,
        identity: String,
        albumKey: String
    ) {

        artworkByTrack[
            identity
        ] = artwork

        if !albumKey.isEmpty {

            artworkByAlbum[
                albumKey
            ] = artwork

            lastArtworkAlbumKey =
                albumKey
        }

        lastArtworkURL =
            artwork
    }

    private func cachedAlbumArtwork(
        albumKey: String
    ) -> String? {

        guard !albumKey.isEmpty else {
            return nil
        }

        if let cached =
            artworkByAlbum[
                albumKey
            ] {

            return cached
        }

        if lastArtworkAlbumKey ==
            albumKey {

            return lastArtworkURL
        }

        return nil
    }

    // MARK: =====================================
    // MARK: iTunes Lookup
    // MARK: =====================================

    private func lookupStoreTrack(
        storeID: String
    ) async -> StoreTrack? {

        var components =
            URLComponents(
                string:
                    "https://itunes.apple.com/lookup"
            )

        components?.queryItems = [

            URLQueryItem(
                name: "id",
                value: storeID
            ),

            URLQueryItem(
                name: "country",
                value: "JP"
            ),

            URLQueryItem(
                name: "entity",
                value: "song"
            )
        ]

        guard let url =
            components?.url
        else {

            return nil
        }

        do {

            var request =
                URLRequest(
                    url: url
                )

            request.timeoutInterval =
                8

            request.cachePolicy =
                .reloadRevalidatingCacheData

            let (data, response) =
                try await URLSession
                    .shared
                    .data(
                        for: request
                    )

            guard let http =
                response
                    as? HTTPURLResponse
            else {

                return nil
            }

            guard
                (200...299)
                    .contains(
                        http.statusCode
                    )
            else {

                return nil
            }

            let decoded =
                try JSONDecoder()
                    .decode(
                        StoreResponse.self,
                        from: data
                    )

            /*
             IDが一致するtrackを優先
             */
            if let numericStoreID =
                Int64(storeID) {

                if let exact =
                    decoded.results.first(
                        where: {
                            $0.trackId ==
                            numericStoreID
                        }
                    ) {

                    return exact
                }
            }

            return decoded.results.first(
                where: {
                    $0.wrapperType ==
                    "track"
                }
            )

        } catch {

            print(
                "iTunes Lookup失敗:",
                error
            )

            return nil
        }
    }

    // MARK: =====================================
    // MARK: iTunes Search
    // MARK: =====================================

    private func searchStoreTrack(
        title: String,
        artist: String,
        album: String
    ) async -> StoreTrack? {

        let searchTerm =
            "\(title) \(artist)"

        var components =
            URLComponents(
                string:
                    "https://itunes.apple.com/search"
            )

        components?.queryItems = [

            URLQueryItem(
                name: "term",
                value: searchTerm
            ),

            URLQueryItem(
                name: "country",
                value: "JP"
            ),

            URLQueryItem(
                name: "media",
                value: "music"
            ),

            URLQueryItem(
                name: "entity",
                value: "song"
            ),

            URLQueryItem(
                name: "limit",
                value: "10"
            )
        ]

        guard let url =
            components?.url
        else {

            return nil
        }

        do {

            var request =
                URLRequest(
                    url: url
                )

            request.timeoutInterval =
                8

            let (data, response) =
                try await URLSession
                    .shared
                    .data(
                        for: request
                    )

            guard let http =
                response
                    as? HTTPURLResponse
            else {

                return nil
            }

            guard
                (200...299)
                    .contains(
                        http.statusCode
                    )
            else {

                return nil
            }

            let decoded =
                try JSONDecoder()
                    .decode(
                        StoreResponse.self,
                        from: data
                    )

            guard
                !decoded.results.isEmpty
            else {

                return nil
            }

            let normalizedTitle =
                normalize(
                    title
                )

            let normalizedArtist =
                normalize(
                    artist
                )

            let normalizedAlbum =
                normalize(
                    album
                )

            var bestResult:
                StoreTrack?

            var bestScore =
                Int.min

            /*
             候補のタイトル/Artist/Albumを採点する。
             */
            for candidate in
                decoded.results {

                let candidateTitle =
                    normalize(
                        candidate.trackName
                        ?? ""
                    )

                let candidateArtist =
                    normalize(
                        candidate.artistName
                        ?? ""
                    )

                let candidateAlbum =
                    normalize(
                        candidate.collectionName
                        ?? ""
                    )

                var score = 0

                // 曲名

                if candidateTitle ==
                    normalizedTitle {

                    score += 100

                } else if
                    !normalizedTitle.isEmpty &&
                    (
                        candidateTitle.contains(
                            normalizedTitle
                        )
                        ||
                        normalizedTitle.contains(
                            candidateTitle
                        )
                    ) {

                    score += 40
                }

                // Artist

                if candidateArtist ==
                    normalizedArtist {

                    score += 60

                } else if
                    !normalizedArtist.isEmpty &&
                    (
                        candidateArtist.contains(
                            normalizedArtist
                        )
                        ||
                        normalizedArtist.contains(
                            candidateArtist
                        )
                    ) {

                    score += 20
                }

                // Album

                if !normalizedAlbum.isEmpty {

                    if candidateAlbum ==
                        normalizedAlbum {

                        score += 40

                    } else if
                        candidateAlbum.contains(
                            normalizedAlbum
                        )
                        ||
                        normalizedAlbum.contains(
                            candidateAlbum
                        ) {

                        score += 15
                    }
                }

                if score >
                    bestScore {

                    bestScore =
                        score

                    bestResult =
                        candidate
                }
            }

            return bestResult

        } catch {

            print(
                "iTunes Search失敗:",
                error
            )

            return nil
        }
    }

    // MARK: =====================================
    // MARK: Artwork URL
    // MARK: =====================================

    private func largeArtworkURL(
        from original: String?
    ) -> String? {

        guard var url =
            original,
              !url.isEmpty
        else {

            return nil
        }

        /*
         Appleの100x100 Artworkを
         600x600へ変更。
         */
        url =
            url.replacingOccurrences(
                of: "100x100bb",
                with: "600x600bb"
            )

        url =
            url.replacingOccurrences(
                of: "100x100-75",
                with: "600x600-75"
            )

        url =
            url.replacingOccurrences(
                of: "100x100",
                with: "600x600"
            )

        /*
         念のためHTTPS化
         */
        if url.hasPrefix(
            "http://"
        ) {

            url =
                "https://" +
                String(
                    url.dropFirst(
                        "http://".count
                    )
                )
        }

        guard let parsed =
            URL(
                string: url
            )
        else {

            return nil
        }

        guard let scheme =
            parsed.scheme?
                .lowercased()
        else {

            return nil
        }

        guard
            scheme == "https"
            ||
            scheme == "http"
        else {

            return nil
        }

        /*
         Discord asset URLの異常値を避ける。
         */
        guard
            url.count <= 300
        else {

            return nil
        }

        return url
    }

    // MARK: =====================================
    // MARK: Apple Music URL
    // MARK: =====================================

    private func fallbackSongURL(
        item: MPMediaItem
    ) -> String? {

        let storeID =
            item.playbackStoreID

        guard
            !storeID.isEmpty
        else {

            return nil
        }

        return
            "https://music.apple.com/song/\(storeID)"
    }

    // MARK: =====================================
    // MARK: Track identity
    // MARK: =====================================

    private func trackIdentity(
        for item: MPMediaItem
    ) -> String {

        /*
         Apple Music Store IDが最優先
         */
        let storeID =
            item.playbackStoreID

        if !storeID.isEmpty {

            return
                "store:\(storeID)"
        }

        /*
         Store IDがない曲はpersistentID
         */
        if item.persistentID != 0 {

            return
                "persistent:\(item.persistentID)"
        }

        /*
         最後のfallback
         */
        let title =
            item.title
            ?? ""

        let artist =
            item.artist
            ?? ""

        let album =
            item.albumTitle
            ?? ""

        let duration =
            Int(
                item.playbackDuration
            )

        return [
            title,
            artist,
            album,
            String(duration)
        ]
        .joined(
            separator: "|"
        )
    }

    // MARK: =====================================
    // MARK: Album key
    // MARK: =====================================

    private func makeAlbumKey(
        artist: String,
        album: String
    ) -> String {

        let normalizedArtist =
            normalize(
                artist
            )

        let normalizedAlbum =
            normalize(
                album
            )

        guard
            !normalizedAlbum.isEmpty
        else {

            return ""
        }

        return
            "\(normalizedArtist)|\(normalizedAlbum)"
    }

    // MARK: =====================================
    // MARK: Normalize
    // MARK: =====================================

    private func normalize(
        _ value: String
    ) -> String {

        value
            .folding(
                options: [
                    .caseInsensitive,
                    .diacriticInsensitive,
                    .widthInsensitive
                ],
                locale:
                    Locale(
                        identifier: "ja_JP"
                    )
            )
            .lowercased()
            .trimmingCharacters(
                in:
                    .whitespacesAndNewlines
            )
            .replacingOccurrences(
                of: " ",
                with: ""
            )
            .replacingOccurrences(
                of: "　",
                with: ""
            )
    }

    // MARK: =====================================
    // MARK: Clear Presence
    // MARK: =====================================

    func clearPresence() {

        lastSuccessfullySentTrackIdentity =
            ""

        DiscordBridge
            .shared()
            .clearPresence()

        DiscordBridge
            .shared()
            .runCallbacks()
    }

    // MARK: =====================================
    // MARK: Background execution window
    // MARK: =====================================

    private func startShortBackgroundWindow() {

        /*
         既にBackground Taskがあるなら
         二重作成しない。
         */
        guard
            backgroundTask ==
            .invalid
        else {

            return
        }

        backgroundTask =
            UIApplication
                .shared
                .beginBackgroundTask(
                    withName:
                        "AppleMusicDiscordPresence"
                ) { [weak self] in

                    Task { @MainActor in

                        guard let self else {
                            return
                        }

                        self.endBackgroundWindow()
                    }
                }

        let createdTaskID =
            backgroundTask

        /*
         beginBackgroundTaskは常駐用ではないので、
         Artwork取得 + Discord送信を終えるための
         短時間だけ使用する。
         */
        Task { [weak self] in

            try? await Task.sleep(
                nanoseconds:
                    8_000_000_000
            )

            guard let self else {
                return
            }

            /*
             古い終了Taskが
             新しいBackground Taskを誤って
             終了させないようID確認。
             */
            guard
                self.backgroundTask ==
                createdTaskID
            else {

                return
            }

            self.endBackgroundWindow()
        }
    }

    private func endBackgroundWindow() {

        guard
            backgroundTask !=
            .invalid
        else {

            return
        }

        let taskID =
            backgroundTask

        backgroundTask =
            .invalid

        UIApplication
            .shared
            .endBackgroundTask(
                taskID
            )
    }

    // MARK: =====================================
    // MARK: Background Refresh
    // MARK: =====================================

    /*
     既存のBackgroundRefreshManager.swiftとの
     互換性を維持するため残す。
     */
    func performBackgroundRefresh() async {

        updatePlaybackStateText()

        startShortBackgroundWindow()

        /*
         Discord callbacksを回す。
         */
        for _ in 0..<10 {

            DiscordBridge
                .shared()
                .runCallbacks()

            try? await Task.sleep(
                nanoseconds:
                    100_000_000
            )
        }

        /*
         Discordが切れている場合は
         再接続処理を促す。
         */
        DiscordBridge
            .shared()
            .reconnectIfNeeded()

        for _ in 0..<10 {

            DiscordBridge
                .shared()
                .runCallbacks()

            try? await Task.sleep(
                nanoseconds:
                    100_000_000
            )
        }

        /*
         現在曲を再確認して送信。
         */
        generation &+= 1

        lastSuccessfullySentTrackIdentity =
            ""

        handlePossibleTrackChange(
            immediate: true,
            forceSend: true
        )

        /*
         Artwork取得Taskが存在するなら
         少し待つ。
         */
        if let task =
            trackUpdateTask {

            await task.value
        }

        DiscordBridge
            .shared()
            .runCallbacks()
    }
}

// MARK: =========================================
// MARK: iTunes API Models
// MARK: =========================================

private struct StoreResponse:
    Decodable {

    let resultCount: Int
    let results: [StoreTrack]
}

private struct StoreTrack:
    Decodable {

    let wrapperType: String?
    let trackId: Int64?
    let trackName: String?
    let artistName: String?
    let collectionName: String?
    let artworkUrl100: String?
    let trackViewUrl: String?
}

private struct ResolvedStoreInformation {

    let songURL: String?
    let artworkURL: String?
}
