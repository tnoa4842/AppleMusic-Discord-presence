import Foundation
import BackgroundTasks
import UIKit

extension Notification.Name {

    static let appleMusicDiscordBackgroundRefresh =
        Notification.Name(
            "AppleMusicDiscordBackgroundRefresh"
        )
}

final class BackgroundRefreshManager {

    static let taskIdentifier =
        "com.example.AppleMusicDiscordPresence.refresh"

    private static var registered = false

    static func register() {

        guard !registered else {
            return
        }

        registered = true

        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskIdentifier,
            using: nil
        ) { task in

            guard let refreshTask =
                    task as? BGAppRefreshTask
            else {

                task.setTaskCompleted(
                    success: false
                )

                return
            }

            handle(
                refreshTask
            )
        }
    }

    static func schedule() {

        let request =
            BGAppRefreshTaskRequest(
                identifier: taskIdentifier
            )

        /*
         これは「5分後に必ず起動」ではない。
         earliestBeginDate は文字通り
         最も早く実行してよい時刻。

         実際の実行タイミングはiOSが決める。
        */

        request.earliestBeginDate =
            Date(
                timeIntervalSinceNow: 5 * 60
            )

        do {

            try BGTaskScheduler.shared.submit(
                request
            )

        } catch {

            print(
                "BGAppRefresh schedule error:",
                error
            )
        }
    }

    private static func handle(
        _ task: BGAppRefreshTask
    ) {

        // 次回分も先に予約
        schedule()

        var completed = false

        task.expirationHandler = {

            guard !completed else {
                return
            }

            completed = true

            task.setTaskCompleted(
                success: false
            )
        }

        DispatchQueue.main.async {

            NotificationCenter.default.post(
                name: .appleMusicDiscordBackgroundRefresh,
                object: nil
            )

            // SDK callback や曲情報同期に
            // 少しだけ処理時間を与える
            DispatchQueue.main.asyncAfter(
                deadline: .now() + 3
            ) {

                guard !completed else {
                    return
                }

                completed = true

                task.setTaskCompleted(
                    success: true
                )
            }
        }
    }
}
