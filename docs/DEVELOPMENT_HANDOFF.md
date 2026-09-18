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

- 通常サイドバーは一般・外観・ショートカット・faster OCR・プライバシー・権限ステータス・Panic・アップデート・高度な設定です。
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
