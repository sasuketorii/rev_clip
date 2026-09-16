---
title: Revclipをインストールする
description: 公開DMGを使ってRevclipを導入し、自動ペーストに必要なアクセシビリティ許可を設定します。
slug: revclip/installation
navOrder: 2
productArea: revclip
docVersion: '0.1.9'
status: draft
verifiedAt: '2026-09-16'
---

# 公開DMGからRevclipをインストールする

RevclipはmacOS 14以降で動作します。配布DMGにはApple Silicon用とIntel用を含むUniversalアプリが入っています。インストールにXcodeやPythonは必要ありません。

## DMGをダウンロードしてアプリケーションへコピーする

1. [Revclipの公開リリース](https://github.com/sasuketorii/rev_clip/releases/latest)を開き、最新リリースのDMGをダウンロードします。本文の対象版は0.1.9（build 42）です。
2. ダウンロードしたDMGを開きます。
3. DMG内のRevclipをMacの「アプリケーション」フォルダへコピーします。
4. コピーが終わったらDMGを取り出します。
5. 「アプリケーション」からRevclipを起動します。

公開DMGはDeveloper IDで署名され、Appleの公証を受けています。必ず上記の公開リリースから入手した配布物を使ってください。

## 自動ペーストを使う場合だけアクセシビリティを許可する

Revclipで履歴項目を選ぶと、まず内容がmacOSのクリップボードへ戻ります。選んだ内容を元のアプリへ自動で貼り付ける場合は、Revclipにアクセシビリティ許可を与えます。

1. macOSの「システム設定」を開きます。
2. 「プライバシーとセキュリティ」から「アクセシビリティ」を開きます。
3. Revclipを許可します。
4. Revclipへ戻り、[最初のコピーを履歴から使います](03-quick-start.md)。

アクセシビリティ許可を与えない場合も、履歴から項目を選んだ後、貼り付け先アプリで⌘Vを押して使えます。許可の変更はmacOSの設定画面で行ってください。

<!-- block: callout tone=info -->
> アクセシビリティ許可は自動で⌘Vを送るために使います。履歴内容をクリップボードへ戻す操作とは別です。許可を与えるかどうかは、使い方に合わせて選んでください。

## インストール後の状態を確認する

Revclipはメニューバーアプリです。起動するとメニューバーから開けるようになり、既定の⌘⇧Vでメインメニュー、⌘⌃Vでテンプレートを含まない履歴メニューを開けます。ショートカットが他のアプリと重なる場合は、Revclipの「設定 → ショートカット」で変更できます。

自動ペーストを許可している場合は、コピー履歴から項目を選ぶと、設定された動作に応じて貼り付け先へ⌘Vが送られます。許可していない場合は、選んだ項目がクリップボードへ戻るので、貼り付け先で⌘Vを押します。

## 困ったとき

<!-- block: dataTable -->
| 状況 | 確認すること |
| --- | --- |
| ダウンロードしたDMGが開かない | 公開リリースからDMGをダウンロードし直し、macOS 14以降であることを確認します。 |
| メニューバーに見当たらない | Revclipを起動し直し、設定でステータス項目を非表示にしていないか確認します。ショートカット⌘⇧Vでも開けます。 |
| ⌘⇧Vが反応しない | 他のアプリとのショートカット競合を避けるため、Revclipの「設定 → ショートカット」で割り当てを変更します。 |
| 選んでも元のアプリへ貼り付けられない | 「設定 → 一般」の「ペーストコマンド」とmacOSの「プライバシーとセキュリティ → アクセシビリティ」を確認します。手動で貼る場合は貼り付け先で⌘Vを押します。 |

## 関連ページ

- [ドキュメント一覧](00-index.md)
- [Revclipについて](01-overview.md)
- [クイックスタート](03-quick-start.md)
- [設定](07-settings.md)
- [トラブルシューティング](11-troubleshooting.md)

<!-- 編集注: 出典: README.md「はじめる」「基本操作」; docs/RELEASING.md「配信先」; docs/QUALITY_REPORT.md「v0.1.9公開・更新配信の確認」; src/Revclip/Revclip/Info.plist (CFBundleShortVersionString, CFBundleVersion, NSAccessibilityUsageDescription); src/Revclip/Revclip/Managers/RCMenuManager.m (setupStatusItem, applyStatusItemPreference); src/Revclip/Revclip/Services/RCHotKeyService.m (registerHotKeyWithCombo:, default main/history combos); src/Revclip/Revclip/Services/RCPasteService.m (performWrite:toApplication:historyDataHash:, sendPasteKeyStroke). -->
