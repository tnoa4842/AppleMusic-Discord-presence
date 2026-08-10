import Foundation
import MediaPlayer
import UIKit


@MainActor
final class PresenceViewModel: ObservableObject {

    @Published var trackTitle =
        "未取得"

    @Published var artist =
        "未取得"

    @Published var musicStatus =
        "停止"

    @Published var discordStatus =
        "未接続"

    @Published var isDiscordReady =
        false

    @Published var autoUpdate =
        true


    private let player =
        MPMusicPlayerController
            .systemMusicPlayer


    private var hasStarted =
        false


    private var observers:
        [NSObjectProtocol] = []


    private var callbackTimer:
        Timer?


    private var healthTimer:
        Timer?


    private var trackUpdateTask:
        Task<Void, Never>?


    private var generation:
        UInt64 = 0


    /*
     現在検出している曲
     */
    private var lastObservedTrackIdentity =
        ""


    /*
     Discordが本当に成功callbackを返した曲
     */
    private var lastSuccessfullySentTrackIdentity =
        ""


    /*
     現在送信処理中の曲。

     同じ曲についてNotificationとTimerが
     重なっても重複送信しない。
     */
    private var currentlySubmittingIdentity =
        ""


    /*
     失敗した曲。

     同一イベント内の無限送信を避けつつ、
     health timerで再試行できるようにする。
     */
    private var lastFailedIdentity =
        ""


    private var lastFailedAt =
        Date.distantPast


    private let failedRetryInterval:
        TimeInterval = 4.0


    private var artworkByTrack:
        [String: String] = [:]


    private var artworkByAlbum:
        [String: String] = [:]


    private var lastArtworkURL:
        String?


    private var lastArtworkAlbumKey:
        String?


    private var storeResultByTrack:
        [String: StoreTrack] = [:]


    private var lastReconnectAttempt =
        Date.distantPast


    /*
     頻繁にReconnectを叩かない。
     */
    private let reconnectCooldown:
        TimeInterval = 8.0


    private var backgroundTask:
        UIBackgroundTaskIdentifier =
            .invalid


    private let trackDebounceNanoseconds:
        UInt64 =
            350_000_000


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


        guard
            authorization ==
            .authorized
        else {

            musicStatus =
                "Apple Music 権限なし"

            return
        }


        configureDiscordCallbacks()


        player
            .beginGeneratingPlaybackNotifications()


        observe(
            .MPMusicPlayerControllerNowPlayingItemDidChange
        ) { [weak self] in

            guard let self else {
                return
            }


            /*
             自然に曲が終わって次曲になった場合も
             ここで拾う。
             */
            self
                .handlePossibleTrackChange(
                    immediate:
                        true
                )
        }


        observe(
            .MPMusicPlayerControllerPlaybackStateDidChange
        ) { [weak self] in

            guard let self else {
                return
            }


            self
                .handlePossibleTrackChange(
                    immediate:
                        true
                )
        }


        let activeObserver =
            NotificationCenter
                .default
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
                         現在曲を必ず読む。

                         ただしforce sendは
                         「未送信の時だけ」。
                         */
                        self
                            .handlePossibleTrackChange(
                                immediate:
                                    true,
                                forceSend:
                                    false
                            )
                    }
                }


        observers.append(
            activeObserver
        )


        let foregroundObserver =
            NotificationCenter
                .default
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
                                immediate:
                                    true
                            )
                    }
                }


        observers.append(
            foregroundObserver
        )


        let backgroundObserver =
            NotificationCenter
                .default
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
                                immediate:
                                    true
                            )
                    }
                }


        observers.append(
            backgroundObserver
        )


        startCallbackTimer()

        startHealthTimer()


        syncFromMusic(
            forcePresenceUpdate:
                false
        )


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


        bridge.onStatusChanged = {
            [weak self]
            ready,
            text in


            Task { @MainActor in

                guard let self else {
                    return
                }


                self.isDiscordReady =
                    ready


                self.discordStatus =
                    text


                if ready {

                    self.lastReconnectAttempt =
                        .distantPast


                    /*
                     ここが重要。

                     前はReady復帰のたびに
                     forceSendしていた。

                     それを削除。

                     DiscordBridge側の
                     pendingPresenceがReady時に
                     1回だけ再送される。
                     */
                    self
                        .handlePossibleTrackChange(
                            immediate:
                                false,
                            forceSend:
                                false
                        )
                }
            }
        }


        bridge.onPresenceResult = {
            [weak self]
            presenceID,
            success in


            Task { @MainActor in

                guard let self else {
                    return
                }


                if self
                    .currentlySubmittingIdentity ==
                    presenceID {

                    self
                        .currentlySubmittingIdentity =
                        ""
                }


                if success {

                    /*
                     この曲がまだ現在曲なら
                     成功済みにする。
                     */
                    guard let item =
                        self.player
                            .nowPlayingItem
                    else {

                        return
                    }


                    let currentIdentity =
                        self.trackIdentity(
                            for:
                                item
                        )


                    guard
                        currentIdentity ==
                        presenceID
                    else {

                        /*
                         既に次曲なら
                         古い成功callbackなので無視。
                         */
                        self
                            .handlePossibleTrackChange(
                                immediate:
                                    true
                            )

                        return
                    }


                    self
                        .lastSuccessfullySentTrackIdentity =
                        presenceID


                    self
                        .lastFailedIdentity =
                        ""


                    return
                }


                /*
                 失敗した場合は成功済みにしない。
                 */
                self
                    .lastFailedIdentity =
                    presenceID


                self
                    .lastFailedAt =
                    Date()


                /*
                 既に次の曲へ変わっていた場合だけ
                 次曲をすぐ確認。
                 */
                if let item =
                    self.player
                        .nowPlayingItem {

                    let currentIdentity =
                        self.trackIdentity(
                            for:
                                item
                        )


                    if currentIdentity !=
                        presenceID {

                        self
                            .handlePossibleTrackChange(
                                immediate:
                                    true
                            )
                    }
                }
            }
        }
    }


    // MARK: =====================================
    // MARK: Manual Connect
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
         Notification取りこぼし対策。

         2秒ごとに現在曲IDだけ確認。

         同じ曲を毎回送信するわけではない。
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
                            immediate:
                                true
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

        guard
            !isDiscordReady
        else {

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


        /*
         Bridge側で
         Reconnecting / Connectingなら
         Connectしない。
         */
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
            NotificationCenter
                .default
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
    // MARK: Music Sync
    // MARK: =====================================


    func syncFromMusic(
        forcePresenceUpdate:
            Bool = false
    ) {

        updatePlaybackStateText()


        handlePossibleTrackChange(
            immediate:
                true,
            forceSend:
                forcePresenceUpdate
        )
    }


    private func updatePlaybackStateText() {

        switch player
            .playbackState {

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
    // MARK: Detect Current Track
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


            currentlySubmittingIdentity =
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

            /*
             曲A → 曲B

             ここで送信状態を
             新しい曲用にリセットする。
             */
            generation &+=
                1


            lastObservedTrackIdentity =
                identity


            currentlySubmittingIdentity =
                ""


            lastFailedIdentity =
                ""


            trackTitle =
                item.title
                ??
                "Unknown Track"


            artist =
                item.artist
                ??
                "Unknown Artist"
        }


        guard
            autoUpdate ||
            forceSend
        else {

            return
        }


        /*
         再生していないならPresence消去。
         */
        guard
            player.playbackState ==
            .playing
        else {

            if !lastSuccessfullySentTrackIdentity
                .isEmpty {

                clearPresence()
            }

            return
        }


        /*
         本当にDiscord成功済みの
         同じ曲なら送らない。
         */
        if !forceSend &&
            identity ==
            lastSuccessfullySentTrackIdentity {

            return
        }


        /*
         現在その曲を送信中なら
         NotificationとTimerが重なっても
         再送しない。
         */
        if !forceSend &&
            identity ==
            currentlySubmittingIdentity {

            return
        }


        /*
         直前に同じ曲の送信が失敗した場合は
         4秒だけ待つ。

         その後health timerが自動再試行する。
         */
        if !forceSend &&
            identity ==
            lastFailedIdentity {

            let elapsed =
                Date()
                    .timeIntervalSince(
                        lastFailedAt
                    )


            if elapsed <
                failedRetryInterval {

                return
            }
        }


        schedulePresenceUpdate(
            identity:
                identity,
            generation:
                generation,
            immediate:
                immediate ||
                changed ||
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
                            currentGeneration
                    )
            }
    }


    // MARK: =====================================
    // MARK: Prepare & Send
    // MARK: =====================================


    private func prepareAndSendPresence(
        originalIdentity:
            String,
        originalGeneration:
            UInt64
    ) async {

        guard autoUpdate else {
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


        /*
         ネットワーク検索中にhealth timerが
         また来ても同曲を送らないため、
         この時点で送信中扱い。
         */
        currentlySubmittingIdentity =
            currentIdentity


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

            if currentlySubmittingIdentity ==
                currentIdentity {

                currentlySubmittingIdentity =
                    ""
            }

            return
        }


        guard
            originalGeneration ==
            generation
        else {

            if currentlySubmittingIdentity ==
                currentIdentity {

                currentlySubmittingIdentity =
                    ""
            }

            return
        }


        guard let latestItem =
            player.nowPlayingItem
        else {

            currentlySubmittingIdentity =
                ""

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

            currentlySubmittingIdentity =
                ""

            handlePossibleTrackChange(
                immediate:
                    true
            )

            return
        }


        guard
            player.playbackState ==
            .playing
        else {

            currentlySubmittingIdentity =
                ""

            clearPresence()

            return
        }


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


        let songURL =
            resolved.songURL
            ??
            fallbackSongURL(
                item:
                    latestItem
            )


        /*
         Discord SDKがReadyでなくても
         Bridgeはpending Presenceとして保持。

         Ready復帰時にBridgeが1回だけ送る。
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


        startShortBackgroundWindow()
    }


    // MARK: =====================================
    // MARK: Manual Refresh
    // MARK: =====================================


    func forceRefresh() {

        generation &+=
            1


        lastSuccessfullySentTrackIdentity =
            ""


        currentlySubmittingIdentity =
            ""


        lastFailedIdentity =
            ""


        handlePossibleTrackChange(
            immediate:
                true,
            forceSend:
                true
        )
    }


    /*
     ContentView旧互換
     */
    func pushCurrentTrack() {

        forceRefresh()
    }


    // MARK: =====================================
    // MARK: Store info
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


            return
                ResolvedStoreInformation(
                    songURL:
                        cached
                            .trackViewUrl,
                    artworkURL:
                        artwork
                )
        }


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

            return lastArtworkURL
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
            components?
                .url
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
                    .first

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
            components?
                .url
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

                let ct =
                    normalize(
                        candidate.trackName
                        ??
                        ""
                    )


                let ca =
                    normalize(
                        candidate.artistName
                        ??
                        ""
                    )


                let cal =
                    normalize(
                        candidate.collectionName
                        ??
                        ""
                    )


                var score =
                    0


                if ct ==
                    normalizedTitle {

                    score +=
                        100

                } else if
                    ct.contains(
                        normalizedTitle
                    )
                    ||
                    normalizedTitle
                        .contains(
                            ct
                        ) {

                    score +=
                        40
                }


                if ca ==
                    normalizedArtist {

                    score +=
                        60

                } else if
                    ca.contains(
                        normalizedArtist
                    )
                    ||
                    normalizedArtist
                        .contains(
                            ca
                        ) {

                    score +=
                        20
                }


                if !normalizedAlbum
                    .isEmpty {

                    if cal ==
                        normalizedAlbum {

                        score +=
                            40
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
                        7
                    )
                )
        }


        guard
            url.count <=
            300
        else {

            return nil
        }


        return url
    }


    private func fallbackSongURL(
        item:
            MPMediaItem
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


    private func trackIdentity(
        for item:
            MPMediaItem
    ) -> String {

        let storeID =
            item.playbackStoreID


        if !storeID.isEmpty {

            return
                "store:\(storeID)"
        }


        if item.persistentID !=
            0 {

            return
                "persistent:\(item.persistentID)"
        }


        return
            [
                item.title ?? "",
                item.artist ?? "",
                item.albumTitle ?? "",
                String(
                    Int(
                        item.playbackDuration
                    )
                )
            ]
            .joined(
                separator:
                    "|"
            )
    }


    private func makeAlbumKey(
        artist:
            String,
        album:
            String
    ) -> String {

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
            "\(normalize(artist))|\(normalizedAlbum)"
    }


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
    // MARK: Clear
    // MARK: =====================================


    func clearPresence() {

        lastSuccessfullySentTrackIdentity =
            ""


        currentlySubmittingIdentity =
            ""


        DiscordBridge
            .shared()
            .clearPresence()


        DiscordBridge
            .shared()
            .runCallbacks()
    }


    // MARK: =====================================
    // MARK: Background
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

                        self?
                            .endBackgroundWindow()
                    }
                }


        let taskID =
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
                backgroundTask ==
                taskID
            else {

                return
            }


            endBackgroundWindow()
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


        DiscordBridge
            .shared()
            .runCallbacks()


        DiscordBridge
            .shared()
            .reconnectIfNeeded()


        /*
         Background refreshが来た時も
         現在曲を確認。

         「1曲目だけで止まる」問題の
         追加保険。
         */
        handlePossibleTrackChange(
            immediate:
                true,
            forceSend:
                false
        )


        if let task =
            trackUpdateTask {

            await task.value
        }


        for _ in 0..<15 {

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
// MARK: Models
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
