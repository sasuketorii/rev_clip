# Security policy / セキュリティ方針

## 保護するもの

Revclipは、クリップボード履歴を扱うローカルアプリです。保存データの漏えいリスクを下げるため、以下を実装しています。

- **保存時の暗号化**: 履歴タイトル、テンプレート本文、検索用ハッシュを含むデータベース全体をSQLCipherで暗号化します。クリップ本文とサムネイルはCryptoKitのAES-256-GCMで暗号化・認証します。
- **鍵の管理**: 暗号学的乱数で生成した256ビットの鍵をmacOSのログインキーチェーンに保存し、データベース用とファイル用の鍵をHKDFで分離します。鍵をリポジトリ、設定ファイル、履歴フォルダへ保存しません。キーチェーンの項目はiCloud同期の対象にしません。
- **機密クリップの除外**: concealed / transient / auto-generatedのマークがあるコピーは、本文の読み取り前に記録対象から外します。監視時の前面アプリが除外設定に一致した場合も、本文を読み取りません。
- **読み込みの制限**: 保存ファイルとインポートにはサイズ上限を設け、保存ファイルの型・認証情報を検証します。保存先のシンボリックリンクを拒否し、データ用ディレクトリとファイルのアクセス権を制限します。
- **失敗時の動作**: 鍵を取得できない、データベースを検証できない、移行を完了できない場合は、履歴収集を開始しません。暗号化された既存データに対して、新しい鍵や空の履歴で上書きする復旧処理は行いません。

## 保護範囲の限界

### エージェントとCLIの境界

RevclipのCLIは履歴本文・履歴一覧・現在のクリップボードを公開しません。`list` / `get` はテンプレート専用で、履歴を指定する追加フィールドや未対応の操作は拒否します。設定CLIは許可された設定項目だけを扱い、履歴の保存件数・期限を変更できても、保存内容は返しません。バグ報告にも履歴を自動添付しません。

これはRevclipが提供するAPIの制限です。端末全体へのアクセス権があるエージェントによる、OSのクリップボードAPI・画面操作・他プロセスへのアクセスまで禁止するサンドボックスではありません。同梱スキルにも、履歴取得を別の手段で迂回しないことを記載しています。

これはパスワードマネージャーや、侵害されたMacから秘密を守る仕組みではありません。

- 暗号化は、**保存ファイルだけがコピーされた場合**の内容保護を主な目的としています。動作中は復号した内容と鍵がメモリに存在します。管理者権限、マルウェア、プロセスへの侵入、ユーザーが許可したキーチェーンアクセスからの完全な保護は保証しません。
- 通常の利用でTouch IDを毎回要求する構成ではありません。Macの画面ロックとFileVaultも併用してください。
- クリップボード自体、貼り付け先アプリ、画面に表示したプレビュー、テンプレートのエクスポートファイルは、この保存暗号化の対象外です。エクスポートには本文が含まれるので、共有先と保存場所を確認してください。
- コピー元が機密マークを付けていないパスワードや個人情報を、確実に自動検出することはできません。必要なアプリを除外設定に追加してください。アプリの判定には監視時の前面アプリを使うため、コピー直後にアプリを切り替えた場合など、コピー元を正しく判定できないことがあります。除外設定だけを秘密情報の完全な防御として扱わないでください。
- 旧版の平文データは起動時に移行しますが、過去のバックアップ、APFSスナップショット、SSD上の残存データまで遡って暗号化・消去することはできません。暗号化形式を読めない旧版へのダウングレードは避けてください。
- 鍵を失うと保存データを復号できません。Revclip側に鍵の預かりや復旧サービスはありません。
- 履歴・テンプレートをクラウド同期する機能はありません。アップデート確認・ダウンロードと、URL単体のリンクプレビュー・ファビコン取得はネットワークを利用します。既定は自動取得です。メニュー表示・ホバー時に取得します。設定の「プライバシー → リンク」で手動取得または取得しないを選べます。手動取得ではリンクにカーソルを合わせて⌥を押した場合だけ取得します。取得時にはIPアドレスやURL全体がサイトに伝わり得ます。許可の取り消しは進行中の取得を中止し、キャッシュを消去します。文章に混在するURLではリンク取得を行いません。
- Developer ID署名とApple公証は配布物の確認に役立ちますが、脆弱性がないことを証明するものではありません。第三者によるセキュリティ認証や、完全な独立監査を受けた製品とは表現しません。

## 問題の報告

設定の「高度な設定 → バグ報告」フォームは、送信ボタンを押した場合だけ、入力した件名・説明・任意の連絡先と、同意した送信元情報（IP・地域・回線・言語・タイムゾーン・アプリ／OSバージョン・User-Agent）をCloudflare経由で開発者のTelegramグループへ送信します。履歴・テンプレート・クリップボード・ログ・スクリーンショットは自動添付しません。入力内容はCloudflareとTelegramで処理されるため、秘密情報を含めないでください。

TelegramのBotトークンと受信先はWorkerのSecretに保存し、アプリには配布しません。報告URL自体は公開情報です。サーバーは送信先を固定し、本文上限・送信回数制限・タイムアウトを適用します。回数制限は不正送信の完全な防止や、アプリからの送信であることの認証を保証しません。

最新リリースを対象に修正します。再現手順、影響、対象バージョンを添えて報告してください。クリップボードの実データ、鍵、認証情報は公開Issueに貼らないでください。非機密の不具合は[Issues](https://github.com/sasuketorii/rev_clip/issues)で受け付けています。機密性のある報告は、まず内容を公開せず、非公開の連絡方法を確認してください。

## English

The optional Bug Report form sends the entered subject, description, optional
contact, and consented source information (IP, region, network, language, timezone, app/OS
versions, and User-Agent) through Cloudflare to the developer's
Telegram group only when Send is pressed. It does not automatically attach history,
templates, clipboard contents, logs, or screenshots. Cloudflare and Telegram process
the submitted information. The bot token and recipient stay in Worker Secrets;
the app contains only the public endpoint. Server-side validation, rate limits and
timeouts reduce abuse but do not authenticate an official app or eliminate spam.

Revclip encrypts its local database with SQLCipher, including history titles and template contents. Clip payloads and thumbnails use authenticated AES-256-GCM encryption through CryptoKit. A randomly generated 256-bit root key is stored in the macOS login Keychain, with separate HKDF-derived keys for the database and files. The Keychain item is not configured for iCloud synchronization.

Concealed, transient, and auto-generated clipboard markers are checked before reading clipboard contents. Capture is also skipped when the frontmost app observed during monitoring matches an exclusion. File reads and imports are bounded; encrypted files are authenticated; storage permissions and symlink checks constrain file operations. If the key, database, or migration cannot be validated, clipboard collection does not start. Existing encrypted data is not replaced with a new key or an empty history.

**The main protection boundary is a copy of the stored files without the key.** This is not a password manager or a defense against a compromised Mac. Keys and decrypted content exist in process memory while the app runs. Normal use does not require biometric authentication for every access. Clipboard contents, destination apps, visible previews, and exported templates are outside the at-rest encryption boundary. Unmarked secrets cannot be detected reliably. App exclusion uses the frontmost app at polling time, not authoritative copy-origin metadata; rapid app switching can therefore miss an excluded source. Use app exclusions, screen locking, and FileVault as appropriate.

Legacy plaintext files are migrated, but old backups, APFS snapshots, and SSD remnants cannot be retroactively encrypted or reliably erased by the app. Avoid downgrading to a release that cannot read the encrypted format. Losing the Keychain key makes stored data unrecoverable; Revclip has no key escrow or recovery service.

Revclip has no cloud history synchronization. Update checks and downloads, plus link previews and favicon retrieval for standalone web URLs, use the network. Automatic fetching is the default: opening a menu or hovering can connect. Choose manual or disabled fetching under Privacy → Links. In manual mode, point at a link and press Option to fetch it. Fetching can expose your IP and full URL to the website. Changing permission cancels pending requests and clears cached previews. URLs embedded in prose do not trigger link retrieval. Developer ID signing and Apple notarization are distribution checks, not proof that an application has no vulnerabilities. Revclip does not claim third-party security certification or a comprehensive independent audit.

Security fixes target the latest release. Include the affected version, impact, and reproduction steps when reporting a problem. Never post real clipboard contents, keys, or credentials in public issues. Use [Issues](https://github.com/sasuketorii/rev_clip/issues) for non-sensitive bugs; establish a private contact channel before sharing a confidential vulnerability report.

## faster OCR candidate boundary

faster OCR (working name: RevOCR) temporarily acquires one display frame for selection and recognizes only the selected crop with Apple Vision. Images stay in memory and are not saved or sent by faster OCR. Results use the existing encrypted text-history path only when collection, format, exclusion and OCR-saving policies allow. Every internal OCR copy includes a transient pasteboard marker to prevent polling and another Revclip distribution from importing it again. The marker is always present, also when the text is saved to Revclip history, so clipboard managers that honor it do not record faster OCR results; this is intended and is not a confidentiality control. It does not prevent other apps or OS clipboard synchronization from accessing copied text. Foreground-app exclusion cannot identify every window represented in the pixels, and OCR does not detect all secrets. No screen-reading CLI or network endpoint is added: the CLI exposes faster OCR settings and shortcuts only, never capture or recognized text. Shortcuts are registered non-exclusively and Revclip does not enumerate other applications' shortcuts. Only while the user explicitly records a shortcut in the focused settings field, a session event tap consumes key presses and releases to prevent shortcut actions. Capture ends on completion, cancellation, focus loss, page removal, or a 30-second timeout; typed events are neither logged nor persisted. If safe capture is unavailable, recording does not start. This is not a continuously running keyboard monitor. See [faster OCR](docs/REV_OCR.md) for cancellation, clipboard races, and remaining acceptance checks.
