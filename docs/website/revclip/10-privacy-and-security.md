---
title: "Revclipの保存データとプライバシー"
description: "保存時の暗号化、macOSの権限、CLIで扱える範囲、削除やバグ報告で送る情報を説明します。"
slug: revclip/privacy-and-security
navOrder: 10
productArea: revclip
docVersion: '0.1.9'
status: draft
verifiedAt: '2026-09-16'
---

# 保存データとプライバシー

Revclipはコピー履歴とテンプレートをMac内に保存し、データの種類に応じて保存時に暗号化します。**現在のクリップボードと、Revclipに保存した履歴は別のデータです。** 暗号化で保護する範囲、削除で消える範囲、外部へ送信される情報を確認してから使ってください。

<!-- block: callout tone=info -->
> **対象版と確認状況:** Revclip 0.1.9（build 42）の説明です。公開CI、配布DMGの署名・公証、更新フィードは確認済みです。実際の描画・貼り付け・連続操作の実機受け入れは完了していません。第三者認証や完全な独立セキュリティ監査を受けた製品ではありません。

## 履歴とテンプレートはMac内に保存されます

Revclipはアカウント登録を必要とせず、履歴やテンプレートをクラウド同期しません。通常版とDemo版の保存領域も分かれています。設定値は履歴データベースとは別のmacOSユーザー設定として保存します。

ネットワークは、アップデートの確認とダウンロード、URL単体のリンクプレビューやファビコン取得、同意したバグ報告で使います。開発版のリンク取得は既定で手動です。「プライバシー → リンク」で取得方法を選択でき、取得しないへ切り替えると進行中の取得とキャッシュを消去します。

| 保存データ | 保存時の保護 |
| --- | --- |
| 履歴タイトル、テンプレート本文、検索用ハッシュなどのデータベース | SQLCipherでデータベース全体を暗号化 |
| 保存したクリップ本文とサムネイル | CryptoKitのAES-256-GCMで暗号化し、改変を検証 |
| データベースとファイルの暗号鍵 | ランダムな256ビットのルート鍵をログインキーチェーンに保存。HKDFでデータベース用とファイル用の鍵を分け、キーチェーン項目はiCloud同期しない |
| macOSのユーザー設定 | 履歴データベースとは別に保存。上記のSQLCipher暗号化の対象ではない |

テンプレートをファイルへエクスポートすると、本文を含むファイルが作られます。アプリ内の保存時暗号化は、そのファイルには適用されません。保存場所や共有先を確認してください。

保存鍵を失うと、既存データを復号できません。Revclipに鍵の預かりや復旧サービスはありません。鍵やデータベースの検証に失敗した場合、Revclipは履歴の記録を開始せず、既存データを新しい鍵や空の履歴で置き換えません。

## 保存時暗号化はMacやOSの権限からデータを隔離しません

暗号化が主に守るのは、鍵を持たない状態でコピーされた保存ファイルです。実行中は鍵と復号済みの内容がMacのメモリにあります。メモリ上の内容は、保存ファイルの暗号化では隠れません。同じMac上で管理者権限を持つプログラムやマルウェアが動く場合、内容が読まれるリスクがあります。Revclipのプロセスへの侵入や、ユーザーが許可したキーチェーンアクセスにも注意してください。通常の利用では、アクセスのたびにTouch IDを求めません。Revclipはパスワードマネージャーではありません。

次の場所やデータは、Revclipの保存時暗号化の対象外です。

- macOSのクリップボード。ほかのアプリと共有され、OSの権限や状態によっては読み取られることがあります。
- Revclipの画面に表示されたプレビューや、内容を貼り付けた先のアプリ。
- テンプレートのエクスポートファイル。
- 旧版が作成したバックアップ、APFSスナップショット、SSD上に残るデータ。

自動ペーストにはmacOSの「アクセシビリティ」権限が必要です。この権限は貼り付け操作のためのもので、保存時暗号化とは別に判断してください。macOSがクリップボードの読み取りを拒否している間、Revclipは内容を記録しません。

### 機密情報を含むアプリを除外する

コピー元が「秘匿」「一時的」「自動生成」のマークを付けた項目は、Revclipが本文を読む前に除外します。除外アプリを設定すると、そのアプリが最前面にあるとRevclipが判定した間のコピーも記録対象から外します。

1. Revclipの「設定」を開き、「除外アプリ」を選びます。
2. 「＋」を押し、除外したいアプリを選んで追加します。
3. 除外アプリの一覧に対象が表示されたことを確認します。

**確認結果:** 対象アプリが一覧に表示されます。監視時にそのアプリが最前面と判定されたコピーは、記録対象から外れます。

この判定は、コピー元のアプリ情報ではなく、監視時に最前面だったアプリに基づきます。コピー直後にアプリを切り替えるなど、タイミングによってはコピー元と判定が一致しないことがあります。機密マークを付けないパスワードや個人情報を、内容だけから確実に検出する機能もありません。

<!-- block: callout tone=warning -->
> クリップボードの監視間隔は既定で500msです。次の観測より前に別の内容で上書きされたコピーは記録できないことがあります。すべてのコピーを記録する保証はありません。

## エージェント用CLIから履歴やクリップボードは読めません

エージェント用CLI（コマンドを入力して使うツール）はテンプレートと許可された設定を扱います。`list` と `get` が返すのはテンプレートだけです。履歴の一覧・本文・書き出しや、現在のクリップボードを読む操作はCLIにありません。履歴の保存件数や期限を変える設定操作も、保存内容を返しません。バグ報告に履歴を自動添付することもありません。

この制限はRevclipが提供するCLIの範囲です。同じOSユーザーとして広い権限を持つエージェントや、Mac全体を操作できるプログラムまで隔離するものではありません。OSのクリップボードAPI、画面操作、別プロセスへのアクセスを通じた取得を防ぐ境界として、保存時暗号化やCLIの機能制限を扱わないでください。同梱スキルは、別の方法で履歴を取得する回避手段も使わないよう案内しています。

## 操作ごとに削除されるデータが異なります

| 操作 | 削除されるもの | 残るもの |
| --- | --- | --- |
| メニューの「履歴を消去」 | 履歴のデータベース行、保存したクリップ、サムネイル | テンプレート、設定、現在のクリップボード |
| 保存件数や保存期限による自動整理 | 条件に該当した履歴と対応ファイル | それ以外の履歴、テンプレート、設定 |
| 設定の「Panic」 | 履歴、テンプレート、設定、保存鍵、現在のクリップボード | Mac上の無関係なファイルや独立したバックアップ |

### 履歴だけを消去する

1. Revclipのメニューで「履歴を消去」を選びます。
2. 確認が表示された場合は「消去」を選びます。

**確認結果:** それまでの履歴がメニューから消え、テンプレート・設定・現在のクリップボードは残ります。

Revclipは監視を止め、処理中のコピー保存を待ってから履歴のデータベース行と対応ファイルを削除し、監視を再開します。再開後のコピーは現在の設定に従って記録されます。

自動整理は、保存件数の上限を超えたときや保存期限を過ぎたときに対象の履歴を削除します。整理は非同期です。コピーが続く場合は最初のコピーから約5秒後に実行し、アプリ起動時、関連設定の変更時、30分ごとにも実行します。ファイル削除に失敗した場合、孤立ファイルの整理で再試行することがあります。

履歴のデータベース行は削除され、SQLiteの `secure_delete`、incremental vacuum、WAL checkpointによる保守も行います。ただし、データベースのファイルサイズだけでは残っている履歴件数を判断できません。通常の削除で、別途作られたバックアップやスナップショット、SSD上の痕跡まで消去できるとは限りません。旧版の平文バックアップも後から暗号化されません。

### Revclipのデータをまとめて消去する

「Panic」は取り消せません。履歴のほか、テンプレート・設定・保存鍵も削除し、macOSで共有されている現在のクリップボードを空にして、成功後にRevclipを終了します。クリップボードを空にすると、ほかのアプリにも影響します。

1. 「設定」から「Panic」を開きます。
2. 入力欄に `Panic` と入力します。
3. 「Revclipの全データを削除」をクリックし、確認画面で「Revclipのデータを削除して終了」を選びます。
4. 削除に成功するとRevclipが終了します。

<!-- block: callout tone=danger -->
> 削除未完了の警告が表示された場合、記録は停止したままで、一部のデータがすでに削除されている可能性があります。表示に従って、終了する前に削除をもう一度試してください。成功を確認できない場合は、すべて消去できたと判断しないでください。Panicを実行しても、独立したバックアップ、APFSスナップショット、SSD上の残存データまで消去できる保証はありません。

## バグ報告は送信内容を確認してから送ります

設定の「不具合報告」フォームでは、入力した内容と、明示的に同意した送信元情報を送ります。

| 情報の種類 | 含まれる内容 |
| --- | --- |
| 入力した内容 | 件名、説明、任意の連絡先 |
| 接続元 | IPアドレス、地域、ネットワーク情報 |
| アプリと環境 | 言語、タイムゾーン、アプリとmacOSのバージョン、User-Agent |

報告はCloudflareを経由して開発者のTelegramグループへ送られ、両サービスで処理されます。

1. 「設定」から「バグ報告」を開き、問題の概要と再現手順を入力します。
2. 連絡先を送る必要がある場合だけ入力します。件名・説明・連絡先に、履歴の実データ、パスワード、認証情報を含めないでください。
3. 送信元情報の同意文を読み、送信に同意する場合だけチェックを入れて送信します。チェックを入れないと送信できません。

CLIから報告する場合も、送信元情報への同意を表す `--consent-source-info` が必須です。報告フォームやCLIは、履歴・テンプレート・クリップボード・ログ・スクリーンショットを自動添付しません。報告文へ自分で貼り付けた情報は送られるため、秘密を含めないでください。

成功応答が表示されたら、報告の送信処理は完了です。

成功応答より先にタイムアウトしても、報告が届いている場合があります。自動再送はありません。送信状態を確認してから、必要に応じて次の報告を送ってください。

## 困ったとき

- コピーが履歴に残った場合は、「除外アプリ」に対象が登録されているか、コピー時にそのアプリが最前面だったかを確認します。すでに記録された履歴は、メニューの「履歴を消去」で削除できます。
- 履歴を消した後もデータベースのファイルサイズが変わらない場合、そのサイズだけで削除の成否や履歴件数を判断できません。バックアップやスナップショットが別に残る場合もあります。
- 保存鍵をキーチェーンから削除すると既存データを復号できません。復旧目的で鍵や保存ファイルを手作業で変更せず、[トラブルシューティング](11-troubleshooting.md)を確認してください。
- Panicで削除未完了と表示された場合は、記録が停止したままです。画面の案内に従って再試行し、解決しない場合は実データや鍵を含めずに[サポートへの連絡方法](12-updates-and-feedback.md)を確認してください。

## 関連ページ

- [履歴と貼り付け](04-history-and-paste.md)：保存する形式や履歴の再利用方法を確認します。
- [設定](07-settings.md)：除外アプリや保存件数・期限を調整します。
- [CLIリファレンス](09-cli-reference.md)：エージェント用CLIが扱うコマンドを確認します。
- [トラブルシューティング](11-troubleshooting.md)：履歴や権限、削除で困ったときの手順を確認します。
- [アップデートとフィードバック](12-updates-and-feedback.md)：更新の確認と同意付きバグ報告の手順を確認します。

<!-- 編集注: 出典
- README.md —「保存・削除・プライバシー」「CLIとAIエージェントからの操作」、0.1.9 / build 42の公開状況
- SECURITY.md —「保護するもの」「保護範囲の限界」「問題の報告」
- docs/TEMPLATE_CLI.md —「History deletion」「History access boundary」「Bug reports」
- docs/AGENT_SUPPORT.md —「Native app commands」「Checking and updating from Agent Settings」
- src/Revclip/Revclip/Services/RCStorageCipher.swift：prepare, databaseKey, encrypt, decrypt, deriveKey, loadKeychainRootKey, keychainQuery, deleteKey
- src/Revclip/Revclip/Managers/RCDatabaseManager.m：deleteAllClipItems, trimClipItemsToLimit, enableSecureDeleteForDatabase, configureIncrementalAutoVacuumForNewDatabase
- src/Revclip/Revclip/Services/RCDataCleanService.m：scheduleDebouncedCleanup, performCleanupOnCleanupQueue
- src/Revclip/Revclip/Managers/RCMenuManager.m：履歴消去の確認と実行
- src/Revclip/Revclip/Services/RCPanicEraseService.m：executePanicEraseWithCompletion:, deleteDatabaseFilesForManager:, finishPanicEraseFailureWithCompletion:
- src/Revclip/Revclip/Services/RCClipboardService.m：startMonitoring, acquireSnapshotForcingRead:, readEligibleClipFromPasteboard:sourceBundleIdentifier:
- src/Revclip/Revclip/Services/RCPrivacyService.m：shouldCaptureClipboardContentsForAccessState:, resolvedClipboardAccessState
- src/Revclip/Revclip/Services/RCExcludeAppService.m：shouldExcludeAppWithBundleIdentifier:, frontmostApplicationBundleIdentifier
- src/Revclip/RevclipCLI/main.m：RCHelp, RCRequest
- src/Revclip/Revclip/Services/RCSnippetCLIService.m：executeRequest:, executeBugReportRequest:, serveClient:
- src/Revclip/Revclip/Services/RCBugReportService.m：sourceMetadata, submitTitle:description:contact:consent:completion:
- src/Revclip/Revclip/UI/Preferences/RCBugReportPreferencesViewController.m：同意チェック初期値、送信可否の判定
- src/Revclip/Revclip/UI/Preferences/RCPanicPreferencesViewController.m：eraseButtonClicked:
- src/Revclip/Revclip/Resources/ja.lproj/Localizable.strings：除外アプリ、履歴を消去、Panicの表示
- agents/AgentSupport/revclip/SKILL.md：履歴取得の境界と回避手段の禁止
-->
