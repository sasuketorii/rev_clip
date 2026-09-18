# メニューフォールバックの世代境界を守る — 2026-09-18

## 対象と証拠の範囲

開始時のmainは `17d40fae188e179fa1e3286c4111f58ab1d2f5ad`。専用ブランチは `hardening/core-boundaries-20260918`。この変更は公開済み製品の新機能追加やメニュー刷新ではなく、キャッシュ消去後に古い非同期結果が再登録される経路を閉じるものです。

作業環境はLinuxで、XcodeとmacOS実機はありません。ローカルcloneは名前解決に失敗したため、GitHub接続からmainのref、ソース、履歴、差分を取得し、同じ開始SHAからブランチを作成しました。ローカルの `git status / fetch / pull`、XCTest、Instrumentsを実行したとは扱いません。GitHub APIによる差分レビューとローカルGit実行も区別します。

開始SHAの既存[CI run 35235711017](https://github.com/sasuketorii/rev_clip/actions/runs/35235711017)は成功しており、Debugテスト、最適化したReleaseテスト、Universalビルド、CLI、配信ガード、Demo静的監査、feedback relayの各ステップが成功していることを確認しました。これは変更前のCI証拠であり、この変更の成功証拠ではありません。変更後の実行結果はPRのChecksとPR本文に、対象Head SHAとともに記録します。この文書のコマンドは実行方法であり、実行済み宣言ではありません。

[製品ページ](https://company.rev-c.com/revclip)は一般利用者向けの紹介・ダウンロード導線、[README](../README.md)と[英語README](../README.en.md)は開発者・改造者・contributor向けの技術入口です。READMEの長さは問題とせず、両方とも変更していません。

## 監査マップ

ツリー、README両言語、SECURITY、CONTRIBUTING、THIRD_PARTY_NOTICES、品質/OCR文書、ビルドと配布設定を確認しました。以下は重要境界を選んで行ったソースレビューです。全ファイルの全行を検証した保証、侵入試験、完全な競合不在証明ではありません。

| 領域 | 責務・依存方向と所有権 | 今回の判断 |
| --- | --- | --- |
| App | 起動・終了とサービスの寿命を調整。AppKitの終了待ちではmain dispatchとrun loopの違いが重要 | 終了ドレイン、タイムアウト、起動処理は変更しない |
| Managers / RCMenuManager | AppKitのメニュー開閉、履歴/テンプレート行、アクション、Services、プレビューを所有。DBからメタデータを取得し、本文読込はutility queue、UI反映はmain | フォールバック結果と消去の世代境界だけを補強 |
| Managers / RCDatabaseManager | FMDatabaseQueueでSQLCipherを直列化。スキーマ検証、panic書込障壁、履歴/テンプレート永続化 | スキーマ、SQL、暗号化キー、接続寿命は不変 |
| Models | RCClipItemは一覧メタデータ、RCClipDataはタイプ別ペイロードとアーカイブ/同一性 | シリアライズ、既存履歴との互換性は不変 |
| Services / Clipboard・Paste・Privacy | changeCountによる取得判定、main上のpasteboard、監視/保存キュー、自己書込・停止世代、許可状態、貼り付け先検証 | ポーリング500ms既定、取得/保存分離、貼り付け順序は不変 |
| Services / HotKey | Carbon登録、正規化、永続化、衝突判定、準備/commit/rollback、OCRとフォルダーのショートカット | 一括分割せず現行のトランザクション境界を維持 |
| Services / Storage・Import | Keychain/HKDF/AES-GCM、移行、私有ディレクトリ・ファイル検証、bounded read、atomic write。Importは版/件数/サイズ/媒体を検証 | crypto、ファイル置換、parser、migrationを変更しない |
| Services / Screenshot・Update | スクリーンショットのquery寿命と直列import、Sparkleと配布設定 | 独立した寿命管理として今回の変更から除外 |
| Services/OCR | main actorが選択・状態を所有。独立crop、Vision認識、cancel/ticket/generationで古い結果を排除 | アルゴリズム、言語、整形、capture、clipboard markerに変更なし |
| UI / Preferences / SnippetEditor | native controllerが表示を所有。設定/言語更新と各ページ、編集サービスに依存 | 表示・ローカライズ・設定キーは変更しない |
| Utilities | パス、色/画像、メニュー外観、ローカライズなどの具体的補助 | 共通frameworkや汎用抽象化を追加しない |
| Vendor | SQLCipher、FMDB、Sparkleとそのライセンス/由来 | 更新や再整形なし |
| CLI / Agent | Foundation CLI → 同一UIDのローカルsocket → 明示的な許可操作。履歴本文と現在のclipboardを読み出すコマンドはない | 新API・権限・データ公開なし |
| Tests / scripts / CI | XCTestの製品コード境界、PythonのCLI/配布契約、Node/workerdのfeedback検証、Demo静的監査 | 既存テストターゲットへ追加し、CIジョブと配布手順は変更しない |
| services/feedback | 明示同意、入力/応答サイズ制限、deadline、rate limit、redirect制約。エラーへ秘密を含めない | アプリの通信範囲を広げない |

### メニューの責務と変更選択

RCMenuManagerには、status itemの寿命、コピー保存完了後の表示、追跡中の行の鮮度、履歴のグループ化、テンプレート、アクション、Services、外観、遅延プレビュー、キャッシュ消去が集まっています。重要なのは行数ではなく、mainの表示状態とbackgroundの結果が同じ消去境界を守れるかです。

確認できる所有物は、メニュー追跡用のweak hash table、行をweak keyとする4つのmap、5つのNSCache、2つのserial utility queueです。サムネイルcacheにはcountLimit 128 / totalCostLimit 32 MiBが設定されていますが、これはプロセスのメモリ上限ではありません。テキスト系cacheに同様の明示的budgetはなく、長時間のunique-history churnとretention時の寿命は別途検証が必要です。全コンポーネントのLOC・メソッド数・参照数を自動集計した結果は今回取得していません。

新しいmanagerへメソッドを移すだけでは世代管理の漏れは解決しません。今回は既存ownerとlockを維持し、受付・結果反映・UI完了の境界を固定しました。大きなクラス分割よりも、具体的なsecurity/lifecycle上の穴を小さく修正する方を優先しました。

[メニュー表示と古い要求の取消の修正](https://github.com/sasuketorii/rev_clip/commit/3afffad456b5d6fd495db66e4d503160f7b573f9)と、[AppKit modal loopの終了deadlock修正](https://github.com/sasuketorii/rev_clip/commit/b57676b3b9173f82a1e10761552a1bff1364d480)の差分を確認しました。今回、そのrun loop、メニュー開閉、停止ドレイン、表示前のclipboard同期は変更しません。

## 発見した問題

従来のフォールバック経路では次の順序が成立します。

1. ホバーした行の本文アーカイブをutility queueで読み始める。
2. mainがClear/Panicの共通cache消去入口を実行する。
3. 古い読込が終わり、本文tooltip、色文字列、色判定、Doneマーカーを再びcacheへ書く。
4. 生存している古い行のcompletionが再設定を行い、previewTextsを再登録する。

これは**消去後のメモリ内cacheへの再登録**の問題です。この経路が消去済みDB行やディスクの履歴を復元する、ネットワークへ送信する、と主張するものではありません。また、Clear後に同じhashを再要求すると、古いDoneが新しいInFlightを上書きするABA型の問題もあります。

## 変更した契約

`cacheGenerationSnapshot`は既存cacheLockで世代を読みます。フォールバックのInFlight登録と最終的なcache反映は、消去と同じlock内で世代を照合します。本文読込、復号、文字列の切り詰め、色の解析はlockの外です。結果の参照と判定値だけを反映し、新しい結果オブジェクト、copy、queue、singleton、protocolは導入しません。

無効になったbatchは残りのアーカイブを読みません。既に開始した読込は完了してよいものの、結果とDoneを公開しません。読込失敗や空パスの場合にも古いDoneを書かない点が重要です。completionは従来どおりmainへ一度配送し、ホバー側でも世代を確認してからAppKitを変更します。単にcompletionを捨てて呼び出し契約を変える修正にはしていません。

lock順序は既存cacheLock → NSCache操作です。新しいlock、lock中のcallback、DB/ファイル/ネットワークI/O、mainからworkerの同期待機は追加していません。結果cacheの書込と消去を直列化するので、照合と書込を別々に行うTOCTOUを避けます。

## 回帰テスト

追加ファイルは `src/Revclip/RevclipTests/RCMenuFallbackLifecycleTests.m`。通常のXcodeGenテスト対象に自動的に含まれ、CIに別の重いジョブは追加しません。

| 境界 | 固定する内容 |
| --- | --- |
| 読込途中の消去 | 古い本文・色・状態を再登録せず、残りのbatchを読まない。completionは一度、mainで実行 |
| queue待機中の消去 | 古い要求によるアーカイブ読込は0回 |
| 同じkeyでの再要求 | 古い成功/失敗のどちらでも、新しいInFlightと結果を壊さない |
| 生存している古いhover行 | 完了通知から再設定やpreview text復活を起こさない |
| 現行世代の互換性 | 本文/URL fallback、切り詰め、色、読めないarchiveのDone、重複要求の読込集約を維持 |
| 開いていない履歴 | 30行を3フォルダーへ構築しても本文/サムネイル読込は0。10行のフォルダーを開く準備でサムネイル要求10、本文読込0 |

実際のproductionメニュー構築・cache・受付・完了を使い、アーカイブ読込だけを合成データへ差し替えます。一般clipboard、利用者DB、Keychain、OCR画像、ネットワークはfixtureへ取り込みません。ゲートとexpectationで操作順序を作り、sleepで競合発生を祈る構造ではありません。timeoutはdeadlock時の終了用であり、性能合格値ではありません。

一時RCClipDataのweak参照が解放される境界も検査しますが、これはRSS、peak memory、allocation count、secure zeroizationの検証ではありません。読込中のローカル変数から即座に秘密を消去する保証も追加していません。

## 開発者向けの再現方法

macOSの開発環境でREADMEの依存準備後に実行します。以下は署名済み配布物の作成ではありません。

```sh
cd src/Revclip
make setup
make test

# 現行CIと同じRelease最適化の全体テスト境界
xcodebuild -project Revclip.xcodeproj -scheme Revclip -configuration Release \
  CODE_SIGNING_ALLOWED=NO ENABLE_TESTABILITY=YES \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS=RC_TESTING \
  'GCC_PREPROCESSOR_DEFINITIONS=$(inherited) RC_TESTING=1' \
  SYMROOT="$PWD/build" test

# Universalコンパイル。Intel実機の動作確認や公証とは異なる
xcodebuild -project Revclip.xcodeproj -scheme Revclip -configuration Release \
  -arch arm64 -arch x86_64 ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO \
  SYMROOT="$PWD/build" build
```

### 任意のcomponent stress

```sh
cd src/Revclip
make setup
xcodebuild -project Revclip.xcodeproj -scheme Revclip -configuration Debug \
  -only-testing:RevclipTests/RCMenuFallbackLifecycleTests \
  -test-iterations 100 -run-tests-until-failure \
  -test-repetition-relaunch-enabled NO \
  CODE_SIGNING_ALLOWED=NO SYMROOT="$PWD/build" test
```

これは同じテストプロセスで、消去/再要求/hover解放の既知の順序を繰り返すcomponent stressです。成功するまでのretryではなく、失敗した時点で止めます。100回は便宜的なローカル上限であり、品質スコアではありません。全アプリの長時間soak、実際のコピー連続操作、OCR cancel/restart、メモリ測定を代替しません。CIでは通常の1回分だけが動きます。

Xcodeの反復試験の考え方はAppleの[日本語セッション](https://developer.apple.com/jp/videos/play/wwdc2021/10296/)と[英語セッション](https://developer.apple.com/videos/play/wwdc2021/10296/)を参照してください。この反復コマンド自体のLinux環境での実行はできていません。

## 性能・セキュリティ・配布の判断

**高速化したとは主張しません。** メニュー構築時に本文を先読みしない、開いたフォルダー以外のサムネイルを要求しない、重複読込を増やさない、という仕事量の契約をテストします。このテスト成功から、実機のend-to-end latencyに退行がないと断言することもできません。追加された短いlock区間の実機での競合・所要時間は未測定です。

ポーリング、DB query/insert、起動、OCR、paste、テンプレート、暗号化とmigration、UserDefaults、CLI、Agent権限、ネットワーク、UI文言は不変です。新しいログやruntime dependencyはありません。アーカイブ読込と解析をmainへ移していません。

XcodeGenのproject.ymlがビルドのsource of truthであること、macOS 14 deployment target、Debug/Release/Demo、Swift 6と対象設定のconcurrency mode、ARC、arm64/x86_64、Hardened Runtime、CLI embeddingを確認しました。生成projectや設定は変更していません。

release.ymlのDeveloper ID、Universal、notarization、stapling、Sparkle EdDSA、appcast、版一致、build単調増加、公開配信確認、取得ツールのversion/checksum確認は維持します。Sparkle 2.9.6、FMDB 2.7.12、SQLCipher 4.19.0の更新やVendor修正は行いません。AGPL/legacy MIT/third-party noticesも不変です。今回、release tagの発行、署名鍵の取得、公開feedの変更、本番更新の試験は行いません。

## Manual validationと未検証環境

ユーザー提供の2026-09-18の記録：**M2 MacBook Air / 8GB RAMの実機で通常操作およびOCRを確認し、開発者の主環境と比較して明確な体感性能低下や重大な挙動差は確認されなかった。**

これはユーザーによる既存版のmanual acceptanceです。今回の変更後ビルドをagentがM2 Airで確認した証拠でも、全Apple Silicon機の保証でもありません。exact latency、CPU、peak/resident memory、energy impact、allocation countを測定したbenchmarkではありません。

| 環境・検証 | この文書作成時の扱い |
| --- | --- |
| 開始SHAのmacOS CI | 上記runの各ステップ成功を確認 |
| 変更後Debug/Release/Universal | PR ChecksとHead SHAに紐づけて判定。開始SHAの成功から流用しない |
| M2 Air 8GB / 通常操作・OCR | ユーザー提供の既存版manual acceptanceのみ |
| macOS 14の実機 / Intel実機 | 今回未検証 |
| Retina / 外部画面 / mixed scale | 今回の変更後実機検証なし |
| Demoの実機 / login item / Sparkle実更新 | 今回未検証。設定不変や静的監査と実機受入を区別 |
| 長時間RSS/Leaks/Allocations/Energy | 未測定 |
| 変更前後のRelease bundle / DMG size | 未測定 |
| ASan / TSan / UBSan | 今回未実行 |

## 残る課題

次の独立したPR候補は、(1) unique-history churn/retentionを含むテキスト系cacheのbudget・寿命検証、(2) 実機の同条件でのメニュー/hover latency・RSS計測と長時間soak、(3) 上記境界が固定された後のstatelessな履歴行構築責務の抽出です。HotKey全面分割、Import parser抽出、更新fixture E2E、sanitizer全種のCI追加は今回に抱き合わせません。

セキュリティレビューの対象は今回変更した非同期cache経路です。データ露出、ログ、filesystem、concurrency、clipboard、network、CLIの変更有無を確認していますが、独立した第三者監査や秘密情報scannerの実行結果は取得していません。
