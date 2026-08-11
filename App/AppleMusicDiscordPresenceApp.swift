import SwiftUI
import UIKit

@main
struct AppleMusicDiscordPresenceApp: App {

    @StateObject
    private var model =
        PresenceViewModel()

    @Environment(\.scenePhase)
    private var scenePhase


    var body: some Scene {

        WindowGroup {

            ContentView(
                model:
                    model
            )
            .task {

                /*
                 Apple Music / Discord側を開始。
                 */
                await model
                    .start()
            }
        }

        /*
         重要。

         アプリが本当にACTIVEになった瞬間に
         位置情報許可を要求する。

         起動途中のinactive状態では
         許可ダイアログを出さない。
         */
        .onChange(
            of:
                scenePhase
        ) {
            oldPhase,
            newPhase in

            guard
                newPhase ==
                .active
            else {

                return
            }


            print(
                "[APP] Scene became ACTIVE"
            )


            BackgroundLocationKeeper
                .shared
                .start()
        }
    }
}
