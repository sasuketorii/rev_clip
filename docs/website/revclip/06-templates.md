---
title: "テンプレートの作成・整理・移行"
description: "文章・画像テンプレートをフォルダで整理し、インポート・エクスポートする手順を説明します。"
slug: revclip/templates
navOrder: 6
productArea: revclip
docVersion: '0.1.9'
status: draft
verifiedAt: '2026-09-16'
---

# テンプレートを作成・整理する

メール文、プロンプト、連絡先などの文章や、よく使う静止画像をテンプレートとして保存できます。フォルダで分類し、必要な項目だけをメニューに表示します。

<!-- block: callout tone=info -->
> **対象版と確認状況:** Revclip 0.1.9（build 42）向けに現行ソースを照合した手順です。2026年9月16日時点で0.1.9の実機受け入れは未完了のため、実機での動作確認済みを示すものではありません。

## テンプレートエディタを開く

1. メニューバーのRevclipアイコンをクリックします。
2. メニュー下部の「テンプレートを編集...」を選びます。

左側にフォルダとテンプレートの一覧、右側に選択中の項目の編集欄が表示されます。

## フォルダと文章テンプレートを作成する

1. エディタ下部のツールバーにある「フォルダを追加」をクリックします。
2. 左側で作成したフォルダを選び、右側の「タイトル」欄に名前を入力します。
3. 下部ツールバーの「テンプレートを追加」をクリックします。選択中のフォルダに新しいテンプレートが作られます。
4. テンプレートを選び、「タイトル」と「テンプレートの内容」を入力します。
5. 「保存」をクリックするか、**⌘S**を押します。項目を切り替えるとき、またはエディタを閉じるときにも変更は保存されます。

**結果:** テンプレートは選択したフォルダに保存されます。フォルダとテンプレートの両方が「メニューに表示」に設定されている場合、メニューのテンプレート欄に表示されます。

## メニューからテンプレートを使う

テンプレートを選ぶと、その文章または画像がmacOSのクリップボードへ書き戻されます。ペーストコマンドが有効なら、Revclipは貼り付け先への自動ペーストも試みます。

1. 自動ペーストする場合は「設定」→「一般」→「ペーストコマンド」をオンにします。自動ペーストを使わない場合はオフにします。
2. 貼り付け先のアプリで、内容を入れたい位置を選びます。
3. メニューバーのRevclipアイコンをクリックし、フォルダを開いて使いたいテンプレートを選びます。

**結果:** オンの場合は、選択したテンプレートをクリップボードへ書き戻した後に貼り付けキーの送信を試みます。オフの場合もテンプレートはクリップボードへ書き戻されるので、貼り付け先で**⌘V**を押します。

自動ペーストにはRevclipのアクセシビリティ許可が必要です。許可がない場合もテンプレートはクリップボードへ書き戻されるため、手動で**⌘V**を試してください。

## テンプレートを編集・移動・非表示にする

1. 左側の一覧で、変更するフォルダまたはテンプレートを選びます。
2. 名前を変えるには「タイトル」を編集します。文章テンプレートの場合は「テンプレートの内容」も編集できます。
3. テンプレートを別のフォルダへ移す場合は、編集欄の「フォルダ」から移動先を選びます。
4. 選択中の項目をメニューから隠すには、「メニューに表示」をオフにします。再表示するときはオンに戻します。
5. 変更をすぐ確定するには「保存」または**⌘S**を使います。

フォルダ名、テンプレート名、テンプレート本文は左側の検索欄で検索できます。並べ替えるときは検索語を消してから、フォルダまたはテンプレートを一覧上でドラッグします。

<!-- block: dataTable -->
| 選択した項目 | メニューでの表示 |
| --- | --- |
| 非表示のフォルダ | フォルダとその中のテンプレートがまとめて表示されません。 |
| 非表示のテンプレート | そのテンプレートだけ表示されません。フォルダと他のテンプレートは残ります。 |

**結果:** 非表示にしてもエディタの一覧には項目が残り、内容は削除されません。エディタでは非表示の印を確認し、あとから設定を戻せます。

## 画像テンプレートを作成・差し替える

1. フォルダを選び、「テンプレートを追加」をクリックします。
2. 画像テンプレートの名前を「タイトル」に入力します。
3. 「メディアを追加…」をクリックし、画像ファイルを1つ選びます。
4. 既存の文章テンプレートに画像を追加する場合は、本文を画像に置き換える確認が表示されます。本文が不要な場合だけ「置換」を選びます。
5. 画像を差し替える場合は、対象テンプレートを選んで「画像を差し替え…」をクリックします。

**結果:** 画像のプレビューがエディタに表示されます。画像データはテンプレートに保存されるため、元ファイルを移動してもテンプレートから利用できます。

画像は、macOSのImageIOで読み込める静止画像を使ってください。アニメーションなど複数フレームの画像は利用できません。画像ファイルは次の条件を満たす必要があります。

<!-- block: dataTable -->
| 条件 | 上限 |
| --- | --- |
| ファイルサイズ | 10 MiB（画面表示では10 MB） |
| 画像の各辺 | 8,192 px |
| 画像全体 | 16,000,000画素 |

## テンプレートとフォルダを削除する

1. エディタで削除したいテンプレート、またはフォルダを選びます。
2. 下部ツールバーの「テンプレートを削除」または「フォルダを削除」をクリックします。
3. 確認画面に表示された対象を確認し、「削除」を選びます。

**結果:** テンプレートを削除すると選択した項目が削除されます。GUIでフォルダを削除すると、中のテンプレートもすべて削除されます。

<!-- block: callout tone=warning -->
> **削除前に確認してください:** フォルダの削除は中のテンプレートも対象です。確認画面に表示されるフォルダ名を確かめてから確定します。

CLIの `folder-delete` は、空のフォルダだけを削除できます。中のテンプレートもまとめて消すGUIの操作とは異なります。CLIでの操作は[CLIリファレンス](09-cli-reference.md)を参照してください。

## テンプレートをインポート・エクスポートする

テンプレートをファイルへ書き出し、別のRevclipへ取り込めます。書き出したファイルは保存時の暗号化の対象外です。

### インポート

1. 「テンプレートをインポート...」をクリックします。
2. 読み込むファイルを選びます。`.revclipsnippets`、`.xml`、`.plist`を選択でき、Clipy互換の形式も読み込めます。
3. 既存の内容を残して取り込む場合は「既存のテンプレートに追加」を選びます。現在のテンプレート全体を読み込み内容へ置き換える場合は「すべてのテンプレートを置換」を選びます。中止する場合は「キャンセル」を選びます。

<!-- block: callout tone=warning -->
> **注意:** 「すべてのテンプレートを置換」を選ぶと、現在の全フォルダとテンプレートが置き換わります。必要な内容がある場合は、先にエクスポートして保管してください。

### エクスポート

1. 「すべてのテンプレートをエクスポート...」をクリックします。
2. 保存先を選びます。初期ファイル名は `templates.revclipsnippets` です。
3. 保存したファイルは、テンプレートを別のRevclip環境へ移すときなどに使えます。

エクスポートは選択中の項目だけではなく、全フォルダと全テンプレートが対象です。非表示にした項目も含まれます。出力はXML plist形式で、テンプレートのタイトル・本文・画像データを含む場合があります。アプリ内データの暗号化は、エクスポートしたファイルには適用されません。

<!-- block: callout tone=warning -->
> **保管先を確認してください:** エクスポートファイルにはテンプレートの内容が含まれます。共有先と保存場所を確認し、不要になったファイルも適切に扱ってください。

インポートとエクスポートで検証されるデータには、次の上限があります。

<!-- block: dataTable -->
| 対象 | 上限 |
| --- | --- |
| ファイル全体 | 50 MiB |
| フォルダ数 | 100 |
| テンプレート数 | 10,000 |
| フォルダ名・テンプレート名 | 各500文字 |
| テキスト本文 | 1 MiB（UTF-8） |
| 画像テンプレート | 10 MiB、単一フレーム、各辺8,192 px以下、合計16,000,000画素以下 |

## 困ったとき

<!-- block: dataTable -->
| 状況 | 対処 |
| --- | --- |
| 「テンプレートを追加」が使えない | 先に「フォルダを追加」で保存先を作り、そのフォルダを選びます。 |
| メニューにフォルダやテンプレートが出ない | エディタで対象を選び、「メニューに表示」がオンか確認します。テンプレートは親フォルダが非表示の場合もメニューに出ません。 |
| 自動ペーストされない | 「設定」→「一般」→「ペーストコマンド」とRevclipのアクセシビリティ許可を確認します。テンプレートはクリップボードへ書き戻されるため、手動の**⌘V**も試せます。 |
| 画像を追加できない | 静止画像か、ファイルサイズ・各辺・総画素数の上限を確認します。macOSのImageIOで読み込めない画像も使えません。 |
| インポートに失敗する | エラー内容を確認し、対応形式か、ファイルサイズや件数・タイトル・本文・画像の上限を超えていないか確認します。 |
| 保存に失敗したと表示される | 変更が保存されていない可能性があります。表示されたエラーを確認し、保存済みとみなさずにもう一度保存してください。 |

## 関連ページ

- [Revclipの概要](01-overview.md)
- [履歴と貼り付け](04-history-and-paste.md)
- [プレビューとファイルのコピー](05-previews-and-file-copy.md)
- [設定](07-settings.md)
- [エージェント設定](08-agent-setup.md)
- [CLIリファレンス](09-cli-reference.md)
- [プライバシーとセキュリティ](10-privacy-and-security.md)

<!--
編集注（公開時は非表示）
出典:
- src/Revclip/Revclip/Managers/RCMenuManager.m — appendApplicationSectionToMenu:, appendSnippetSectionToMenu:, appendSnippetDictionaries:folderIdentifier:toMenu:, capturePasteTargetApplication, selectSnippetMenuItem:
- src/Revclip/Revclip/Managers/RCDatabaseManager.m — fetchSnippetCatalog, deleteSnippetFolder:
- src/Revclip/Revclip/UI/SnippetEditor/SnippetEditorView.swift — editor, toolbar, selectionActions, transferActions, confirmDelete(), chooseMedia(replacing:), importSnippets(), exportSnippets()
- src/Revclip/Revclip/UI/SnippetEditor/SnippetEditorModel.swift — persistDraftIfNeeded(), addFolder(), addSnippet(), loadMedia(from:replacing:), toggleEnabled(), moveFolders(from:to:), moveSnippets(in:from:to:), moveSelectedSnippet(to:), importSnippets(from:merge:), exportSnippets(to:)
- src/Revclip/Revclip/Services/RCPasteService.m — performWrite:toApplication: and pastePlainText:toApplication:
- src/Revclip/Revclip/UI/Preferences/RCGeneralPreferencesViewController.m — pasteCommandChanged:, pasteCommandButton
- src/Revclip/Revclip/Services/RCSnippetMedia.m — isValidImageData:, readImageAtURL:error:, pasteboardTIFFForData:
- src/Revclip/Revclip/Services/RCSnippetCLIService.m — folder-delete empty-folder check
- src/Revclip/Revclip/Services/RCSnippetImportExportService.m — exportSnippetsToURL:error:, exportSnippetsAsXMLData:, importSnippetsFromURL:merge:error:, persistParsedFolders:merge:error:, validateImportLimitsForFolders:error:
- src/Revclip/Revclip/Resources/ja.lproj/Localizable.strings — Template Editor labels, template import choice, delete confirmation, image picker notice
- README.md — テンプレート, インポートとエクスポート
- docs/TEMPLATE_CLI.md — Template results and limits, History access boundary
- docs/AGENT_SUPPORT.md and agents/AgentSupport/revclip/SKILL.md — supported local template CLI operations and limits
- src/Revclip/project.yml — packages agents/AgentSupport as the app's Resources/AgentSupport payload
- SECURITY.md — 保護範囲の限界, エージェントとCLIの境界
確認メモ: 現行エディタは「すべてのテンプレートをエクスポート...」を表示し、サービスは全カタログを書き出す。本文とルートREADME.mdをこの仕様に統一した。
-->
