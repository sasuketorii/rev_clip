# faster OCR

> build 58追補：全体XCTest 382件とCLI関連88件が成功。初回起動・再オープンのメニュー表示と、`-suppressLaunchMenu YES` による背景起動時の表示抑止をDemo実機で確認。証拠と回帰検証の現状は [QUALITY_REPORT.md](QUALITY_REPORT.md)。以下の未検証・過去ビルドの記録は、その時点の範囲を示す。

Revclipへ追加する、画面の文字をコピーする機能。仕様は [要件定義書 v1.0](revocr-requirements-apple-vision-v1.0-2026-09-17.md)。本書は、未公開の候補の操作・設計・検証の記録であり、公開版への搭載を示さない。「RevOCR」は開発中の旧称で、設定の保存キー・アセット名・要件定義書のファイル名には、互換性のために残っている。

実装を変更する人は、先に [開発メモ](FASTER_OCR_DEVELOPMENT.md) を読むこと。守る不変条件、過去の失敗の原因、変更の時のチェック項目は、そちらが正本である。

本書の前半は**現在の状態**、後半の「履歴」は、build 43〜53の時点ごとの記録である。履歴の数値やハッシュは、その時点のもので、現在の候補の証拠ではない。

## 操作

`⌘⇧2`、またはメニューの「画面の文字をコピー…」で起動する。ポインタのある画面の静止画の上で、文字を囲む。認識の後、文字がコピーされ、`⌘V`で貼り付けられる。自動の貼り付けは、行わない。初回の利用の時だけ、画面収録の許可を案内する。

メニューから起動した場合も、メニューを開いたままホットキーを押した場合も、メニューの追跡が終わってから、画面を取得する。自分のアプリのメニュー・通知・プレビューは、取得の対象から外す。

選択中は、Esc・Delete（Backspace／前方削除）・右クリック・ショートカットの再押下で取消。他のアプリへ切り替えた時も、取消になる。認識中は、ショートカットの再押下で取消。利用者の指示により、途中の進捗の表示と取消ボタンは無く、最後の結果だけを表示する（初期仕様4.4・9.2からの変更）。認識の期限10秒は、維持している。複数の画面をまたぐ選択は、できない。

選択の十字（48pt）は、システムのカーソルではなく、選択ウィンドウの内容として描く。静止中にシステムのカーソルが矢印へ戻る問題と、録画に映らない問題への対処である。選択範囲の四隅の延長線は、十字の腕と同じ長さ（22.5pt）。色は、メニューのカスタムカラーの `primary` に連動し、未設定の時は `#007FFF`。選択範囲の塗りは、10%で固定。

結果の通知は、小さな角丸の暗色のパネル。成功は緑 `#22c55e`、失敗は赤 `#ff0000`、情報は白。認識した本文は、表示しない。

### 起動できない時の案内

| 状況 | 表示 |
|---|---|
| 前面のアプリを特定できない（バンドルIDが無い） | 除外設定を確認できないため、開始しない。判定できない発信元は、止める側へ倒す |
| 除外したアプリが前面 | 除外したアプリでは利用できない |
| 履歴の消去中・終了の処理中 | 利用できない |
| ポインタが、どの画面の範囲にも入っていない | 対象の画面を利用できない。近い画面へ推測で切り替えることは、しない |
| 選択画面を1秒以内に表示できなかった | 選択画面を表示できなかった |

ポインタの画面の判定は、AppKitの座標の範囲と一致する半開区間（xは `[minX, maxX)`、yは `(minY, maxY]`）で行う。画面の最上段では、yが画面の高さと同じ値になるためである。

## 設定・ショートカット・CLI

設定 → faster OCRで、有効／無効、ショートカット、認識言語、文章の言語補正、履歴保存を変更できる。設定 → 権限ステータスで、アクセシビリティ・クリップボード・画面収録の状態を確認できる（開くだけでは、許可の要求も、クリップボードの読み取りも行わない）。

有効にする操作は、このmacOSで使えない場合と、保存済みの認識言語がこのmacOSに無い場合に、拒否する。別の言語へ黙って置き換えることは、しない。無効にする操作と、ショートカットの解除は、常に受け付ける。旧版が保存した重複の状態からも、これで抜けられる。

### ショートカットの契約（設定画面とCLIで共通）

対象は、メインメニュー・履歴メニュー・テンプレートメニュー・履歴消去・faster OCRの5つ。テンプレートフォルダのショートカットは、重複の判定の相手として参加する。

1. 要求の全体を、適用した後の状態で検証する。このため、1回の要求の中で、2つのショートカットを入れ替えられる。
2. Revclipの中の重複は、相手の機能の名前を示して拒否する。該当の設定を開くボタンを出す。
3. macOSの有効なキーボードショートカットとの重複は、`CopySymbolicHotKeys` で、割り当ての時だけ照合する。macOSは名前を返さないので、名前は示さない。
4. 新しい組み合わせを、先にmacOSへ登録する。Revclipのほかの機能が今持っている組み合わせは、OSを呼ばずに、登録の持ち主を付け替える。すべて成功した時だけ、古い登録を外して、保存する。
5. 失敗した時は、以前の登録と保存値を、そのまま残す。

**他のアプリとの重複は、検出できない。** macOSのホットキーは非排他で、同じキーを複数のアプリが登録でき、押すと全部のアプリへ通知が届く。登録の返り値に、相手の情報は無い。Revclipは、排他での登録、他のアプリの設定の読み取り、キーボードの常時監視を、行わない。登録の失敗は「登録できませんでした」と表示し、他のアプリが原因だとは表示しない。

### CLI

`settings-schema` / `settings-get` / `settings-set` に、`ocr_enabled`、`ocr_save_history`、`ocr_language_correction`、`ocr_language` と、`shortcut_main`、`shortcut_history`、`shortcut_snippet`、`shortcut_clear_history`、`shortcut_ocr` がある。形と例は [TEMPLATE_CLI.md](TEMPLATE_CLI.md)。画面の取得・faster OCRの起動・認識結果の取得を行うCLIは、無い。CLIからの変更は、開いている設定画面にも反映される。

## データと制限

選択の前に、対象の画面を1枚だけ一時的に取得し、同じ静止画から、選択範囲を独立したSDRのバッファへ切り出す。画像は、ファイルにも履歴にも保存しない。faster OCRは、外部との通信を追加しない。使っていない間は、画面の取得・Vision・ウォームアップ・専用の周期タイマーを、動かさない。

認識の結果は、通常のテキストの履歴として、既存の除外・保存形式・重複・暗号化・容量のルールに従う。

- **履歴へ保存するのは、Revclipのクリップボードの許可が「常に許可」の時だけ。** 「確認」（macOS 15.4以降の既定）・拒否・不明の時は、コピーのみ。通常のコピーは「確認」でも取り込まれるため、挙動が違う。設定 → faster OCRの「認識結果を履歴へ保存」の下に、その旨を表示する。コピーのたびに通知を増やすことは、しない。
- **認識した文字には、常に一時マーカー（`org.nspasteboard.TransientType`）を付ける。** 履歴へ保存する場合も、同じである。取消の後・再起動の後・別の配布版（通常版とDemo）での再取り込みを防ぐための、安全側の設計である。副作用として、この規約に従う他のクリップボード管理アプリは、faster OCRの結果を記録しない。機密保護の仕組みではなく、他のアプリやOSの同期が文字へアクセスすることは、防がない。

処理中の別のコピーは、同じ内容の再コピーも含めて、優先する。Clear・Panic・終了・取消・ロックの後に、古い認識結果を反映しない。これらの後は、結果の通知も出さない。OSのペーストボードには、他のアプリとの原子的な比較交換が無く、世代の確認と書き込みの間の微小な競合は、完全には排除できない。書き込みに失敗した後に、古いコピーを復元しない。

画面全体は3,200万画素、認識の範囲は1,600万画素、結果はUTF-8で1MiBが上限。8×8px未満の選択は、選び直し。画面の取得5秒、選択の無操作120秒、認識10秒で、確定の権限を破棄する。

### 認識と整形

日本語の横書き・英語・混在を中心に検証する。縦書き、ルビ、多段組み、手書き、任意の回転、複雑な表の読み順は、保証しない。URL・コード・空白も、誤認識し得る。独自の文字の置換・要約・翻訳はせず、言語補正は既定でOFF。自動モードの言語の順序は、優先言語・日本語・英語から作る。優先言語が英語の場合について、合成の画像の2条件（同じ8種の文）では、日本語優先との差を観測しなかった。一般の画像で同等かどうかは、未検証である。

Visionが返した観測を、縦の重なりで同じ物理的な行へまとめ、上から下、左から右へ並べる。同じ物理的な行の上の断片は、次の条件を満たす時だけ連結し、それ以外は別の行として残す（間隔と高さは、画素へ換算して比べる）。

| 条件 | 出力 |
|---|---|
| 間隔が、文字高の0.15倍以下 | 空白なしで連結 |
| ASCIIの語の端どうしで、間隔が0.2〜0.8倍 | 空白1つで連結 |
| 行の最も左の断片が、**箇条書きの記号**で、幅が高さの1.5倍以下、間隔が3倍以下 | 空白1つで連結（build 54で追加） |
| それ以外（列の境界） | 別の行のまま |

箇条書きの記号は、決まった集合だけである：`•` `◦` `○` `●` `・` `‣` `▪` `■` `□` `◆` `◇` `–` `—` `-` `*`、Visionが丸印を読んだ時の `o` `O` `0`、`1.` `2)` `a.` の形。それ以外の1〜2文字（`A`、`12`、`ID` など）は、表の値として、列のままにする。文字は、削除も書き換えもしない。折り返された行を段落へつなげる処理は、入れていない。

既知の限界：

- **アイコンが、漢字などの文字として認識されることがある。** 日本語優先のモデルの性質である。合成の実験では、汚染された行は、行全体のconfidenceが下がり、正しい先頭の文字を単独で認識し直した結果も不安定だった。正しい文字を消さずに、アイコンだけを外せる根拠が無いため、自動の除去は入れていない。
- `0` は、丸印の読みでもあり、表の値でもある。行の最も左にあり、間隔が3倍以下の時だけ、記号として扱う。
- 2列の文章は、左右の行が交互に並ぶ。多段組みの読み順は、保証の対象外である。

## 現在の検証の状態（build 54のソース）

| 範囲 | 状態 |
|---|---|
| 自動テスト | build 54向け実装で369件成功・失敗0。実行中のソース変更なし。その後の変更はビルド番号54への更新と検証記録。`.local/revocr/claude-diagnostic/FIX_ALL_BUILD54.md` と `fix54-full-tests.log` に証拠を記録 |
| ビルド・Demo反映 | Demoと通常Releaseのarm64/x86_64ビルド成功。Demo 0.2.0 (54)のみ開発署名でインストール・起動。通常Releaseは署名なしのコンパイル確認であり、配布合格ではない。`.local/revocr/demo54-manifest.json` に導入したバンドルを記録 |
| インストール済みDemoのCLI | 実ソケット経由で44項目のスキーマ、OCR設定・ショートカットの読み取り、不正言語とアプリ内競合の拒否・設定不変、言語補正の変更・読み戻し・全設定の復元を確認。GUI反映とOSの実ホットキー配送は別途未検証。証拠は `.local/revocr/claude-diagnostic/demo54-cli-write-restore.json` と `demo54-cli-rejection.json` |
| メニューの残像 | Demo 53で、利用者が実機で解消を確認 |
| 十字の静止時の表示、隠したカーソルの維持 | 実機の目視が必要 |
| 画面の最上段での起動、フルスクリーンのアプリの上での起動、権限が無い状態の初回のアラート | 未実施（実機が必要） |
| CarbonのホットキーとNSMenuのキー相当が、同じ入力で両方届くか | 未確認。両方の時刻が分かり、一致した時だけ、同じ入力として扱う。入口の種類と時刻を、デバッグログへ出す |
| 通常版とDemoの同時起動、外部・回転・倍率の違う画面、macOS 14、Intelの実機 | 未実施 |
| 通常のReleaseでの、10分のアイドル・30分の混合・100回の反復 | 未実施 |
| 精度（仕様15.3）と性能（仕様15章）の受入 | **未達・未実施。** 実機の受入は、不合格のまま |
| CleanShot Xでの録画の全経路 | 未検証 |
| 選択範囲の四隅の延長線を、十字の腕の長さ（22.5pt）へ変更 | 関連テスト成功。実機の目視は、未実施 |
| アプリを開いた時のメニュー（下の節） | 起動中の再open：Demo 56の実機で、メニューの表示を確認。初期起動：Demo 56・57では、出なかった（常駐アプリは、起動でアクティブにならず、頼んでも、ならなかった）。アクティブかどうかを見ずに、ホットキーと同じ呼び出しで出す形へ変えたが、**修正後の実機は未検証。** ログイン時の自動起動と `open -g` で出ないことも、未検証 |
| Servicesの入口（下の節） | **実機は未検証。** 関連テスト63件成功・失敗0、守りを外した7つの変異で、対応する7件の失敗を確認。全体テストは、この変更の後、未実行。証拠は `.local/revocr/claude-diagnostic/svc-targeted-final.log` と `svc-mutation.log` |
| 公開・公証・更新の配信、通常版の置き換え | 未実施。通常版は0.1.9 (42)のまま |

## 関連：アプリを開いた時のメニュー

Applicationsフォルダ・Launchpad・SpotlightからRevclipを開くと、メインのホットキー（`⌘⇧V`）と同じメニューが、ポインタの位置に出る。起動中にもう一度開いた時も、同じ。設定などのウィンドウが開いている時は、そのウィンドウが前へ出るだけ。

- 出さない場合：ログイン時の自動起動、右クリックのサービスによる起動、起動中のRevclipへの背景での再open（`open -g`）、更新やApplicationsへの移動の後の再起動、起動の準備中、案内のモーダルの表示中、Clear・Panic・終了の処理中。
- **未起動の状態から、背景で起動（`open -g`）した時は、通常の起動と見分けられないので、メニューが出る。** スクリプトから起動する時は、次の引数を付ける：`open -g <アプリ> --args -suppressLaunchMenu YES`。
- 選んだ後は、メインのホットキーと同じ、既存の貼り付けの挙動（実機は、未確認）。
  - 未起動から開いた時：Revclipは前面にならないので、その時に前面のアプリ（開く操作をしたFinderなど）が、貼り付け先になる。
  - 起動中にもう一度開いた時：Revclipが前面になるので、貼り付け先が無い。選んだ項目は、クリップボードへ入り、自動の貼り付けは、起きない。
- **実機は未検証。** 起動の種類の見分けは、macOSが送る起動のイベントの形と、アクティブかどうかに頼っている。特に、ログイン時の自動起動でメニューが出ないことは、実機で確かめる必要がある。

## 関連：Servicesの入口（他のアプリの右クリックから、履歴とテンプレートを選ぶ）

faster OCRとは別の機能だが、同じ作業で追加したので、状態をここに置く。**実機のブラウザで確認できるまで、READMEなどの利用者向けの文書には、載せない。**

- 他のアプリの右クリックのメニュー（「サービス」の中のことがある）に、「Revclip」（Demoは「Revclip Demo」）が出る想定。選ぶと、Revclipの履歴とテンプレートのメニューが、ポインタの位置に開く。項目を選ぶと、その文字が、元のアプリの入力欄へ入る。Revclipが未起動なら、macOSが起動する。
- 入るのは、文字だけ（書式なし）。画像・PDF・ファイルの履歴と、メディアのテンプレートは、無効の表示になる。
- 一般のクリップボードは、変わらない。貼り付けのキーも、送らない。アクセシビリティの許可は、不要。
- 何も入らない場合：取消、50秒の経過、Clear・Panic・終了の処理中、Revclipのメニューやモーダルの案内が出ている時。
- 制限：直前のコピーが、メニューにまだ出ていないことがある。応答を待つ間は、Revclipのホットキーのメニューは、開かない。
- サービスの要求で起動した時だけ、起動時の案内（クリップボード、アクセシビリティ）を見送り、次の通常の起動で出す。判定の根拠は弱く、外れた時は、案内が出て、要求は何も返さない。

実機でしか分からず、未検証の点：

1. Braveなどの空の入力欄の右クリックに、項目が出るか。出る位置。メニューの更新に、ログインし直しや `pbs -update` が要るか。
2. 返した文字が、入力欄へ入るか。
3. 未起動からの起動で、メニューが出るまでの時間。macOSが、サービスの起動の印（`svit`）を、どの形で送るか（起動のログに出る）。
4. 前面でない常駐アプリが出すメニューの、キーボードの操作。
5. 50秒の時間切れが、メニューの追跡中に発火するか。

# 履歴（build 43〜53の時点ごとの記録）

以下は、その時点の記録である。版の番号・ハッシュ・件数・「現在」という表現は、各時点のものである。

## 初回実機フィードバック（2026-09-17）

Demo 0.2.0 (43)を起動後、利用者から「TextSniperより精度が悪い」「アイコンが漢字になる」「貼付け時に中央揃え」「案内文字と暗転が邪魔」「詰まる感じ」との報告。機能・精度・操作感の実機受入は不合格として調査を継続する。自動328件成功を体験品質の合格に置き換えない。

後続build 44では案内文字と全体の暗転を除き、選択範囲だけ薄く着色する。OCRコピーはプレーンテキスト＋一時マーカーであり、HTML／RTFを出していないことを確認する。貼付け先と失敗原文は確認中。Claudeと合成比較で認識入力・設定・アイコン誤認識を調査中。以下のbuild 43候補ハッシュ・性能値は初回候補の記録で、後続修正の合格を示さない。

### 現在のDemo：0.2.0 (46)

カーソルを24pt（14ptの約1.7倍）へ拡大。従来はcursor rect登録だけだったため、他のAppKitイベントでカーソルが戻った後の再設定経路がなかった。表示・キーウィンドウ化・移動・ドラッグ・cursorUpdateで再設定し、選択が終了したら再設定しない。矢印へのリセットを模擬する回帰は修正前9 assertion失敗、修正後成功。これはプロセス内のカーソル状態の検証であり、WindowServer上の表示継続の実機合格ではない。

300ms進捗ポップアップを経路ごと削除。成功／失敗は緑／赤の原色アセットとして描画し、vibrancyとウィンドウ影を除く。旧結果通知は次の画面取得より前に閉じ、通知の写り込みを防ぐ。情報アイコンは白。入力過大時は選択UIを閉じてからエラーを表示する。

製品の通知ビューを使う合成プレビューの緑・赤・角丸を画像確認し、インストールしたDemoの成功通知も画像確認。証跡は `.local/revocr/popup46-preview.png` と `popup46-installed-success.png`。実画面の自動操作はフォーカス競合を含み、OCR本文・取消・カーソル継続表示の実機合格とはしていない。旧build 45は `.local/revocr/previous-demo45.app`。最新導入記録は `.local/revocr/demo46-manifest.json`。

### build 45の記録

build 44の修正を含め、指定プライマリ`#007FFF`と14×14pt・線幅1ptの小さい十字カーソルへ変更。選択範囲だけ10%の青、青い細枠と四隅の延長線。署名検証後にDemoへ反映・起動。通常版と公開DMGは更新していない。TextSniperは利用者の再指示で終了確認済み。設定・ログイン項目は変更しない。

関連19件はbuild 44の内容で成功。最後の色・カーソル寸法変更はUniversal Demoビルドと署名検証で確認。自動実機試験は検証用ウィンドウのフォーカス取得失敗で未完了（検証用アプリは終了済み）。アイコン誤認識と貼付け先の中央揃えは未解決。

最新版の導入記録は `.local/revocr/demo45-manifest.json`。旧Demoは `.local/revocr/previous-demo44.app`、初回OCR候補は `.local/revocr/previous-demo43.app`、OCR追加前は `.local/revocr/previous-demo.app`。元の配布候補DMGはbuild 43の古い候補で、今回の修正を含まず配布不可とする。

修正後の既定autoモード・合成12例100回は11/12完全一致、CER2/218=0.917%、初回259.372ms、warm p50 111.707ms／p95 144.005ms。認識のみの測定で実画面の品質・性能合格ではない。初回の手動ja-en計測と設定が異なるため、改善率として直接比較しない。

### build 44の原因確認と変更

- 文字間隔の不具合：Visionの正規化X距離と正規化Y高さを直接比較していたため、選択範囲の縦横比で空白・改行の判断が変化した。同じ20px文字高・10px間隔で、横長では`Helloworld`、縦長では不要な改行を再現（追加回帰1件・3 assertion失敗）。切り抜き画像の実寸で矩形をピクセル単位へ変換して比較し、関連19件が成功。寸法は必須引数として省略による再発を防ぎ、横長・縦長・正方形で固定した。曖昧な断片は従来の仕様どおり別行に残す。
- 描画：ドラッグごとのNSImage生成と画面全体への再描画要求を削減。画像キャッシュは選択終了時に解放。全体の暗転・視覚上の案内文字を削除し、提供された選択画面の参考画像に合わせ、範囲内だけ薄い青10%で着色し、青い1pt枠・四隅の延長線・青い十字カーソルを表示する。Esc／Delete取消とアクセシビリティ用の案内は保持。
- コピー形式：隔離ペーストボードに中央揃えHTMLを先に入れても、OCR後は文字列・一時マーカー・OSが公開する旧文字列型aliasのみ。HTML／RTFが残らない追加回帰が成功。貼付け先の中央揃え現象の真因は未確定。
- アイコン：Claudeの13pt日本語＋16pt SF Symbols（2x）合成実験で家→`介`、ゴミ箱→`血`、四角→`口`を再現。Vision認識段階の誤りであり、整形修正だけでは解決しない。低信頼行の丸ごと削除は正しい本文を失う。先頭部分の追加認識による除去案も、正文字の誤削除率と追加時間が未確定のため未採用。
- 検証の不足：従来の合成ベンチマークは手動`ja-en`であり、既定`auto`ではなかった。測定モードを明示するようハーネスを修正。初回値は手動モードの値として保持する。実機と同じ画面をTextSniperと比較した試験は未実施。

原因調査の生結果は `.local/revocr/claude-diagnostic/`。合成実験であり、利用者の失敗画面を取得したものではない。操作感・アイコン・貼付けの実機受入は継続中。

## 実装と検証の記録

- 開始点：`feat/ocr`、HEAD `868553963898f8561ba19cde147fab1944a07962`、開始時クリーン。候補版 `0.2.0` / build `43`。作業中の差分は未コミット。
- effort: heavy / risk: critical（クリップボード、保存、消去境界）/ scope: cross-module / effect: scoped-source-write＋許可されたDemo候補準備。
- 単一実装担当が入口から結果まで所有し、独立レビューで境界を確認する。公開・通常版の置換は対象外。
- 既存経路：`RCHotKeyService` → `RCOCRCoordinator` → ScreenCaptureKit → AppKit選択 → `RCVisionTextRecognizer` → `RCClipboardService`の一回限りの受付 → 既存の監視／保存キュー。
- `RCClipboardService.stopMonitoring`がOCR取消通知と監視世代更新の共通境界。Clear／Panic／終了の既存呼出元を実コードで確認。Tree-sitterの索引・inbound traceも実行したが、Objective-Cの部分解析と同名メソッドの曖昧性があり、グラフは未検証候補として扱った。
- 自動テストは既存の隔離機構を使用する。名前付きペーストボード、一時DB、一時鍵、メモリ上の設定のみ。一般クリップボードやユーザー履歴を試験入力にしない。
- Apple公式API資料とXcode 26.6 SDKで、単発取得APIのmacOS 14 availabilityとVisionの対応言語APIを照合。新しいmacOS専用APIへ置換していない。

| 確認範囲 | 状態 |
|---|---|
| 変更前：コピー・ドレイン・終了の関連テスト | PASS |
| build 43時点の全回帰（後続変更の証拠ではない） | 328 tests / 0 failures、230.790秒。Delete取消を含む凍結済み最終製品ソース |
| HUD・字間調整後の重点回帰 | 40 tests / 0 failures |
| 最終Delete取消追加：受付・HUD・ローカライズ | 11 tests / 0 failures。Esc／Backspace／前方Deleteの取消を含む |
| 通常／Demoの機能分岐検査 | PASS。同じOCRソース |
| 独立コードレビュー | CODE LGTM。実機・性能・配布受入とは別。Delete追加は後続の局所変更 |
| 差分セキュリティスキャン | PASS。全体には既存Sparkleリンク7件と既存テストfixture1件の検出があり、全体PASSではない |
| 実画面の選択→コピー→履歴再利用、権限拒否／許可 | ユーザーによる選択・コピー実操作あり。取消等の受入網羅は未完。試験はユーザー承認済みで、許可待ちではない |
| macOS 14・Intel実機・外部画面・回転・HDR | 未実施 |
| 通常Releaseの10分アイドル・30分混合・100回実操作 | 未実施 |
| Demoインストール | 0.2.0 (43)へ更新。旧バンドル退避。新候補の起動・実機受入は未実施 |
| 通常版インストール・公開・公証 | 未実施。通常版0.1.9 (42)を保持 |

### 合成認識・性能測定

macOS 26.6.2、Apple M2 Max・96GiB、Xcode 26.6／SDK 26.5。製品の認識コードを使う独立した最適化済みハーネスで、1280×720pxの合成12例を100回認識した。Vision revision 3、ja-JP/en-US、言語補正OFF。画面取得・AppKit選択・クリップボード・保存は含まない。

- 初回308.415ms、ウォームp50 124.135ms／p95 146.991ms。
- 完全一致7/12、空白・改行を含む拡張書記素でCER 7/218 = 3.211%。独立した実画面コーパスの受入結果ではない。
- `RevOCR`の大小文字、日英間の空白、メールの`@`、コードの`l`と`1`、記号の全角化等に誤りが残る。独自置換で正解へ寄せない。
- RSSは開始約8.6MB、10回時約100.7MB、100回時約107.4MB。認識フレームワークの常駐を含み、「メモリ増加なし」やアプリ全体の性能合格とは扱わない。

4例のXCTestでも混在文字列の空白欠落を観測した。テストがPASSでも完全一致したとの主張には使わない。

### 候補と復旧

Demoは既存と同じbundle ID・保存領域・更新feed無効・Apple Development署名クラスを保持。通常版候補はDeveloper ID署名、Hardened Runtime、デバッグ許可entitlementなしのUniversal（arm64／x86_64）。Demoの開発署名は既存と同じくデバッグ許可を持ち、公開用通常版とは区別する。署名の一致はTCCの許可継続を保証しない。

旧Demoは `.local/revocr/previous-demo.app`。戻す場合はDemoを正常終了し、終了確認後に現候補を別名退避して旧バンドルを元のインストール位置へ戻す。DB・設定・Keychainを初期化しない。TextSniperは今回の依頼で終了したが、ログイン項目・設定は変更していない。

候補DMGは `.local/revocr/Revclip-0.2.0-43-candidate.dmg`。公開、公証、Gatekeeper受入、Sparkle配信は未実施。未コミット差分の候補なので、HEADだけでは再現識別できない。最終ソース・バンドル・DMGのハッシュと検証状態は `.local/revocr/candidate-manifest.json` に記録する。初回のデバッグ許可付き通常版DMGは不採用であり、配布対象ではない。

検証ログは `.local/revocr/`。`final-full.log`（最終全回帰）、`full3.log`（中間）、`final-focused.log`、`cancel-tests.log`、`benchmark-final.jsonl`を範囲ごとに参照する。追加のOrca CLI経由のClaude相談は読み取り専用で行い、未実施受入と署名・検証時点の区別を再確認した。

### Demo build 47: recording visibility (historical)

Selection explicitly used `NSWindow.SharingType.none`, preventing capture by recording paths that respect window sharing. Selection and result panels now use `readOnly`. OCR takes its source screenshot before selection appears, so this does not include selection decorations in OCR input. The user confirmed selection visibility in recording after installation. Custom cursor recording remained unresolved. The stationary cursor reset and intermittent latency remain under investigation; build 47 does not claim to resolve them.

### Demo build 48: selection pointer and primary color

Fable 5.1 was consulted using the existing Orca terminal. A synthetic native AppKit probe reproduced the stationary reset with unchanged mouse coordinates: the process-local cursor remained 24pt while the system cursor changed to a 28×40pt arrow by 200ms. Disabling cursor rectangles, a one-shot activation callback, waiting for activation, and assuming the pointer was already inside each failed in separate probes. The external reset source remains unidentified.

The crosshair is now a 24pt layer in the selection window, independent of OS cursor image replacement and included in window capture. Pointer movement repositions only that layer with implicit animations disabled. Native pointer hiding is balanced during active/key/inside selection; leaving, deactivation, and close restore it. Deactivation cancels the selection. No cursor polling timer is used. An activation attempt that fails within one second cancels without showing the selection.

Selection border, crosshair, and fill reuse the existing enabled menu primary palette via `RCMenuStyle`; customization disabled or invalid primary falls back to `#007FFF`. Fill opacity stays fixed at 0.10 (90% transparency). Colors are resolved once per selection, avoiding preferences reads on pointer movement. Retina scale is applied to the crosshair layers. Status success/failure colors are unchanged.

Validation: focused tests, synthetic native window capture, and installed Demo checks are recorded separately in `.local/revocr/`. The native window capture contains the crosshair as actual window pixels. CleanShot X 5.0 recording/export acceptance and hardware cursor visibility after hiding remain unverified. The unavailable `CGCursorIsVisible` API was rejected by the SDK in a diagnostic experiment and is not part of the product.

### Demo build 49: stroke visibility

User-requested visual adjustment: selection border and corner extensions increase from 1pt to 1.5pt. The primary-color crosshair stroke also increases from 1pt to 1.5pt, retaining its 24pt bounds and existing halo. Fill opacity remains 0.10. Verified with Universal Demo build and signature validation; no new behavioral test is claimed for this visual-only change.

### Demo build 50: larger crosshair

Following feedback that the initial crosshair still looked small and thin, its bounds increase to 32pt, primary stroke to 2pt, and white halo to 3pt. Selection border remains 1.5pt and fill opacity remains 0.10. The cursor layer regression expectation is updated to the requested size.

### Demo build 51: crosshair at 150 percent

The user confirmed the initial pointer was the intended target and requested 1.5 times its current size. Crosshair bounds are now 48pt, primary stroke 3pt, halo 4.5pt, with centered geometry scaled by 1.5. Border and fill are unchanged.

### Demo build 52: shortcut display and permission status

The visible feature name is `faster OCR`; internal settings keys and asset names remain compatible. All shortcut recorders display the unmodified base key alongside modifier symbols, fixing Shift+2 appearing as a quote. The OCR menu item reads the saved key and modifiers, respects an explicitly cleared shortcut, and invalidates menu caches when those settings change. Custom-colored menu rows also render all configured modifiers.

Settings now includes Permission Status for Accessibility (automatic paste), Clipboard (history collection), and Screen Recording (OCR capture). Each card shows a green/yellow dot, a textual status, a purpose explanation, and a System Settings button. Checks do not request permission or read clipboard content. Clipboard ask/unknown/denied are not shown as granted; old OS versions without the privacy setting are labeled permission-not-required and their settings button is disabled. The page refreshes on appearance and app reactivation, without polling. Existing permission-opening routes are reused. The screen-recording management row moves out of the OCR page into this shared page.

Official access-state semantics: https://developer.apple.com/documentation/appkit/nspasteboard/accessbehavior-swift.enum . Local evidence and Fable 5.1 review are under `.local/revocr/`. The user-provided requirements file is preserved unchanged.


### Demo build 53: OCR menu dismissal

The user reproduced a fading Revclip menu frozen into the selection background. Fable 5.1 implemented a shared entry for menu and hotkey requests. Menu tracking is cancelled without animation, and a pending request runs only after the final tracked menu closes and the default/modal run loop resumes. Duplicate entries remain coalesced through the deferred execution boundary. Clipboard monitoring generation and a cancellation epoch reject requests invalidated by Clear, Panic, termination, lock, sleep, settings or display changes.

The ScreenCaptureKit filter excludes Revclip's transient menu/notice/preview windows while retaining ordinary Revclip windows and other apps. No fixed sleep or idle capture loop is added. Apple API reference: https://developer.apple.com/documentation/screencapturekit/sccontentfilter .

Fable's final focused regression run passed 66 tests with zero failures. Removing the pending-request guard made the double-entry regression fail; the implementation was restored before the final run. These are automated checks, not acceptance of the installed menu-click/capture interaction. The independent review also checked the deferred-request lifecycle boundary. Evidence is recorded under `.local/revocr/claude-diagnostic/`.

The separate line-break investigation remains an investigation: isolated list markers are emitted as separate lines by the current gap rule. Same-row reconstruction and optional paragraph reflow have not been introduced in build 53. The original requirements file remains unchanged.
