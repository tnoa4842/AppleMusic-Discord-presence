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

    private var started =
        false

    private override init() {
        super.init()

        manager.delegate =
            self

        /*
         Apple自身がバックグラウンドで
         省電力に継続させる候補として挙げている精度。
         */
        manager.desiredAccuracy =
            kCLLocationAccuracyThreeKilometers

        manager.distanceFilter =
            kCLDistanceFilterNone

        manager.activityType =
            .other

        /*
         自動停止させない。
         */
        manager.pausesLocationUpdatesAutomatically =
            false

        /*
         Background Locationを許可。
         Info.plist側にlocationが無い状態で
         trueにするとクラッシュするので、
         必ず後述のInfo.plist変更もセット。
         */
        manager.allowsBackgroundLocationUpdates =
            true

        /*
         使用中許可のままBackgroundへ行く場合、
         青い位置情報インジケータが表示される。
         */
        manager.showsBackgroundLocationIndicator =
            true
    }


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


        switch manager.authorizationStatus {

        case .notDetermined:

            /*
             最初は「使用中のみ」で十分。
             必ずアプリが前面の時に呼ぶ。
             */
            manager
                .requestWhenInUseAuthorization()


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


    private func startLocationUpdates() {

        guard !started else {
            return
        }

        started =
            true

        manager
            .startUpdatingLocation()

        print(
            "[LocationKeeper] STARTED"
        )
    }


    func locationManagerDidChangeAuthorization(
        _ manager:
            CLLocationManager
    ) {

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


    func locationManager(
        _ manager:
            CLLocationManager,
        didUpdateLocations locations:
            [CLLocation]
    ) {

        /*
         位置そのものは今回使わない。

         Core LocationのBackground executionを
         維持するのが目的。

         ついでにDiscord callbackを回す。
         */
        DiscordBridge
            .shared()
            .runCallbacks()

        print(
            "[LocationKeeper] background heartbeat",
            Date()
        )
    }


    func locationManager(
        _ manager:
            CLLocationManager,
        didFailWithError error:
            Error
    ) {

        print(
            "[LocationKeeper] Error:",
            error
        )
    }


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
