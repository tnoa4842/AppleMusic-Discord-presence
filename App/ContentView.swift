import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: PresenceViewModel

    var body: some View {
        NavigationStack {
            Form {
                Section("Apple Music") {
                    LabeledContent("曲", value: model.trackTitle)
                    LabeledContent("アーティスト", value: model.artist)
                    LabeledContent("再生", value: model.musicStatus)
                }

                Section("Discord") {
                    LabeledContent("状態", value: model.discordStatus)

                    Button("Discord に接続") {
                        model.connectDiscord()
                    }

                    Button("今の曲を送信") {
                        model.pushCurrentTrack()
                    }
                    .disabled(!model.isDiscordReady)

                    Button("Presence を消す", role: .destructive) {
                        model.clearPresence()
                    }
                    .disabled(!model.isDiscordReady)
                }

                Section {
                    Toggle("曲変更を自動反映", isOn: $model.autoUpdate)
                } footer: {
                    Text("iOS がこのアプリを完全に停止・サスペンドした間は、曲変更を即時反映できない場合があります。アプリ復帰時に再同期します。")
                }
            }
            .navigationTitle("Music → Discord")
        }
        .task {
            await model.start()
        }
    }
}
