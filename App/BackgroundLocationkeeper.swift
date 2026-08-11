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
     iOS 17以降。

     When In Useでも
     Background Location Sessionを
     明示的に維持する。
     */
    private var backgroundActivitySession:
        CLBackgroundActivitySession?


    private var started =
        false


    private override init() {

        super.init()


        manager.delegate =
            self


        /*
         重要。

         前回の3km精度はやめる。

         Appleの推奨条件に合わせて
         100m以上の精度にする。
         */
        manager.desiredAccuracy =
            kCLLocationAccuracyHundredMeters


        /*
         distanceFilterは設定しない。

         前回入れていた
         kCLDistanceFilterNone も
         今回は明示設定しない。
         */


        manager.activityType =
            .other


        /*
         iOSに自動停止させない。
         */
        manager
            .pausesLocationUpdatesAutomatically =
            false


        /*
         Background Location使用中を
         ユーザーに表示。
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


        print(
            "[LocationKeeper] Authorization:",
            manager.authorizationStatus.rawValue
        )


        switch manager.authorizationStatus {

        case .notDetermined:

            /*
             今回はAlwaysを要求。

             iOS側の仕様により
             最初は「使用中」になる場合もある。
             */

            manager
                .requestAlwaysAuthorization()


        case .authorizedWhenInUse,
             .authorizedAlways:

            startLocationUpdates()


        case .denied,
             .restricted:

            print(
                "[LocationKeeper] Location permission denied"
            )


        @unknown default:

            break
        }
    }


    // MARK: =====================================
    // MARK: Start Updating
    // MARK: =====================================

    private func startLocationUpdates() {

        guard !started else {
            return
        }


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
             allowsBackgroundLocationUpdates = true
             をlocation無しで設定すると
             iOSがアプリを終了させるため、
             ここで止める。
             */

            print(
                "[LocationKeeper] ERROR: location background mode missing"
            )

            return
        }


        // MARK: Background Activity Session

        if #available(
            iOS 17.0,
            *
        ) {

            /*
             強参照を保持。

             When In Useの状態でも
             Background Activity Sessionを
             継続させる。
             */

            if backgroundActivitySession ==
                nil {

                backgroundActivitySession =
                    CLBackgroundActivitySession()


                print(
                    "[LocationKeeper] CLBackgroundActivitySession CREATED"
                )
            }
        }


        // MARK: Background updates

        manager
            .allowsBackgroundLocationUpdates =
            true


        /*
         念のため改めて設定。
         */

        manager.desiredAccuracy =
            kCLLocationAccuracyHundredMeters


        manager
            .pausesLocationUpdatesAutomatically =
            false


        manager
            .showsBackgroundLocationIndicator =
            true


        /*
         重要。

         必ずアプリ前面時にここへ到達させる。
         */

        manager
            .startUpdatingLocation()


        started =
            true


        print(
            "[LocationKeeper] CONTINUOUS LOCATION STARTED"
        )
    }


    // MARK: =====================================
    // MARK: Authorization Changed
    // MARK: =====================================

    func locationManagerDidChangeAuthorization(
        _ manager:
            CLLocationManager
    ) {

        print(
            "[LocationKeeper] Authorization changed:",
            manager.authorizationStatus.rawValue
        )


        switch manager.authorizationStatus {

        case .authorizedWhenInUse,
             .authorizedAlways:

            startLocationUpdates()


        case .denied,
             .restricted:

            started =
                false


            print(
                "[LocationKeeper] Permission denied"
            )


        case .notDetermined:

            break


        @unknown default:

            break
        }
    }


    // MARK: =====================================
    // MARK: Location Updates
    // MARK: =====================================

    func locationManager(
        _ manager:
            CLLocationManager,
        didUpdateLocations locations:
            [CLLocation]
    ) {

        /*
         座標は保存・送信しない。

         Discord SDK callbacksだけ
         生存確認として回す。
         */

        DiscordBridge
            .shared()
            .runCallbacks()


        guard let location =
            locations.last
        else {

            return
        }


        print(
            "[LocationKeeper] HEARTBEAT",
            Date(),
            "accuracy:",
            location.horizontalAccuracy
        )
    }


    // MARK: =====================================
    // MARK: Error
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
    // MARK: Pause / Resume
    // MARK: =====================================

    func locationManagerDidPauseLocationUpdates(
        _ manager:
            CLLocationManager
    ) {

        print(
            "[LocationKeeper] PAUSED"
        )
    }


    func locationManagerDidResumeLocationUpdates(
        _ manager:
            CLLocationManager
    ) {

        print(
            "[LocationKeeper] RESUMED"
        )
    }
}
