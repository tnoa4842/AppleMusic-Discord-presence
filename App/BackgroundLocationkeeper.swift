import Foundation
import CoreLocation
import UIKit


final class BackgroundLocationKeeper:
    NSObject,
    CLLocationManagerDelegate
{
    static let shared =
        BackgroundLocationKeeper()


    private let manager =
        CLLocationManager()


    /*
     iOS 17以降で
     When In UseのままBackground Locationを
     継続するためのSession。
     */
    private var backgroundActivitySession:
        CLBackgroundActivitySession?


    private var started =
        false


    /*
     Always昇格要求を
     同じ起動中に何度も投げないため。
     */
    private var alwaysUpgradeRequested =
        false


    private override init() {

        super.init()


        manager.delegate =
            self


        /*
         位置そのものが目的ではないので
         GPS最高精度までは要求しない。

         ただし前回の3kmよりは
         更新されやすい100m精度。
         */
        manager.desiredAccuracy =
            kCLLocationAccuracyHundredMeters


        manager.activityType =
            .other


        /*
         iOSによる自動Pauseを防ぐ。
         */
        manager
            .pausesLocationUpdatesAutomatically =
            false


        /*
         Background Location中であることを
         iOS上に表示可能にする。
         */
        manager
            .showsBackgroundLocationIndicator =
            true
    }


    // MARK: =====================================
    // MARK: Start
    // MARK: =====================================

    func start() {

        guard
            CLLocationManager
                .locationServicesEnabled()
        else {

            print(
                "[LocationKeeper] Location Services disabled"
            )

            return
        }


        let status =
            manager.authorizationStatus


        print(
            "[LocationKeeper] start() authorization:",
            status.rawValue
        )


        switch status {

        // MARK: 初回

        case .notDetermined:

            /*
             重要。

             いきなりAlwaysではなく
             まず「このAppの使用中」を要求。

             Apple公式の推奨順序。
             */

            print(
                "[LocationKeeper] Requesting WHEN IN USE"
            )


            manager
                .requestWhenInUseAuthorization()


        // MARK: 使用中許可済み

        case .authorizedWhenInUse:

            /*
             まず位置情報更新を開始。

             この時点でBackground Locationを
             有効にする。
             */

            startLocationUpdates()


            /*
             その後にAlwaysへ昇格要求。

             Alwaysが取れなくても
             Continuous Background Locationは
             When In Useの状態で動作可能。
             */

            requestAlwaysUpgradeIfNeeded()


        // MARK: 常に許可済み

        case .authorizedAlways:

            startLocationUpdates()


        // MARK: 拒否

        case .denied:

            print(
                "[LocationKeeper] Location permission DENIED"
            )


        case .restricted:

            print(
                "[LocationKeeper] Location permission RESTRICTED"
            )


        @unknown default:

            print(
                "[LocationKeeper] Unknown authorization status"
            )
        }
    }


    // MARK: =====================================
    // MARK: Start Location Updates
    // MARK: =====================================

    private func startLocationUpdates() {

        guard !started else {

            /*
             既に開始済みでも
             Sessionが消えていたら作り直す。
             */

            createBackgroundSessionIfNeeded()

            return
        }


        /*
         IPAに本当に
         UIBackgroundModes/locationが
         入っているか実行時チェック。
         */

        let modes =
            Bundle.main
                .object(
                    forInfoDictionaryKey:
                        "UIBackgroundModes"
                )
            as? [String]
            ?? []


        print(
            "[LocationKeeper] UIBackgroundModes:",
            modes
        )


        guard
            modes.contains(
                "location"
            )
        else {

            /*
             location無しで
             allowsBackgroundLocationUpdates = true
             を使うと危険なので止める。
             */

            print(
                "[LocationKeeper] ERROR: UIBackgroundModes/location missing"
            )

            return
        }


        createBackgroundSessionIfNeeded()


        /*
         Continuous Background LocationをON。
         */

        manager
            .allowsBackgroundLocationUpdates =
            true


        manager.desiredAccuracy =
            kCLLocationAccuracyHundredMeters


        manager
            .pausesLocationUpdatesAutomatically =
            false


        manager
            .showsBackgroundLocationIndicator =
            true


        /*
         必ずForegroundで開始する。
         */

        manager
            .startUpdatingLocation()


        started =
            true


        print(
            "[LocationKeeper] ================================="
        )

        print(
            "[LocationKeeper] CONTINUOUS LOCATION STARTED"
        )

        print(
            "[LocationKeeper] authorization:",
            manager.authorizationStatus.rawValue
        )

        print(
            "[LocationKeeper] background enabled:",
            manager.allowsBackgroundLocationUpdates
        )

        print(
            "[LocationKeeper] ================================="
        )
    }


    // MARK: =====================================
    // MARK: Background Activity Session
    // MARK: =====================================

    private func createBackgroundSessionIfNeeded() {

        if #available(
            iOS 17.0,
            *
        ) {

            guard
                backgroundActivitySession ==
                nil
            else {

                return
            }


            /*
             強参照として保持する。

             When In Use状態でも、
             アプリをBackgroundで
             in-useとして扱うためのSession。
             */

            backgroundActivitySession =
                CLBackgroundActivitySession()


            print(
                "[LocationKeeper] CLBackgroundActivitySession CREATED"
            )
        }
    }


    // MARK: =====================================
    // MARK: Request Always
    // MARK: =====================================

    private func requestAlwaysUpgradeIfNeeded() {

        guard
            manager.authorizationStatus ==
            .authorizedWhenInUse
        else {

            return
        }


        guard
            !alwaysUpgradeRequested
        else {

            return
        }


        alwaysUpgradeRequested =
            true


        /*
         まずWhen In Useを取得した後に
         Alwaysへ昇格を要求する。

         Apple公式が要求している順序。
         */

        print(
            "[LocationKeeper] Requesting ALWAYS upgrade"
        )


        manager
            .requestAlwaysAuthorization()
    }


    // MARK: =====================================
    // MARK: Authorization Callback
    // MARK: =====================================

    func locationManagerDidChangeAuthorization(
        _ manager:
            CLLocationManager
    ) {

        let status =
            manager.authorizationStatus


        print(
            "[LocationKeeper] Authorization changed:",
            status.rawValue
        )


        switch status {

        // MARK: 使用中許可

        case .authorizedWhenInUse:

            /*
             まず即座に位置情報更新開始。
             */

            startLocationUpdates()


            /*
             そのあとAlwaysへ昇格。
             */

            requestAlwaysUpgradeIfNeeded()


        // MARK: Always

        case .authorizedAlways:

            print(
                "[LocationKeeper] ALWAYS AUTHORIZED"
            )


            startLocationUpdates()


        // MARK: 未選択

        case .notDetermined:

            /*
             delegate設定直後にも
             呼ばれる場合がある。

             ここでは勝手にダイアログを
             二重表示しない。
             */

            break


        // MARK: 拒否

        case .denied:

            started =
                false


            print(
                "[LocationKeeper] PERMISSION DENIED"
            )


        case .restricted:

            started =
                false


            print(
                "[LocationKeeper] PERMISSION RESTRICTED"
            )


        @unknown default:

            break
        }
    }


    // MARK: =====================================
    // MARK: Location Update
    // MARK: =====================================

    func locationManager(
        _ manager:
            CLLocationManager,
        didUpdateLocations locations:
            [CLLocation]
    ) {

        /*
         座標は一切保存しない。
         サーバー送信もしない。

         今回必要なのは
         Background Locationによる
         実行継続だけ。
         */


        /*
         Discord SDK callbackを
         Location Updateのタイミングでも回す。
         */

        DiscordBridge
            .shared()
            .runCallbacks()


        guard let latest =
            locations.last
        else {

            return
        }


        print(
            "[LocationKeeper] HEARTBEAT",
            Date(),
            "accuracy:",
            latest.horizontalAccuracy,
            "appState:",
            applicationStateText()
        )
    }


    // MARK: =====================================
    // MARK: Failure
    // MARK: =====================================

    func locationManager(
        _ manager:
            CLLocationManager,
        didFailWithError error:
            Error
    ) {

        print(
            "[LocationKeeper] ERROR:",
            error.localizedDescription
        )
    }


    // MARK: =====================================
    // MARK: Pause
    // MARK: =====================================

    func locationManagerDidPauseLocationUpdates(
        _ manager:
            CLLocationManager
    ) {

        print(
            "[LocationKeeper] PAUSED"
        )
    }


    // MARK: =====================================
    // MARK: Resume
    // MARK: =====================================

    func locationManagerDidResumeLocationUpdates(
        _ manager:
            CLLocationManager
    ) {

        print(
            "[LocationKeeper] RESUMED"
        )


        DiscordBridge
            .shared()
            .runCallbacks()
    }


    // MARK: =====================================
    // MARK: App State Debug
    // MARK: =====================================

    private func applicationStateText()
        -> String
    {

        switch
            UIApplication
                .shared
                .applicationState {

        case .active:

            return "ACTIVE"


        case .inactive:

            return "INACTIVE"


        case .background:

            return "BACKGROUND"


        @unknown default:

            return "UNKNOWN"
        }
    }
}
