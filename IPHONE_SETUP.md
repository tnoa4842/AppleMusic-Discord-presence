# iPhone だけでセットアップする手順

## A. Discord 側

Safari で Discord Developer Portal を開く。

1. Applications → New Application
2. 作成したアプリの Application ID を控える
3. Social SDK のセットアップを進め、最新 SDK をダウンロード
4. OAuth2:
   - Public Client: ON
   - Redirect URI:
     `discord-YOUR_APP_ID:/authorize/callback`
5. SDK の ZIP は Files アプリに保存

## B. GitHub 側

1. GitHub で空リポジトリを作成
2. このプロジェクト一式をアップロード
3. Discord SDK の ZIP を次の名前・場所でアップロード:
   `VendorUpload/discord-social-sdk.zip`

SDK ZIP の内部構造は問いません。
Actions の `prepare_discord_sdk.sh` が以下を再帰検索します。

- `discord_partner_sdk.xcframework`
- `discordpp.h`

## C. GitHub Secrets

Repository → Settings → Secrets and variables → Actions

最低限:

- `DISCORD_APP_ID`
  - Discord Application ID
- `BUNDLE_ID`
  - 例: `com.yourname.AppleMusicDiscordPresence`

署名済み IPA を作る場合はさらに:

- `APPLE_TEAM_ID`
- `P12_BASE64`
- `P12_PASSWORD`
- `MOBILEPROVISION_BASE64`

### Base64 について

`.p12` と `.mobileprovision` の中身を Base64 化した文字列を GitHub Secret に入れます。
この2ファイルは秘密情報です。公開リポジトリへ直接アップロードしないでください。

## D. まず unsigned build

Actions → `Build unsigned IPA` → Run workflow

成功すると Artifacts に:

`AppleMusicDiscordPresence-unsigned.ipa`

が出ます。

これは「コードが iOS 向けにビルドできた」確認用で、そのまま通常 iPhone には入りません。

## E. 実機用 signed build

必要な署名 Secrets を登録後:

Actions → `Build signed IPA` → Run workflow

Artifact:

`AppleMusicDiscordPresence-signed.ipa`

を iPhone にダウンロード。

### インストールについて

Apple の署名条件を満たした IPA なら、利用している配布方式に応じてインストールできます。
Free Apple ID の 7日署名を完全に iPhone 単体で新規作成する仕組みは Apple 公式には提供されていません。
SideStore も初回導入にはコンピュータが必要です。

## F. 初回起動

1. Apple Music のアクセスを許可
2. `Discordに接続`
3. Discord アプリへ飛ぶので認証
4. Music で曲を再生
5. アプリへ戻る
6. Discord の別アカウント等から Presence を確認
