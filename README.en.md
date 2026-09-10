<div align="center">
  <img src="revclip_icon_rounded.png" width="128" height="128" alt="Revclip icon" />
  <h1>Revclip</h1>
  <p><strong>Copy once. Find it again. Make your clipboard your own.</strong></p>
  <p>A native macOS clipboard manager. Local history. Reusable templates. Yours to customize.</p>

  <a href="https://github.com/sasuketorii/rev_clip/releases/latest"><img src="https://img.shields.io/github/v/release/sasuketorii/rev_clip?color=007aff" alt="Latest release" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-34c759" alt="MIT License" /></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-111827?logo=apple&amp;logoColor=white" alt="macOS 14 or later" />
  <img src="https://img.shields.io/badge/UI-AppKit%20%2B%20SwiftUI-007aff" alt="AppKit and SwiftUI" />
  <img src="https://img.shields.io/badge/runtime_dependencies-2-5856d6" alt="2 direct third-party runtime dependencies" />
  <a href="https://github.com/sasuketorii/rev_clip/actions/workflows/ci.yml"><img src="https://github.com/sasuketorii/rev_clip/actions/workflows/ci.yml/badge.svg" alt="Build and tests" /></a>

  <p><a href="README.md">日本語</a> · <strong>English</strong></p>
  <p><a href="#get-started">Get started</a> · <a href="docs/CUSTOMIZATION.md">Customize</a> · <a href="CONTRIBUTING.md">Contribute</a></p>
</div>

---

**History, templates, and settings—all at ⌘⇧V.** Revclip lives in your Mac's menu bar. Browse past copies, preview a template, and paste it into the app you were using. Keep your workflow moving from a single menu.

## A small app for everyday copying

| Feature | What it means for you |
| --- | --- |
| **Native macOS UI** | Standard AppKit menus and SwiftUI, without an Electron or WebView runtime. |
| **Local history** | Your history and templates stay on your Mac. No account or cloud setup required. |
| **Ten items at a time** | History is grouped into folders of ten by default. Adjust the grouping and menu options in settings. |
| **Reusable templates** | Organize text into folders, edit it in a dedicated editor, and import or export your collection. |
| **Preview before pasting** | Hover to preview an item. When space allows, the preview appears below the submenu. |
| **Your preferred appearance** | Choose light, dark, or system appearance. Change the source to build a UI that suits you. |

Revclip uses the network for features such as update checks. It does not provide cloud history sync.

## Privacy and resource use

- **Choose what gets saved.** Copies marked as confidential or transient are excluded from history. You can also exclude specific apps from capture.
- **Protect local files.** Clip files use restricted permissions, and decoding limits the allowed types. This does not guarantee encryption at rest or automatic detection of secrets that have not been marked as sensitive.
- **Read only when the clipboard changes.** Monitoring checks the change count and skips reading unchanged contents. Saving performs archive conversion once.
- **Keep storage growth in check.** Set limits on history count and saved clip size. The saved-size limit is not a guarantee of maximum runtime memory use.

Native UI and few dependencies are the foundation of the design. We have not published comparative CPU or memory benchmarks against other clipboard managers.

## How to use it

Available in Japanese, English, Korean, Simplified Chinese, French, German, Brazilian Portuguese, and Italian. Revclip follows your preferred macOS language. To choose a language for Revclip only, use System Settings → General → Language & Region → Applications, then restart Revclip.

1. Launch Revclip and copy text or other content as usual.
2. Press **⌘⇧V** and choose a history item or template.
3. Paste into the original app. Turn off automatic paste if you only want to copy the selected item to the clipboard.

| Entry point | Opens |
| --- | --- |
| **⌘⇧V** | History, templates, clear history, settings, template editing, and quit |
| **⌘⌃V** | History and app actions, without templates |
| **Menu bar icon** | The main menu |

Automatic paste requires macOS Accessibility permission. Keyboard shortcuts can be changed in settings.

## Get started

**[Download the latest DMG](https://github.com/sasuketorii/rev_clip/releases/latest)** — Developer ID signed and notarized by Apple. The Universal app supports Apple Silicon and Intel. Open the DMG, drag Revclip into Applications, and launch it. Future updates can be checked from within the app.

To build and customize the source, you need **Xcode 26.6** and **XcodeGen**. The app targets **macOS 14 or later** on Apple Silicon and Intel. A paid Apple Developer membership is not required for a Debug build.

```sh
git clone https://github.com/sasuketorii/rev_clip.git
cd rev_clip
brew install xcodegen
make -C src/Revclip setup
make -C src/Revclip debug
open src/Revclip/build/Debug/Revclip.app
```

Launch Xcode once to install its required components, and select Xcode as the active command-line developer tools installation. Quit any existing Revclip instance before opening your build. Builds with the same app identifier use the existing settings and data.

```sh
# Run tests
make -C src/Revclip test

# Edit in Xcode; the project is generated from project.yml
open src/Revclip/Revclip.xcodeproj
```

## Just two direct runtime dependencies

Both third-party dependencies are vendored. A normal build does not need to fetch them through CocoaPods or Swift Package Manager.

| Library | Purpose | Vendored version |
| --- | --- | --- |
| [FMDB](https://github.com/ccgus/fmdb) | A wrapper around macOS SQLite | 2.7.12 |
| [Sparkle](https://github.com/sparkle-project/Sparkle) | App updates | 2.9.6 |

This count excludes macOS system frameworks, Sparkle's internal components, and development tools. XcodeGen generates the project; Pillow is needed only to regenerate icons. See [third-party notices](THIRD_PARTY_NOTICES.md) for licensing details.

## Make the UI yours

Menu density, preview spacing, editor layout, icons—change the parts you use every day. The **MIT license** permits modification, redistribution, and commercial use. Keep the copyright and license notices.

| What to change | Where to start |
| --- | --- |
| Menu and history structure | [RCMenuManager.m](src/Revclip/Revclip/Managers/RCMenuManager.m) |
| Preview position and timing | [RCFastPreviewController.m](src/Revclip/Revclip/UI/RCFastPreviewController.m) |
| Light and dark appearance | [RCAppearanceController.swift](src/Revclip/Revclip/UI/Appearance/RCAppearanceController.swift) |
| Template editor | [SnippetEditor](src/Revclip/Revclip/UI/SnippetEditor) |
| App configuration and build settings | [project.yml](src/Revclip/project.yml) |
| Icons | [generate_icons.py](scripts/generate_icons.py) |

The [customization guide](docs/CUSTOMIZATION.md) covers data separation and update configuration when running your own version alongside the official app. Supporting guides are currently in Japanese. Bug reports and improvement PRs are welcome.

## License

[MIT](LICENSE) © sasuke torii and Revclip contributors. Bundled libraries retain their respective licenses.
