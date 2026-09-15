# Revclipを自分の道具にする

## UIを編集する

アプリの入口は `src/Revclip/Revclip/App/RCAppDelegate.m`、メニュー構築は `Managers/RCMenuManager.m` です（以下のソースパスは `src/Revclip/Revclip` を基準にしています）。

- **メニュー**: 標準のNSMenuが選択・サブメニュー・キーボード操作を担当します。表示や並びを変えるときも、クリック・矢印キー・Enter・設定・終了まで動作確認してください。
- **プレビュー**: `UI/RCFastPreviewController.m` に遅延と配置処理があります。画面端では上側に回り込むため、下端や複数画面でも確認してください。
- **エディタ**: `UI/SnippetEditor/SnippetEditorView.swift` がSwiftUIの表示、`SnippetEditorModel.swift` が保存などの操作を担当します。
- **テーマ**: `UI/Appearance/RCAppearanceController.swift` がアプリの外観を適用します。固定の白・黒より、外観に追従する色を使うと両モードに対応しやすくなります。
- **翻訳**: `Resources/*.lproj/Localizable.strings` を編集します。新しい表示文字列には各言語のキーを揃え、`RCLocalizedString` で取得してください。`UI/Localization/RCLocalization` が選択言語を管理し、`RCLanguageDidChangeNotification` で表示を更新します。XIBの固定ラベルには対応するセルのObject IDをidentifierとして設定し、同名の`.strings`テーブルで翻訳します。入力値やユーザーが作成した本文は翻訳しません。

変更後はリポジトリのルートから `make -C src/Revclip test` を実行し、実際の貼り付け先アプリでも確認してください。

## アイコンを変更する

READMEの画像は `revclip_icon_rounded.png`（ラウンド版）です。アプリアイコンとは別に差し替えられます。

アプリアイコン用の `revclip_icon_square.png` を用意し、ルートから以下を実行します。Pillowはアイコン生成時だけ使用します。

```sh
python3 -m venv .venv
.venv/bin/pip install Pillow
.venv/bin/python scripts/generate_icons.py
```

## 独自版を並行して使う

`src/Revclip/project.yml` が設定の正本です。生成した `.xcodeproj` を直接編集しても、再生成で上書きされます。

撮影用の分離版は、追加設定なしで次のコマンドから起動できます。通常版を終了し、`revclip-demo` を起動します。

```sh
make -C src/Revclip demo-run
```

Demo版は `com.revclip.revclip-demo`、`revclip-demo` の保存領域、専用のUserDefaultsとKeychainサービスを使います。通常版の履歴・設定・暗号鍵は読みません。更新確認とログイン時起動はDemo版では無効です。

独自のForkを作る場合は、次の設定を同じ組み合わせで変更します。

1. `PRODUCT_BUNDLE_IDENTIFIER` を独自の値にします。アプリ名・著作権表示も必要に応じて変更します。
2. **保存先も分離します。** Bundle IDの変更だけでは十分ではありません。`RC_STORAGE_DIRECTORY_NAME` と `RCStorageDirectoryName` を独自名へ変更し、既存データを使わず空のデータから始めてください。
3. ショートカットの競合を避け、ログイン項目も独自版として確認します。
4. Sparkleの `SUFeedURL` と `SUPublicEDKey` を自分の配信先・公開鍵に変更します。秘密鍵はコードに含めません。独自版に公式版の更新を上書き適用しないよう、配布前に必ず設定してください。
5. `make -C src/Revclip setup` で再生成します。

再配布では[MITライセンス](../LICENSE)と[第三者ライセンス](../THIRD_PARTY_NOTICES.md)を保持してください。署名・公証・更新配信は[リリース手順](RELEASING.md)を参照してください。

### Demo image templates

In `revclip-demo`, **Add Media…** beneath the template content attaches a still image to the selected template and keeps its title. **Replace Image…** replaces the selected image. Images are embedded in the encrypted template database, so moving the source file does not break a template. The menu shows a thumbnail beside the title; selecting it pastes an image through the existing paste service.

Each image is limited to 10 MB, 16 megapixels, and 8192 pixels per side. Animated images are not supported. Image exports use snippet format version 2 and include the image bytes; text-only exports retain version 1. Imports accept both versions. The total import/export file limit remains 50 MB.

Image templates also show an aspect-preserving hover preview directly beneath the submenu. Its panel stays within the submenu width and is capped at 360 points high. Demo builds use `DEMO_CODE_SIGN_IDENTITY` (default `Apple Development`) so normal rebuilds retain a stable signing identity for macOS Accessibility permissions.

### HTML clipboard history

The Types settings include HTML (formatting and design clipboard data). HTML is
saved verbatim in the encrypted history archive and restored with the other
representations, including after an intervening copy. This retains embedded
design payloads without parsing or rendering HTML. Capture is capped at 32 MiB
and remains subject to the configured archive size limit and excluded-app /
concealed-clipboard protections. Disabling HTML removes that representation
from newly captured entries. Existing history is unchanged; entries captured
before HTML support must be copied again. Browser-internal source tokens are
not persisted, and this does not promise support for arbitrary private formats.
