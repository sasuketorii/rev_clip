# faster OCR 開発メモ：守る不変条件と、2026-09-17に踏んだ失敗

- 作成：2026-09-17、Claude Fable 5.1（モデルID `claude-fable-5-1`）。`feat/ocr`、開始HEAD `8685539` の上の未コミットの変更が対象。
- 役割：**faster OCR、ショートカット、メニューからの起動、それらのCLIを触る人が、作業の前に読む文書。** 同じ失敗を繰り返さないための、判断の根拠と確認の手順を置く。
- 分担：ユーザーに見える挙動・制限・検証の状態（未実施の一覧を含む）は、[REV_OCR.md](REV_OCR.md) が正本。ここには、書かない。要件は、[要件定義書](revocr-requirements-apple-vision-v1.0-2026-09-17.md)。
- この文書の「確認済み」は、コードの読解、ログ、テスト、合成の実験のどれで確かめたかを添えている。「未検証」と書いた点を、確認済みとして扱わないこと。

## 1. 入口と所有ファイル

| 関心 | ファイル（`src/Revclip/` からの相対パス） | 入口 |
|---|---|---|
| 操作の状態・世代・取得・確定の前後 | `Revclip/Services/OCR/RCOCRCoordinator.swift` | `request(fromApplication:eventTime:origin:)`（ホットキーとメニューの単一の入口）、`commit(_:context:id:using:)`、`invalidate()`、`cancel()` |
| 選択UIと十字 | `Revclip/Services/OCR/RCOCRSelectionController.swift` | `show()`、`close()`、`refreshPointer()`、`releasePointer()` |
| 認識と整形 | `Revclip/Services/OCR/RCVisionTextRecognizer.swift` | `recognizeCrop`、`format(_:imageSize:)`、`isListMarker(_:)` |
| コピーの確定と履歴の受付 | `Revclip/Services/RCClipboardService.m` | `beginOCRFromApplication:saveToHistory:refusal:`、`commitRecognizedText:context:completion:`、`persistClipData:` |
| メニューの追跡の終了待ち | `Revclip/Managers/RCMenuManager.m` | `performAfterMenuTrackingEnds:`、`menuDidClose:`、`menuWillOpen:` |
| ショートカットの割り当て | `Revclip/Services/RCHotKeyService.m` | `prepareAssignments:ocrEnabledAfterCommit:transaction:`、`commitPreparedAssignments:`、`discardPreparedAssignments:`、`applyAssignments:` |
| 拒否の案内と、該当の設定への導線 | `Revclip/UI/HotKeyRecorder/RCHotKeyRecorderView.m` | `presentAssignmentResult:window:` |
| CLI | `Revclip/Services/RCSettingsCLIService.m` | `settings-schema` / `settings-get` / `settings-set` |
| Servicesの入口（他のアプリの右クリックから、文字を返す） | `Revclip/Managers/RCMenuManager.m`、`Revclip/UI/Appearance/RCMenuStyle.m`、`Revclip/App/RCAppDelegate.m`、`Revclip/Info.plist` の `NSServices` | `insertFromRevclip:userData:error:`、`captureServiceSelection:`、`+setSelectionInterceptor:`、`+launchEventIndicatesService:` |
| アプリを開いた時のメニュー（Applicationsからの起動、起動中の再open） | `Revclip/App/RCAppDelegate.m` | `handleUserOpen`、`applicationShouldHandleReopen:hasVisibleWindows:`、`+launchEventIsUserOpen:`、`+selfRelaunchStamp:coversLaunchAt:` |
| 定数 | `Revclip/App/RCConstants.h`（`kRCOCR…Key`）、`RCHotKeyService.h`（`RCDefaultOCRKeyCombo()`、スロット名、通知名） | 設定キーや既定のキーを、文字列や数値で書き足さない |

## 2. 守る不変条件

変更の前後で、これが成り立つことを確かめる。括弧の中は、対応するテストである。

1. **使っていない間は、画面の取得・Vision・専用のタイマーが動かない。** 設定や権限のページを開いても、許可の要求と、クリップボードの本文の読み取りは起きない。
2. **操作の開始の後に、別のコピーがあれば、OCRの結果を書かない。** 同じ内容の再コピーも、世代の変化として扱う（`RCOCRCommitTests`）。
3. **1回の受付は、1回だけ保存される。** 内部の世代の登録と、明示的な履歴の受付で、二重にも欠落にもならない（`RCOCRCommitTests`）。
4. **Clear・Panic・終了・ロック・スリープ・機能の無効化の後は、何も復活しない。** クリップボード、履歴、メニュー、**結果の通知**のすべてが対象（`RCOCRNoticeTests.testStopDuringTheCommitAwait…`）。
5. **メニューの後ろで待っている要求は、チケットを持たない。** 停止の世代（`invalidationEpoch`）と、`RCClipboardService.monitoringGeneration` の両方が一致した時だけ、開始する（`RCOCRNoticeTests.testRequestWaitsBehindMenuGate…`）。
6. **画面を止める前に、自分のメニューの追跡が終わっている。** かつ、自分のメニュー・通知・プレビューは、取得の対象から外す（`RCMenuParityTests` のメニュー待機の5件、`RCOCRNoticeTests.testCaptureExcludes…`）。
7. **ショートカットの変更が失敗したら、以前の登録と保存値が残る。** 対象は、全スロットで共通（`RCHotKeyContractTests`）。
8. **他のアプリを、名指ししない。排他で登録しない。ほかのアプリの設定を読まない。キーボードを常時監視しない。**
9. **整形は、文字を削除も書き換えもしない。** 連結するのは、条件を満たした断片だけ。列の境界は、別の行のまま（`RCOCRVisionTests`）。
10. **通常版とDemoで、機能の差を作らない。** 違うのは、配布のメタデータだけ（[DISTRIBUTIONS.md](DISTRIBUTIONS.md)、`scripts/check_demo_parity.py`）。
11. **Servicesの応答は、サービス用のペーストボードだけに書く。** 一般のクリップボードへの書き込みと、貼り付けのキー送信は、しない。取消・文字を持たない項目・停止・時間切れでは、何も返さない。応答を待っている間は、ほかのメニューを開かない（`RCMenuParityTests` のServicesの8件）。

## 3. 起きた問題と、その判断

### 3.1 メニューから起動すると、メニューが画面に残る

- **症状**：「画面の文字をコピー…」を選ぶと、半透明のメニューが、選択の背景に残った（実機の画像で確認）。
- **原因（確認済み）**：
  - メニューが閉じるフェードの途中で、ScreenCaptureKitが画面を取得していた。
  - 独自スタイルのメニュー行（`Revclip/UI/Appearance/RCMenuStyle.m` の `activateItem`）は、`cancelTracking` の直後に、`dispatch_async(main)` で動作を送る。**メインのディスパッチキューは、メニューの追跡中のrun loop（イベント追跡モード）でも処理される。** `DispatchQueue.main.async` は、「メニューが閉じた後」の保証にならない。
  - `menuDidClose:` も、画面の合成の完了を意味しない。ウィンドウは、フェードで残る。
- **採用**（2層）：
  1. `performAfterMenuTrackingEnds:`。開いているメニューは、`cancelTrackingWithoutAnimation` で閉じる。最後の `menuDidClose:` の後、`CFRunLoopPerformBlock` で、既定モードとモーダルパネルモードに限って実行する。イベント追跡モードでは、走らない。
  2. 取得のフィルタで、自分のプロセスの、フローティングのレベルと、ポップアップメニュー以上のレベルのウィンドウを外す（`RCOCRCaptureExclusion`）。フェードの進み具合に、依存しない。
- **棄却**：固定の待ち時間。取得の直前の、ウィンドウの一覧のポーリング。
- **待機の枠の扱い**：
  - 待機中の要求は、**実行の瞬間まで保持する**。`menuDidClose:` で先に空にすると、もう一方の入口が「追跡中は0」を見て、二重に起動する。
  - 新しいルートのメニューが開いたら、古い要求を捨てる。
  - `menuDidClose:` が届かなかった枠は、次の要求の時に復旧する。タイマーは、使わない。
- **実測**：Demo 53で、利用者が解消を確認。メニューを開いたままホットキーを押す経路と、フィルタでメニューバーのアイコンが静止画に残るかは、実機で未確認。

### 3.2 十字カーソルが静止中に矢印へ戻る。録画に映らない

- **症状**：起動の直後は十字、動かさないと矢印、動かすと十字。録画（CleanShot X 5.0）に、十字が映らない。
- **原因（合成の診断で確認）**：
  - 表示から約110〜200ms後に、**実際のカーソルだけ**が矢印へ戻る。`NSCursor.current` は、十字のまま。つまり、自分のプロセスの `NSCursor.set()` を通っていない。AppKitは、十字を出していると思い込んだままなので、マウスが動くまで直さない。
  - 戻している主体（WindowServerか、前のアプリか）は、**未特定**。
  - カーソル矩形の無効化、`didBecomeActive` からの再設定、前面化の完了を待ってからの表示は、どれも効かなかった。
  - カーソルは、ウィンドウではない。`sharingType` は、カーソルの録画に関係しない。
  - CleanShot X 5.0が、カスタムカーソルを描き直す方式かどうかは、推測で、未検証。
- **採用**：十字を、選択ビューの中のレイヤーとして描く。システムのカーソルは、「前面・キー・範囲内」の時だけ隠す。`hide()` と `unhide()` は、Bool 1つで守り、それぞれ1か所からだけ呼ぶ。
- **棄却**：周期タイマーでの再設定。非公開API。排他的な手段。
- **壊しやすい点**：
  - `close()` は、**observerの解除を先に**行う。その後に、前のアプリを前面へ戻す。逆にすると、範囲を確定するたびに、`didResignActive` で認識が取消される。
  - 静止中は、`mouseEntered` が来ない。範囲の中かどうかは、`NSEvent.mouseLocation` で判定する。
  - 手で足したレイヤーには、`contentsScale` を設定する。設定しないと、Retinaでぼける。
  - `acceptsMouseMovedEvents` と、トラッキング領域の `.mouseMoved` は、両方残している。二重に届いているかは、未計測。根拠なしに、削除しない。
- **未確認**：隠した状態が、約+200msの初期化を越えて維持されるか。目視だけで確認できる（`CGCursorIsVisible` は、SwiftのSDKで使えない）。

### 3.3 同じキー入力が、メニューのキー相当とグローバルなホットキーの両方に届くか

- **未検証。** 前に、「登録済みのホットキーは、キー入力を消費するので、二重には届かない」と推論したが、SDKの記述に裏付けが無く、撤回した。
- **採用**：
  - メニューの追跡中に届いた2つは、待機の枠で1つになる（テストあり）。
  - その後に届いた2つ目は、**入力のイベントの時刻が一致した時だけ**、同じ入力として扱う（`RCOCRCoordinator.isSameInput`）。どちらかの時刻が0か欠損なら、判定しない。差が2msを超えるなら、別の入力とする。2ms以内の押し直しは、同じ入力として無視される。人の操作で、この間隔は起きないと見込んでいるが、実機では確かめていない。キーのリピートや、入力を生成するツールでの挙動も、未確認である。「再押下で取消」が実機で保たれることは、確認が必要である。
  - 時刻の基準は、どちらも起動からの秒（`GetEventTime`、`NSEvent.timestamp`）。ただし、ホットキーのイベントが、元のキー入力の時刻を持つかどうかは、確かめていない。
- **確かめ方**：デバッグログの `request origin=… eventTime=…`（サブシステム `com.revclip`、カテゴリ `RCOCRCoordinator`）を、メニューを開いたままホットキーを押して読む。内容は、含まれない。
- **棄却**：一定の時間、入力を無視する方式。再押下での取消を壊す。

### 3.4 ショートカットの契約と、競合の検出の限界

- **SDKで確認したこと**（`Carbon.framework` の `CarbonEvents.h`、`RegisterEventHotKey` の説明）：
  - 既定（`inOptions = 0`）は、非排他。同じキーを、複数のアプリが登録できる。押すと、全部へ通知が届く。
  - 同じアプリは、同じ組み合わせを二重に登録できない。
  - 返り値は、`OSStatus` と、自分の参照だけ。
- **したがって、`status != noErr` は、登録の失敗の検出であり、他のアプリとの競合の検出ではない。** 他のアプリと重なっても、登録は成功し、両方が反応する。文言で、他のアプリを原因として示さない。
- **検出できるのは3つだけ**：
  - Revclipの中の重複（相手の名前が分かる）
  - macOSの有効なショートカット（`CopySymbolicHotKeys`。名前は無い）
  - 登録の失敗
- **採用した順序**：
  1. 要求の全体を、適用した後の状態で検証する。入れ替えを許す。
  2. **prepare**：自分の誰も持っていない組み合わせだけを、先にOSへ登録する。
  3. ほかの失敗し得る処理を行う。CLIでは、ログイン項目。
  4. **commit**：新しい登録（`RegisterEventHotKey`）は、ここでは行わない。自分のほかのスロットが持っている組み合わせは、OSを呼ばずに、登録の持ち主を付け替える。不要になった古い登録を外し、保存する。
     - 古い登録の解除（`UnregisterEventHotKey`）は、失敗し得る。失敗しても、commitは止めない。そのIDを配送の表から外すので、そのキーが押されても、Revclipは反応しない。失敗は、ログへ出すだけで、呼び出し元へは返していない。OSの側に登録が残る可能性があることが、限界である。
  5. 失敗したら、**discard**。prepareで登録した分だけを、解放する。
- **棄却**：「順に割り当てて、失敗したら戻す」。戻す時の再登録の成功を、保証できない。
- **そのための仕組み**：OSへ渡すホットキーのIDは、登録ごとに一意。「ID → スロット」の表で、配送する。固定のIDへ戻すと、付け替えの後の配送を取り違える。
- **機能の無効化と、解除は、常に通す。** 旧版が保存した重複から抜ける手段だからである。`Keep` の割り当ては、登録する時だけ、重複を調べる。
- **同じ要求の中の `ocr_enabled`** が、OCRのキーを登録するかどうかを決める。現在のスイッチでは、ない。
- **commitは、登録を確定してから保存する。** 保存の通知から再入した `reloadOCRHotKey` は、確定済みの状態を見て、何もしない。
- **固定のスロットは、フォルダより優先。** フォルダのキーは、`registerSnippetFolderHotKeyWithoutPersisting:` の1か所で、固定のスロットとの重複を調べる。

### 3.5 世代と、遅れて出る結果の通知

- **発見**：確定を待っている間の再押下でも結果を通知しようとして、「操作が空でも通知する」形にした。すると、Clear・Panic・終了・ロック・機能の無効化の後にも、成功の通知が復活した。レビューで見つかった。
- **採用**：
  - 確定の前に、停止の世代（`stopEpoch`）と、監視の世代を記録する。待ちの後で、どちらかが変わっていれば、結果が何であっても、通知しない。
  - 画面の構成の変更は、停止ではない。`invalidationEpoch`（待機中の要求向け）だけを進め、`stopEpoch` は進めない。切り抜きへ進んだ認識と、その通知は、生かす。
  - **通知するかどうかに関係なく、自分の操作は、必ず終了させる。** 新しい操作には、触れない。終了を通知の後ろへ置くと、画面の変更の後に、操作とチケットが残る。
- **世代は3つある。混ぜないこと。**

| 世代 | 進むきっかけ | 使う場所 |
|---|---|---|
| `invalidationEpoch` | 外部の停止と、画面・Spaceの変更 | メニューの後ろで待つ要求 |
| `stopEpoch` | 外部の停止だけ | 確定の後の通知 |
| `monitoringGeneration` | 監視の停止と再開 | チケット、受付、上の両方 |

メイン以外のスレッドからの停止は、Coordinatorへ非同期で届く。このため、`monitoringGeneration` の照合を、省略できない。

### 3.6 整形：箇条書きの記号と、列の境界

- **症状**：箇条書きの丸印が、`O` だけの行になった。
- **原因（実画像で確認）**：Visionが、丸印を、独立した観測として返した。記号と本文の間隔は、文字高の約1.5倍。「広い間隔は別の行」の規則に入った。macOS 26の文書構造API（`RecognizeDocumentsRequest`）も、同じ画像で、リストを0件と返した。
- **先に見つけた別の不具合**：横の間隔（画像の幅で正規化）と、文字高（画像の高さで正規化）を、直接比べていた。切り抜きの形で、結果が変わった。`format` は、画素へ換算してから比べる。`imageSize` には、**Visionへ渡した切り抜き**の寸法を渡す。
- **採用**：行の最も左の断片が、**決まった集合の記号**（`isListMarker`）で、幅が高さの1.5倍以下、間隔が3倍以下の時だけ、空白1つで連結する。
- **棄却**：
  - 同じ行の断片を、無条件に連結する。2列の文章と、表が潰れる。
  - 任意の1〜2文字を、記号とみなす。`A` / `123` の表が潰れる。
  - 記号の削除。`o`、`0`、`-` は、正しい値と区別できない。
  - 折り返しの自動の結合。意図した改行を壊す。仕様7章の範囲外。
- **アイコンが漢字になる件**は、安全に外せる根拠が無い。低いconfidenceの行を捨てると、正しいラベルごと消える（合成の実験）。入れていない。

### 3.7 Servicesの入口：同期のAPIと、既存のメニューの再利用

目的は、Revclipが未起動でも、Webの空の入力欄の右クリックから、履歴とテンプレートを選べるようにすること。**成功の条件は、実機のブラウザの空の入力欄で、選んだ文字が入ること。サービスの登録と自動テストの成功は、その証拠にならない。** 実機の状態は、[REV_OCR.md](REV_OCR.md) の表が正本。

- 形：入力なし、文字を返すサービス（`NSReturnTypes` だけ。`NSRequiredContext` は、空の辞書でも必要）。名前は、配布ごとのビルド設定 `RC_SERVICE_MENU_TITLE`（通常版「Revclip」、Demo「Revclip Demo」）。製品のソースに、Demoの分岐は無い。`project.yml` を変えた後は、`make -C src/Revclip setup` が必要（生成し直さないと、名前が空になる。実際に起きた）。
- **サービスの処理は、同期である。** 戻る時点で、ペーストボードに結果が要る。ホットキーの表示（`presentHistoryAfterClipboardSynchronization:`）は、非同期の前処理を含むので、使わない。メニューの表示そのもの（`popUpMenuPositioningItem:`）は同期なので、履歴とテンプレートだけのメニューを、直接出す。run loopを回して非同期の結果を待つことは、しない。直前のコピーが、メニューにまだ出ていないことがある（制限）。
- 選択の受け取り：標準の項目の動作は、`popUp` の中で走る。`selectClipMenuItem:` と `selectSnippetMenuItem:` の先頭で、`captureServiceSelection:` が項目を記録して、貼り付けをやめる。独自スタイルの行は、`cancelTracking` の後に `dispatch_async` で動作を送るので、`popUp` が戻る時点では、まだ走っていない。サービスの処理中だけ、行が、`RCMenuStyle` の `selectionInterceptor` へ同期で項目を渡し、動作を送らない。後から届く動作が無いので、二重の貼り付けの経路が無い。
- 受理するのは、**この要求が開いたメニューの項目だけ**（ルートのメニューの一致）。ほかのメニューの項目は、通常の意味のまま。
- 応答を待つ間は、`popUpMenuAtMouseLocation:` が、ほかのメニューを開かない。履歴とメインのホットキーは、既存の `trackingMenus` の確認でも止まる。テンプレートとフォルダのホットキーには、その確認が無かった。ステータス項目のクリックは、AppKitが開くので止めない。クリックで、サービスのメニューが先に閉じ、要求は「何も返さない」で終わる。faster OCRのホットキーも、メニューを閉じてから始まるので、同じ。
- 文字を返せない項目（画像・PDF・ファイルの履歴、メディアのテンプレート）は、`validateMenuItem:` で、最初から無効にする。判定は、行ごと・表示ごとに走るので、DBを読まない（履歴は `primaryType`、テンプレートは、行を作る時にプレビュー用へ登録した `previewImageData` の有無）。選んだ内容は、選択の後に、DBから読み直す。
- 守り：開始の拒否（監視の停止中、消去中、メニューの追跡中、モーダルの表示中、再入）。終了の確認（監視の世代、消去中、50秒）は、**内容の読み込みの前と後の2回**。読み込みと復号の間に、別のスレッドから停止が届くためである。セッションの印（フラグ、interceptor、タイマー）は、`@try/@finally` の中だけで立てる。タイマーは、この要求の間だけの単発で、メニューの追跡のモード（`NSEventTrackingRunLoopMode`）にも足す。
- 起動：`servicesProvider` は、起動の準備の後に設定する。サービスの要求で起動された時だけ、起動時のモーダルの案内（クリップボードの案内、アクセシビリティの案内）を見送る。案内が、要求の待っているメニューの前に出るためである。通常の起動と、ログイン項目の起動は、変えない。
  - 判定（`+launchEventIndicatesService:`）の根拠は、弱い。`AERegistry.h` は、`keyAELaunchedAsServiceItem` が「`kAEOpenApplication` のイベントにあれば」としか書いていない。公開されているコード（ログイン項目の判定と同じ形）は、`keyAEPropData` の列挙値として読む。両方を受け付けた。**現行のmacOSが、どちらの形で送るか、送らないかは、未検証。** 起動のログ（`event=… prdt=… svit=… service=…`）に、実際の形が出る。テストは、規則（2つの形は真、通常・ログイン項目・ほかのイベントは偽）だけを固定していて、OSの挙動の証拠ではない。
  - 判定が外れた時：偽になれば、案内が出て、要求は何も返さない（利用者は、案内を閉じて、もう一度操作する）。真になるのは、`svit` が付いた時だけなので、通常の起動の案内は、消えない。
- アクセシビリティの許可は、この入口には不要（貼り付けのキーを送らない）。

### 3.8 アプリを開いた時に、メインのホットキーと同じメニューを出す

利用者の優先は、3.7の右クリックより、こちらである。「アプリケーションでRevclipを選んだら、`⌘⇧V` と同じメニューが出ればよい」。

- 新しいメニューは、作らない。`handleUserOpen` は、`RCMenuManager.popUpStatusMenuFromHotKey` を呼ぶだけ。Clear・Panic・終了の後の遅れた表示の拒否、連続した要求の一本化、追跡中のメニューへの重ね表示の拒否、Servicesの応答待ちの間の拒否は、その経路が、すでに持っている。
- 入口は2つ。起動中の再open（`applicationShouldHandleReopen:hasVisibleWindows:`。開いているウィンドウがあれば、AppKitの既定のまま、前へ出すだけ）と、起動（`applicationDidFinishLaunching:` の最後。初回の案内のモーダルが、すべて終わった後）。
- **勝手に出さないための条件**は、すべて満たした時だけ出す、の向きにした。
  - 起動のイベントが、起動の属性（`keyAEPropData`）の無い `kAEOpenApplication`（`+launchEventIsUserOpen:`）。ログイン項目（`lgit`）、Servicesの起動（`svit`）、知らない属性、イベントなしは、偽。
  - 再openでは、Revclipが、アクティブなアプリである（初期起動には、この条件は無い。下を参照）。イベントの直後にアクティブ化が届く場合に備えて、1秒以内の `applicationDidBecomeActive:` を1回だけ待つ。タイマーは使わず、時刻の比較で、古い待ちを捨てる。
  - 起動のイベントは、`applicationDidFinishLaunching:` の先頭で、1回だけ読む。案内のモーダルの後では、現在のイベントが、別のものか、無しになり得る。
  - アクティブ化を待つ間に、監視の世代が変わったら（Clear、Panic、停止と再開）、要求を捨てる。メニューの経路の守りは、呼ばれた時点からしか効かないためである。
  - 起動の準備が終わっている。モーダルが出ていない。終了の処理中でない。満たさない要求は、捨てる（後から出さない）。
  - Revclip自身による再起動（更新の後、Applicationsへの移動の後）でない。再起動の直前に、時刻の印（`kRCSelfRelaunchStampKey`）を書く。起動の時に読んで、必ず消す。5分を超えた印は、無視する（再起動が失敗した時に、後の起動を黙らせないため）。
- **初期起動は、アクティブかどうかを見ずに、メニューを出す（build 56・57の実機で、2回、方針を変えた）。** 起動中の再openは、macOSがアクティブにする（実機で、メニューの表示まで確認）。一方、常駐（`LSUIElement`）のアプリは、`open` による初期起動では、アクティブにならない（実機：`event='oapp' prdt='' svit=0`、`active=false`、メニューなし）。
  - 失敗1（build 56）：届かないアクティブ化を1秒待って、要求を捨てていた。
  - 失敗2（build 57）：`-[NSApplication activate]` を頼んでから、待った。実機では、アクティブにならなかった。**実機で確かめていない前提（頼めば、アクティブになる）の上に、待ちを重ねたのが誤り。**
  - 現在：`handleUserLaunch` は、準備が終わっていて、モーダルが無く、終了の処理中でなければ、`popUpStatusMenuFromHotKey` を、そのまま呼ぶ。メインのホットキーのメニューは、もともと、Revclipがアクティブでない状態で出ている。同じ呼び出しである。
  - 初期起動で、メニューを出さない起動の見分けは、起動のイベント（ログイン項目 `lgit`、Services `svit`、知らない属性、イベントなし）と、自己再起動の印だけになった。**`open -g` の初期起動は、通常の起動と同じイベントで届くので、見分けられない。** スクリプトから背景で起動する時の契約は、起動の引数 `-suppressLaunchMenu YES`（`open -g <app> --args -suppressLaunchMenu YES`）。このリポジトリのCLIは、アプリを起動しない。
  - 起動中の再openは、今までどおり、アクティブな時だけ出す（`open -g` の再openでは、出ない）。
  - ログイン項目の判定（`keyAEPropData == keyAELaunchedAsLogInItem`）は、`SMAppService.mainApp` を使う公開のライブラリ（LaunchAtLogin-Modern の `wasLaunchedAtLogin`）と同じ形。このアプリでの実機の確認は、まだ無い。
- 選んだ後の挙動は、既存の貼り付けの経路のまま。新しい貼り付けの処理は、足していない。結果は、入口で違う（コードの読解による。実機は、未確認）。
  - 初期起動：Revclipは、アクティブでないまま。`capturePasteTargetApplication` は、その時に前面のアプリ（起動元のFinderやターミナルなど）を、貼り付け先にする。メインのホットキーと同じで、設定が有効なら、そのアプリへ貼り付ける。
  - 起動中の再open：Revclipが前面。自分自身は、貼り付け先にならない（`capturePasteTargetApplication` と `RCPasteService.isUsableTarget:`）。選んだ項目は、クリップボードへ入り、自動の貼り付けは、起きない（Revclipの設定画面が前面の時と、同じ）。
- **未検証（実機が必要）**：Finder・Launchpad・Spotlight・Dockからの起動が、属性の無い `kAEOpenApplication` で届くか。`SMAppService` のログイン項目の起動に、`lgit` が付くか、アクティブにならないか。常駐（`LSUIElement`）のアプリが、Finderからの起動でアクティブになるか。再openの時点で、アクティブになっているか。起動のログ（`event=… prdt=… svit=…`）に、実際の形が出る。テストは、規則を固定しているだけで、OSの挙動の証拠ではない。

## 4. 検証の進め方で、実際に失敗したこと

1. **古いソースのテスト結果を、最終の候補の証拠にした。** 全体テストの開始の後に、ソースが変わっていた。
   → **ソースを固定してから、テスト、ビルド、配布物の順に進める。** 途中で編集したら、最初からやり直す。ログとソースの更新時刻を照合し、差分と未追跡ファイルのハッシュを、候補に結び付ける。重い検証の実行中は、追跡対象のファイルを編集しない。
2. **古いバイナリを、候補として扱いかけた。** 修正の前に作ったDMGが、同じ名前で残っていた。
   → 作り直す前に、古い成果物の名前を変える。インストール済みのアプリは、版・build・実行ファイルのハッシュで照合する。
3. **真理値表だけのテストは、配線の誤りを検出しなかった。** `reportsCommitOutcome` の真理値表は、製品の待ちの後から、世代の比較を消しても、通った。
   → **実際に使う処理を小さく切り出し、テストから駆動する。** 保留した完了の間に、停止を起こす（`RCOCRCoordinator.commit(_:context:id:using:)`）。さらに、**守りを外した変異でテストが落ちること**を確かめてから、元へ戻す。今回の実測は、次のとおり。
   - 世代の比較を外す：16件が失敗。
   - 待機の判定の順序を戻す：3件が失敗。
4. **製品では使われない関数を、テストが検証していた。** 同じ処理を、製品の側へ複製したためである。
   → 複製しない。テストは、製品の入口から、結果までを通す（`RCHistoryUseTests` は、`enqueueCapturedClip:source:` 経由）。
5. **集中テストでは通り、全体テストで落ちた。** `objectForKey:` は、プロセス全体の登録ドメインの既定値を返す。
   → 「書き込まれていない」ことは、`persistentDomainForName:` の前後の比較で確かめる。
6. **合成の指標を、既定の設定の結果として示した。** ベンチマークは、手動の `ja-en` だった。
   → 測定のモードを、明記する。合成の2条件の結果を、一般の保証へ広げない。
7. **推論を、事実として書いた。** カーソルの原因と、キー入力の消費。
   → SDKのヘッダ、ログ、実測のどれで確かめたかを添える。確かめていない点は、未検証と書く。

## 5. 変更する時のチェック項目

- [ ] 新しい入口（メニュー、ホットキー、設定、CLI）は、`request(fromApplication:eventTime:origin:)` か、`prepareAssignments…` を通っているか。
- [ ] 待ち（`await`、run loop、メニュー）の後で、世代を確かめ直しているか。3つの世代のうち、正しいものを使っているか。
- [ ] 取消・停止の経路で、通知・操作・チケット・カーソルの隠し・observerが残らないか。
- [ ] 設定のキー・既定のキー・通知の名前を、定数から取っているか。
- [ ] 文言を足したら、9言語へ同じキーを入れたか（`LocalizationTests`）。使わなくなったキーは、9言語から外したか。
- [ ] 新しいテストは、製品の入口から結果までを通しているか。守りを外すと、落ちるか。
- [ ] テストが、実際のホットキーの登録・クリップボード・履歴・権限に触れていないか（`RCHotKeyContractProbe` は、OSの呼び出しを差し替える。テストホストの `NSUserDefaults.standard` は、メモリ上の領域）。
- [ ] ユーザーに見える挙動が変わったら、[REV_OCR.md](REV_OCR.md) の前半を直したか。要件からの変更は、理由と影響を記録したか。
- [ ] メニューの項目の動作や、メニューを開く入口を足したら、Servicesの応答を待っている間の扱い（記録するか、開かないか）を決めたか。
- [ ] 他のアプリを原因として示す文言、排他の登録、常時の監視を、足していないか。

## 6. 検証のコマンド

```sh
make -C src/Revclip setup      # XcodeGenで、プロジェクトを生成（新しいファイルを足した時）
make -C src/Revclip test       # 全体テスト（Debug）
make -C src/Revclip demo       # Demoのビルドと署名の検証
python3 scripts/check_demo_parity.py   # 通常版とDemoで、機能の分岐が無いこと
```

全体テストと、ビルドは、重い処理である（全体テストは、約4分）。ほかの作業と並行している時は、重い処理の同時実行を抑えるガードを通す。ガードの本体は、このリポジトリの外のスキル（rev-development-harness）にある。場所は環境ごとに違うので、変数で渡す。受領証（`--out`）は、作業ツリーの外へ置く。

```sh
REVH=<rev-development-harness の scripts/bin/revh.mjs>
node "$REVH" command run --guard required --class heavy --root "$PWD" --task <タスク名> \
  --out <作業ツリーの外の受領証.json> -- make -C src/Revclip test
```

受領証の `exitCode` と `sourceChanged` を確認する。`sourceChanged` が `true` なら、実行中にソースが変わっている。その結果は、証拠に使わない。

関連のテストだけを回す時は、`-only-testing:RevclipTests/<クラス名>` を付ける。今回の変更に対応するクラスは、`RCHotKeyContractTests`、`RCOCRHotKeyTests`、`RCSettingsCLITests`、`RCOCRVisionTests`、`RCOCRNoticeTests`、`RCOCRCommitTests`、`RCMenuParityTests`（メニューの待機と、Servicesの入口）、`RCHistoryUseTests`、`RCUserOpenTests`（`RCAppTerminationTests.m` の中）、`LocalizationTests`。

`RCPreferencesSidebarTests` が、全体の実行の中で、異常終了したことがある（この文書の作成より前の記録。スタックは、入力メソッドの起動から、テスト用のdefaultsの `addSuiteNamed:` の中断へ至っていた、とされる。2026-09-17の全体の実行2回では、起きていない）。**単独の再実行で通っても、原因の確定にはならない。** 起きた時は、クラッシュログ・スタック・再現の条件（全体の実行か、単独か、入力メソッドの状態）を残す。原因が分からなければ、未解明と書く。失敗した実行を、合格の証拠に置き換えない。

同じクラスで、別の形の失敗もあった（2026-09-17、build 56の全体の実行、381件中1件。その後、GUIの操作が無い条件でも再現した）。`testPaletteRefreshPreservesActiveEditorUntilNextAppearanceVisit` の中の `drainMainQueue`（メインのキューへの1ブロックを、2秒待つ）が、時間切れになった。**原因は、製品ではなく、テストの書き方と、環境の遅さの重なり**（テストホストのスタックの採取で確認）。テストが、`NSTextField` を `NSHostingController.view` の下へ足していた。SwiftUIは、これを実行時の警告として出し、XCTestは、issueとして記録する。その記録が、メインのスレッドでスタックをシンボル化し、dSYMをSpotlightで探す（`WaitForSpotlightQueryToReachState`）。Spotlightの応答が遅い時だけ、2秒を超える（普段は、テスト全体で約0.3秒。遅い時は、2.5〜5.8秒）。警告は、成功していた実行のログにも、出ていた。修正は、フィールドを、ウィンドウの `contentView` へ足すこと（守りが見るのは、ウィンドウの first responder だけ）。待ち時間は、延ばしていない。Spotlightが遅くなった理由は、未確認。教訓：**テストのログに出る実行時の警告は、XCTestの中で、メインのスレッドを止め得る。** GUIの実機の操作と、XCTestは、同時に走らせない。

## 7. 通常版とDemo

- 同じソース、同じ機能。違うのは、Bundle ID・保存先・更新のフィード・署名だけ（[DISTRIBUTIONS.md](DISTRIBUTIONS.md)）。
- Demoの差し替えは、旧バンドルを退避し、同じ場所へ置き換え、署名・版・build・フィードが無いことを確かめる。通常版には、触れない。
- 画面収録の許可は、Bundle IDと署名に結び付く。署名の違う版へ入れ替えると、許可の登録し直しが必要になることがある。
- 通常版とDemoを同時に起動した時の、同じキーの扱いは、未確認（3.4のとおり、両方が反応する想定）。

## 8. 未実施の範囲

[REV_OCR.md](REV_OCR.md) の「現在の検証の状態」が正本。ここには、写さない。
