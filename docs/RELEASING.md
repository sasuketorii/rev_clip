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

### GitHub APIのtokenの扱い（v0.2.0の公開で起きたこと）

v0.2.0（build 58）の公開ジョブは、署名・公証・公開まで成功した後、この検証だけが失敗しました。原因は、匿名のGitHub APIの `403 rate limit exceeded` です。GitHubのホストランナーは、アドレスをほかの利用者と共有するので、匿名のAPIの上限が、すでに使い切られていることがあります。配信の不整合ではなく、同じスクリプトの、別の環境からの匿名の検証は、成功しました。タグの付け替えや、検証の省略は、していません。

対応の原則は、次のとおりです。

- tokenを使うのは、**GitHub APIのメタデータの照会（公開タグのSHA、latest Release）だけ**。環境変数 `GITHUB_TOKEN` があれば使い、無ければ匿名で照会します。ローカルの実行に、tokenは要りません。公開ジョブは、この手順にだけ、ジョブの `github.token` を渡します。
- **フィード（appcast）とDMGは、常に匿名で取得します。** 利用者のMacが受け取るものを、同じ条件で確かめるためです。tokenを付けると、公開されていないものでも、取得できてしまいます。
- tokenを送るのは、`https://api.github.com` ちょうど（HTTPS、ポートと利用者情報なし）だけ。リダイレクト先へは、転送しません（リダイレクトで引き継がれないヘッダとして付けます）。形の合わないtokenは、通信の前に拒否します。
- tokenは、ログ、receipt、エラーの文面に、出しません。
- tokenの有無で、照合の内容（タグのSHA、latest版、フィードの版・build・URL・署名の存在、DMGのサイズ・期限・SHA-256）は、変わりません。
- APIが403／429を返した時は、配信の不整合と区別できる文面で、失敗します。

### v0.2.1で検出したトークン形式の互換性

公開後の配信確認が `GITHUB_TOKEN has an unexpected form` で止まりました。旧検証は255文字を上限にしていましたが、GitHubは2026年4月からActionsの `GITHUB_TOKEN` を含むinstallation tokenを約520文字・可変長の形式へ移行しています（[公式案内](https://github.blog/changelog/2026-04-24-notice-about-upcoming-new-format-for-github-app-installation-tokens/)）。トークンは不透明な値として扱い、文字数やJWT内部に依存しません。

検証はHTTPヘッダに安全な文字集合だけを確認します。API宛だけに送り、リダイレクト・Feed・DMGには送らず、ログ・receiptにも出さない制約は維持します。長い偽tokenによる回帰を追加済みです。v0.2.1のタグには旧スクリプトが含まれるため、Releaseを再実行せず、修正済みmainの検証スクリプトで公開タグ・build・SHAを照合してください。公開assetは差し替えません。

### 公開の後に、検証だけが失敗した時の手順

公開ジョブの再実行は、**配信の検証まで、進みません。** ジョブの初めの `Validate version matches tag` が、「ビルド番号は、配布済みのappcastより大きい」ことを求めるためです。公開が済んだ版の再実行は、公開済みのビルド番号と同じ値になるので、ここで止まります（v0.2.0、build 58の再実行で、実際に止まりました）。これは、意図どおりの動作です。同じ版を、もう一度、署名・公証・添付して、配布物を差し替えることを、防いでいます。配布物は、初回の公開のままです。

- **このガードは、緩めません。** 再実行を通すための条件の追加、ビルド番号だけの変更、タグの付け替え、Releaseやassetの作り直しは、しません。
- 公開の後に行うのは、**配信の検証だけ**です。上の `scripts/verify_release_delivery.py` を、公開タグ・ビルド番号・対象SHAを指定して、実行します。特定のCIの基盤には、依存しません。ログインしていない環境から、tokenなしで実行できます。匿名のAPIの上限に当たる環境では、`GITHUB_TOKEN` を渡します（使われるのは、APIの照会だけ）。
- 検証が `passed` なら、そのreceiptを、公開の検証の証拠にします。最終報告には、公開ジョブの検証のステップが失敗した事実と理由、再実行がガードで止まった事実、後から行った検証のreceiptを、分けて書きます。ジョブの失敗の表示を、成功として扱いません。
- 検証が、配信の不整合で失敗した時は、公開の状態を調べます。直す必要があれば、**新しいビルド番号の、新しい版**として、公開し直します。

これらは、`scripts/tests/test_release_delivery.py` で確かめています（`python3 -m unittest scripts/tests/test_release_delivery.py`）。

最終報告には公開URL・対象SHA・検証receipt・通常版／Demoの反映状態・未確認事項を記載します。READMEの現在版と品質報告も実際の公開状態へ揃えます。

## CIの担当範囲

- Woodpeckerの `.woodpecker/check.yaml` は、PythonのCLI・インストーラ・配信検証、通常版／Demo版の機能差チェック、Node.jsのフィードバック中継テストを実行します。署名鍵・配信権限・ホストのボリュームを渡しません。
- Woodpeckerの共有checkoutには書込可能な親ディレクトリがあるため、インストーラ試験はコンテナ内で作成した所有者専用のコピーで実行します。製品の親ディレクトリ権限チェックを緩めたり、共有ボリューム全体をchmodしたりしません。
- `.github/workflows/ci.yml` はmacOS上のXcodeテスト（Debug／Release）とUniversalビルド、ネイティブCLIを確認します。Linuxの検証成功でAppKit・Vision・ScreenCaptureKitの動作合格を代用しません。
- `.github/workflows/release.yml` の `build-sign` は読み取り権限でビルド・署名・公証・EdDSA署名を行います。鍵を削除してから署名済み成果物をartifactへ渡し、別の `publish` ジョブだけが書込み権限で公開します。公開ジョブには署名用secretsを渡さず、artifact IDとSHA-256を照合します。
- `scripts/build-tools.json` はXcodeGenとSparkleの版・公式URL・SHA-256の共通定義です。XcodeGenとDMGツールは証明書import前に準備します。`scripts/verify_sparkle.py` は公式archiveとVendorのバイト列・symlink・実行属性・LICENSEを比較し、Woodpeckerでも実行します。
- `scripts/verify_app_signature.py` は配布appと同梱CLI・Sparkle各部品のDeveloper ID、Team、Hardened Runtime、timestampを検証します。appのentitlementは現状空が期待値です。不要だったApple Events entitlementを除去し、再署名時にも期待値を明示しています。
- Woodpeckerは公開処理を行いません。macOSビルドの実行環境・GitHubの利用枠と、署名公開runが実際に成功したかは別途確認します。
- 開発コミットは、対象ブランチのクリーンな状態で `wp-check`、続いて `wp-verify --push` を実行します。Giteaの `ci` remoteで **pushイベント・同一ブランチ・同一SHA・初回実行** の成功を確認してから、GitHubの `origin` へ送ります。mainに公開する変更はmain上でこの経路を使います。
- タグ付けの前に、そのSHAのmacOS CIも確認してください。WoodpeckerとmacOS CIの結果、公開後の配信検証を別々に記録します。

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
