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

    private let player =
        MPMusicPlayerController.systemMusicPlayer

    private var observers: [NSObjectProtocol] = []

    private var callbackTimer: Timer?

    private var lastArtworkStoreID: String?

    private var cachedArtworkURL: String?

    func start() async {

        let auth =
            await MPMediaLibrary.requestAuthorization()

        guard auth == .authorized else {
            musicStatus = "Apple Music 権限なし"
            return
        }

        DiscordBridge.shared().onStatusChanged = {
            [weak self] ready, text in

            Task { @MainActor in

                self?.isDiscordReady = ready
                self?.discordStatus = text

                if ready {
                    self?.pushCurrentTrack()
                }
            }
        }

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

        observers.append(
            NotificationCenter.default.addObserver(
                forName:
                    UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in

                Task { @MainActor in
                    self?.syncFromMusic()
                }
            }
        )

        callbackTimer =
            Timer.scheduledTimer(
                withTimeInterval: 0.20,
                repeats: true
            ) { _ in

                DiscordBridge.shared().runCallbacks()
            }

        syncFromMusic()
    }

    private func observe(
        _ name: Notification.Name,
        action: @escaping @MainActor () -> Void
    ) {

        observers.append(
            NotificationCenter.default.addObserver(
                forName: name,
                object: player,
                queue: .main
            ) { _ in

                Task { @MainActor in
                    action()
                }
            }
        )
    }

    func connectDiscord() {

        let appID =
            GeneratedConfig.discordApplicationID

        guard appID != 0 else {

            discordStatus =
                "DISCORD_APP_ID が未設定"

            return
        }

        DiscordBridge.shared().start(
            withApplicationID: appID
        )
    }

    func syncFromMusic() {

        switch player.playbackState {

        case .playing:
            musicStatus = "再生中"

        case .paused:
            musicStatus = "一時停止"

        case .stopped:
            musicStatus = "停止"

        default:
            musicStatus = "その他"
        }

        guard let item = player.nowPlayingItem else {

            trackTitle = "再生中の曲なし"
            artist = ""

            lastArtworkStoreID = nil
            cachedArtworkURL = nil

            if autoUpdate && isDiscordReady {
                clearPresence()
            }

            return
        }

        trackTitle =
            item.title ?? "Unknown Track"

        artist =
            item.artist ?? "Unknown Artist"

        if autoUpdate && isDiscordReady {
            pushCurrentTrack()
        }
    }

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
            Int64(now - elapsed)

        let end =
            duration > 0
            ? Int64(
                now - elapsed + duration
            )
            : 0

        let storeID =
            item.playbackStoreID

        let songURL: String?

        if storeID.isEmpty {
            songURL = nil
        } else {
            songURL =
                "https://music.apple.com/song/\(storeID)"
        }

        /*
         まず現在キャッシュしている
         ジャケットURLでPresenceを送る。
        */

        if storeID == lastArtworkStoreID,
           let artworkURL = cachedArtworkURL {

            sendPresence(
                title: title,
                artist: artistName,
                album: album,
                songURL: songURL,
                artworkURL: artworkURL,
                start: start,
                end: end
            )

            return
        }

        /*
         曲が変わったのでキャッシュをリセット。
        */

        lastArtworkStoreID = storeID
        cachedArtworkURL = nil

        /*
         とりあえず画像なしでPresenceを送信。
         その後ジャケット取得が成功したら更新する。
        */

        sendPresence(
            title: title,
            artist: artistName,
            album: album,
            songURL: songURL,
            artworkURL: nil,
            start: start,
            end: end
        )

        guard !storeID.isEmpty else {
            return
        }

        Task {
            await fetchArtworkAndUpdate(
                storeID: storeID,
                title: title,
                artist: artistName,
                album: album,
                songURL: songURL,
                start: start,
                end: end
            )
        }
    }

    private func sendPresence(
        title: String,
        artist: String,
        album: String,
        songURL: String?,
        artworkURL: String?,
        start: Int64,
        end: Int64
    ) {

        DiscordBridge.shared().updatePresence(
            title: title,
            artist: artist,
            album: album,
            songURL: songURL,
            artworkURL: artworkURL,
            startTimestamp: start,
            endTimestamp: end
        )
    }

    private func fetchArtworkAndUpdate(
        storeID: String,
        title: String,
        artist: String,
        album: String,
        songURL: String?,
        start: Int64,
        end: Int64
    ) async {

        guard let url = URL(
            string:
                "https://itunes.apple.com/lookup?id=\(storeID)&country=JP"
        ) else {
            return
        }

        do {

            let (data, _) =
                try await URLSession.shared.data(
                    from: url
                )

            let response =
                try JSONDecoder().decode(
                    ITunesLookupResponse.self,
                    from: data
                )

            guard
                let artwork =
                    response.results.first?.artworkUrl100
            else {
                return
            }

            /*
             Appleの100x100 URLを
             高解像度に変更。
            */

            let highResolution =
                artwork.replacingOccurrences(
                    of: "100x100",
                    with: "600x600"
                )

            /*
             取得中に別の曲へ変わっていたら
             古いジャケットを送らない。
            */

            guard
                player.nowPlayingItem?.playbackStoreID
                    == storeID
            else {
                return
            }

            cachedArtworkURL =
                highResolution

            lastArtworkStoreID =
                storeID

            sendPresence(
                title: title,
                artist: artist,
                album: album,
                songURL: songURL,
                artworkURL: highResolution,
                start: start,
                end: end
            )

        } catch {

            print(
                "Artwork取得失敗:",
                error
            )
        }
    }

    func clearPresence() {

        DiscordBridge.shared()
            .clearPresence()
    }

    deinit {

        player.endGeneratingPlaybackNotifications()

        callbackTimer?.invalidate()

        for observer in observers {
            NotificationCenter.default
                .removeObserver(observer)
        }
    }
}

private struct ITunesLookupResponse:
    Decodable {

    let results:
        [ITunesLookupResult]
}

private struct ITunesLookupResult:
    Decodable {

    let artworkUrl100:
        String?
}
