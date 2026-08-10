import Foundation
import MediaPlayer
import UIKit


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


    // MARK: - Lifecycle

    private var hasStarted =
        false

    private var observers:
        [NSObjectProtocol] = []


    // MARK: - Timers

    private var callbackTimer:
        Timer?

    private var healthTimer:
        Timer?


    // MARK: - Presence

    private var trackUpdateTask:
        Task<Void, Never>?

    private var generation:
        UInt64 = 0

    private var lastObservedTrackIdentity =
        ""

    /*
     ここはDiscordから本当に
     UpdateRichPresence成功callbackを
     受けた時だけ変更する。
     */
    private var lastSuccessfullySentTrackIdentity =
        ""


    // MARK: - Artwork cache

    private var artworkByTrack:
        [String: String] = [:]

    private var artworkByAlbum:
        [String: String] = [:]

    private var lastArtworkURL:
        String?

    private var lastArtworkAlbumKey:
        String?


    // MARK: - Store cache

    private var storeResultByTrack:
        [String: StoreTrack] = [:]


    // MARK: - Reconnect

    private var lastReconnectAttempt =
        Date.distantPast

    private let reconnectCooldown:
        TimeInterval = 4.0


    // MARK: - Background

    private var backgroundTask:
        UIBackgroundTaskIdentifier =
            .invalid


    // MARK: - Debounce

    private let trackDebounceNanoseconds:
        UInt64 =
            450_000_000


    // MARK: =====================================
    // MARK: Start
    // MARK: =====================================

    func start() async {

        guard !hasStarted else {
            return
        }

        hasStarted =
            true


        let authorization =
            await MPMediaLibrary
                .requestAuthorization()


        guard authorization ==
                .authorized
        else {

            musicStatus =
                "Apple Music 権限なし"

            return
        }


        configureDiscordCallbacks()


        player
            .beginGeneratingPlaybackNotifications()


        // 曲変更通知

        observe(
            .MPMusicPlayerControllerNowPlayingItemDidChange
        ) { [weak self] in

            guard let self else {
                return
            }

            self
                .handlePossibleTrackChange(
                    immediate: false
                )
        }


        // 再生状態変更通知

        observe(
            .MPMusicPlayerControllerPlaybackStateDidChange
        ) { [weak self] in

            guard let self else {
                return
            }

            self
                .handlePossibleTrackChange(
                    immediate: true
                )
        }


        // Active

        let activeObserver =
            NotificationCenter.default
                .addObserver(
                    forName:
                        UIApplication
                            .didBecomeActiveNotification,
                    object:
                        nil,
                    queue:
                        .main
                ) { [weak self] _ in

                    Task { @MainActor in

                        guard let self else {
                            return
                        }

                        self
                            .startShortBackgroundWindow()

                        DiscordBridge
                            .shared()
                            .reconnectIfNeeded()

                        /*
                         アプリを開いた時は
                         必ず現在曲を再確認。
                         */
                        self
                            .handlePossibleTrackChange(
                                immediate: true,
                                forceSend: true
                            )
                    }
                }


        observers.append(
            activeObserver
        )


        // Foreground

        let foregroundObserver =
            NotificationCenter.default
                .addObserver(
                    forName:
                        UIApplication
                            .willEnterForegroundNotification,
                    object:
                        nil,
                    queue:
                        .main
                ) { [weak self] _ in

                    Task { @MainActor in

                        guard let self else {
                            return
                        }

                        DiscordBridge
                            .shared()
                            .reconnectIfNeeded()

                        self
                            .handlePossibleTrackChange(
                                immediate: true
                            )
                    }
                }


        observers.append(
            foregroundObserver
        )


        // Background

        let backgroundObserver =
            NotificationCenter.default
                .addObserver(
                    forName:
                        UIApplication
                            .didEnterBackgroundNotification,
                    object:
                        nil,
                    queue:
                        .main
                ) { [weak self] _ in

                    Task { @MainActor in

                        guard let self else {
                            return
                        }

                        self
                            .startShortBackgroundWindow()

                        self
                            .handlePossibleTrackChange(
                                immediate: true
                            )
                    }
                }


        observers.append(
            backgroundObserver
        )


        startCallbackTimer()

        startHealthTimer()


        /*
         現在曲をまず読み込む。
         */
        syncFromMusic(
            forcePresenceUpdate: false
        )


        /*
         Discord自動接続。
         */
        let appID =
            GeneratedConfig
                .discordApplicationID


        if appID != 0 {

            discordStatus =
                "Discord 自動接続中"

            DiscordBridge
                .shared()
                .start(
                    withApplicationID:
                        appID
                )
        }
    }


    // MARK: =====================================
    // MARK: Discord callbacks
    // MARK: =====================================

    private func configureDiscordCallbacks() {

        let bridge =
            DiscordBridge.shared()


        // MARK: Connection state

        bridge.onStatusChanged = {
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


                if ready {

                    self.lastReconnectAttempt =
                        Date.distantPast


                    /*
                     切断状態からReadyへ復帰。

                     Discord側Presenceが消えている
                     可能性があるので再送。
                     */
                    if !wasReady {

                        self
                            .lastSuccessfullySentTrackIdentity =
                            ""
                    }


                    self
                        .handlePossibleTrackChange(
                            immediate: true,
                            forceSend: true
                        )
                }
            }
        }


        // MARK: Presence result

        bridge.onPresenceResult = {
            [weak self]
            presenceID,
            success in

            Task { @MainActor in

                guard let self else {
                    return
                }


                /*
                 失敗なら絶対に
                 「送信成功済み」にしない。
                 */
                guard success else {

                    print(
                        "Presence送信失敗:",
                        presenceID
                    )

                    return
                }


                /*
                 成功callbackが返ってきた時点で
                 既に次の曲へ変わっている可能性がある。

                 古い曲の成功を
                 新しい曲の成功として扱わない。
                 */
                guard let currentItem =
                    self.player.nowPlayingItem
                else {

                    return
                }


                guard
                    self.player.playbackState ==
                    .playing
                else {

                    return
                }


                let currentIdentity =
                    self.trackIdentity(
                        for:
                            currentItem
                    )


                guard
                    currentIdentity ==
                    presenceID
                else {

                    return
                }


                /*
                 ここで初めて
                 「この曲はDiscordへ送れた」
                 と記録する。
                 */
                self
                    .lastSuccessfullySentTrackIdentity =
                    presenceID


                print(
                    "Presence送信成功:",
                    presenceID
                )
            }
        }
    }


    // MARK: =====================================
    // MARK: Manual Discord connect
    // MARK: =====================================

    func connectDiscord() {

        let appID =
            GeneratedConfig
                .discordApplicationID


        guard appID != 0 else {

            discordStatus =
                "DISCORD_APP_ID が未設定"

            return
        }


        discordStatus =
            "Discord 接続中"


        startShortBackgroundWindow()


        DiscordBridge
            .shared()
            .start(
                withApplicationID:
                    appID
            )
    }


    // MARK: =====================================
    // MARK: Discord callback timer
    // MARK: =====================================

    private func startCallbackTimer() {

        callbackTimer?
            .invalidate()


        callbackTimer =
            Timer.scheduledTimer(
                withTimeInterval:
                    0.20,
                repeats:
                    true
            ) { _ in

                DiscordBridge
                    .shared()
                    .runCallbacks()
            }


        if let callbackTimer {

            RunLoop.main.add(
                callbackTimer,
                forMode:
                    .common
            )
        }
    }


    // MARK: =====================================
    // MARK: Health monitor
    // MARK: =====================================

    private func startHealthTimer() {

        healthTimer?
            .invalidate()


        /*
         曲変更Notificationが何らかの理由で
         飛ばなかった場合でも、
         2秒ごとに現在曲を直接確認する。
         */
        healthTimer =
            Timer.scheduledTimer(
                withTimeInterval:
                    2.0,
                repeats:
                    true
            ) { [weak self] _ in

                Task { @MainActor in

                    guard let self else {
                        return
                    }


                    DiscordBridge
                        .shared()
                        .runCallbacks()


                    self
                        .reconnectDiscordIfNeeded()


                    self
                        .handlePossibleTrackChange(
                            immediate: false
                        )
                }
            }


        if let healthTimer {

            RunLoop.main.add(
                healthTimer,
                forMode:
                    .common
            )
        }
    }


    // MARK: =====================================
    // MARK: Reconnect
    // MARK: =====================================

    private func reconnectDiscordIfNeeded() {

        guard !isDiscordReady else {
            return
        }


        let now =
            Date()


        guard
            now.timeIntervalSince(
                lastReconnectAttempt
            )
            >=
            reconnectCooldown
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
        _ name:
            Notification.Name,
        action:
            @escaping
            @MainActor () -> Void
    ) {

        let observer =
            NotificationCenter.default
                .addObserver(
                    forName:
                        name,
                    object:
                        player,
                    queue:
                        .main
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
        forcePresenceUpdate:
            Bool = false
    ) {

        updatePlaybackStateText()


        handlePossibleTrackChange(
            immediate:
                forcePresenceUpdate,
            forceSend:
                forcePresenceUpdate
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
    // MARK: Detect track change
    // MARK: =====================================

    private func handlePossibleTrackChange(
        immediate:
            Bool,
        forceSend:
            Bool = false
    ) {

        updatePlaybackStateText()


        guard let item =
            player.nowPlayingItem
        else {

            trackUpdateTask?
                .cancel()


            generation &+=
                1


            lastObservedTrackIdentity =
                ""


            lastSuccessfullySentTrackIdentity =
                ""


            trackTitle =
                "再生中の曲なし"


            artist =
                ""


            if autoUpdate ||
                forceSend {

                clearPresence()
            }


            return
        }


        let identity =
            trackIdentity(
                for:
                    item
            )


        let changed =
            identity !=
            lastObservedTrackIdentity


        if changed {

            generation &+=
                1


            lastObservedTrackIdentity =
                identity


            trackTitle =
                item.title
                ??
                "Unknown Track"


            artist =
                item.artist
                ??
                "Unknown Artist"


            /*
             重要。

             曲が変わった時点では
             lastSuccessfullySentTrackIdentityを
             新しい曲へ変更しない。

             Discord成功callbackが来るまで
             前の曲IDのまま。
             */
        }


        guard
            autoUpdate ||
            forceSend
        else {

            return
        }


        /*
         本当にDiscord送信成功済みの
         同じ曲だけスキップする。
         */
        if !changed &&
            !forceSend &&
            identity ==
                lastSuccessfullySentTrackIdentity {

            return
        }


        schedulePresenceUpdate(
            identity:
                identity,
            generation:
                generation,
            immediate:
                immediate ||
                forceSend,
            forceSend:
                forceSend
        )
    }


    // MARK: =====================================
    // MARK: Debounce
    // MARK: =====================================

    private func schedulePresenceUpdate(
        identity:
            String,
        generation currentGeneration:
            UInt64,
        immediate:
            Bool,
        forceSend:
            Bool
    ) {

        trackUpdateTask?
            .cancel()


        trackUpdateTask =
            Task { [weak self] in

                guard let self else {
                    return
                }


                if !immediate {

                    do {
                        try await
                            Task.sleep(
                                nanoseconds:
                                    self
                                        .trackDebounceNanoseconds
                            )
                    } catch {
                        return
                    }
                }


                guard
                    !Task.isCancelled
                else {

                    return
                }


                await self
                    .prepareAndSendPresence(
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
        originalIdentity:
            String,
        originalGeneration:
            UInt64,
        forceSend:
            Bool
    ) async {

        guard
            autoUpdate ||
            forceSend
        else {

            return
        }


        guard let item =
            player.nowPlayingItem
        else {

            clearPresence()

            return
        }


        let currentIdentity =
            trackIdentity(
                for:
                    item
            )


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


        guard
            player.playbackState ==
            .playing
        else {

            clearPresence()

            return
        }


        let title =
            item.title
            ??
            "Unknown Track"


        let artistName =
            item.artist
            ??
            "Unknown Artist"


        let album =
            item.albumTitle
            ??
            ""


        trackTitle =
            title


        artist =
            artistName


        let albumKey =
            makeAlbumKey(
                artist:
                    artistName,
                album:
                    album
            )


        let resolved =
            await
            resolveStoreInformation(
                item:
                    item,
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


        guard
            !Task.isCancelled
        else {

            return
        }


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
                for:
                    latestItem
            )
            ==
            currentIdentity
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


        // MARK: Artwork

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


        if let artworkURL {

            saveArtwork(
                artworkURL,
                identity:
                    currentIdentity,
                albumKey:
                    albumKey
            )
        }


        // MARK: Time

        let duration =
            latestItem
                .playbackDuration


        let elapsed =
            max(
                0,
                player
                    .currentPlaybackTime
            )


        let now =
            Date()
                .timeIntervalSince1970


        let startTimestamp =
            Int64(
                now -
                elapsed
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
            resolved.songURL
            ??
            fallbackSongURL(
                item:
                    latestItem
            )


        // MARK: Discord

        /*
         ここでは「送信成功済み」にしない。

         updatePresenceはあくまで
         「送信依頼した」だけ。

         DiscordBridgeから
         onPresenceResult(..., true)
         が返った時だけ成功扱いになる。
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
                presenceID:
                    currentIdentity,
                startTimestamp:
                    startTimestamp,
                endTimestamp:
                    endTimestamp
            )


        DiscordBridge
            .shared()
            .runCallbacks()


        /*
         以前ここにあった

         if isDiscordReady {
             lastSuccessfullySentTrackIdentity =
                 currentIdentity
         }

         は削除。

         これが今回のバグの本丸。
         */


        startShortBackgroundWindow()
    }


    // MARK: =====================================
    // MARK: Manual refresh
    // MARK: =====================================

    func forceRefresh() {

        generation &+=
            1


        /*
         強制再送したいので
         一旦成功済み扱いを解除。
         */
        lastSuccessfullySentTrackIdentity =
            ""


        handlePossibleTrackChange(
            immediate:
                true,
            forceSend:
                true
        )
    }


    /*
     旧ContentView互換。
     */
    func pushCurrentTrack() {

        forceRefresh()
    }


    // MARK: =====================================
    // MARK: Resolve Store Information
    // MARK: =====================================

    private func resolveStoreInformation(
        item:
            MPMediaItem,
        identity:
            String,
        title:
            String,
        artist:
            String,
        album:
            String,
        albumKey:
            String
    ) async
        -> ResolvedStoreInformation {

        // Store cache

        if let cached =
            storeResultByTrack[
                identity
            ] {

            let artwork =
                largeArtworkURL(
                    from:
                        cached
                            .artworkUrl100
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


            return
                ResolvedStoreInformation(
                    songURL:
                        cached
                            .trackViewUrl,
                    artworkURL:
                        artwork
                )
        }


        // Track artwork cache

        if let cachedArtwork =
            artworkByTrack[
                identity
            ] {

            return
                ResolvedStoreInformation(
                    songURL:
                        fallbackSongURL(
                            item:
                                item
                        ),
                    artworkURL:
                        cachedArtwork
                )
        }


        // Exact Store ID lookup

        let storeID =
            item
                .playbackStoreID


        if !storeID.isEmpty {

            if let result =
                await
                lookupStoreTrack(
                    storeID:
                        storeID
                ) {

                storeResultByTrack[
                    identity
                ] =
                    result


                let artwork =
                    largeArtworkURL(
                        from:
                            result
                                .artworkUrl100
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


                return
                    ResolvedStoreInformation(
                        songURL:
                            result
                                .trackViewUrl
                            ??
                            fallbackSongURL(
                                item:
                                    item
                            ),
                        artworkURL:
                            artwork
                    )
            }
        }


        // Same-album cache

        if let albumArtwork =
            cachedAlbumArtwork(
                albumKey:
                    albumKey
            ) {

            return
                ResolvedStoreInformation(
                    songURL:
                        fallbackSongURL(
                            item:
                                item
                        ),
                    artworkURL:
                        albumArtwork
                )
        }


        // Search fallback

        if let result =
            await
            searchStoreTrack(
                title:
                    title,
                artist:
                    artist,
                album:
                    album
            ) {

            storeResultByTrack[
                identity
            ] =
                result


            let artwork =
                largeArtworkURL(
                    from:
                        result
                            .artworkUrl100
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


            return
                ResolvedStoreInformation(
                    songURL:
                        result
                            .trackViewUrl
                        ??
                        fallbackSongURL(
                            item:
                                item
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


        return
            ResolvedStoreInformation(
                songURL:
                    fallbackSongURL(
                        item:
                            item
                    ),
                artworkURL:
                    cachedAlbumArtwork(
                        albumKey:
                            albumKey
                    )
            )
    }


    // MARK: =====================================
    // MARK: Artwork cache
    // MARK: =====================================

    private func saveArtwork(
        _ artwork:
            String,
        identity:
            String,
        albumKey:
            String
    ) {

        artworkByTrack[
            identity
        ] =
            artwork


        if !albumKey.isEmpty {

            artworkByAlbum[
                albumKey
            ] =
                artwork


            lastArtworkAlbumKey =
                albumKey
        }


        lastArtworkURL =
            artwork
    }


    private func cachedAlbumArtwork(
        albumKey:
            String
    ) -> String? {

        guard
            !albumKey.isEmpty
        else {

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

            return
                lastArtworkURL
        }


        return nil
    }


    // MARK: =====================================
    // MARK: iTunes Lookup
    // MARK: =====================================

    private func lookupStoreTrack(
        storeID:
            String
    ) async
        -> StoreTrack? {

        var components =
            URLComponents(
                string:
                    "https://itunes.apple.com/lookup"
            )


        components?
            .queryItems = [

                URLQueryItem(
                    name:
                        "id",
                    value:
                        storeID
                ),

                URLQueryItem(
                    name:
                        "country",
                    value:
                        "JP"
                ),

                URLQueryItem(
                    name:
                        "entity",
                    value:
                        "song"
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
                    url:
                        url
                )


            request
                .timeoutInterval =
                8


            request
                .cachePolicy =
                .reloadRevalidatingCacheData


            let (
                data,
                response
            ) =
                try await
                URLSession
                    .shared
                    .data(
                        for:
                            request
                    )


            guard let http =
                response
                    as?
                    HTTPURLResponse
            else {

                return nil
            }


            guard
                (200...299)
                    .contains(
                        http
                            .statusCode
                    )
            else {

                return nil
            }


            let decoded =
                try
                JSONDecoder()
                    .decode(
                        StoreResponse.self,
                        from:
                            data
                    )


            if let numericStoreID =
                Int64(
                    storeID
                ) {

                if let exact =
                    decoded
                        .results
                        .first(
                            where: {

                                $0.trackId ==
                                    numericStoreID
                            }
                        ) {

                    return exact
                }
            }


            return
                decoded
                    .results
                    .first(
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
        title:
            String,
        artist:
            String,
        album:
            String
    ) async
        -> StoreTrack? {

        let searchTerm =
            "\(title) \(artist)"


        var components =
            URLComponents(
                string:
                    "https://itunes.apple.com/search"
            )


        components?
            .queryItems = [

                URLQueryItem(
                    name:
                        "term",
                    value:
                        searchTerm
                ),

                URLQueryItem(
                    name:
                        "country",
                    value:
                        "JP"
                ),

                URLQueryItem(
                    name:
                        "media",
                    value:
                        "music"
                ),

                URLQueryItem(
                    name:
                        "entity",
                    value:
                        "song"
                ),

                URLQueryItem(
                    name:
                        "limit",
                    value:
                        "10"
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
                    url:
                        url
                )


            request
                .timeoutInterval =
                8


            let (
                data,
                response
            ) =
                try await
                URLSession
                    .shared
                    .data(
                        for:
                            request
                    )


            guard let http =
                response
                    as?
                    HTTPURLResponse
            else {

                return nil
            }


            guard
                (200...299)
                    .contains(
                        http
                            .statusCode
                    )
            else {

                return nil
            }


            let decoded =
                try
                JSONDecoder()
                    .decode(
                        StoreResponse.self,
                        from:
                            data
                    )


            guard
                !decoded
                    .results
                    .isEmpty
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


            for candidate in
                decoded.results {

                let candidateTitle =
                    normalize(
                        candidate
                            .trackName
                        ??
                        ""
                    )


                let candidateArtist =
                    normalize(
                        candidate
                            .artistName
                        ??
                        ""
                    )


                let candidateAlbum =
                    normalize(
                        candidate
                            .collectionName
                        ??
                        ""
                    )


                var score =
                    0


                if candidateTitle ==
                    normalizedTitle {

                    score +=
                        100

                } else if
                    !normalizedTitle
                        .isEmpty
                    &&
                    (
                        candidateTitle
                            .contains(
                                normalizedTitle
                            )
                        ||
                        normalizedTitle
                            .contains(
                                candidateTitle
                            )
                    ) {

                    score +=
                        40
                }


                if candidateArtist ==
                    normalizedArtist {

                    score +=
                        60

                } else if
                    !normalizedArtist
                        .isEmpty
                    &&
                    (
                        candidateArtist
                            .contains(
                                normalizedArtist
                            )
                        ||
                        normalizedArtist
                            .contains(
                                candidateArtist
                            )
                    ) {

                    score +=
                        20
                }


                if !normalizedAlbum
                    .isEmpty {

                    if candidateAlbum ==
                        normalizedAlbum {

                        score +=
                            40

                    } else if
                        candidateAlbum
                            .contains(
                                normalizedAlbum
                            )
                        ||
                        normalizedAlbum
                            .contains(
                                candidateAlbum
                            ) {

                        score +=
                            15
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


            return
                bestResult

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
        from original:
            String?
    ) -> String? {

        guard var url =
            original,
              !url.isEmpty
        else {

            return nil
        }


        url =
            url
                .replacingOccurrences(
                    of:
                        "100x100bb",
                    with:
                        "600x600bb"
                )


        url =
            url
                .replacingOccurrences(
                    of:
                        "100x100-75",
                    with:
                        "600x600-75"
                )


        url =
            url
                .replacingOccurrences(
                    of:
                        "100x100",
                    with:
                        "600x600"
                )


        if url.hasPrefix(
            "http://"
        ) {

            url =
                "https://"
                +
                String(
                    url.dropFirst(
                        "http://"
                            .count
                    )
                )
        }


        guard let parsed =
            URL(
                string:
                    url
            )
        else {

            return nil
        }


        guard let scheme =
            parsed
                .scheme?
                .lowercased()
        else {

            return nil
        }


        guard
            scheme ==
                "https"
            ||
            scheme ==
                "http"
        else {

            return nil
        }


        guard
            url.count <=
            300
        else {

            return nil
        }


        return url
    }


    // MARK: =====================================
    // MARK: Song URL
    // MARK: =====================================

    private func fallbackSongURL(
        item:
            MPMediaItem
    ) -> String? {

        let storeID =
            item
                .playbackStoreID


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
        for item:
            MPMediaItem
    ) -> String {

        let storeID =
            item
                .playbackStoreID


        if !storeID.isEmpty {

            return
                "store:\(storeID)"
        }


        if item.persistentID != 0 {

            return
                "persistent:\(item.persistentID)"
        }


        let title =
            item.title
            ??
            ""


        let artist =
            item.artist
            ??
            ""


        let album =
            item.albumTitle
            ??
            ""


        let duration =
            Int(
                item
                    .playbackDuration
            )


        return
            [
                title,
                artist,
                album,
                String(
                    duration
                )
            ]
            .joined(
                separator:
                    "|"
            )
    }


    // MARK: =====================================
    // MARK: Album key
    // MARK: =====================================

    private func makeAlbumKey(
        artist:
            String,
        album:
            String
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
            !normalizedAlbum
                .isEmpty
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
        _ value:
            String
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
                        identifier:
                            "ja_JP"
                    )
            )

            .lowercased()

            .trimmingCharacters(
                in:
                    .whitespacesAndNewlines
            )

            .replacingOccurrences(
                of:
                    " ",
                with:
                    ""
            )

            .replacingOccurrences(
                of:
                    "　",
                with:
                    ""
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
    // MARK: Background window
    // MARK: =====================================

    private func startShortBackgroundWindow() {

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

                        self
                            .endBackgroundWindow()
                    }
                }


        let createdTaskID =
            backgroundTask


        Task { [weak self] in

            try? await
                Task.sleep(
                    nanoseconds:
                        8_000_000_000
                )


            guard let self else {
                return
            }


            guard
                self.backgroundTask ==
                createdTaskID
            else {

                return
            }


            self
                .endBackgroundWindow()
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
    // MARK: Background Refresh compatibility
    // MARK: =====================================

    func performBackgroundRefresh() async {

        updatePlaybackStateText()


        startShortBackgroundWindow()


        for _ in 0..<10 {

            DiscordBridge
                .shared()
                .runCallbacks()


            try? await
                Task.sleep(
                    nanoseconds:
                        100_000_000
                )
        }


        DiscordBridge
            .shared()
            .reconnectIfNeeded()


        for _ in 0..<10 {

            DiscordBridge
                .shared()
                .runCallbacks()


            try? await
                Task.sleep(
                    nanoseconds:
                        100_000_000
                )
        }


        generation &+=
            1


        lastSuccessfullySentTrackIdentity =
            ""


        handlePossibleTrackChange(
            immediate:
                true,
            forceSend:
                true
        )


        if let task =
            trackUpdateTask {

            await task.value
        }


        /*
         UpdateRichPresence callbackを
         受け取る時間も少し確保。
         */
        for _ in 0..<20 {

            DiscordBridge
                .shared()
                .runCallbacks()


            try? await
                Task.sleep(
                    nanoseconds:
                        100_000_000
                )
        }
    }
}


// MARK: =========================================
// MARK: iTunes Models
// MARK: =========================================

private struct StoreResponse:
    Decodable {

    let resultCount:
        Int

    let results:
        [StoreTrack]
}


private struct StoreTrack:
    Decodable {

    let wrapperType:
        String?

    let trackId:
        Int64?

    let trackName:
        String?

    let artistName:
        String?

    let collectionName:
        String?

    let artworkUrl100:
        String?

    let trackViewUrl:
        String?
}


private struct ResolvedStoreInformation {

    let songURL:
        String?

    let artworkURL:
        String?
}
