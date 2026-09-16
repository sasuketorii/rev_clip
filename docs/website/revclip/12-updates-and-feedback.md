---
title: 更新と不具合報告
description: 公開版とインストール済みの版を確認して通常版を更新し、同意した範囲で不具合を報告する手順を説明します。
slug: revclip/updates-and-feedback
navOrder: 12
productArea: revclip
docVersion: '0.1.9'
status: draft
verifiedAt: '2026-09-16'
---

# アプリを更新し、不具合を報告する

このページでは、Macで起動しているRevclipの版を確認し、通常版を更新する方法と、不具合の内容を開発者へ送る方法を説明します。報告を送る前に、送信される項目を確認してください。

<!-- block: callout tone=info -->
> **対象版と確認状況:** 2026年9月16日時点で公開されている通常版は v0.1.9（0.1.9 / build 42）です。対象版の公開CI、DMGの署名・公証、更新フィードの検証は完了していますが、実際のMacでの描画・貼り付け・連続操作の受け入れ確認は完了していません。公開されたことだけで、すべてのMacでの動作確認済みとは判断できません。

## インストール済みの版と公開版を確認する

インストール済みの版は、いま起動しているアプリの設定画面で確認します。公開版の番号は[GitHub Releases](https://github.com/sasuketorii/rev_clip/releases/latest)で確認できます。この2つは別の情報なので、更新前後に両方を見ます。

1. 確認したい通常版またはDemo版を起動します。
2. メニューバーのRevclipから「設定」を開き、「アップデート」を選びます。
3. 画面に表示される「バージョン X (Y)」を確認します。Xがアプリの版、Yがビルド番号です。
4. 通常版の場合は[最新の公開Release](https://github.com/sasuketorii/rev_clip/releases/latest)を開き、そこに表示される版とビルドを比べます。Demo版の場合は、通常版のReleaseではなく、用意されたDemoビルドの版を確認します。

**結果:** 設定画面の番号は起動中のインストール済みアプリの情報です。通常版の公開Releaseに新しい版がある場合は、次の手順で更新します。開発用リポジトリのHEADやソースのコミット番号だけでは、Macに入っているアプリの版は分かりません。

## 通常版を更新する

通常版は、設定画面からSparkleの更新確認を使います。定期確認を有効にしていても、確認だけでアプリのダウンロードやインストールが自動で完了する設定ではありません。

1. Revclipで「設定」→「アップデート」を開きます。
2. すぐに確認する場合は「今すぐ確認」を選びます。定期確認を使う場合は「自動的にアップデートを確認」をオンにし、確認間隔を選びます。
3. 更新が案内されたら、表示された版を確認し、Sparkleの画面に沿ってダウンロードとインストールを進めます。
4. アプリの再起動を求められたら、表示された案内に従います。
5. 更新後にもう一度「設定」→「アップデート」を開き、バージョンとビルド番号を確認します。

**結果:** 設定画面の版とビルド番号が、公開Releaseに表示されたものと一致すれば、その版が起動しています。公開Releaseに新しい版があるのに更新確認で見つからない場合は、通常版で操作しているかを確かめてから、[インストール手順](./02-installation.md)に沿ってReleaseのDMGを使います。

<!-- block: dataTable -->
| 項目 | 通常版 | Demo版 |
| --- | --- | --- |
| アプリ名 | Revclip.app | revclip-demo.app |
| 更新フィード | 公開Releaseに添付する署名付きフィード | 通常版のフィードは設定されていません |
| 更新方法 | 「設定」→「アップデート」で確認 | 新しいDemoビルドを用意して置き換える |
| データ領域 | Revclip | revclip-demo |

Demo版は通常版と別のデータ領域を使います。テンプレート、設定、ログイン項目、macOSの権限は自動で通常版へ移行しません。通常版のReleaseでDemo版を更新したり、Demo版の動作を通常版の更新確認で判定したりしないでください。

エージェントへ登録したRevclipスキルも、アプリ本体を更新しただけでは自動で置き換わりません。更新が必要な場合は、「設定」→「エージェント設定」から案内を取得し、対象エージェントで確認・更新の手順を実行します。利用者が編集したスキルや管理対象ではないスキルは上書きされず、競合として残る場合があります。詳しくは[エージェント設定](./08-agent-setup.md)を参照してください。

## アプリから不具合を報告する

「設定」→「不具合報告」から報告できます。「タイトル」と「詳細」は必須、「返信先」は任意です。フォームには送信元情報の説明と、送信対象アプリのバージョン、macOS、言語、タイムゾーンが表示されます。

<!-- block: dataTable -->
| 送信内容 | 送信される情報 |
| --- | --- |
| 入力した内容 | タイトル、詳細、入力した場合は返信先 |
| アプリから付ける情報 | アプリのバージョンとビルド、macOSのバージョン、言語、タイムゾーン |
| 送信元情報への同意後にサーバーが取得する情報 | 送信元IPアドレス、おおよその地域、ネットワーク事業者（ASN）、User-Agent |
| 報告に自動添付しない情報 | クリップボード、コピー履歴、テンプレート、設定、ログ、スクリーンショット |

送信内容はCloudflareを経由して開発者のTelegramグループへ届きます。自動添付されない情報でも、自分で説明欄へ貼り付ければ送信されます。パスワード、APIキー、認証情報、顧客情報、個人情報、実際のクリップボード内容は記入しないでください。

1. 「タイトル」には、どの操作で起きる問題かを短く書きます。
2. 「詳細」には再現手順、実際の結果、期待した結果を書きます。
3. 返信が必要な場合だけ、「返信先」を入力します。
4. 送信元情報の説明を読み、送信に同意する場合に限り「送信元情報の取得に同意します。」をオンにします。同意しない場合は送信しません。
5. 内容を確認して「報告を送信」を押します。

「詳細」欄は次のように整理すると、起きたことを伝えやすくなります。

~~~text
再現手順:
1.
2.

実際の結果:
期待した結果:
発生条件:
~~~

**結果:** 成功時は「報告を送信しました。Revclipの改善にご協力いただきありがとうございます。」と表示され、入力欄がクリアされます。送信失敗時は入力内容が残ります。アプリを起動している間は下書きが保持されますが、アプリを終了した後まで保存される仕組みではありません。送信失敗後にフォームを開き直すと、入力は戻りますが同意はオフなので、再送する場合は送信内容を再確認して改めて同意してください。

<!-- block: callout tone=warning -->
> 報告は自動再送されません。通信がタイムアウトしても、すでに届いている場合があります。同じ内容をすぐに送り直すと重複する可能性があるため、送信状況が分からない場合は再送を急がないでください。

## CLIから不具合を報告する

CLIは、Revclipアプリに同梱された実行ファイルから報告を依頼します。選択した通常版またはDemo版が起動中で、CLIを含む更新済みの版である必要があります。CLIは説明ファイルを添付ファイルとして送らず、ファイルのUTF-8テキストを説明欄に読み込みます。読み込んだファイルはCLIが削除しません。

次の手順で、ローカルのUTF-8テキストファイルを用意してから実行します。[CLIリファレンス](./09-cli-reference.md)の手順でAPPを対象アプリに設定してから、送信する内容を `report.txt` に保存し、例の件名を置き換えてください。説明ファイルの中身は本文として送信されます。ファイルそのものは削除されません。

~~~sh
"$APP/Contents/Helpers/revclip" --app Revclip bug-report \
  --title="不具合の件名" \
  --description-file="report.txt" \
  --consent-source-info
~~~

Demo版から送る場合は、APPをDemo版アプリの場所にし、コマンドの「--app Revclip」を「--app revclip-demo」に置き換えます。どちらの場合も「--consent-source-info」は省略できず、このコマンドを実行すると送信元情報の取得に同意したものとして送信を試みます。内容と同意を確認してから実行してください。

件名は120文字、説明は2,500文字、連絡先は任意で200文字までです。上限はUTF-16の単位数で判定されるため、一部の絵文字などは見た目の1文字が2以上として数えられます。説明ファイルを使わず標準入力から渡す方法や、連絡先を付けるオプションは[CLIリファレンス](./09-cli-reference.md)を参照してください。

**結果:** 成功時はCLIが `ok: true` と `status: sent` を含むJSONを返します。失敗時は `ok: false` とエラーを返し、終了コードも失敗を示します。CLIは再試行しません。タイムアウト後は送信されたか分からない場合があるため、結果を確認する前に同じコマンドを繰り返さないでください。

ネットワーク送信が始まった後に失敗した場合、アプリは入力内容を実行中のメモリ上の下書きとして保持します。アプリを終了すると下書きは残りません。CLIからの送信に失敗した後でGUIフォームを開き直すと、下書きが表示されても送信元情報への同意はオフなので、再送前に内容を確認して改めて同意してください。

## 困ったとき

<!-- block: dataTable -->
| 症状 | 確認すること |
| --- | --- |
| 「今すぐ確認」でエラーになる | ネットワーク接続と通常版で起動していることを確認し、時間を置いてから再確認します。Demo版には通常版の更新フィードがありません。 |
| 公開Releaseに新しい版があるのに更新が見つからない | 設定画面のバージョンとビルドを読み直し、通常版かDemo版かを確かめます。通常版ならDMGからの更新手順を確認します。 |
| CLIがアプリへ接続できない | 対象アプリを起動し、通常版には「--app Revclip」、Demo版には「--app revclip-demo」を指定します。更新前のアプリには現在の報告CLIが含まれない場合があります。 |
| GUIで送信ボタンを押せない | 件名と説明を入力し、長さの上限を超えていないこと、送信元情報への同意をオンにしたことを確認します。 |
| CLIの結果がタイムアウトまたは不明になる | 送信前にタイムアウトしたと明示されていない限り、届いている可能性があります。自動再送はされないため、同じ内容をすぐに再送しないでください。 |
| 報告に秘密情報を含めてしまった | 公開Issueへ詳細を転載しないでください。機密性のある脆弱性は、内容を公開せず非公開の連絡方法を確認してください。 |

通常の不具合を公開で相談する場合は[GitHub Issues](https://github.com/sasuketorii/rev_clip/issues)を利用できます。非公開で共有する必要がある内容は、連絡方法を先に確認してください。アプリやCLIからの送信には、上記の送信先と同意内容が適用されます。

## 関連ページ

- [インストール](./02-installation.md)
- [設定](./07-settings.md)
- [エージェント設定](./08-agent-setup.md)
- [CLIリファレンス](./09-cli-reference.md)
- [プライバシーとセキュリティ](./10-privacy-and-security.md)
- [トラブルシューティング](./11-troubleshooting.md)

<!-- 編集注: 出典
README.md「アップデート」「通常版とDemo版」「困ったとき」
SECURITY.md「エージェントとCLIの境界」「問題の報告」
docs/TEMPLATE_CLI.md「Native app commands」「Bug reports」
docs/AGENT_SUPPORT.md「Native app commands」「Checking and updating from Agent Settings」
agents/AgentSupport/revclip/SKILL.md「Select the app」「Bug reports」
src/Revclip/Revclip/UI/Preferences/RCUpdatesPreferencesViewController.m updateVersionInfo/checkNowClicked; src/Revclip/Revclip/Services/RCUpdateService.m setupUpdaterForUpdateCheck/applyStoredPreferencesToUpdater
src/Revclip/Revclip/UI/Preferences/RCBugReportPreferencesViewController.m consentCheckbox/updateSendAvailability/serviceDidChange/sendReport; src/Revclip/Revclip/Services/RCBugReportService.m sourceMetadata/submitTitle
src/Revclip/Revclip/Resources/ja.lproj/Localizable.strings 「Bug Report」「Send Report」「Report sent」日本語表示
src/Revclip/Revclip/UI/Preferences/RCPreferencesWindowController.m RCPreferencesTabBugReport
src/Revclip/RevclipCLI/main.m RCHelp/RCRequest/RCSend; src/Revclip/Revclip/Services/RCSnippetCLIService.m executeBugReportRequest
-->
