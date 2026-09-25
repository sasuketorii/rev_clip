# Harness findings

## 2026-09-25 FIRST-RUN-H1

既存のOCR回帰は合成画像の認識精度・コピー確定・取消を検証していたが、初回認識が10秒を越える場合のCoordinatorの期限を検証していなかった。通常の高速なMacだけでは初回初期化の失敗を見逃す。`RCOCRFirstRunTests`で時計と認識完了を制御し、12秒の初回成功、60秒超の取消、連打、遅延成功の破棄を検証する。

Debug全443件、最終関連25件、Python/ネイティブCLI 97件が成功。最終の配信検証は `docs/QUALITY_REPORT.md` に記録する。

## 2026-09-25 FIRST-RUN-H2: ローカルXcodeのSDK stat cache待機

最初のビルドは `clang-stat-cache` のCFRunLoop待機で進まず、CPU使用率0%だった。今回起動したビルドだけを中断し、Xcode同梱xcspecで確認した `SDK_STAT_CACHE_ENABLE=NO` をローカルコマンドに指定して再実行した。製品設定・CI設定や共有SDKキャッシュは変更していない。

## 2026-09-25 FIRST-RUN-H3: 権限確認の対照実験

製品権限controllerを読み込む新規IDの専用アプリと、Cocoa + CGRequestだけの独立した署名アプリで比較した。どちらもOS側登録完了に至らなかった。ネイティブUIの呼出成功とOS設定の登録完了を分離して記録する。証拠は `.local/first-run/permission-page.json`、`tcc-registration.log`、`control-click.json`。

## 2026-09-25 FIRST-RUN-H4: 実機受入の待機条件

公開後の実機確認前に `IOConsoleUsers` の `CGSSessionScreenIsLocked=Yes` を確認し、利用者へ解除を依頼した。ロック解除なしで権限ダイアログ確認を完了扱いにしない。APIのみの対照実験の失敗を、この後のロック観測だけで説明しない。公開・署名・公証・匿名配信照合は完了しており、実機受入とは別の状態として記録する。
