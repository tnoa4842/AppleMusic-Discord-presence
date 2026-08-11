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


        manager.desiredAccuracy =
            kCLLocationAccuracyThreeKilometers


        manager.distanceFilter =
            kCLDistanceFilterNone


        manager.activityType =
            .other


        manager.pausesLocationUpdatesAutomatically =
            false


        /*
         ここでは
         allowsBackgroundLocationUpdates = true
         にしない。

         Info.plistが正しく反映されていない状態で
         trueにすると起動時クラッシュする可能性がある。
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


        /*
         最終的にビルドされたInfo.plistに
         location background modeが本当にあるか確認。
         */

        let modes =
            Bundle.main
                .object(
                    forInfoDictionaryKey:
                        "UIBackgroundModes"
                )
            as? [String]
            ?? []


        if modes.contains(
            "location"
        ) {

            manager
                .allowsBackgroundLocationUpdates =
                true


            print(
                "[LocationKeeper] Background Location ENABLED"
            )

        } else {

            /*
             locationが入っていなくても
             アプリ自体は落とさない。
             */

            manager
                .allowsBackgroundLocationUpdates =
                false


            print(
                "[LocationKeeper] WARNING: UIBackgroundModes/location not found"
            )
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
         座標そのものは使わない。
         保存もしない。
         */


        DiscordBridge
            .shared()
            .runCallbacks()


        print(
            "[LocationKeeper] heartbeat",
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
