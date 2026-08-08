# Apple Music → Discord Presence (iPhone-only workflow)

iPhone の Apple Music で再生中の曲を Discord Rich Presence に反映するための iOS アプリ雛形です。

この版は **手元の Mac / Xcode を使わず**、iPhone の Safari から GitHub を操作し、
GitHub Actions の macOS runner で IPA をビルドすることを前提にしています。

## できること

- `MPMusicPlayerController.systemMusicPlayer` から iPhone 標準 Music アプリの現在曲を取得
- 曲名 / アーティスト / アルバム / 再生時間を取得
- 曲変更・再生状態変更を監視
- Discord Social SDK へ OAuth2 + PKCE でログイン
- Rich Presence を更新
- アプリ復帰時に現在曲へ再同期

## 重要な制限

iOS がこのアプリを完全に suspend すると、他アプリ (Music) の曲変更通知を永久に受け続けることはできません。
そのため「常時100%リアルタイム」は Apple のバックグラウンド制限次第です。
アプリ動作中、バックグラウンドへ移った直後、復帰時には同期できます。

また、iOS 26 の通常端末へ IPA を入れるには **Apple の有効なコード署名** が必要です。
GitHub Actions で署名まで行う場合は Apple Developer 用の証明書と provisioning profile が必要です。

## iPhone だけでの流れ

1. Discord Developer Portal で Application を作る
2. Social SDK をダウンロード
3. このリポジトリを GitHub にアップロード
4. Discord SDK の ZIP を `VendorUpload/discord-social-sdk.zip` としてアップロード
5. GitHub Secrets に `DISCORD_APP_ID` を登録
6. Actions → `Build unsigned IPA` を実行してコンパイル確認
7. 実機インストール用は `Build signed IPA` を使う
8. 生成された Artifact の `.ipa` を iPhone へダウンロードしてインストール

詳しい操作は `IPHONE_SETUP.md` を参照。
