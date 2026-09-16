---
title: 最初のコピーを履歴から使う
description: 文章をコピーし、Revclipのメニューから選んで貼り付けるまでを確認します。
slug: revclip/quick-start
navOrder: 3
productArea: revclip
docVersion: '0.1.9'
status: draft
verifiedAt: '2026-09-16'
---

# コピーした文章を履歴から貼り付ける

Revclipをインストールしたら、機密情報ではない短いテスト文章で、コピー・履歴表示・貼り付けを順に確認できます。

## コピーから貼り付けまで進める

1. テキストエディタなどで、`Revclipのテスト`のような短い文章を入力して選択します。
2. ⌘Cでコピーします。コピー監視は既定で500ms間隔です。観測、データの読み込み、保存、画面表示にかかる時間は別に加わります。
3. ⌘⇧Vを押してメインメニューを開きます。履歴だけを開く場合は⌘⌃Vを使います。ショートカットを変更済みなら、メニューバーのRevclipアイコンから開けます。
4. 履歴の一覧から、今コピーしたテスト文章を選びます。
5. 自動ペーストが有効でアクセシビリティ許可もある場合は、元のアプリへ貼り付けられます。自動ペーストを使わない場合は、貼り付け先に戻って⌘Vを押します。

メインメニューには履歴とテンプレートが表示されます。履歴メニューはテンプレートを含みません。設定した履歴形式や除外アプリによっては、コピーした内容が記録されないことがあります。

<!-- block: callout tone=warning -->
> **表示のタイミング:** 0.1.9では、ショートカットからメニューを開いたときにコピーの取得・保存を待つよう改善されています。メニューバーアイコンから開いた場合は、行を選択しておらずサブメニューも開いていないときに、保存後に一覧が更新されます。0.1.9の実際の描画・貼り付け・連続操作を使った実機受入は完了していません。500msの観測前に上書きされたコピーを回収する保証もありません。

## 表示と貼り付けの結果を確認する

コピーした文章が履歴に現れ、選択後に同じ文章が貼り付け先へ入れば、基本の再利用を確認できています。自動ペーストを無効にしている場合は、選択時に内容がクリップボードへ戻るので、貼り付け先で⌘Vを押した後の文章を確認します。

Revclipの「設定 → 一般」で「ペーストコマンド」をオフにすると、以降は選択後に自分で⌘Vを押す運用になります。ショートカットを変える場合は「設定 → ショートカット」を開きます。

## 困ったとき

<!-- block: dataTable -->
| 症状 | 次に確認すること |
| --- | --- |
| 履歴が空のまま | コピー後に少し待ち、もう一度メニューを開きます。「設定 → 種類」でプレーンテキストが保存対象か、除外アプリにコピー元が含まれていないか確認します。 |
| 直前のコピーが見当たらない | 500msの観測より前に次のコピーで上書きされた可能性があります。機密情報ではない短い内容を1つだけコピーして再確認します。 |
| 選択しても貼り付けられない | 「設定 → 一般」の「ペーストコマンド」とアクセシビリティ許可を確認します。手動貼り付けでは、貼り付け先に戻って⌘Vを押します。 |
| ショートカットが開かない | メニューバーのRevclipアイコンから開き、他アプリとの競合があれば「設定 → ショートカット」で変更します。 |

## 関連ページ

- [ドキュメント一覧](00-index.md)
- [インストール](02-installation.md)
- [コピー履歴と貼り付け](04-history-and-paste.md)
- [プレビューとFinderのファイルコピー](05-previews-and-file-copy.md)
- [トラブルシューティング](11-troubleshooting.md)

<!-- 編集注: 出典: README.md「はじめる」「基本操作」「コピー履歴と保存形式」; docs/QUALITY_REPORT.md「0.1.9 (42) ユーザーテスト候補」(公開版のコピー直後表示修正と未完了の実機受入); src/Revclip/Revclip/Services/RCClipboardService.m (kRCClipboardPollingInterval, observePendingClipboardChangeWithCompletion:, readEligibleClipFromPasteboard:sourceBundleIdentifier:); src/Revclip/Revclip/Services/RCHotKeyService.m (main/history hot-key defaults); src/Revclip/Revclip/Managers/RCMenuManager.m (presentHistoryAfterClipboardSynchronization:, refreshStatusMenuAfterClipboardSynchronization:, capturePasteTargetApplication, selectClipMenuItem:); src/Revclip/Revclip/Services/RCPasteService.m (performWrite:toApplication:historyDataHash:, sendPasteKeyStroke); src/Revclip/Revclip/App/RCConstants.h (kRCPrefInputPasteCommandKey default). -->
