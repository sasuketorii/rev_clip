# CMS登録とDemo日本語テンプレート追加の記録

実施日: 2026-09-17（日本時間）。対象原稿はRevclip 0.1.9（build 42）。

## CMS登録

CMSの日本語Docsへ13ページを登録しました。既存の入口ID 92を更新し、12章をその子ページとして追加しました。CMS上は `published`、翻訳状態は `approved`、公開言語は `ja` です。続くユーザーの承認を受け、サイトのデプロイと配信確認まで実施しました。

| ページ | CMS ID | 公開経路 |
| --- | --- | --- |
| [00-index.md](00-index.md) | 92 | `/docs/revclip` |
| [01-overview.md](01-overview.md) | 93 | `/docs/revclip/overview` |
| [02-installation.md](02-installation.md) | 94 | `/docs/revclip/installation` |
| [03-quick-start.md](03-quick-start.md) | 95 | `/docs/revclip/quick-start` |
| [04-history-and-paste.md](04-history-and-paste.md) | 96 | `/docs/revclip/history-and-paste` |
| [05-previews-and-file-copy.md](05-previews-and-file-copy.md) | 97 | `/docs/revclip/previews-and-file-copy` |
| [06-templates.md](06-templates.md) | 98 | `/docs/revclip/templates` |
| [07-settings.md](07-settings.md) | 99 | `/docs/revclip/settings` |
| [08-agent-setup.md](08-agent-setup.md) | 100 | `/docs/revclip/agent-setup` |
| [09-cli-reference.md](09-cli-reference.md) | 101 | `/docs/revclip/cli-reference` |
| [10-privacy-and-security.md](10-privacy-and-security.md) | 102 | `/docs/revclip/privacy-and-security` |
| [11-troubleshooting.md](11-troubleshooting.md) | 103 | `/docs/revclip/troubleshooting` |
| [12-updates-and-feedback.md](12-updates-and-feedback.md) | 104 | `/docs/revclip/updates-and-feedback` |

## 確認したこと

- 認証なしのCMS公開APIで全13件を取得し、登録用データと本文が一致することを確認。
- 全12章の親がID 92であること、版・公開状態・公開言語を確認。
- リンク112本を抽出し、Revclip内の経路が登録したページへ対応することを確認。
- 既存サイトのschemaで表35個・注意枠27個・コード枠18個を検証。実際のLexical変換処理で本文ブロックと目次107項目を生成。
- Markdownの `sh` はCMSが受け付ける `bash` へ変換。コード本文は保持。表・注意枠内のリンクは直後のクリック可能な関連リンクとして維持。
- 編集コメントとfrontmatterを掲載本文から除外。元のローカルMarkdownは維持。
- 記事用lintの箇条書き比率警告が導入・クイックスタート・トラブル対処の3章に残る。いずれも操作手順であり、手順を文章へ崩す対象とは判断していない。ほかの検出事項は修正済み。

## Demo版の日本語テンプレート（初回登録）

`revclip-demo` のみに、次の3フォルダ・15件を追加しました。既存の英語フォルダは残しています。全件をCLIで読み戻し、タイトルと本文の一致を確認しました。履歴と現在のクリップボードの取得、通常版の変更は行っていません。

| フォルダ | テンプレート |
| --- | --- |
| 日本語・メール | お問い合わせへの返信、日程調整、資料送付、受領のお礼、確認のお願い |
| 日本語・業務連絡 | 進捗報告、議事録、作業依頼、不具合報告、引き継ぎ |
| 日本語・AIへの依頼 | 文章を読みやすく整える、要点と次の行動を整理する、実装を依頼する、レビューを依頼する、Revclipにテンプレートを登録する |

## 日本語Demoの訂正

初回の日本語15件は、ユーザーが求めていた英語Demoの日本語版とは異なる内容でした。2026-09-17に提供された元CSVを使い、日本語5フォルダー・58件へ置き換えました。英語59件は維持しています。元データ、メールの書式、確認結果は [日本語Demoデータ](../../../assets/demo/ja/README.md) に記録しています。

## サイトの公開確認

ユーザーの「デプロイしていいよ」という承認を受け、2026-09-17（日本時間）に公開しました。

- 公開先: [Revclip ドキュメント](https://company.rev-c.com/docs/revclip)
- Worker: `revc-website`
- 配信Version ID: `f6d5d786-9c76-4de9-895f-9458a521ca37`
- ビルド日時（UTC）: `2026-09-16T16:08:52.039Z`
- 直前の配信Version ID: `d4da3d1b-40d7-4a1e-9b1e-cc3ab802bff8`
- 前回公開時の配布用コピーが現行配信物と一致することを確認し、隔離コピーから集約スクリプト `pnpm run deploy` を実行。作業中のサイトcheckoutの未コミット変更は取り込んでいません。
- 公開HTMLが参照するアセット27件を、手元のビルドとバイト単位で照合。
- Revclip全13ページの公開HTMLを手元のビルドとバイト単位で照合し、対象バージョン0.1.9の掲載を確認。既存のRevclip紹介ページも照合。
- ブラウザのDOMで入口の12章へのリンク、表、目次を確認。デスクトップ幅でページ全体の横はみ出しなし。

日本語だけの見出しが空のHTML IDになる既存不具合を修正しました。英数字を含む従来のIDは維持し、日本語だけの場合は本文と目次で同じIDを使います。属性値のエスケープも維持し、4件の回帰検証に合格。全13ページの見出しリンクの解決を確認し、公開CLIページでもリンク切れ0件・表8個・コード枠9個をDOMで確認しました。

再配信直後には4つのアセットが一時的に404を返しました。直後の再検証では27件すべてがバイト一致し、全13ページも最終ビルドと一致しました。

配布用コピーのlockfileだけでは、前回実際に使われた `media-chrome` 依存を再現できませんでした。今回は前回ビルドの依存フォルダーを隔離先へコピーして、同じ依存でビルドしています。サイト全体のlockfileと実依存の整合は、この文書公開とは別の未解決事項です。

## 未確認事項

ブラウザのスクリーンショット取得はタイムアウトし、画像による目視確認は未完了です。狭い画面の表示、コードのクリップボードへの実コピー、Demoの貼り付け操作テストも実施していません。CMS登録・配信確認と、これらの操作確認を区別します。
