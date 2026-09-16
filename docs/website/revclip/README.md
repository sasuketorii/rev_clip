# Revclip サイト向けドキュメント原稿

company.rev-c.com の `/docs/revclip` 向けに準備する日本語原稿です。まずローカルMarkdownで内容を確定し、サイトの既存Content Blocksへ移すための編集情報を併記します。

- 対象公開版: **Revclip 0.1.9 / build 42**
- 製品ソース: `ae00ec899deb0c75003427f7f85597f0dd2715f8`
- 文書・ライセンス確認元: `7ba829dda850c3bd69add357d0f292c402a3c853`
- 原稿状態: **全13ページの原稿作成・ソース照合・CMS登録済み**。サイトへのデプロイと全13ページの配信確認も完了しました。
- 編集注とfrontmatterは掲載準備用です。読者向け本文として表示しません。

## 読者の目的と章構成

| 順番 | ページ | 読者ができるようになること | 掲載先案 |
| --- | --- | --- | --- |
| 0 | [00-index.md](00-index.md) | 目的別にガイドを選ぶ | `/docs/revclip` |
| 1 | [01-overview.md](01-overview.md) | 履歴とテンプレートの違い、対応環境、機能の範囲を把握する | `/docs/revclip/overview` |
| 2 | [02-installation.md](02-installation.md) | 配布アプリを導入し、必要な権限を設定する | `/docs/revclip/installation` |
| 3 | [03-quick-start.md](03-quick-start.md) | 最初のコピーから履歴の再利用まで試す | `/docs/revclip/quick-start` |
| 4 | [04-history-and-paste.md](04-history-and-paste.md) | 保存形式、並び順、自動・手動貼り付けを使い分ける | `/docs/revclip/history-and-paste` |
| 5 | [05-previews-and-file-copy.md](05-previews-and-file-copy.md) | 文章・画像・SVG・URLプレビューとFinderコピーの違いを理解する | `/docs/revclip/previews-and-file-copy` |
| 6 | [06-templates.md](06-templates.md) | 文章・画像テンプレートを整理し、移出入する | `/docs/revclip/templates` |
| 7 | [07-settings.md](07-settings.md) | 設定を目的に合わせて調整し、変更の影響を理解する | `/docs/revclip/settings` |
| 8 | [08-agent-setup.md](08-agent-setup.md) | スキルを導入・更新し、テンプレート管理をエージェントへ依頼する | `/docs/revclip/agent-setup` |
| 9 | [09-cli-reference.md](09-cli-reference.md) | 実在するCLIを対象アプリを明示して使う | `/docs/revclip/cli-reference` |
| 10 | [10-privacy-and-security.md](10-privacy-and-security.md) | 保存・暗号化・削除・エージェントのアクセス境界を理解する | `/docs/revclip/privacy-and-security` |
| 11 | [11-troubleshooting.md](11-troubleshooting.md) | 症状に応じて安全に切り分ける | `/docs/revclip/troubleshooting` |
| 12 | [12-updates-and-feedback.md](12-updates-and-feedback.md) | 更新を確認し、同意した情報だけで不具合を報告する | `/docs/revclip/updates-and-feedback` |

## 出典の優先順位

1. 現行の製品実装と配布構成。
2. ルートのREADME、SECURITY、`docs/TEMPLATE_CLI.md`、`docs/AGENT_SUPPORT.md`。
3. `docs/QUALITY_REPORT.md`の対象版と実測条件が一致する検証記録。
4. サイト既存部品のschemaとrenderer（見せ方の対応確認）。

LPの訴求文や過去の会話だけで機能・保証・性能を補いません。ソース上で確認できる仕様と、実機で確認済みの挙動を区別します。

## 執筆と掲載の境界

原稿ファイルは通常のMarkdownとして読める形にします。CMSへの自動投入データやHTMLを本文と混ぜません。章ごとの担当を分けて並列執筆し、統合時に表記・リンク・コマンド・機密情報・既知制約を確認します。

掲載部品とCMS移行時の対応は [PARTS-AND-PUBLISHING.md](PARTS-AND-PUBLISHING.md) を参照してください。ユーザーの追加承認を受け、サイトのデプロイも実施しました。

照合対象・検証方法・未実施範囲は [検証記録](VERIFICATION.md) にまとめています。

2026-09-17の[CMS登録とDemoテンプレート追加の記録](CMS-REGISTRATION.md)に、登録IDと読み戻し結果を記載しています。
