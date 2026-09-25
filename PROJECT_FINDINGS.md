# Project findings

## 2026-09-25 FIRST-RUN-P1: 画面収録一覧への未登録

`RCPermissionsPreferencesController.openSettings` → `RCOCRCoordinator.openScreenRecordingSettings` は設定URLを開くだけだった。初回のセットアップから進むと権限要求APIを一度も実行しない。OCR実行時の独自アラート経路だけが要求を実行しており、導線が不一致だった。共通入口で未許可時に `CGRequestScreenCaptureAccess` を実行してから設定を開く。ページ表示だけでは要求しない。`project.yml`へ画面取得の利用目的も追加する。

## 2026-09-25 FIRST-RUN-P2: 初回認識の失効と処理中表示

Coordinatorは初回を含め一律10秒でチケットを取消し、Visionが戻るまで `workerBusy` を保持する。初期化が10秒を越えると、後から認識できてもコピーせず、その間の再試行は「前の処理を終了しています」になる。さらに認識器は対応言語照会の後に取消対象requestを登録していた。初期化中の取消が実requestに届かない区間が存在した。

初回成功までは上限60秒、以降10秒に分け、requestは言語照会前に取消セルへ登録する。アイドル時のウォームアップや並行Visionの増殖は追加しない。Appleの処理が戻る前にbusyだけを解除する変更は、CPU・メモリの無制限増加になるため行わない。

このMacの新プロセス合成試験では最初426ms、以後中央値130msだった。ユーザー端末の初期化時間は未取得であり、10秒超が実端末で起きたという直接証拠ではない。コード上の失敗条件と遅延注入の再現を、実端末の観測と区別する。OS内部の処理が永久に戻らない場合の強制中断はプロセス内Vision APIでは保証できない。

## 2026-09-25 FIRST-RUN-P3: 開発文書の競合検出ポリシー

`FASTER_OCR_DEVELOPMENT.md`の不変条件8は他アプリ設定を一切読まないと記載していたが、現行のCleanShot X専用アダプターと矛盾していた。現行の限定的な例外を `DEVELOPMENT_HANDOFF.md` に参照させ、無制限に他アプリ設定を読む許可にはしない。

## 2026-09-25 FIRST-RUN-P4: 実機のOS権限登録の限界

署名した新規bundle IDで製品の権限ページを表示し、未許可表示とボタンからのCGRequest呼出をTCCログで確認した。しかしこのMacでは設定一覧に追加されず、ScreenCaptureKitの列挙による要求でも解消しなかった。Revclipを一切読み込まない最小のDeveloper ID署名アプリでも `CGRequestScreenCaptureAccess()` はfalseとなり、OSの許可ダイアログが現れなかった。この環境でのOS側登録完了は未確認で、ソース修正の成功として扱わない。非公開API・TCC DB変更や他アプリの権限リセットは使用しない。Appleの公開API以外への置換は、この対照実験では裏付けられなかった。
