<div align="center">
  <img src="design/branding/revclip_icon_rounded.png" width="128" height="128" alt="Revclip icon" />
  <h1>Revclip</h1>
  <p><strong>Copy once. Find it again. Make your clipboard your own.</strong></p>
  <p>A native macOS clipboard manager. Local history. Reusable templates. Yours to customize.</p>

  <a href="https://github.com/sasuketorii/rev_clip/releases/latest"><img src="https://img.shields.io/github/v/release/sasuketorii/rev_clip?color=007aff" alt="Latest release" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-AGPLv3-34c759" alt="AGPLv3 License" /></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-111827?logo=apple&amp;logoColor=white" alt="macOS 14 or later" />
  <img src="https://img.shields.io/badge/UI-AppKit%20%2B%20SwiftUI-007aff" alt="AppKit and SwiftUI" />
  <img src="https://img.shields.io/badge/runtime_dependencies-3-5856d6" alt="3 direct third-party runtime dependencies" />
  <a href="https://github.com/sasuketorii/rev_clip/actions/workflows/ci.yml"><img src="https://github.com/sasuketorii/rev_clip/actions/workflows/ci.yml/badge.svg" alt="Build and tests" /></a>

  <p><a href="README.md">日本語</a> · <strong>English</strong></p>
  <p><a href="#get-started">Get started</a> · <a href="docs/CUSTOMIZATION.md">Customize</a> · <a href="CONTRIBUTING.md">Contribute</a></p>
</div>

---

**History, templates, and settings—all at ⌘⇧V.** Revclip lives in your Mac's menu bar. Browse past copies, preview a template, and paste it into the app you were using. Keep your workflow moving from a single menu.

A clipboard for working with agents: ask an agent to create, edit, or delete reusable text, prompt, and image templates. Revclip CLI has no commands for reading clipboard history. This defines the CLI’s capabilities; it does not guarantee isolation from an agent with broader OS permissions.

This README describes the **v0.2.0 implementation (build 58, September 17, 2026)**, including faster OCR, permission status, and 44 CLI settings. See [Releases](https://github.com/sasuketorii/rev_clip/releases) for distribution history.

See the [quality verification report](docs/QUALITY_REPORT.md) for the 0.1.8 termination fix and maintenance release, measured results, and remaining acceptance checks.

## A small app for everyday copying

| Feature | What it means for you |
| --- | --- |
| **Native macOS UI** | Standard AppKit menus and SwiftUI, without an Electron or WebView runtime. |
| **Local history** | Your history and templates stay on your Mac. No account or cloud setup required. |
| **Ten items at a time** | History is grouped into folders of ten by default. Adjust the grouping and menu options in settings. |
| **Reusable templates** | Organize text and embedded images into folders, edit them in the dedicated editor or CLI, and import or export your collection. |
| **Preview before pasting** | Hover to preview text, images, supported standalone SVG code, or a standalone URL link card. |
| **Your preferred appearance** | Choose light, dark, or system appearance and edit separate light/dark menu palettes with HEX input. |

In the development build, link fetching defaults to automatic under Privacy → Links. Specialized preferences are grouped into category tabs under Advanced Settings.

Revclip uses the network for updates, standalone URL previews and favicons, and bug reports explicitly submitted with consent. It does not provide cloud history sync.

## Privacy and resource use

- **Choose what gets saved.** Copies marked as confidential or transient are excluded from history. You can also exclude specific apps from capture.
- **Encrypt saved data.** SQLCipher protects the history and template database; AES-256-GCM protects clip payloads and thumbnails. Keys are managed in the macOS Keychain. See the [security policy](SECURITY.md) for the protection boundary and limitations.
- **Read only when the clipboard changes.** Monitoring checks the change count and skips reading unchanged contents. Saving performs archive conversion once.
- **Keep storage growth in check.** Set limits on history count and saved clip size. The saved-size limit is not a guarantee of maximum runtime memory use.

Native UI and few dependencies are the foundation of the design. We have not published comparative CPU or memory benchmarks against other clipboard managers.

### Agent access to history

Agents can use Revclip CLI to create, edit, and delete templates, change allowlisted settings, and submit bug reports with explicit consent. **There are no CLI commands to read history lists, history contents, or the current clipboard.** Changing retention settings does not grant access to stored contents. Bug reports do not automatically attach history.

SQLCipher encrypts the database, AES-256-GCM encrypts saved clip payloads and thumbnails, and macOS Keychain manages the keys. These protect stored data. Neither encryption at rest nor the CLI restrictions completely isolate agents granted broad permissions as the same OS user, or programs with OS-wide control. Other macOS APIs and tools may still read the current clipboard. Runtime memory, the screen, paste destinations, exports, and backups are outside the blanket protection of this storage encryption. See the [security policy](SECURITY.md).

### Bounded history and clearing it

The default history limit is 30 items. When a new copy exceeds the configured count, cleanup removes the oldest excess history rows and their associated files. Age follows history update order, which can change when an item is copied again or reordered after pasting. Cleanup is asynchronous, so the count can temporarily exceed the limit. This deletes stored history rather than merely hiding it.

If you are concerned about retained copies, choose **Clear History** in the menu. It deletes Revclip’s history rows, saved archives, and thumbnails while preserving templates and settings. Neither automatic eviction nor Clear History guarantees secure erasure of backups, snapshots, or physical SSD remnants. Clear History does not empty the current macOS clipboard; new copies can be recorded after monitoring resumes, according to your settings.

### History ordering in 0.1.7

Starting with 0.1.7, recopying content and using history are handled separately. External copies of the same content follow **Overwrite same history**; selecting an existing history item follows **Reorder after pasting**. With both off neither action changes order; with only overwrite on only external recopy moves the item; with only reorder on only history use moves it; with both on both do.

History use is recorded when restoring the clipboard succeeds, including when automatic paste is off. Canceling later key delivery does not undo a successful restore. Failed writes do not update recency, and template use does not count as history use.

Stored update times advance by at least 1ms beyond the retained maximum to preserve last-use order across same-millisecond operations and clock rollback. A large clock rollback can delay age-based expiry; count-based retention still follows last-update order. The default polling interval remains 500ms and cannot recover every copy overwritten before observation. See the [quality report](docs/QUALITY_REPORT.md) for measurements and unverified runtime acceptance.

### Bug-report privacy

Bug reports require explicit consent to collect and send source information: IP address, region, network, language, timezone, app/OS versions, and User-Agent. Reports go through Cloudflare to the developer's Telegram group. History, templates, clipboard contents, logs, and screenshots are not automatically attached. Contact details are optional; failed submissions preserve the input and are not automatically retried. A timeout does not prove that the report was not delivered. The bot token stays in server-side secrets, not in the app.

## How to use it

Available in Japanese, English, Korean, Simplified Chinese, French, German, Brazilian Portuguese, Italian, and Vietnamese. Choose a language in Settings → General → App Language, and the change applies immediately. Choose Follow System to use your preferred macOS language.

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

For a recording build with isolated data, run the following command. It quits the regular app before launching `revclip-demo`.

```sh
make -C src/Revclip demo-run
```

Launch Xcode once to install its required components, and select Xcode as the active command-line developer tools installation. Quit any existing Revclip instance before opening a regular Debug build. Builds with the same app identifier use the existing settings and data; the Demo build uses its own app identifier and storage directory.

```sh
# Run tests
make -C src/Revclip test

# Edit in Xcode; the project is generated from project.yml
open src/Revclip/Revclip.xcodeproj
```

The repository’s `scripts/revclip` and `agents/AgentSupport/install.py` remain Python compatibility/developer tools. Their Python requirement does not apply to the distributed app, native CLI, or skill setup.

## Agent access and SVG previews

Settings → Agent Settings provides a copyable setup prompt. Run it once in Codex
or Claude Code to inspect the supported agent configuration roots on your Mac
and install the bundled Revclip skill into detected tools. The installer protects
unmanaged or locally edited skills; absent products are skipped. The CLI and skill
ship inside the app. The native CLI and installer require neither Python nor a repository checkout.

Agent Settings checks installation state (`installed`) and update availability (`update_available`) when opened and when you choose Recheck. Inspection does not install or overwrite anything. If updates are available, copy the setup prompt and run it manually in your agent. Only validated, unedited managed copies can be updated; local edits and conflicts are preserved.

For terminal use, replace the relative placeholder below with your app location. Subsequent examples use the same `APP` variable:

```sh
APP='path/to/Revclip.app'
"$APP/Contents/Helpers/revclip" agent inspect --app Revclip
"$APP/Contents/Helpers/revclip" agent install --app Revclip
"$APP/Contents/Helpers/revclip" agent inspect --app Revclip
```

The native CLI defaults to `Revclip`; pass `--app revclip-demo` for Demo. Template, settings, and bug-report commands require the target app to be running. Local `agent inspect/install` commands do not start or require the running app.

The CLI supports template creation, editing and deletion, plus settings discovery,
reading and writing for 44 settings, including four OCR preferences and five shortcuts. Panic remains GUI-only. Permissions and update
checks use the app's existing UI. See [agent support](docs/AGENT_SUPPORT.md) and
the [CLI reference](docs/TEMPLATE_CLI.md) for commands and reload instructions.

Settings writes validate all values before mutation. Retention changes schedule normal cleanup without an extra confirmation. CLI notifications update affected controls while preserving unrelated drafts; language changes rebuild the preferences UI. An active HEX editor defers palette-page replacement until the next visit.

Standalone SVG shape code can be previewed in the menu text color. The original
code is preserved when pasted. A bounded background renderer and cache keep the
work on demand; unsupported SVG uses the text preview.

## Report a bug

Open **Settings → Bug Report**, between Agent Settings and Panic. Enter a title and reproduction steps, optionally add contact details, and check the source-information consent box before sending. The GUI and CLI use the same submission service.

```sh
"$APP/Contents/Helpers/revclip" --app Revclip bug-report --title 'Problem summary' --description-file report.txt --consent-source-info
```

The consent flag explicitly authorizes collection and submission of the source information described above. See [feedback deployment](docs/FEEDBACK_DEPLOYMENT.md) and the [security policy](SECURITY.md).

## v0.1.6 validation

Local results recorded on September 16, 2026.

| Check | Result |
| --- | --- |
| macOS XCTest | 225 passed in 24.8 seconds |
| CLI and installer tests, total | 77 passed in 5.9 seconds: 40 Python compatibility + 37 native |
| Native Universal Debug compilation | arm64 and x86_64 passed |
| Bug-report Worker tests | 23 passed, zero skipped |
| Image display for files copied in Finder | Reporter confirmed the image displays on their Mac |
| SVG benchmark | All 8 inputs rendered; first render 1.672–19.835 ms; mean of 100 cache hits 0.00499–0.00663 ms |

One warm Demo run measured 512 ms from launch to CLI readiness and 227 ms to quit. RSS settled near 178.5 MiB; CPU samples at seconds 2–9 displayed 0.0%. The first sample showed 70.8% CPU and 0.38 seconds cumulative CPU time (0.39 seconds in the final sample). This short run uses one data condition and has no comparison baseline. It does not establish cold-start performance, full UI readiness, regular-app performance, or results on other hardware/data. See [performance notes](docs/PERFORMANCE.md).

**Validation and publication:** UI AX (accessibility) text-area reachability is covered by the passing final test run. Local validation and verification of public distribution artifacts are separate. Finder acceptance, local tests, and compilation do not establish completion of all performance work, public CI success, or signed/notarized distribution acceptance. Check [Releases](https://github.com/sasuketorii/rev_clip/releases) for published versions.

## Three focused runtime dependencies

All three third-party dependencies are vendored. A normal build does not need to fetch them through CocoaPods or Swift Package Manager.

| Library | Purpose | Vendored version |
| --- | --- | --- |
| [FMDB](https://github.com/ccgus/fmdb) | A wrapper around SQLite | 2.7.12 |
| [SQLCipher](https://github.com/sqlcipher/sqlcipher) | Encrypted storage database | 4.19.0 |
| [Sparkle](https://github.com/sparkle-project/Sparkle) | App updates | 2.9.6 |

This count excludes macOS system frameworks, Sparkle's internal components, and development tools. XcodeGen generates the project; Pillow is needed only to regenerate icons. See [third-party notices](THIRD_PARTY_NOTICES.md) for licensing details.

## Make the UI yours

Menu density, preview spacing, editor layout, icons—change the parts you use every day. Version 0.1.0 onward uses AGPLv3. See LICENSE for source provision obligations when distributing or providing modified versions over a network.

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

Current Revclip releases (v0.1.0 onward) use **[AGPL-3.0-only](LICENSE)**, not a dual AGPL/MIT license. The [legacy notice](docs/notices/legacy-mit.txt) is retained for code published through v0.0.32. Bundled libraries retain their respective licenses.

© sasuke torii and Revclip contributors.

## faster OCR

Press `⌘⇧2`, select screen text, then paste the copied result. faster OCR uses AppKit selection, a temporary ScreenCaptureKit frame and on-device Apple Vision on macOS 14 or later. The "faster OCR" settings page controls the switch, shortcut, language, language correction and history saving, and "Permission Status" shows the state of Screen Recording and the other permissions. The same settings are available through the CLI `settings-get` / `settings-set`; no CLI operation captures the screen or returns recognized text.

Images are not saved or sent; copied text remains on the OS clipboard. Recognized text carries the transient pasteboard marker (`org.nspasteboard.TransientType`), so other clipboard managers that honor it do not record that text. It is saved to Revclip history only while clipboard access for Revclip is set to always allow; otherwise it is copied only.

When a shortcut cannot be used, Revclip reports one of three things: another Revclip feature uses it, an enabled macOS keyboard shortcut uses it, or macOS refused the registration. Whether another application uses the same keys cannot be determined on macOS; in that case both applications react.

See [faster OCR](docs/REV_OCR.md) for limits and verification status. "RevOCR" was the working name during development.

Opening Revclip from Applications uses the same history and template menu as **⌘⇧V**. If a settings or editor window is already visible, it comes forward instead. Login and background launches are excluded. See [implementation and acceptance status](docs/REV_OCR.md) for verification limits.

For a scripted background launch without the menu, use `open -g path/to/Revclip.app --args -suppressLaunchMenu YES`. On first launch, `open -g` alone cannot be distinguished from an ordinary open. Local build 58 validation passed 382 XCTest cases and 88 CLI/installer/delivery tests. Public delivery and real-device coverage are recorded separately in the [quality report](docs/QUALITY_REPORT.md).
