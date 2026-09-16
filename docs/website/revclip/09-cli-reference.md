---
title: "CLIリファレンス"
description: "配布版Revclip 0.1.9のネイティブCLIでテンプレート、許可された設定、エージェント用スキルを管理します。"
slug: revclip/cli-reference
navOrder: 9
productArea: revclip
docVersion: '0.1.9'
status: draft
verifiedAt: '2026-09-16'
---

# CLIリファレンス

Revclipアプリに同梱されたネイティブCLIを使い、テンプレート、許可された設定、エージェント用スキルを操作できます。このページは配布版 **0.1.9（build 42）** のコマンドを対象にしています。アプリ本体の版はCLI内の選択肢で切り替えるものではなく、実行するアプリ内のCLIによって決まります。

<!-- block: callout tone=warning -->
> **0.1.9の実機受入状況**
>
> 実際の画面描画、貼り付け、連続操作の実機受入は未完了です。このページのコマンド説明は現行ソースとテストの照合結果であり、実機受入の完了を示すものではありません。

## 使う前に

1. 対象アプリの場所を `APP` に設定します。次の `path/to/Revclip.app` は相対パスの記入例です。実際の場所へ置き換えてください。
2. アプリ内のCLIを `CLI` として指定します。
3. テンプレート・設定・バグ報告を操作する場合は、同じ対象アプリを起動しておきます。

<!-- block: code language=bash -->
```sh
APP="path/to/Revclip.app"
CLI="$APP/Contents/Helpers/revclip"

"$CLI" --help
```

`--help`（短縮形 `-h`）は、使用方法とコマンド一覧をJSONで表示します。`--app Revclip` は通常版、`--app revclip-demo` はDemo版を選びます。省略時は通常版が対象です。誤操作を避けるため、コマンド例では対象を明示してください。

### コマンド構文

次の `revclip` は、上で `CLI` に設定した同梱バイナリを表します。`|` は選択肢のどちらか一方を指定する記号です。

<!-- block: code language=text -->
```text
revclip --help
revclip [--app Revclip|revclip-demo] settings-schema
revclip [--app Revclip|revclip-demo] settings-get [--key KEY]
revclip [--app Revclip|revclip-demo] settings-set --json OBJECT | --file FILE|-
revclip [--app Revclip|revclip-demo] app-action ACTION
revclip [--app Revclip|revclip-demo] bug-report --title TITLE (--description TEXT | --description-file FILE|-) [--contact TEXT] --consent-source-info
revclip [--app Revclip|revclip-demo] folders
revclip [--app Revclip|revclip-demo] folder-create --title TITLE
revclip [--app Revclip|revclip-demo] folder-delete ID
revclip [--app Revclip|revclip-demo] list [--folder ID]
revclip [--app Revclip|revclip-demo] get ID
revclip [--app Revclip|revclip-demo] create --folder ID --title TITLE (--content TEXT | --content-file FILE|- | --image FILE) [--enabled true|false]
revclip [--app Revclip|revclip-demo] update ID [--folder ID] [--title TITLE] [--content TEXT | --content-file FILE|- | --image FILE] [--enabled true|false]
revclip [--app Revclip|revclip-demo] delete ID
revclip [--app Revclip|revclip-demo] agent inspect|install [--home HOME] [--source PATH] [--provider ID[,ID...]]
```

アプリを起動するのは利用者です。テンプレート・設定・バグ報告のコマンドを実行する前に、選んだアプリを起動してください。`agent inspect` と `agent install` はローカルのスキル登録を扱い、アプリの起動は必要ありません。

<!-- block: callout tone=info -->
> `--app` は通常版とDemo版のどちらへ接続するかを選びます。アプリのバージョンを選ぶオプションではありません。0.1.9のコマンドを使うには、0.1.9（build 42）のアプリに同梱されたCLIを実行してください。

## 出力と終了コード

通常のCLIコマンドは、成功時に `ok` と `result`、失敗時に `ok` と `error` を含むJSONを標準出力へ1件出します。CLI自体の入力エラーでは `note` が追加される場合があります。

<!-- block: code language=json -->
```json
{
  "ok": true,
  "result": {
    "identifier": "<作成されたID>"
  }
}
```

| 終了コード | 意味 |
| --- | --- |
| `0` | コマンド成功。`agent` コマンドでは未検出の製品や未対応の製品がスキップされても、失敗がなければ `0` です。 |
| `1` | アプリ側の失敗、競合、入力ファイルの読み取り失敗、またはタイムアウトなど。 |
| `2` | コマンド名・引数の指定ミス。 |

書き込みのタイムアウトは、処理が完了したか分からない場合があります。再実行する前に、テンプレートなら `list` / `get`、設定なら `settings-get` で現在の状態を確認してください。バグ報告は配信済みの可能性があるため、タイムアウト後に同じ報告を自動で再送しないでください。

## フォルダとテンプレート

テンプレートコマンドが扱うのは、Revclipに登録したフォルダとテンプレートです。IDには応答の `identifier` を使います。表示名やデータベースの行番号はIDの代わりになりません。

<!-- block: dataTable -->
| コマンド | 入力 | 結果・動作 |
| --- | --- | --- |
| `folders` | なし | フォルダ一覧。各フォルダの `identifier` を確認できます。 |
| `folder-create --title TITLE` | 空でないフォルダ名 | フォルダを作成し、`result.identifier` を返します。 |
| `folder-delete ID` | 空のフォルダID | 空のフォルダを削除します。テンプレートが残っているフォルダは削除できません。 |
| `list [--folder ID]` | 任意のフォルダID | テンプレート一覧。`--folder` を省くと全フォルダが対象です。 |
| `get ID` | テンプレートID | そのテンプレートを返します。 |
| `create` | `--folder ID`、`--title TITLE`、本文か画像を1つ（`--content TEXT`、`--content-file`、`--image FILE`）。任意で `--enabled true/false`。 | テンプレートを作成し、`result.identifier` を返します。 |
| `update ID` | 任意の `--folder ID`、`--title TITLE`、本文または画像、`--enabled true/false` のうち1つ以上。 | 指定した項目を更新します。変更項目を省くことはできません。 |
| `delete ID` | テンプレートID | そのテンプレートを削除し、対象の `identifier` を返します。 |

`list` と `get` の結果にはテキストテンプレートの本文が含まれます。画像テンプレートでは画像データそのものはJSONに含めず、サイズを `media_bytes` で示します。本文が機密情報を含む場合、ターミナル出力を共有しないでください。

### テンプレートを作る・更新する

1. `folders` を実行して、使うフォルダの `identifier` を確認します。新しいフォルダが必要なら `folder-create` を実行します。
2. `create` の `--folder` と `--title` に値を入れ、本文か画像を1つ指定します。
3. 成功応答の `result.identifier` を控えます。以降の更新・取得・削除にはそのIDを使います。
4. `get ID` で変更後のテンプレートを確認します。

<!-- block: code language=bash -->
```sh
"$CLI" --app Revclip folders
"$CLI" --app Revclip folder-create --title "作業用"
"$CLI" --app Revclip create --folder FOLDER_ID --title "挨拶" --content "お世話になっております。"
"$CLI" --app Revclip get TEMPLATE_ID
```

`FOLDER_ID` と `TEMPLATE_ID` は、直前の応答にある `identifier` へ置き換えます。`folder-create` と `create` の成功結果は次の形式です。

<!-- block: code language=json -->
```json
{
  "ok": true,
  "result": {
    "identifier": "<実際の応答にあるID>"
  }
}
```

長い本文はUTF-8のテキストファイルから読み込めます。`-` を指定すると標準入力を読みます。

<!-- block: code language=bash -->
```sh
"$CLI" --app Revclip create --folder FOLDER_ID --title "案内文" --content-file message.txt
printf "%s" "更新後の本文" | "$CLI" --app Revclip update TEMPLATE_ID --content-file -
"$CLI" --app Revclip create --folder FOLDER_ID --title "ロゴ" --image logo.png
"$CLI" --app Revclip update TEMPLATE_ID --enabled false
```

| 入力 | 上限・動作 |
| --- | --- |
| `--title` | 1〜4096 UTF-16コード単位。作成時に必須です。 |
| `--content` / `--content-file` | UTF-8のテキストで最大1 MiB。`--content-file` は通常ファイルか `-` を指定します。 |
| `--image` | 画像ファイルで最大10 MiB。単一画像で、各辺8,192 px以下、合計16,000,000画素以下の形式に限ります。 |
| `--enabled` | `true` または `false`。省略時は作成なら有効、更新なら既存の状態を保持します。 |

`update` でタイトルや有効状態だけを変更すると、本文と画像は保持されます。`--content` / `--content-file` を指定すると画像をテキストへ置き換え、`--image` を指定するとテキストを画像へ置き換えます。`--folder` を指定すると移動先フォルダを変更します。

## 設定を読む・変更する

`settings-schema` がCLIから変更できる設定名、型、範囲、列挙値、操作を返します。対応設定は35項目です。設定名や値を推測せず、最初にスキーマを確認してください。

<!-- block: dataTable -->
| コマンド | 入力 | 結果・動作 |
| --- | --- | --- |
| `settings-schema` | なし | 対応設定、型・範囲、アクション、境界情報を返します。 |
| `settings-get [--key KEY]` | 任意の設定名 | `--key` があれば1項目、なければ現在の設定値一式を返します。 |
| `settings-set` | `--json OBJECT` または `--file FILE` のどちらか1つ。`--file -` は標準入力です。 | 空でないJSONオブジェクトを検証して変更します。 |
| `app-action ACTION` | `update-check` または `permissions` | 対応するアプリ操作をキューへ入れます。 |

次の例は外観を変更する場合です。コマンドのJSON値はシェルで引用し、設定ファイルを使う場合はUTF-8のJSONオブジェクトを用意してください。

<!-- block: code language=bash -->
```sh
"$CLI" --app Revclip settings-schema
"$CLI" --app Revclip settings-get --key appearance
"$CLI" --app Revclip settings-set --json '{"appearance":"dark"}'
"$CLI" --app Revclip settings-get --key appearance
"$CLI" --app Revclip settings-set --file settings.json
"$CLI" --app Revclip app-action update-check
"$CLI" --app Revclip app-action permissions
```

`settings-set` の入力は1 MiB以下のUTF-8 JSONです。空のオブジェクト、重複キー、`NaN` / `Infinity`、スキーマにないキーや範囲外の値は拒否されます。すべての値を変更前に検証しますが、複数サービスにまたがる変更は一括トランザクションではありません。応答の `applied_keys` と `values` を確認し、必要なら `settings-get` でも読み直してください。

`login_at_startup` を変更するときはmacOSの承認が必要な場合があります。そのキーを変更した応答には `login_status` も含まれます。

`max_history_size` や保存期限の設定変更は、条件に応じて通常の履歴整理を予定します。追加の削除確認はなく、応答の `cleanup_scheduled` は整理を予定したかを示すだけで、削除完了の確認ではありません。

<!-- block: callout tone=warning -->
> CLIで扱えない設定があります。ショートカットとPanicはCLIの対象外です。対応するキー以外のアプリ設定を直接書き換えるコマンドはありません。

`app-action` が返す `status: queued` は操作の受付です。`permissions` で必要なmacOSの許可を得るときや、更新を完了するときは、画面を確認して利用者が操作してください。許可済み・更新済みを示す応答ではありません。

## エージェント用スキルを確認・登録する

`agent inspect` は登録状態を確認し、`agent install` はアプリに同梱されたRevclipスキルを対応するエージェントのスキル配置先へコピーまたは更新します。コマンドはエージェントを起動せず、登録後の再読み込みも行いません。

<!-- block: code language=bash -->
```sh
"$CLI" agent inspect --app Revclip
"$CLI" agent install --app Revclip --provider codex,claude
"$CLI" agent inspect --app Revclip --provider codex,claude
```

| オプション | 入力・動作 |
| --- | --- |
| `--app` | `Revclip` または `revclip-demo`。使うアプリの同梱スキルを選びます。省略時は `Revclip` です。 |
| `--provider ID[,ID...]` | 登録先をプロバイダーIDで絞ります。繰り返し指定できます。 |
| `--home HOME` | 検査・登録に使うホームを変更します。絶対パスまたは `~/` で始まるパスを指定し、相対パスと `..` は使えません。 |
| `--source PATH` | `AgentSupport` ディレクトリまたはその `revclip` 子ディレクトリを明示します。絶対パスまたは `~/` で始まり、`..` を含まないパスが必要です。通常は省略します。 |

`--provider` に指定できるIDは `codex`、`claude`、`cursor`、`antigravity2`、`antigravity-ide`、`antigravity-cli`、`gemini`、`grok`、`kimi`、`kimi-legacy`、`hermes`、`deepseek-harness` です。`antigravity-cli` はバンドル登録の対象外で、検出された場合は `unsupported` としてスキップされます。`deepseek-harness` は実験的な対象です。各エージェントの配置と再読み込み方法は[エージェント導入ガイド](08-agent-setup.md)を参照してください。

`inspect` と `install` は、アプリに同梱されたプロバイダー一覧にある設定場所だけを確認します。検出先の存在はエージェントのインストールや実行中セッションを保証しません。検出先そのものを新しく作らず、登録先の既存スキルが手作業で変わっている場合は競合として扱い、上書きしません。

応答は `schema_version`、`command`、`app`、`ok`、`source_error`、`providers` を含むJSONです。`providers` の各行には `detected`、`state`、`action`、`update_available`、`reason`、`reload` などが含まれます。

<!-- block: dataTable -->
| 出力値 | 意味 |
| --- | --- |
| `state: missing` | 登録先にRevclipスキルがありません。 |
| `state: current` | 管理対象のコピーがアプリ同梱版と一致しています。 |
| `state: managed` | 管理対象のコピーがありますが、アプリ同梱版と差があります。`update_available` も確認してください。 |
| `state: conflict` | 未管理または変更済みのコピーなどがあり、安全に扱えません。 |
| `state: unsupported` | そのプロバイダー形式へのスキル登録は未対応です。 |
| `action: skipped` / `none` | 登録先が未検出でスキップされた状態 / `inspect` のみ実行した状態です。 |
| `action: installed` / `updated` / `unchanged` / `failed` | 新規登録 / 更新 / 変更不要 / 失敗です。 |

終了コード `0` でも、未検出や未対応の登録先はスキップされることがあります。全件登録されたと判断せず、各行の `action` と `reason` を確認してください。登録後のスキル再読み込みは `reload` の案内に従ってください。

## バグ報告を送る

CLIのバグ報告は、件名と説明を入力し、送信元情報の送信へ明示的に同意した場合だけ送信されます。次のコマンドは報告内容をネットワーク経由で開発者へ送ります。

<!-- block: callout tone=danger -->
> `--consent-source-info` は必須です。このオプションを含めると、送信元IP、地域、回線、言語、タイムゾーン、アプリ・OSの情報、User-Agentも送信対象になります。報告内容と任意の連絡先はCloudflare経由で開発者のTelegramグループへ送信されるため、秘密情報を含めないでください。

<!-- block: code language=bash -->
```sh
"$CLI" --app Revclip bug-report --title "問題の概要" --description-file report.txt --consent-source-info
```

`--description` には説明を直接指定できます。`--description-file` はUTF-8のファイルまたは `-`（標準入力）を指定します。どちらか一方が必要です。`--contact` は任意です。

<!-- block: dataTable -->
| 入力 | 制限 |
| --- | --- |
| `--title` | 1〜120 UTF-16コード単位。前後の空白は送信前に取り除きます。 |
| `--description` / `--description-file` | 1〜2,500 UTF-16コード単位。ファイル入力は最大16 KiBです。 |
| `--contact` | 0〜200 UTF-16コード単位。省略できます。 |

成功時は `result.status` が `sent` になります。これはTelegramから成功応答を受け取ったことを示します。CLIはクリップボード、履歴、テンプレート、ログ、スクリーンショットを自動添付しませんが、説明欄に自分で入力した情報は送信されます。タイムアウト後は送信済みか不明な場合があるため、同じ報告をすぐに再送しないでください。

## 履歴とセキュリティの境界

CLIにはコピー履歴の一覧・本文、または現在のクリップボードを読むコマンドがありません。`list` と `get` はテンプレートだけを返し、履歴を指定する入力も拒否します。設定コマンドは許可リストの設定だけを扱います。

<!-- block: callout tone=warning -->
> これはCLIが提供する操作範囲です。保存データの暗号化やCLIのコマンド制限は、同じmacOSユーザー権限を持つプログラムからの完全な隔離を意味しません。CLI以外のファイル・macOS API・画面操作へのアクセスまで、このCLIが制限するわけではありません。

クリップボードの監視間隔は既定で500msです。次の観測より前に別のコピーで上書きされた内容をすべて記録できる保証はありません。履歴の保存・復元については[履歴と貼り付け](04-history-and-paste.md)、保存とアクセスの境界は[プライバシーとセキュリティ](10-privacy-and-security.md)を確認してください。

## 困ったとき

<!-- block: dataTable -->
| 表示・症状 | 確認すること |
| --- | --- |
| `Start the updated ...app first` | 対象アプリが起動しているか、アプリ内CLIと `--app Revclip` / `--app revclip-demo` の選択が一致しているかを確認します。 |
| `Unknown setting key` / `Invalid value` | `settings-schema` で許可されたキー、型、範囲、選択肢を調べます。 |
| `Login item registration failed` | ログイン項目の登録に失敗し、他のアプリ設定値は書き込まれていません。`settings-get --key login_at_startup` で状態を確認し、必要なら設定画面から変更します。 |
| `Folder not found` / `Template ID not found` | 表示名ではなく、直前の応答の `identifier` を使っているか確認します。 |
| `Folder must be empty` | フォルダ内のテンプレートを確認し、必要なものを移動または個別に削除してから実行します。 |
| `No fields to update` | `update` に変更する `--title`、`--folder`、本文・画像、`--enabled` のいずれかを追加します。 |
| `Editor is loading media or its draft could not be saved` | テンプレートエディタの読み込みや保存が終わってから、一覧で現在の状態を確認して操作します。 |
| `Operation timed out` | `list` / `get` または `settings-get` で状態を確認してから、必要な場合だけ再実行します。バグ報告は自動再送しません。 |
| `agent install` が競合・失敗を返す | `inspect` の各行にある `state` と `reason` を確認します。競合コピーを強制上書きするオプションはありません。 |

`queued` は操作を受け付けた状態であり、macOSの許可や更新の完了を表しません。画面で必要な操作を確認してください。ほかの症状は[トラブルシューティング](11-troubleshooting.md)を参照してください。

## 関連ページ

- [はじめに](00-index.md)
- [テンプレートを使う](06-templates.md)
- [設定を調整する](07-settings.md)
- [エージェント連携を設定する](08-agent-setup.md)
- [更新とフィードバック](12-updates-and-feedback.md)
- [プライバシーとセキュリティ](10-privacy-and-security.md)

<!-- 編集注: 出典: README.md「CLIとAIエージェントからの操作」「エージェントからの履歴アクセス」「コピー履歴と保存形式」; SECURITY.md「エージェントとCLIの境界」「問題の報告」; docs/TEMPLATE_CLI.md「Template CLI」「Preferences CLI」「History access boundary」「Bug reports」; docs/AGENT_SUPPORT.md「Native app commands」「Detection and destinations」「JSON contract and exit status」; docs/QUALITY_REPORT.md「v0.1.9公開・更新配信の確認」; src/Revclip/project.yml:AgentSupport resource / Embed native CLI; src/Revclip/RevclipCLI/main.m:RCHelp, RCRequest, RCSend, RCOutput; src/Revclip/RevclipCLI/RCAgentSkillInstaller.h:runArguments contract; src/Revclip/RevclipCLI/RCAgentSkillInstaller.m:RCAbsolute, RCUpdateRow, RCRun, runArguments; src/Revclip/Revclip/Services/RCSnippetCLIService.m:executeRequest:, executeBugReportRequest:, serveClient:; src/Revclip/Revclip/Services/RCSettingsCLIService.m:RCSettingsDefinitions, executeOnMainThread:; src/Revclip/RevclipTests/RCSnippetCLITests.m:RCSnippetCLIPrivacyBoundaryTests; src/Revclip/RevclipTests/RCSettingsCLITests.m:testSchemaAndDefaultsCoverEveryPreferencesPageExceptExcludedGroups; agents/AgentSupport/providers.json:providers; agents/AgentSupport/revclip/SKILL.md「Templates」「Preferences and app actions」「Bug reports」「Results and failures」. -->
