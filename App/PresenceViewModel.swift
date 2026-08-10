import Foundation
import MediaPlayer
import UIKit


@MainActor
final class PresenceViewModel: ObservableObject {

    // MARK: =====================================
    // MARK: UI
    // MARK: =====================================

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


    // MARK: =====================================
    // MARK: Apple Music
    // MARK: =====================================

    private let player =
        MPMusicPlayerController
            .systemMusicPlayer


    // MARK: =====================================
    // MARK: Lifecycle
    // MARK: =====================================

    private var hasStarted =
        false


    private var observers:
        [NSObjectProtocol] = []


    // MARK: =====================================
    // MARK: Timers
    // MARK: =====================================

    private var callbackTimer:
        Timer?


    private var healthTimer:
        Timer?


    // MARK: =====================================
    // MARK: Presence
    // MARK: =====================================

    private var trackUpdateTask:
        Task<Void, Never>?


    private var generation:
        UInt64 = 0


    /*
     現在検出している曲。
     */
    private var lastObservedTrackIdentity =
        ""


    /*
     Discordが本当に成功callbackを返した曲。
     */
    private var lastSuccessfullySentTrackIdentity =
        ""


    /*
     現在送信処理中の曲。

     曲変更通知と2秒Timerが重なっても
     同じ曲を何度も送らない。
     */
    private var currentlySubmittingIdentity =
        ""


    /*
     直前に送信失敗した曲。
     */
    private var lastFailedIdentity =
        ""


    private var lastFailedAt =
        Date.distantPast


    private let failedRetryInterval:
        TimeInterval = 4.0


    // MARK: =====================================
    // MARK: Artwork cache
    // MARK: =====================================

    private var artworkByTrack:
        [String: String] = [:]


    private var artworkByAlbum:
        [String: String] = [:]


    private var lastArtworkURL:
        String?


    private var lastArtworkAlbumKey:
        String?


    // MARK: =====================================
    // MARK: Store cache
    // MARK: =====================================

    private var storeResultByTrack:
        [String: StoreTrack] = [:]


    // MARK: =====================================
    // MARK: Reconnect
    // MARK: =====================================

    private var lastReconnectAttempt =
        Date.distantPast


    private let reconnectCooldown:
        TimeInterval = 8.0


    // MARK: =====================================
    // MARK: Background task
    // MARK: =====================================

    private var backgroundTask:
        UIBackgroundTaskIdentifier =
            .invalid


    // MARK: =====================================
    // MARK: Debounce
    // MARK: =====================================

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


        // MARK: Background Location開始

        /*
         ここが今回の追加。

         アプリが前面にいる間に
         Core Locationを開始する。

         その後バックグラウンドへ移動しても
         Continuous Background Locationが
         継続する。
         */

        BackgroundLocationKeeper
            .shared
            .start()


        // MARK: Discord callbacks

        configureDiscordCallbacks()


        // MARK: Apple Music notifications

        player
            .beginGeneratingPlaybackNotifications()


        /*
         曲が変わった時。

         手動スキップでも、
         曲が最後まで終わって次曲になった時でも
         ここが呼ばれる。
         */

        observe(
            .MPMusicPlayerControllerNowPlayingItemDidChange
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


        /*
         再生・停止・一時停止など。
         */

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


        // MARK: App Active

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


                        /*
                         念のため位置情報サービスを確認。
                         既に開始済みなら何もしない。
                         */

                        BackgroundLocationKeeper
                            .shared
                            .start()


                        self
                            .startShortBackgroundWindow()


                        DiscordBridge
                            .shared()
                            .reconnectIfNeeded()


                        /*
                         アプリを開いた時は
                         現在曲を読み直す。

                         Ready復帰のたびに
                         無理矢理Presence送信はしない。
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


        // MARK: Foreground

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


        // MARK: Background

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


                        /*
                         今までの短時間BackgroundTaskも
                         保険として残しておく。
                         */

                        self
                            .startShortBackgroundWindow()


                        self
                            .handlePossibleTrackChange(
                                immediate:
                                    true
                            )


                        DiscordBridge
                            .shared()
                            .runCallbacks()
                    }
                }


        observers.append(
            backgroundObserver
        )


        // MARK: Timers

        startCallbackTimer()

        startHealthTimer()


        // MARK: Initial sync

        syncFromMusic(
            forcePresenceUpdate:
                false
        )


        // MARK: Discord auto connect

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


                self.isDiscordReady =
                    ready


                self.discordStatus =
                    text


                if ready {

                    self.lastReconnectAttempt =
                        Date.distantPast


                    /*
                     Readyへ戻っただけでは
                     強制Presence送信しない。

                     Bridge側のpending Presenceが
                     あればBridgeが送る。
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


        // MARK: Presence result

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


                // MARK: Success

                if success {

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


                    /*
                     callbackが返ってくるまでに
                     既に次曲になっていた場合、
                     古い曲の成功として無視する。
                     */

                    guard
                        currentIdentity ==
                        presenceID
                    else {

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


                    print(
                        "[Presence] SUCCESS:",
                        presenceID
                    )


                    return
                }


                // MARK: Failure

                self
                    .lastFailedIdentity =
                    presenceID


                self
                    .lastFailedAt =
                    Date()


                print(
                    "[Presence] FAILED:",
                    presenceID
                )


                /*
                 失敗している間に
                 次曲へ移っていたら
                 新しい曲をすぐ処理する。
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


        /*
         Discord SDK callbacks。

         Foregroundでは0.2秒ごと。

         Background Locationで
         アプリが生きている間も
         RunLoopが動けばこれが継続する。

         さらにBackgroundLocationKeeper側でも
         location updateのたびに
         runCallbacks()を呼ぶ。
         */

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
         曲変更Notificationを
         万が一取りこぼした場合の保険。

         2秒ごとに現在曲を確認。

         同じ曲ならPresenceは送らない。
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
         Bridge側で現在statusを見る。

         Connecting /
         Reconnecting /
         HttpWait

         ならConnectを重ねない。
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


        // MARK: No current song

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


            lastFailedIdentity =
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


        // MARK: New song

        if changed {

            generation &+=
                1


            lastObservedTrackIdentity =
                identity


            /*
             前の曲の送信処理状態を解除。
             */

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


            print(
                "[Music] NEW TRACK:",
                trackTitle,
                "-",
                artist
            )
        }


        guard
            autoUpdate ||
            forceSend
        else {

            return
        }


        // MARK: Not playing

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


        // MARK: Already successfully sent

        if !forceSend &&
            identity ==
            lastSuccessfullySentTrackIdentity {

            return
        }


        // MARK: Currently sending

        if !forceSend &&
            identity ==
            currentlySubmittingIdentity {

            return
        }


        // MARK: Recent failure cooldown

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


        // MARK: Send

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
         iTunes検索中に2秒Timerが来ても
         重複送信しない。
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


        // MARK: Playback time

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
         BridgeがReadyでなくても
         最新Presenceをpendingとして保持する。
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
     旧ContentView互換。
     */

    func pushCurrentTrack() {

        forceRefresh()
    }


    // MARK: =====================================
    // MARK: Store information
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


        // MARK: Already cached

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


        // MARK: Track artwork cache

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


        // MARK: Store ID lookup

        let storeID =
            item.playbackStoreID


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


        // MARK: Album cache

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


        // MARK: Search fallback

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
                    .first

        } catch {

            print(
                "[iTunes] Lookup失敗:",
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
                "[iTunes] Search失敗:",
                error
            )


            return nil
        }
    }


    // MARK: =====================================
    // MARK: Artwork
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


        guard
            URL(
                string:
                    url
            )
            != nil
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
    // MARK: Track Identity
    // MARK: =====================================

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
                item.title
                ??
                "",

                item.artist
                ??
                "",

                item.albumTitle
                ??
                "",

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


    // MARK: =====================================
    // MARK: Album Key
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
    // MARK: Short Background Task
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
    // MARK: BGAppRefresh compatibility
    // MARK: =====================================

    func performBackgroundRefresh() async {

        updatePlaybackStateText()


        startShortBackgroundWindow()


        DiscordBridge
            .shared()
            .runCallbacks()


        DiscordBridge
            .shared()
            .reconnectIfNeeded()


        /*
         iOSがBGAppRefreshを起こしてくれた場合も
         現在曲を確認。
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


        /*
         Discord callbackを受け取る猶予。
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
