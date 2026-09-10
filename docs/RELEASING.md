# リリース

通常の開発は署名不要のDebugビルドで行えます。この手順は、署名・Apple公証済みのDMGとSparkle更新フィードを配布するメンテナー向けです。

## 配信先

公式の配信先は、この公開リポジトリのGitHub Releasesです。

- Feed: `https://github.com/sasuketorii/rev_clip/releases/latest/download/appcast.xml`
- DMG: 各リリースに添付

別のリポジトリや外部gistは不要です。最初のバイナリリリースを公開するまではFeedは利用できません。ソースの初回公開とバイナリ配布は別の工程です。

## 事前設定

`.github/workflows/release.yml` は `v*` タグで実行します。対象リポジトリのActions secretsに以下を設定してください。値をソース・Issue・ログへ書かないでください。

| Secret | 用途 |
| --- | --- |
| `APPLE_CERTIFICATE_P12` | Developer ID Application証明書と秘密鍵を含むP12のBase64 |
| `APPLE_CERTIFICATE_PASSWORD` | P12のパスワード |
| `APPLE_TEAM_ID` | 署名・公証のTeam ID |
| `APPLE_ID` | 公証に使用するApple ID |
| `APPLE_APP_PASSWORD` | Appleのアプリ用パスワード |
| `SPARKLE_PRIVATE_KEY` | SparkleのEdDSA署名鍵 |

既存リポジトリのSecretsは新しいリポジトリに自動では移りません。Forkも独自に設定します。`project.yml` の `SUPublicEDKey` と署名鍵が一致し、`SUFeedURL` が自分の配信先を向いていることを確認してください。Appleの署名とSparkleの署名は別の仕組みです。

## 公開手順

1. `src/Revclip/project.yml` の `CFBundleShortVersionString` と `CFBundleVersion` を更新します。現在のワークフローは `0.0.N` / build `N` の対応を検査します。
2. `make -C src/Revclip setup` と `make -C src/Revclip test` を実行し、実アプリの基本操作を確認します。
3. バージョン変更をコミットしてmainへ反映し、一致する `v0.0.N` タグをpushします。
4. Releaseワークフローが署名、DMG作成、公証、Sparkle署名、appcast生成、GitHub Releaseへの添付まで成功したことを確認します。
5. ログインしていない状態でDMGとFeedを取得でき、Feedの版・URL・署名が配布物と一致することを確認します。実際の更新と新規インストールも検証してください。

証明書や署名鍵が未設定の状態でタグを作成しないでください。通常のmain/PR向けCIには配布用のSecretsは不要です。
