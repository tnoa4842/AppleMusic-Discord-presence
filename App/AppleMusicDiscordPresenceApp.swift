import SwiftUI

@main
struct AppleMusicDiscordPresenceApp: App {

    @StateObject
    private var model =
        PresenceViewModel()


    var body: some Scene {

        WindowGroup {

            ContentView(
                model:
                    model
            )
            .task {

                /*
                 位置情報許可を
                 アプリ起動直後に直接要求。

                 PresenceViewModelの処理順に
                 依存させない。
                 */
                BackgroundLocationKeeper
                    .shared
                    .start()


                /*
                 その後、
                 Apple Music / Discordを開始。
                 */
                await model
                    .start()
            }
        }
    }
}
