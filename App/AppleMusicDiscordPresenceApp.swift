import SwiftUI
import CoreLocation


@main
struct AppleMusicDiscordPresenceApp: App {

    @StateObject
    private var model =
        PresenceViewModel()


    @StateObject
    private var locationProbe =
        LocationPermissionProbe()


    var body: some Scene {

        WindowGroup {

            VStack(
                spacing: 0
            ) {

                // MARK: =========================
                // MARK: Location Debug
                // MARK: =========================

                VStack(
                    alignment: .leading,
                    spacing: 8
                ) {

                    Text(
                        "位置情報診断"
                    )
                    .font(
                        .headline
                    )


                    Text(
                        "権限: \(locationProbe.statusText)"
                    )


                    Text(
                        "UsageDescription: \(locationProbe.hasUsageDescription ? "あり" : "なし")"
                    )


                    Text(
                        "Background location: \(locationProbe.hasBackgroundLocation ? "あり" : "なし")"
                    )


                    Button {

                        locationProbe
                            .requestPermission()

                    } label: {

                        Text(
                            "位置情報許可を要求"
                        )
                        .frame(
                            maxWidth:
                                .infinity
                        )
                    }
                    .buttonStyle(
                        .borderedProminent
                    )


                    Button {

                        locationProbe
                            .refresh()

                    } label: {

                        Text(
                            "状態を再確認"
                        )
                        .frame(
                            maxWidth:
                                .infinity
                        )
                    }
                    .buttonStyle(
                        .bordered
                    )
                }
                .padding()
                .background(
                    .thinMaterial
                )


                Divider()


                // MARK: =========================
                // MARK: Original App
                // MARK: =========================

                ContentView(
                    model:
                        model
                )
            }
            .task {

                await model
                    .start()
            }
        }
    }
}


// MARK: =========================================
// MARK: Location Permission Probe
// MARK: =========================================

final class LocationPermissionProbe:
    NSObject,
    ObservableObject,
    CLLocationManagerDelegate
{

    @Published
    var statusText =
        "確認中"


    @Published
    var hasUsageDescription =
        false


    @Published
    var hasBackgroundLocation =
        false


    private let manager =
        CLLocationManager()


    override init() {

        super.init()


        manager.delegate =
            self


        refresh()
    }


    // MARK: =====================================
    // MARK: Refresh
    // MARK: =====================================

    func refresh() {

        let status =
            manager
                .authorizationStatus


        switch status {

        case .notDetermined:

            statusText =
                "notDetermined / 未選択"


        case .authorizedWhenInUse:

            statusText =
                "authorizedWhenInUse / 使用中のみ許可"


        case .authorizedAlways:

            statusText =
                "authorizedAlways / 常に許可"


        case .denied:

            statusText =
                "denied / 拒否"


        case .restricted:

            statusText =
                "restricted / 制限あり"


        @unknown default:

            statusText =
                "unknown"
        }


        // MARK: Usage Description

        let description =
            Bundle
                .main
                .object(
                    forInfoDictionaryKey:
                        "NSLocationWhenInUseUsageDescription"
                )
            as? String


        hasUsageDescription =
            !(description ?? "")
                .isEmpty


        // MARK: Background Mode

        let modes =
            Bundle
                .main
                .object(
                    forInfoDictionaryKey:
                        "UIBackgroundModes"
                )
            as? [String]
            ?? []


        hasBackgroundLocation =
            modes.contains(
                "location"
            )


        print(
            "[LocationProbe] ========================"
        )


        print(
            "[LocationProbe] status:",
            statusText
        )


        print(
            "[LocationProbe] usageDescription:",
            hasUsageDescription
        )


        print(
            "[LocationProbe] UIBackgroundModes:",
            modes
        )


        print(
            "[LocationProbe] ========================"
        )
    }


    // MARK: =====================================
    // MARK: Request Permission
    // MARK: =====================================

    func requestPermission() {

        refresh()


        let status =
            manager
                .authorizationStatus


        print(
            "[LocationProbe] BUTTON PRESSED"
        )


        switch status {

        case .notDetermined:

            /*
             ボタンを人間が押しているので
             アプリは確実にForeground。

             ここで直接要求する。
             */

            print(
                "[LocationProbe] requestWhenInUseAuthorization()"
            )


            manager
                .requestWhenInUseAuthorization()


        case .authorizedWhenInUse:

            statusText =
                "使用中の位置情報は既に許可済み"


            /*
             Background側の処理も開始。
             */

            BackgroundLocationKeeper
                .shared
                .start()


        case .authorizedAlways:

            statusText =
                "常に許可済み"


            BackgroundLocationKeeper
                .shared
                .start()


        case .denied:

            statusText =
                "拒否されています。設定から変更が必要"


        case .restricted:

            statusText =
                "iOSの制限により位置情報を使用できません"


        @unknown default:

            statusText =
                "不明な権限状態"
        }
    }


    // MARK: =====================================
    // MARK: Authorization Changed
    // MARK: =====================================

    func locationManagerDidChangeAuthorization(
        _ manager:
            CLLocationManager
    ) {

        DispatchQueue
            .main
            .async {

                self.refresh()


                switch
                    manager
                        .authorizationStatus {

                case .authorizedWhenInUse,
                     .authorizedAlways:

                    print(
                        "[LocationProbe] AUTHORIZED"
                    )


                    BackgroundLocationKeeper
                        .shared
                        .start()


                default:

                    break
                }
            }
    }
}
