import SwiftUI

struct ContentView: View {
    @ObservedObject var model: PresenceViewModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {

                    // MARK: - Apple Music

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Apple Music")
                            .font(.headline)

                        HStack {
                            Text("状態")
                                .foregroundStyle(.secondary)

                            Spacer()

                            Text(model.musicStatus)
                        }

                        Divider()

                        VStack(alignment: .leading, spacing: 5) {
                            Text(model.trackTitle)
                                .font(.title3)
                                .fontWeight(.semibold)

                            if !model.artist.isEmpty {
                                Text(model.artist)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(.regularMaterial)
                    )

                    // MARK: - Discord

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Discord")
                            .font(.headline)

                        HStack {
                            Text("接続状態")
                                .foregroundStyle(.secondary)

                            Spacer()

                            HStack(spacing: 6) {
                                Circle()
                                    .fill(
                                        model.isDiscordReady
                                        ? Color.green
                                        : Color.orange
                                    )
                                    .frame(width: 8, height: 8)

                                Text(model.discordStatus)
                            }
                        }

                        Button {
                            model.connectDiscord()
                        } label: {
                            Text(
                                model.isDiscordReady
                                ? "Discord 接続済み"
                                : "Discord に接続"
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isDiscordReady)

                        Button {
                            model.forceRefresh()
                        } label: {
                            Label(
                                "今の曲をDiscordへ反映",
                                systemImage: "arrow.clockwise"
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(!model.isDiscordReady)
                    }
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(.regularMaterial)
                    )

                    // MARK: - 自動更新

                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(
                            "自動更新",
                            isOn: $model.autoUpdate
                        )

                        Text(
                            "Apple Musicの曲変更を検出して、Discordの表示を自動更新します。"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(.regularMaterial)
                    )
                }
                .padding()
            }
            .navigationTitle("Music Presence")
        }
    }
}
