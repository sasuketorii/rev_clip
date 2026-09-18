# 開発引き継ぎ: 設定・リンクプレビュー・検証

対象は2026-09-18の設定整理とhardening継続対応です。[所有箇所と境界](HARDENING_20260918.md)を確認してから変更してください。以下はリポジトリルートから実行します。

## 最初に確認すること

`git status --short`で未コミット作業を確認し、他の開発者の変更を上書きしません。`src/Revclip/project.yml`が正本で、生成`.xcodeproj`は編集/コミットしません。XcodeGenは`brew upgrade`任せにせず、CIと同じ固定版を利用できます。

```sh
bash scripts/install_xcodegen.sh "$PWD/.local/pinned-xcodegen"
PATH="$PWD/.local/pinned-xcodegen/bin:$PATH" make -C src/Revclip setup
python3 scripts/verify_sparkle.py
python3 -m unittest discover -s scripts/tests -p 'test_build_provenance.py'
```

Pythonは3.12以降を使用します（CIはsetup-pythonで3.14を指定）。`verify_sparkle.py`は公式配布物をダウンロードするためネットワークが必要です。XcodeGenは実行ファイルに加え`share/xcodegen/SettingPresets`も必要です。`--version`成功だけでは検証にならず、実プロジェクトを生成してプリセット欠落の警告がないことを確認します。固定版変更時は`build-tools.json`とVendorを一緒に検証し、検証失敗を無効化して通さないでください。

コード探索は`rev_skills`の`codebase-graph-discovery`スキルに従います。Objective-Cのグラフは部分解析になるため、呼出元を`rg`と実コードでも確認します。graph上に辺がないことは未使用の証拠になりません。

## 設定画面とリンク取得

- 通常サイドバーはセットアップ・一般・外観・ショートカット・faster OCR・プライバシー・権限ステータス・アップデート・高度な設定・Panicです。Panic は末尾の黄色文字です。
- セットアップは「権限ステータス」「クリップボードメニュー」「FasterOCR」の順で、最初は権限を表示します。権限は既存 `RCPermissionsPreferencesController` を子controllerとして再利用し、切替時にviewを着脱します。既存のサイドバー権限導線も維持します。ショートカット部分は既存の RCHotKeyService の保存・競合チェックを共用します。メニューと OCR の保存済みショートカットを表示し、初期値は ⌘⇧V / ⌘⇧2 です。既存の設定を上書きしません。
- ショートカット入力中だけ session-head の CGEventTap で key down/up を消費し、キーを離してから既存の割り当て処理を呼びます。常駐監視はしません。フォーカス喪失・画面移動・Esc・完了・30秒タイムアウトで必ず破棄し、遅延入力はセッション世代で無効化します。安全に捕捉できない場合は入力を開始せず黄色で案内します。
- 競合は各設定画面の黄色ラベルに表示します。macOS 標準と Revclip 内の競合は検証できますが、他アプリの登録は列挙できません。非排他登録が存在しても他プロセスの排他 probe は成功することを macOS 26 で実測したため、probe による誤判定・一時的な横取りは採用していません。
- キーボードは提供された画像 `src/Revclip/Revclip/Resources/Keyboard/macbook_keyboard.png` を無加工で使用します。`RCKeyboardShortcutView` の矩形は原寸 2546×1046 の物理キー座標です。画像差し替え時は矩形と表示比率も確認してください。US 配列にないキーは入力欄で表示し、別のキーを誤点灯させません。
- 既存の`showTab:`識別子は維持します。高度な設定はmenu/type/agents/bug-report、プライバシーはlinks/excludeです。別の設定保存層を作らず既存controllerを再利用します。
- ページ変更前にfield editorをcommitします。言語変更時のcontroller再生成、子ページへの直接遷移、最後のタブの復元もテストします。
- リンクは未設定なら自動です。手動モードではリンクへポインタを合わせてOptionを押すと、そのURLだけ取得します。通常のホバーでは通信しません。「取得しない」は処理中の要求とcacheを消去します。
- プレビューpanelはマウス操作を透過し、NSMenuの追跡中に出ます。そこへ通常のボタンを置くだけでは押せません。入力経路を変えるときは実際のメニュー追跡中に確認してください。Option-Pのlocal monitorは実メニュー追跡中に機能せず撤去しました。手動取得はhover入口と、手動リンクカード表示中だけの50 ms timerでmodifierを読む方式です。押下の立ち上がりだけを処理し、hide/選択解除/無効化でtimerを撤去します。常時ポーリングやグローバル監視を追加しないでください。キー処理関数を直接呼ぶテストだけではNSMenuでの入力到達を保証できません。遅延hoverのReleaseテストではfixtureのmenuを`objc_precise_lifetime`で保持します。itemからmenuはweakなので、最後のローカル参照後に最適化でmenuが解放されると入力処理に到達しません。
- ポリシー変更はserviceのcancel、previewの世代、menuの設定snapshotの3箇所に関係します。UIだけ変えて通信を残さないでください。

## テストとCIの役割

macOS上でDebugに加えて最適化Releaseを確認します。Releaseのテスト用defineは本番ビルドへ持ち込まないでください。

```sh
xcodebuild -project src/Revclip/Revclip.xcodeproj -scheme Revclip \
  -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
xcodebuild -project src/Revclip/Revclip.xcodeproj -scheme Revclip \
  -configuration Release -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  ENABLE_TESTABILITY=YES SWIFT_ACTIVE_COMPILATION_CONDITIONS=RC_TESTING \
  'GCC_PREPROCESSOR_DEFINITIONS=$(inherited) RC_TESTING=1' test
```

`$(inherited)`はXcode用の文字列です。引用を二重引用符へ変えるとshellのコマンド置換になり、設定を壊します。

重点スイートは`RCMenuFallbackLifecycleTests`、`RCHistoryRetentionTests`、`RCLinkPreviewServiceTests`、`RCFastPreviewTests`、`RCPreferencesSidebarTests`です。競合はgate/expectationで再現し、成功するまでretryするテストにしません。テストでは利用者の実clipboard/DB/Keychainや外部URLをfixtureにしません。

この環境ではGitHub Actionsの課金制限による失敗とコードの失敗を区別します。WoodpeckerはLinuxの契約/配布/Demo静的監査/feedback検証を担当し、XCTest・AppKit・署名済みUniversal buildを代替しません。ローカルmacOS結果を同じcommitに紐づけて残します。

```sh
# 未コミット差分を整理・レビューしてcommitした後
wp-check
wp-verify --push
```

`wp-verify --push`はci remoteへ現在のcommitを送り、対象SHAの初回push pipeline成功後にoriginへ送ります。古いpipelineの緑や再実行成功で別のSHAを承認しないでください。詳細は[CIの担当範囲](RELEASING.md#ciの担当範囲)を確認してください。

## Demoで確認してから本番へ

```sh
make -C src/Revclip demo
make -C src/Revclip demo-run
```

Demoの署名にはローカルApple Development identityが必要です。`demo-run`はビルド出力を起動します。Applicationsへ配置する場合は起動中Demoを正常終了し、既存bundleを退避してから新bundleをコピーしてください。設定や履歴を削除して導線確認を通してはいけません。

通常版とDemoはデータ領域が別ですがショートカットは競合します。既存`Scripts/run_demo.sh`を利用して通常版を正常終了します。起動要求だけで成功とせず、実行中bundle、署名、UIを確認します。Orcaのapp一覧にLSUIElementのDemoが出ない場合は、稼働PIDで指定し設定ウィンドウを開きます。常駐メニューしかない状態の「AX windowなし」を権限未許可と即断せず、window一覧とpermission実測を分けます。設定の一般/高度な設定/プライバシーを行き来し、入力保存・タブ・翻訳・再起動後の保存を確認します。リンク確認には自分で用意した非機密のURLだけを使用します。

本番リリースはDemo受入後に[配布手順](RELEASING.md)へ進みます。開発署名のDemoを公証済み配布物と同一視しません。

## 再発を防ぐ注意点

- `NSCache`はevictionするので処理中要求の所有権を任せません。別集合と上限で重複/待機数を管理します。
- cache消去時は世代を進めます。期限/件数による履歴削除も削除項目を含む`historyRemoved`通知を通します。全消去とは分け、無関係なcacheの再取得を増やさないようにします。DBだけ消してpreview本文を残さないでください。
- 主アプリのentitlementsは現在空です。再署名時に明示して、archive由来の不要な権限が復活しないようにします。追加権限は用途と署名検証ポリシーも変更します。
- releaseは署名jobから公開jobへhash付きartifactを渡します。公開jobへ署名秘密を渡しません。証明書import途中の失敗でも一時ファイル/keychainを片付け、cleanup失敗なら転送を止めます。
- 実行した検証と未検証環境を区別します。単体テスト成功だけでIntel実機、RSS上限、実Sparkle更新の成功を宣言しません。

### ショートカット記録と警告の所有者

- 競合判定は `RCHotKeyService` のslotを基準にし、自分の保存済みキーの再設定を拒否しません。UIが古い警告を別slotへ持ち越すと自己競合に見えるため、画面移動・保存値変更・設定再読込で警告を解除します。共有ラベルには失敗したslot名も表示します。
- 記録の確定はevent tapで消費したキーのrelease後だけです。AppKitへ入力が漏れた場合は保存せず停止します。捕捉開始前のkeyUpは通し、重ねて押されたキーは全releaseを待ちます。OS全体の他アプリの非排他登録を確実に検出できるとは表示しません。
- 回帰は `RCSetupPreferencesTests` / `RCHotKeyRecordingTests` / `RCHotKeyContractTests` にあります。実機ではメニュー側でOCRキーを入力して拒否された後、OCRへ切替→同じOCRキーの再設定→別ページ往復を確認します。成功時は警告なし、拒否時は保存済み値を維持します。

## 自動更新のリマインダー

`RCUpdateService` が Sparkle の updater delegate と standard user driver delegate を兼ねます。`LSUIElement` の常駐アプリでは、通常の定期更新ダイアログは他アプリの背後に表示されるため、`userDriverDelegate:nil` に戻さないでください。起動直後など `immediateFocus` が真なら Sparkle の表示を使い、それ以外は gentle reminder を表示します。

- 更新待ちの専用メニューバーボタンは通常アイコンの表示設定から独立しています。通知センターの許可拒否・集中モードでも、更新を開く導線を残します。フォーカスを強制的に奪いません。
- 通知 delegate は起動時に登録し、前のプロセスから残った通知もクリックで更新確認へ進めます。通知を見た時点、または更新セッション終了時にリマインダーを撤去します。
- 通知許可と配信は非同期です。世代と通知ごとの UUID で、閉じたセッションの通知復活や次のセッションの通知削除を防ぎます。定期ポーリングは追加していません。
- 更新ボタンは Sparkle の controller に直接 `checkForUpdates:` を渡し、保留中セッションを前面に戻します。新規通信を独自に開始しません。自動確認間隔の既定値は引き続き24時間です。
- 回帰テストは `RCUpdateServiceNotificationPolicyTests`。通知拒否、遅延した許可応答・配信完了、手動確認との重複、セッション終了、次セッションへの復帰を含みます。単体テストでは通知センターを差し替え、利用者の権限を変更しません。
- 実 Sparkle の確認は別 bundle ID・別 defaults・署名した専用更新 fixture で行います。製品の bundle ID や更新フィードを検証のために書き換えないでください。通知の表示確認と更新インストール完了は別の受入条件です。
