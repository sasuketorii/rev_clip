---
title: 設定を使い方に合わせる
description: Revclip開発版の設定画面で履歴、外観、メニュー、ショートカットなどを変更する手順を説明します。
slug: 'revclip/settings'
navOrder: 7
productArea: revclip
docVersion: 'development'
status: draft
verifiedAt: '2026-09-18'
---

# 設定を使い方に合わせる

「設定」では、履歴の保存方法やメニューの見え方、起動時の動作を変更できます。開発版ではサイドバーを一般・外観・ショートカット・faster OCR・プライバシー・アップデート・高度な設定に整理しています。

「高度な設定」の上タブでメニュー、保存形式、エージェント連携、緊急消去、バグ報告を切り替えます。「プライバシー」の上タブにはリンク取得、除外アプリ、権限状態があります。保存済みの設定はそのまま引き継ぎます。

リンク取得の既定は自動です。手動取得では⌥を押しながらリンクへカーソルを合わせたときだけサイトに接続します。「自動で取得」はメニュー表示・ホバーでも取得し、「取得しない」は進行中の処理を中止してキャッシュも消去します。

## 設定を開いて変更する

1. メニューバーのRevclipアイコンをクリックします。
2. メニューから「設定...」を選びます。
3. 左側の一覧で変更したいページを選びます。
4. トグル、数値欄、ポップアップ、ショートカット欄を変更します。
5. 設定画面を閉じて、必要な操作を行い、結果を確かめます。

通常の設定は変更時に保存され、保存ボタンはありません。言語は変更後すぐにアプリの表示へ反映されます。メニューの色や並びは、履歴メニューを開き直すと確認できます。エージェント設定のインストール、不具合報告の送信、Panicの削除は通常の設定変更とは異なり、利用者が明示的に実行します。

**期待する結果:** 設定ページを開き直したときに選んだ値が残っています。保存件数や期限を変えた場合は、通常の履歴整理が非同期で進むため、件数がすぐに変わらないことがあります。

## 一般では履歴の扱いと起動動作を変える

「一般」では履歴の保存上限、期限、ペースト、言語などを調整します。

| 項目 | 変更するとどうなるか | 既定値・範囲 |
| --- | --- | --- |
| 履歴の最大保存数 | 上限を超えた古い履歴を整理します。保存件数はメニュー上の表示件数とは別です。 | 30件、1〜9,999件 |
| 古い履歴を自動削除 | 有効にすると、指定した期間を超えた履歴を整理します。単位は日・時間・分です。 | 無効、30日 |
| ログイン時に起動 | macOSのログイン項目としてRevclipを登録します。登録できない場合は画面の案内に従ってください。 | 有効 |
| ステータス項目の表示 | メニューバーのRevclipアイコンを表示または非表示にします。 | 表示 |
| ペーストコマンド | 履歴項目を選んだ後、前のアプリへ自動ペーストする動作を切り替えます。無効にした場合は貼り付け先で⌘Vを押します。自動ペーストにはアクセシビリティ権限が必要です。 | 有効 |
| ペースト後に並び替え | 履歴から使った項目を新しい位置へ移動するかを切り替えます。 | 有効 |
| 同一履歴を上書き | 同じ内容をもう一度コピーしたとき、既存履歴の更新順を新しくします。 | 有効 |
| 同一履歴をコピー | 設定値は保存されますが、0.1.9の実装ではこの値を参照する操作処理を確認できません。切り替えによる効果は案内していません。 | 有効 |
| アプリの言語 | アプリの表示言語を選びます。「システムに従う」ではmacOSの優先言語を使います。履歴やテンプレート本文は翻訳しません。 | システムに従う |

保存数を下げたり、短い期限を有効にしたりすると、条件に合う履歴が削除されます。削除済みの履歴はRevclip内には戻せません。別のバックアップやmacOSのスナップショット、SSD上の残存データまで消える操作ではありません。

<!-- block: callout tone=warning -->
> 保存件数や期限の変更は履歴そのものに影響します。メニューに表示する件数だけを変えたい場合は「メニュー」を調整してください。

## 外観ではテーマとメニューの色を選ぶ

テーマは「システムに従う」「ライト」「ダーク」から選びます。既定はシステム設定に従う表示です。メニューの色をカスタマイズすると、履歴とテンプレートのメニューに使う通常時のアイコン・文字・背景色と、選択時の文字・背景色を指定できます。設定画面とテンプレート編集画面の色は変わりません。

1. 「外観」で「メニューの色をカスタマイズ」を有効にします。
2. 色見本を押してカラーパネルから選ぶか、HEX欄へ6桁の値を入力します。`#` は省略できます。
3. ライト表示とダーク表示でそれぞれ色を確認します。
4. 既定の色へ戻すときは「メニューの色をリセット」を押します。カスタム色を消去し、カスタマイズを無効にします。

通常時のアイコンはプライマリ色、ホバー時のアイコンはホバーテキスト色に揃います。既存の透過とぼかしは維持されます。

カスタム色は既定で無効です。ライト用とダーク用の色は別に保存されます。色の変更は次にメニューを開いたときに確認できます。

## メニューでは履歴の並びと補助表示を整える

「メニュー」の設定は表示方法に関するものです。履歴そのものの保存数を変えません。

| 項目 | 変更するとどうなるか | 既定値・範囲 |
| --- | --- | --- |
| インライン表示の項目数 | 履歴をフォルダにまとめる前に、メニュー直下へ表示する件数を指定します。0なら直下には表示しません。 | 0件、0〜99件 |
| フォルダ内の項目数 | まとめた履歴を1つのサブメニューに表示する件数です。 | 10件、1〜99件 |
| タイトルの最大文字数 | 履歴メニューに表示するタイトルの長さを調整します。 | 40文字、1〜200文字 |
| 番号を表示 | 履歴項目へ順番の番号を表示します。 | 有効 |
| 0から番号を開始 | 項目番号を0から始めます。「番号を表示」が有効なときに使えます。 | 無効 |
| 数字キーのショートカットを追加 | 数字キーで履歴項目を選ぶための割り当てを追加します。 | 無効 |
| 履歴消去の項目を追加 | メニューに履歴消去の項目を表示します。 | 有効 |
| 消去前に確認を表示 | 履歴消去の前に確認を表示します。履歴消去項目が有効なときに使えます。 | 有効 |
| ツールチップを表示 | 履歴項目にポインタを合わせたときの補足表示を切り替えます。 | 有効 |
| ツールチップの最大長 | ツールチップの表示長を調整します。 | 10,000文字、1〜10,000文字 |
| 画像プレビューを表示 | 履歴メニュー内の画像プレビューを表示します。 | 有効 |
| サムネイルの幅・高さ | メニュー内の画像サムネイルの大きさを調整します。 | 幅100、高さ32、各16〜512 |
| カラープレビューを表示 | 色として認識された項目の色見本を表示します。 | 有効 |
| アイコンを表示 | 履歴項目のアイコンを表示します。 | 有効 |
| アイコンのサイズ | メニュー内アイコンの大きさを調整します。 | 16、8〜64 |

## 種類では履歴に記録する形式を選ぶ

「種類」では、Revclipが履歴として記録するクリップボード形式を選びます。コピー元が提供する形式はアプリによって異なるため、形式を有効にしてもコピー元や貼り付け先が提供・受理しないデータまでは作れません。

| 形式 | 既定値 |
| --- | --- |
| プレーンテキスト | 有効 |
| リッチテキスト（RTF） | 有効 |
| 添付付きリッチテキスト（RTFD） | 有効 |
| HTML | 有効 |
| PDF | 有効 |
| ファイル名 | 有効 |
| URL | 有効 |
| 画像（TIFF） | 有効 |

## 除外アプリでは記録したくないアプリを登録する

除外アプリに一致すると、監視時にそのアプリが前面にある場合はコピーを記録しません。既定の除外リストは空です。

1. 「除外アプリ」で「＋」を押し、アプリケーションを選びます。
2. または、対象アプリを前面にしてからRevclipへ戻り、「現在のアプリを追加」を押します。
3. 登録を外すときは一覧からアプリを選び、「−」を押します。

追加後、対象アプリが前面にあるときの新しいコピーが履歴に入らないことを確かめます。除外を追加しても、すでに保存されている履歴は削除されません。判定は監視時点の前面アプリに基づくため、コピーの直後に別アプリへ切り替えると、コピー元と一致しない場合があります。機密情報を確実に見分ける機能ではありません。

## ショートカットは設定画面でキーを入力して変更する

「ショートカット」では、各入力欄を選んでキーの組み合わせを押します。設定CLIからは変更できません。既定の割り当ては次のとおりです。

| 操作 | 既定のショートカット |
| --- | --- |
| メインメニューを開く | ⌘⇧V |
| 履歴メニューを開く | ⌘⌃V |
| テンプレートメニューを開く | ⌘⇧B |
| 履歴を消去 | 割り当てなし |

「デフォルトにリセット」を押すと確認が表示されます。確定すると、メイン・履歴・テンプレートの3つを既定値へ戻し、履歴消去のショートカットを解除します。CLIでショートカットを指定すると拒否されます。CLIで変更できる設定の範囲は[CLIリファレンス](09-cli-reference.md)を参照してください。

## アップデートでは確認頻度を選ぶ

「アップデート」では自動確認の有効・無効と頻度を選べます。自動確認は既定で有効、間隔は毎日です。頻度は毎日、毎週、毎月から選択できます。「今すぐ確認」を押すと手動で更新を確認します。確認にはネットワークを使います。表示されるバージョン情報は現在起動しているアプリのものです。

## エージェント設定は確認と手動インストールを分ける

「エージェント設定」を開くか「再確認」を押すと、対応するエージェントのスキル登録状態と更新有無を読み取ります。この確認だけではファイルを書き換えません。

スキルを登録または更新するには、画面のセットアップ用プロンプトをコピーし、対応エージェントで実行します。管理対象と確認できないファイルや、利用者が編集したファイルは上書きせず、競合として報告します。対応先や結果の読み方は[エージェント設定](08-agent-setup.md)を参照してください。

## 不具合報告は内容を確認してから送信する

「不具合報告」では、件名（必須、120文字まで）、説明（必須、2,500文字まで）、任意の連絡先（200文字まで）を入力します。送信元情報の共有に同意し、送信ボタンを押した場合にだけ報告を送ります。報告はCloudflare経由でサポートチームのTelegramグループへ送信されます。

同意した場合、送信元のIPアドレス、おおよその地域、ネットワーク事業者（ASN）、アプリとmacOSのバージョン、言語、タイムゾーンも含まれます。クリップボード、履歴、ログ、スクリーンショットは自動添付されません。入力文は外部サービスで処理されるため、パスワードや認証情報、実際のクリップ内容を書かないでください。送信先と扱いの詳細は[プライバシーとセキュリティ](10-privacy-and-security.md)を確認してください。

## PanicはRevclipのデータ全体を削除する

<!-- block: callout tone=danger -->
> **Panicは取り消せません。** 履歴だけを消したい場合は、通常の履歴消去を使ってください。PanicはRevclipの履歴、テンプレート、設定、保存鍵を削除し、macOSで共有する現在のクリップボードを空にしてからアプリを終了します。

実行する場合は、「Panic」入力欄へ `Panic` と入力し、削除ボタンを押して確認ダイアログで確定します。Mac上の他のファイルは削除対象ではありません。削除に失敗した場合は一部のデータがすでに消えている可能性があります。完了したと判断せず、画面に表示される再試行の案内に従ってください。

## 設定の値や効果を確認できないとき

- 数値欄が変更できない場合は、関連する設定が無効になっていないか確認します。たとえば期限の値は自動削除を有効にしたときに変更できます。
- ログイン時起動が有効にならない場合は、Revclipの画面に出る案内を確認し、必要ならmacOSの「システム設定」の「ログイン項目」で状態を確認します。
- メニューバーのアイコンを非表示にした後で設定へ戻るには、「ショートカット」で割り当てたメインメニューの組み合わせ（既定は⌘⇧V）でメニューを開き、「設定...」を選びます。
- コピーが履歴に入らない場合は、「種類」と「除外アプリ」を確認してください。前面アプリの切り替えや500msの観測間隔により、すべてのコピーを記録できるとは限りません。
- ショートカットはアプリの設定画面で変更します。CLIでは登録・変更できません。CLIで読み書きできるのは許可された設定値で、コピー履歴や現在のクリップボードを読むコマンドはありません。このAPI制限は、同じOSユーザー権限を持つ別プログラムやmacOSのクリップボードAPIまで隔離するものではありません。保護範囲は[プライバシーとセキュリティ](10-privacy-and-security.md)で確認できます。
- 更新確認で問題が出る場合は、[更新と不具合報告](12-updates-and-feedback.md)を参照してください。

## 関連ページ

- [Revclipについて](01-overview.md)
- [エージェント設定](08-agent-setup.md)
- [CLIリファレンス](09-cli-reference.md)
- [プライバシーとセキュリティ](10-privacy-and-security.md)
- [トラブルシューティング](11-troubleshooting.md)
- [更新と不具合報告](12-updates-and-feedback.md)

<!--
編集注: 出典はすべてrepo相対パス。

説明書: README.md「設定画面」「メニューの色をカスタマイズ」「対応言語」「コピー履歴と保存形式」「保存・削除・プライバシー」; SECURITY.md「エージェントとCLIの境界」「保護範囲の限界」「問題の報告」; docs/TEMPLATE_CLI.md「Preferences CLI」「History access boundary」「Bug reports」; docs/AGENT_SUPPORT.md「Checking and updating from Agent Settings」; agents/AgentSupport/revclip/SKILL.md「Preferences and app actions」。

設定カテゴリと実装: src/Revclip/Revclip/UI/Preferences/RCPreferencesWindowController.m `tabIdentifiers`, `titleForTabIdentifier:`; src/Revclip/Revclip/Utilities/RCUtilities.m `registerDefaultSettings`; src/Revclip/Revclip/UI/Preferences/RCGeneralPreferencesViewController.m `applyPreferenceValues`, `arrangeSettingsPage`; src/Revclip/Revclip/UI/Preferences/RCMenuPreferencesViewController.m `arrangeSettingsPage`; src/Revclip/Revclip/UI/Preferences/RCTypePreferencesViewController.m `isStoreTypeEnabledForKey:`; src/Revclip/Revclip/UI/Preferences/RCShortcutsPreferencesViewController.m `defaultKeyComboForDefaultsKey:`, `resetHotKeysToDefaults`; src/Revclip/Revclip/UI/Preferences/RCUpdatesPreferencesViewController.m `loadUpdateSettings`, `checkNowClicked:`; src/Revclip/Revclip/UI/Preferences/RCExcludePreferencesViewController.m `addApplication:`, `addCurrentApplication:`, `removeApplication:`; src/Revclip/Revclip/UI/Appearance/RCAppearanceController.swift `AppearancePreferencesView`, `MenuColorPreferences`; src/Revclip/Revclip/UI/Preferences/RCAgentPreferencesViewController.m `copyPrompt:` and inspection path; src/Revclip/Revclip/UI/Preferences/RCBugReportPreferencesViewController.m `loadView`, `sendReport:`; src/Revclip/Revclip/UI/Preferences/RCPanicPreferencesViewController.m `eraseButtonClicked:`.

CLI・動作境界: src/Revclip/Revclip/Services/RCSettingsCLIService.m `RCSettingsDefinitions`; src/Revclip/RevclipCLI/main.m `history_readable`, `clipboard_readable`, `RCUsageRequire`; src/Revclip/Revclip/Services/RCClipboardService.m `kRCClipboardPollingInterval`; src/Revclip/Revclip/Managers/RCMenuManager.m `appendApplicationSectionToMenu:`, `appendClipItems:`, `menuBaseTitleForClipItem:`.

保存と削除: src/Revclip/Revclip/Services/RCLoginItemService.m `loginItemStatus`, `setLoginItemEnabled:`; src/Revclip/Revclip/Services/RCExcludeAppService.m `shouldExcludeCurrentApp`, `excludedBundleIdentifiers`, `setExcludedBundleIdentifiers:`; src/Revclip/Revclip/Services/RCUpdateService.m `automaticallyChecksForUpdates`, `updateCheckInterval`; src/Revclip/Revclip/Services/RCPanicEraseService.m `executePanicEraseWithCompletion:`.

UIラベル: src/Revclip/Revclip/Resources/ja.lproj/Localizable.strings; src/Revclip/Revclip/Resources/ja.lproj/RCGeneralPreferencesView.strings; src/Revclip/Revclip/Resources/ja.lproj/RCTypePreferencesView.strings; src/Revclip/Revclip/Resources/ja.lproj/RCShortcutsPreferencesView.strings; src/Revclip/Revclip/Resources/ja.lproj/RCUpdatesPreferencesView.strings。

既知の制約: 一般の「同一履歴をコピー」はUI・CLIの保存処理と既定値のみ確認でき、操作側で値を利用する経路は確認できない。本文に制約として明記。今回の文書作成では製品挙動は変更していない。
-->
