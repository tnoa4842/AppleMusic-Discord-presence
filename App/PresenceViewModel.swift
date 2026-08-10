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


    // MARK: - Player

    private let player =
        MPMusicPlayerController.systemMusicPlayer


    // MARK: - Notifications

    private var observers: [NSObjectProtocol] = []


    // MARK: - Timers

    private var callbackTimer: Timer?
    private var healthTimer: Timer?


    // MARK: - Tasks

    private var trackUpdateTask: Task<Void, Never>?


    // MARK: - Update generation

    /*
     曲を連続スキップしたとき、

     曲A Artwork検索
     ↓
     曲B
     ↓
     曲C
     ↓
     遅れて曲A検索が返る

     という競合が起きる。

     generation を使い、
     古い検索結果を完全に捨てる。
     */
    private var generation: UInt64 = 0


    // MARK: - Track identity

    private var lastObservedTrackIdentity = ""

    private var lastSuccessfullySentTrackIdentity = ""


    // MARK: - Artwork cache

    /*
     曲IDごとのArtworkキャッシュ。
     */
    private var artworkByTrack:
        [String: String] = [:]


    /*
     アルバムごとのArtworkキャッシュ。

     今回の
     「同じアルバムの次曲でSDK画像になる」
     対策の中心。
     */
    private var artworkByAlbum:
        [String: String] = [:]


    /*
     最後に正常取得できたArtwork。
     */
    private var lastArtworkURL: String?

    private var lastArtworkAlbumKey: String?


    // MARK: - Store cache

    private var storeResultByTrack:
        [String: StoreTrack] = [:]


    // MARK: - Reconnect

    private var lastReconnectAttempt =
        Date.distantPast


    // MARK: - Background task

    private var backgroundTask:
        UIBackgroundTaskIdentifier = .invalid


    // MARK: - Constants

    private let trackDebounceNanoseconds:
        UInt64 = 450_000_000

    private let reconnectCooldown:
        TimeInterval = 4.0


    // MARK: - Start

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

            self?.handlePossibleTrackChange(
                immediate: false
            )
        }


        observe(
            .MPMusicPlayerControllerPlaybackStateDidChange
        ) { [weak self] in

            self?.handlePossibleTrackChange(
                immediate: true
            )
        }


        observers.append(
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
                        immediate: true
                    )
                }
            )
        )


        observers.append(
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
            )
        )


        observers.append(
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
            )
        )


        startCallbackTimer()
        startHealthTimer()


        handlePossibleTrackChange(
            immediate: true
        )
    }


    // MARK: - Discord callback

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
                 Readyへ復帰した瞬間、
                 必ず現在曲を再送する。

                 接続切れ後にPresenceだけ
                 空になる症状への対策。
                 */
                if ready {

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


    // MARK: - Timers

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


                    DiscordBridge
                        .shared()
                        .runCallbacks()


                    self.reconnectDiscordIfNeeded()


                    /*
                     通知が落ちても3秒ごとに
                     現在曲を確認する。

                     連続スキップ時の保険。
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


    // MARK: - Notification helper

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


        observers.append(observer)
    }


    // MARK: - Connect Discord

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


        DiscordBridge
            .shared()
            .start(
                withApplicationID: appID
            )
    }


    // MARK: - Reconnect

    private func reconnectDiscordIfNeeded() {

        guard !isDiscordReady else {
            return
        }


        let now = Date()


        guard now.timeIntervalSince(
            lastReconnectAttempt
        ) >= reconnectCooldown else {
            return
        }


        lastReconnectAttempt =
            now


        DiscordBridge
            .shared()
            .reconnectIfNeeded()
    }


    // MARK: - Public sync

    func syncFromMusic() {

        handlePossibleTrackChange(
            immediate: true
        )
    }


    // MARK: - Track change

    private func handlePossibleTrackChange(
        immediate: Bool,
        forceSend: Bool = false
    ) {

        updatePlaybackStateText()


        guard let item =
            player.nowPlayingItem else {

            trackUpdateTask?.cancel()

            generation &+= 1

            lastObservedTrackIdentity =
                ""

            trackTitle =
                "再生中の曲なし"

            artist =
                ""


            if autoUpdate &&
                isDiscordReady {

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
         曲変更していないうえ、
         forceでもない場合。

         ただしReadyなのに
         Presence送信履歴がないなら送る。
         */
        if !changed &&
            !forceSend &&
            identity ==
                lastSuccessfullySentTrackIdentity {

            return
        }


        schedulePresenceUpdate(
            item: item,
            identity: identity,
            generation: generation,
            immediate: immediate || forceSend
        )
    }


    // MARK: - Playback state

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

        case .seekingForward,
             .seekingBackward:
            musicStatus =
                "シーク中"

        @unknown default:
            musicStatus =
                "その他"
        }
    }


    // MARK: - Schedule

    private func schedulePresenceUpdate(
        item: MPMediaItem,
        identity: String,
        generation currentGeneration: UInt64,
        immediate: Bool
    ) {

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
                    generation:
                        currentGeneration
                )
            }
    }


    // MARK: - Prepare Presence

    private func prepareAndSendPresence(
        originalIdentity: String,
        generation originalGeneration: UInt64
    ) async {

        guard autoUpdate else {
            return
        }


        guard let item =
            player.nowPlayingItem else {
            return
        }


        let currentIdentity =
            trackIdentity(
                for: item
            )


        /*
         スキップ連打で古いTaskに
         なっていたらここで終了。
         */
        guard currentIdentity ==
                originalIdentity else {

            return
        }


        guard originalGeneration ==
                generation else {

            return
        }


        guard player.playbackState ==
                .playing else {

            if isDiscordReady {
                clearPresence()
            }

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


        /*
         Store情報とArtworkを解決。
         */
        let resolved =
            await resolveStoreInformation(
                item: item,
                identity: currentIdentity,
                title: title,
                artist: artistName,
                album: album,
                albumKey: albumKey
            )


        /*
         ネット検索中に曲が変わっていたら
         絶対に古い曲を送らない。
         */
        guard !Task.isCancelled else {
            return
        }


        guard originalGeneration ==
                generation else {
            return
        }


        guard let latestItem =
            player.nowPlayingItem else {
            return
        }


        guard trackIdentity(
            for: latestItem
        ) == currentIdentity else {
            return
        }


        guard player.playbackState ==
                .playing else {
            return
        }


        /*
         Artwork優先順位

         1. 今回の曲IDから取れたArtwork
         2. 同じアルバムのキャッシュ
         3. 同アルバムで直前に成功したArtwork

         これにより同一アルバム連続曲で
         一瞬nilになりSDK画像へ戻るのを防ぐ。
         */
        var artworkURL =
            resolved.artworkURL


        if artworkURL == nil {

            artworkURL =
                artworkByAlbum[
                    albumKey
                ]
        }


        if artworkURL == nil,
           lastArtworkAlbumKey ==
                albumKey {

            artworkURL =
                lastArtworkURL
        }


        /*
         ここで成功Artworkを記憶。
         */
        if let artworkURL {

            artworkByTrack[
                currentIdentity
            ] = artworkURL


            if !albumKey.isEmpty {

                artworkByAlbum[
                    albumKey
                ] = artworkURL
            }


            lastArtworkURL =
                artworkURL

            lastArtworkAlbumKey =
                albumKey
        }


        let duration =
            latestItem.playbackDuration


        let elapsed =
            max(
                0,
                player.currentPlaybackTime
            )


        let now =
            Date().timeIntervalSince1970


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


        /*
         Apple Music URL。

         Store lookupから取れた場合を優先。
         */
        let songURL =
            resolved.songURL ??
            fallbackSongURL(
                item: latestItem
            )


        /*
         Discordが切れていてもBridge側に
         最新Presenceを保存させる。

         そのためreadyでなくても
         updatePresenceは呼ぶ。
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


        /*
         Readyなら送信済み扱い。
         切断中ならBridgeのpending扱いなので
         Ready復帰後に再送される。
         */
        if isDiscordReady {

            lastSuccessfullySentTrackIdentity =
                currentIdentity
        }


        startShortBackgroundWindow()
    }


    // MARK: - Manual push

    /*
     ContentView等から
     model.pushCurrentTrack()
     で呼べる形を維持。
     */
    func pushCurrentTrack() {

        guard let item =
            player.nowPlayingItem else {

            clearPresence()
            return
        }


        let identity =
            trackIdentity(
                for: item
            )


        generation &+= 1

        lastObservedTrackIdentity =
            identity


        schedulePresenceUpdate(
            item: item,
            identity: identity,
            generation: generation,
            immediate: true
        )
    }


    // MARK: - Store resolve

    private func resolveStoreInformation(
        item: MPMediaItem,
        identity: String,
        title: String,
        artist: String,
        album: String,
        albumKey: String
    ) async -> ResolvedStoreInformation {

        /*
         まず曲キャッシュ。
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


            if let artwork {

                artworkByTrack[
                    identity
                ] = artwork


                if !albumKey.isEmpty {

                    artworkByAlbum[
                        albumKey
                    ] = artwork
                }
            }


            return ResolvedStoreInformation(
                songURL:
                    cached.trackViewUrl,

                artworkURL:
                    artwork
            )
        }


        /*
         すでにArtworkだけある場合も
         それを優先。
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
         playbackStoreIDがあるなら
         ID lookupを最優先。

         曲名検索より圧倒的に安全。
         */
        let storeID =
            item.playbackStoreID


        if !storeID.isEmpty {

            if let result =
                await lookupStoreTrack(
                    storeID: storeID
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

                    artworkByTrack[
                        identity
                    ] = artwork


                    if !albumKey.isEmpty {

                        artworkByAlbum[
                            albumKey
                        ] = artwork
                    }
                }


                return ResolvedStoreInformation(
                    songURL:
                        result.trackViewUrl,

                    artworkURL:
                        artwork
                )
            }
        }


        /*
         ID lookupで取れなかった場合。

         同アルバムArtworkがもうあるなら、
         新しく検索する前にそれを使用。

         同じアルバムの次曲では
         ほぼここで確実に拾える。
         */
        if let albumArtwork =
            artworkByAlbum[
                albumKey
            ] {

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
         最後の手段として
         曲名 + アーティスト検索。
         */
        if let searched =
            await searchStoreTrack(
                title: title,
                artist: artist,
                album: album
            ) {

            storeResultByTrack[
                identity
            ] = searched


            let artwork =
                largeArtworkURL(
                    from:
                        searched.artworkUrl100
                )


            if let artwork {

                artworkByTrack[
                    identity
                ] = artwork


                if !albumKey.isEmpty {

                    artworkByAlbum[
                        albumKey
                    ] = artwork
                }
            }


            return ResolvedStoreInformation(
                songURL:
                    searched.trackViewUrl,

                artworkURL:
                    artwork
            )
        }


        /*
         本当に何も取れなかった場合だけ
         同アルバムの直前Artwork。
         */
        if lastArtworkAlbumKey ==
            albumKey {

            return ResolvedStoreInformation(
                songURL:
                    fallbackSongURL(
                        item: item
                    ),

                artworkURL:
                    lastArtworkURL
            )
        }


        return ResolvedStoreInformation(
            songURL:
                fallbackSongURL(
                    item: item
                ),

            artworkURL:
                nil
        )
    }


    // MARK: - Apple lookup

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
            components?.url else {
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
                    as? HTTPURLResponse,

                  (200 ... 299)
                    .contains(
                        http.statusCode
                    ) else {

                return nil
            }


            let decoded =
                try JSONDecoder()
                    .decode(
                        StoreResponse.self,
                        from: data
                    )


            return decoded.results
                .first {
                    $0.wrapperType ==
                        "track"
                }

        } catch {

            return nil
        }
    }


    // MARK: - Apple search

    private func searchStoreTrack(
        title: String,
        artist: String,
        album: String
    ) async -> StoreTrack? {

        let term =
            "\(title) \(artist)"


        var components =
            URLComponents(
                string:
                    "https://itunes.apple.com/search"
            )


        components?.queryItems = [

            URLQueryItem(
                name: "term",
                value: term
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
            components?.url else {
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
                    as? HTTPURLResponse,

                  (200 ... 299)
                    .contains(
                        http.statusCode
                    ) else {

                return nil
            }


            let decoded =
                try JSONDecoder()
                    .decode(
                        StoreResponse.self,
                        from: data
                    )


            /*
             まず曲名 + artist一致を優先。
             */
            if let best =
                decoded.results.first(
                    where: {

                        normalize(
                            $0.trackName ?? ""
                        )
                        ==
                        normalize(title)

                        &&

                        normalize(
                            $0.artistName ?? ""
                        )
                        ==
                        normalize(artist)
                    }
                ) {

                return best
            }


            /*
             曲名一致。
             */
            if let titleMatch =
                decoded.results.first(
                    where: {

                        normalize(
                            $0.trackName ?? ""
                        )
                        ==
                        normalize(title)
                    }
                ) {

                return titleMatch
            }


            /*
             最後に先頭。
             */
            return decoded.results.first

        } catch {

            return nil
        }
    }


    // MARK: - Artwork

    private func largeArtworkURL(
        from original:
            String?
    ) -> String? {

        guard var url =
            original,

              !url.isEmpty else {
            return nil
        }


        /*
         iTunes Search APIの
         artworkUrl100を高解像度化。

         Apple CDNはだいたい
         xxx/100x100bb.jpg
         のような形式。
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


        /*
         httpだった場合はhttps化。
         */
        if url.hasPrefix("http://") {

            url =
                "https://" +
                url.dropFirst(
                    "http://".count
                )
        }


        guard let parsed =
            URL(string: url),

              let scheme =
            parsed.scheme?
                .lowercased(),

              scheme == "https" ||
              scheme == "http"
        else {

            return nil
        }


        /*
         DiscordのLargeImage URL制限を
         超える異常URLは送らない。
         */
        guard url.count <= 300 else {
            return nil
        }


        return url
    }


    // MARK: - URLs

    private func fallbackSongURL(
        item: MPMediaItem
    ) -> String? {

        let storeID =
            item.playbackStoreID


        guard !storeID.isEmpty else {
            return nil
        }


        return
            "https://music.apple.com/jp/song/\(storeID)"
    }


    // MARK: - Identity

    private func trackIdentity(
        for item: MPMediaItem
    ) -> String {

        let storeID =
            item.playbackStoreID


        if !storeID.isEmpty {

            return "store:\(storeID)"
        }


        /*
         Store IDが空の曲でも、
         persistentIDがあるなら使用。
         */
        if item.persistentID != 0 {

            return
                "persistent:\(item.persistentID)"
        }


        /*
         最後のfallback。
         */
        let title =
            item.title ?? ""

        let artist =
            item.artist ?? ""

        let album =
            item.albumTitle ?? ""

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


    private func makeAlbumKey(
        artist: String,
        album: String
    ) -> String {

        let normalizedArtist =
            normalize(artist)

        let normalizedAlbum =
            normalize(album)


        guard !normalizedAlbum.isEmpty else {
            return ""
        }


        return
            "\(normalizedArtist)|\(normalizedAlbum)"
    }


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

            .trimmingCharacters(
                in:
                    .whitespacesAndNewlines
            )

            .lowercased()
    }


    // MARK: - Background window

    private func startShortBackgroundWindow() {

        if backgroundTask != .invalid {
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


        /*
         beginBackgroundTaskは
         永久バックグラウンド権ではない。

         曲変更通知直後に
         Artwork検索 + Discord送信が
         完了する時間を少し確保する用途。
         */
        Task { [weak self] in

            try? await Task.sleep(
                nanoseconds:
                    8_000_000_000
            )


            guard !Task.isCancelled else {
                return
            }


            await MainActor.run {

                self?.endBackgroundWindow()
            }
        }
    }


    private func endBackgroundWindow() {

        guard backgroundTask !=
                .invalid else {
            return
        }


        let identifier =
            backgroundTask


        backgroundTask =
            .invalid


        UIApplication
            .shared
            .endBackgroundTask(
                identifier
            )
    }


    // MARK: - Clear

    func clearPresence() {

        lastSuccessfullySentTrackIdentity =
            ""


        DiscordBridge
            .shared()
            .clearPresence()
    }


    // MARK: - Cleanup

    deinit {

        player
            .endGeneratingPlaybackNotifications()


        callbackTimer?
            .invalidate()


        healthTimer?
            .invalidate()


        trackUpdateTask?
            .cancel()


        for observer in observers {

            NotificationCenter
                .default
                .removeObserver(
                    observer
                )
        }
    }
}


// MARK: - Store models

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
