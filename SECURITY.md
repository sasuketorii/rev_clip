# Security policy / セキュリティ方針

## 保護するもの

Revclipは、クリップボード履歴を扱うローカルアプリです。保存データの漏えいリスクを下げるため、以下を実装しています。

- **保存時の暗号化**: 履歴タイトル、テンプレート本文、検索用ハッシュを含むデータベース全体をSQLCipherで暗号化します。クリップ本文とサムネイルはCryptoKitのAES-256-GCMで暗号化・認証します。
- **鍵の管理**: 暗号学的乱数で生成した256ビットの鍵をmacOSのログインキーチェーンに保存し、データベース用とファイル用の鍵をHKDFで分離します。鍵をリポジトリ、設定ファイル、履歴フォルダへ保存しません。キーチェーンの項目はiCloud同期の対象にしません。
- **機密クリップの除外**: concealed / transient / auto-generatedのマークがあるコピーと、ユーザーが除外したアプリからのコピーは、本文の読み取り前に記録対象から外します。
- **読み込みの制限**: 保存ファイルとインポートにはサイズ上限を設け、保存ファイルの型・認証情報を検証します。保存先のシンボリックリンクを拒否し、データ用ディレクトリとファイルのアクセス権を制限します。
- **失敗時の動作**: 鍵を取得できない、データベースを検証できない、移行を完了できない場合は、履歴収集を開始しません。暗号化された既存データに対して、新しい鍵や空の履歴で上書きする復旧処理は行いません。

## 保護範囲の限界

これはパスワードマネージャーや、侵害されたMacから秘密を守る仕組みではありません。

- 暗号化は、**保存ファイルだけがコピーされた場合**の内容保護を主な目的としています。動作中は復号した内容と鍵がメモリに存在します。管理者権限、マルウェア、プロセスへの侵入、ユーザーが許可したキーチェーンアクセスからの完全な保護は保証しません。
- 通常の利用でTouch IDを毎回要求する構成ではありません。Macの画面ロックとFileVaultも併用してください。
- クリップボード自体、貼り付け先アプリ、画面に表示したプレビュー、テンプレートのエクスポートファイルは、この保存暗号化の対象外です。エクスポートには本文が含まれるので、共有先と保存場所を確認してください。
- コピー元が機密マークを付けていないパスワードや個人情報を、確実に自動検出することはできません。必要なアプリを除外設定に追加してください。
- 旧版の平文データは起動時に移行しますが、過去のバックアップ、APFSスナップショット、SSD上の残存データまで遡って暗号化・消去することはできません。暗号化形式を読めない旧版へのダウングレードは避けてください。
- 鍵を失うと保存データを復号できません。Revclip側に鍵の預かりや復旧サービスはありません。
- 履歴・テンプレートをクラウド同期する機能はありません。アップデート確認とダウンロードはネットワークを利用します。
- Developer ID署名とApple公証は配布物の確認に役立ちますが、脆弱性がないことを証明するものではありません。第三者によるセキュリティ認証や、完全な独立監査を受けた製品とは表現しません。

## 問題の報告

最新リリースを対象に修正します。再現手順、影響、対象バージョンを添えて報告してください。クリップボードの実データ、鍵、認証情報は公開Issueに貼らないでください。非機密の不具合は[Issues](https://github.com/sasuketorii/rev_clip/issues)で受け付けています。機密性のある報告は、まず内容を公開せず、非公開の連絡方法を確認してください。

## English

Revclip encrypts its local database with SQLCipher, including history titles and template contents. Clip payloads and thumbnails use authenticated AES-256-GCM encryption through CryptoKit. A randomly generated 256-bit root key is stored in the macOS login Keychain, with separate HKDF-derived keys for the database and files. The Keychain item is not configured for iCloud synchronization.

Confidential, transient, and auto-generated clipboard markers, along with excluded source apps, are checked before reading clipboard contents. File reads and imports are bounded; encrypted files are authenticated; storage permissions and symlink checks constrain file operations. If the key, database, or migration cannot be validated, clipboard collection does not start. Existing encrypted data is not replaced with a new key or an empty history.

**The main protection boundary is a copy of the stored files without the key.** This is not a password manager or a defense against a compromised Mac. Keys and decrypted content exist in process memory while the app runs. Normal use does not require biometric authentication for every access. Clipboard contents, destination apps, visible previews, and exported templates are outside the at-rest encryption boundary. Unmarked secrets cannot be detected reliably. Use app exclusions, screen locking, and FileVault as appropriate.

Legacy plaintext files are migrated, but old backups, APFS snapshots, and SSD remnants cannot be retroactively encrypted or reliably erased by the app. Avoid downgrading to a release that cannot read the encrypted format. Losing the Keychain key makes stored data unrecoverable; Revclip has no key escrow or recovery service.

Revclip has no cloud history synchronization. Update checks and downloads use the network. Developer ID signing and Apple notarization are distribution checks, not proof that an application has no vulnerabilities. Revclip does not claim third-party security certification or a comprehensive independent audit.

Security fixes target the latest release. Include the affected version, impact, and reproduction steps when reporting a problem. Never post real clipboard contents, keys, or credentials in public issues. Use [Issues](https://github.com/sasuketorii/rev_clip/issues) for non-sensitive bugs; establish a private contact channel before sharing a confidential vulnerability report.
