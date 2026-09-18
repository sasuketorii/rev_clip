# メニュー・プレビュー・配布の境界 — 2026-09-18

この文書はPR #2の世代管理修正と、その継続課題の現在の実装をまとめます。最初のLinux上のレビュー記録に代わる現行マップです。公開済み版と開発版の挙動を混同しないでください。再現手順と落とし穴は[開発引き継ぎ](DEVELOPMENT_HANDOFF.md)、配布の正規手順は[RELEASING](RELEASING.md)にあります。

## 所有箇所と守る契約

| 所有箇所 | 契約 | 回帰テスト |
| --- | --- | --- |
| `RCMenuManager` | 消去と結果反映を同じlock・generationで照合。古い結果は本文・色・Done・hoverへ再登録しない。I/Oとcallbackはlock外 | `RCMenuFallbackLifecycleTests` |
| `RCMenuManager` | 本文tooltip 512件/4 MiB、色文字列512件/1 MiB、判定/状態512件。別のin-flight集合で受付32件を制限し、NSCache evictionで重複読込を起こさない | 受付上限・状態/payload eviction・2,048個のunique payloadの解放検証 |
| `RCDataCleanService` → `RCMenuManager` | 保持期限/件数による削除後にmainで`historyRemoved`通知。削除対象の本文・画像・リンクcacheを無効化し表示世代を進める。無関係な完了済みcacheは保持 | `RCHistoryRetentionTests`、削除通知のcache無効化テスト |
| `RCLinkPreviewService` | 未設定は自動。無効/手動/自動をユーザーが選択。手動の暗黙要求は通信しない。無効化は進行中/待機要求を中止しcacheを消去。不正な設定値は無効扱い | `RCLinkPreviewServiceTests` |
| `RCFastPreviewController` | 手動取得はホバー中にOptionを押した行だけ。keyDown monitorには依存しない。非同期完了は世代と弱参照を検査 | `RCFastPreviewTests` |
| `RCPreferencesWindowController` | サイドバー9項目。高度な設定/プライバシーの子ページは上タブ。従来のページIDを維持し直接遷移を壊さない | `RCPreferencesSidebarTests` |
| `scripts/build-tools.json` | XcodeGen/Sparkleの版・公式URL・SHA-256の唯一の定義。Vendorの内容/実行属性/symlinkを公式配布物と照合 | `scripts/tests/test_build_provenance.py` |
| `.github/workflows/release.yml` | 署名と公開を別jobに分離。署名jobはcontents read、公開だけwrite。署名素材を片付けてからartifactを転送し、digestを検査 | actionlint、provenance tests、署名検証スクリプト |

## 問題の性質

PR #2で閉じた経路は、消去前に始めた非同期読込が消去後にメモリ内cacheへ戻る問題です。削除済みDB/ディスク履歴を復元する問題ではありません。同じhashの再要求では古い完了が新しいInFlightを上書きしないことも検証します。

継続課題ではテキストcacheの予算、受付上限、retention時の無効化を追加しました。`NSCache`のlimitはOSのeviction方針への指定であり、プロセスRSSの厳密な上限ではありません。2,048件の合成payloadのweak参照が解放される試験は、長時間実機soak、secure zeroization、Leaks、latency測定の代替ではありません。

リンク取得は外部サイトにIPアドレスやURLを伝えます。利用者の指定により開発版の既定は自動です。手動・無効への明示的な選択は保持します。一度の明示取得は他のURLを自動取得する許可になりません。取得済みのメモリcacheは手動モードでも再利用できます。自動取得へ切り替えるとメニュー/ホバーから取得します。

## 検証の読み方と残る受入

2026-09-18のmacOS開発環境でDebug全体394テストが成功し、その後追加した手動操作・churnを含む対象テストと、最適化Release全体396テストも成功しました。再レビュー後の対象62テストと、さらに追加した削除中の読込・URL所有者の配線/上限を含むメニュー13テストも成功しました。以後の変更の証拠は、同じcommitに対するローカルXCTest結果とWoodpeckerのpipelineを使用してください。以前のmainや公開版の成功を新しい差分の証拠に流用しません。

公式Sparkle 2.9.6との一致、固定XcodeGenの取得・実行、および既存の配布済みアプリに対する署名検証スクリプトは確認しました。変更した本番release workflowの公証・公開・Sparkle実更新の一連の動作は、本番リリースを実行するまで未検証です。

次の項目は実機受入/計測の範囲として残ります。対応コードがない「放置された既知バグ」と、未実施の環境検証を区別してください。

- Demoの日本語設定画面で高度な設定/プライバシーの切替とリンク無効化の反映を確認。メニュー追跡中の手動取得、通常コピー/OCRは利用者受入を継続。
- Intel実機、macOS 14、mixed-scale外部画面の確認。Universalコンパイル成功だけでは代替できません。
- 同条件でのmenu/hover latency、RSS/Allocations/Energyと長時間soak。性能改善の数値はまだ主張しません。
- 本番署名、公証、配信、更新のE2E。Demoの利用者確認後に実施します。

既存のM2 Air / 8 GBで通常操作・OCRに明確な体感退行がなかったという利用者確認は、以前の版についての記録です。この差分の実測とは扱いません。
