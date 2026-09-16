# リリース

通常の開発は署名不要のDebugビルドで行えます。この手順は、署名・Apple公証済みのDMGとSparkle更新フィードを配布するメンテナー向けです。

## 配信先

公式の配信先は、この公開リポジトリのGitHub Releasesです。

- Feed: `https://github.com/sasuketorii/rev_clip/releases/latest/download/appcast.xml`
- DMG: 各リリースに添付

新しいアプリの配信に別のリポジトリや外部gistは不要です。v0.0.25から、この公開リポジトリで署名・公証済みDMGとFeedを提供しています。

## 完了判定：ローカル更新と公開配信を分ける

0.1.9のローカル候補をインストールした際、公開フィードが0.1.8のまま残り、更新画面に「最新0.1.8／使用中0.1.9」と表示されました。原因は、インストール完了と公開配信完了を同じ状態として扱ったことです。版番号の表示だけを直すのではなく、以下の証拠が揃うまで公開完了と報告しません。

| 段階 | 必要な証拠 |
| --- | --- |
| ローカル候補 | 対象SHA、版・build、回帰結果、署名済み候補。公開済みとは呼ばない |
| 公開 | 対象SHAのmain CIとタグReleaseジョブ成功、公開タグのSHA、latest Release・appcast・DMGの一致、公証・署名の検証 |
| このMacへの反映 | 通常版とDemoの両方の版・build、各バイナリと元の検証済みバンドルの一致。片方だけを更新して完了にしない |
| 実機受入 | コピー・表示・貼り付け・終了を実際に確認した範囲。CI成功から推定しない |

公開ジョブは添付後に `scripts/verify_release_delivery.py` を実行します。公開タグのSHA、latest版、フィードの版・build・URL・署名の存在、公開DMGのサイズ・SHA-256を照合し、不一致ならジョブを失敗させます。公開後の失敗は自動ロールバックを意味しません。公開状態を調べ、配信不整合を解消してから完了としてください。公開後のチェックを省略した再実行や、タグの付け替えで成功に見せかけないこと。

ローカル反映まで依頼された場合は、同じチェックに通常版とDemoの両方を渡します。Python 3.11以降を使うメンテナー向けツールで、配布アプリの実行依存ではありません。以下の値とアプリの場所は対象に合わせて指定してください。

```sh
python3 scripts/verify_release_delivery.py \
  --tag v0.1.9 --build 42 --sha ae00ec899deb0c75003427f7f85597f0dd2715f8 \
  --app "$REGULAR_APP" --demo-app "$DEMO_APP" \
  --output .local/release-delivery.json
```

通常版とDemoの引数は両方必須です（両方省略したCIでは公開配信だけを検証）。このチェックはアプリを起動せず、履歴・クリップボード・設定・Keychainを読みません。成功receiptは検証完了時だけ生成し、既存receiptは検証開始時に削除します。Apple公証、署名の暗号学的検証、インストール済みバイナリの由来、実際のSparkle更新操作、UI受入は別途確認が必要です。

最終報告には公開URL・対象SHA・検証receipt・通常版／Demoの反映状態・未確認事項を記載します。READMEの現在版と品質報告も実際の公開状態へ揃えます。

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

1. `src/Revclip/project.yml` の `CFBundleShortVersionString` と `CFBundleVersion` を更新します。ビルド番号は独立した正整数の連番です。タグとのバージョン一致と、配布済みappcastより大きいビルド番号であることを検査します。
2. `make -C src/Revclip setup` と `make -C src/Revclip test` を実行し、実アプリの基本操作を確認します。
3. バージョン変更をコミットしてmainへ反映し、一致する `v0.0.N` タグをpushします。
4. Releaseワークフローが署名、DMG作成、公証、Sparkle署名、appcast生成、GitHub Releaseへの添付まで成功したことを確認します。
5. ログインしていない状態でDMGとFeedを取得でき、Feedの版・URL・署名が配布物と一致することを確認します。実際の更新と新規インストールも検証してください。

証明書や署名鍵が未設定の状態でタグを作成しないでください。通常のmain/PR向けCIには配布用のSecretsは不要です。

## このリポジトリで次の版を出す

公式リポジトリには上記6種類のSecretsを設定済みです。ローカルに公証用パスワードを保存する必要はありません。リポジトリのルートから、版を更新してテストした後に実行します（`N` は実際の版に置き換えてください）。

```sh
git add src/Revclip/project.yml src/Revclip/Revclip/Info.plist
git commit -m "Prepare release 0.0.N"
git push origin main
git tag v0.0.N
git push origin v0.0.N
gh run list --workflow release.yml
# 表示されたReleaseのIDを指定
gh run watch RUN_ID --exit-status
```

成功後、GitHub ReleasesのDMGをダウンロードし、アプリの更新確認まで検証します。証明書・Appleの認証情報を失効または更新した場合は対応するSecretsも更新してください。Sparkle鍵の変更は既存ユーザーの更新検証に影響するため、通常のリリースで作り直さないでください。

## インストーラのデザイン

0.0.31から `design/Revclip-Installer.dmgtemplate` を使用します。Rilmazafone 2.6で編集し、背景・位置・粒子感をまとめて保存します。詳細は `design/README.md` を参照してください。

ローカルとReleaseワークフローは同じ `src/Revclip/Scripts/create_dmg.sh` を使います。アプリは引数で渡し、テンプレートの一時コピーへ設定されます。CIはSHA-256を固定したRilmazafoneを取得し、Apple署名を検証します。

## 旧版からの移行

旧版が参照する公開gistには、v0.0.25の署名付きappcastを残しています。旧版はこのDMGで新しい更新先へ移り、以後はこのリポジトリのFeedを使用します。この互換用gistとv0.0.25のリリース資産は削除しないでください。今後の通常リリースで旧リポジトリを更新する必要はありません。
