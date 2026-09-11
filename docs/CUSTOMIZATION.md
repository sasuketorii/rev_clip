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

1. `PRODUCT_BUNDLE_IDENTIFIER` を独自の値にします。アプリ名・著作権表示も必要に応じて変更します。
2. **保存先も分離します。** Bundle IDの変更だけでは十分ではありません。`App/RCConstants.m` と `Managers/RCDatabaseManager.m` の保存先定義、および `Revclip` を使うデータパスを確認し、独自名へ変更します。既存データを使って検証せず、独自版の空のデータから始めてください。
3. ショートカットの競合を避け、ログイン項目も独自版として確認します。
4. Sparkleの `SUFeedURL` と `SUPublicEDKey` を自分の配信先・公開鍵に変更します。秘密鍵はコードに含めません。独自版に公式版の更新を上書き適用しないよう、配布前に必ず設定してください。
5. `make -C src/Revclip setup` で再生成します。

再配布では[MITライセンス](../LICENSE)と[第三者ライセンス](../THIRD_PARTY_NOTICES.md)を保持してください。署名・公証・更新配信は[リリース手順](RELEASING.md)を参照してください。
