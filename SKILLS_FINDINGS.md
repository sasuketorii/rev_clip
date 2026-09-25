# Skills findings

## 2026-09-25 FIRST-RUN-S1

`rev_skills`の `codebase-graph-discovery` を使用。現行wrapperは `current` のv0.11.0へ解決した。Revclipのindexは部分解析96ファイル、全体解析失敗1ファイルを報告。権限設定のinbound traceは設定画面の1件のみで、同ファイル内のOCR許可アラートからの呼出を列挙しなかった。exit 4 (`edge_evidence_unverified`, `language_not_evaluated`) であり、Swiftの完全な呼出一覧として採用しない。

Swift用SourceKit経路の手順は `swift build` とSwiftPMのindexを前提としており、このXcodeGen/Objective-C混在プロジェクトでの利用は未検証。スキルのSwift「採用」は他プロジェクトの実績であり、本プロジェクトの完全性を保証しない。実ソースと `rg` で両導線を確認した。
