# Regular and demo distributions

Both applications use the same sources, Release optimization, universal architectures,
startup sequence, defaults, editor, clipboard services, and CLI. Product source must
contain no demo macro or demo bundle-name condition. CI enforces this with
`scripts/check_demo_parity.py` and runs both Debug and optimized Release tests.

`src/Revclip/project.yml` selects distribution metadata:

| Setting | Regular | Demo |
| --- | --- | --- |
| Application | Revclip.app | revclip-demo.app |
| Bundle identifier | com.revclip.Revclip | com.revclip.revclip-demo |
| Storage directory name | Revclip | revclip-demo |
| Update feed | Public signed releases | Unconfigured |
| Signing | Developer ID for distribution | Local development identity |

Separate bundle IDs also isolate preferences, login registration and macOS permissions.
Existing settings and templates are retained. Application installation uses the actual
bundle filename for both distributions. An unconfigured update feed prevents updater
initialization in the shared updater service, including manual checks; a local demo must
never consume a regular release and overwrite its identity. There is no separate demo
feature implementation. Configure a dedicated signed feed if demo updates are published.

Both bundles contain the same native CLI implementation at
`Contents/Helpers/revclip` and skill resources at `Contents/Resources/AgentSupport`.
The app runtime, skill installation, and CLI operations do not require Python.
Set `APP` to the bundle location; these examples use a relative placeholder:

```sh
APP='path/to/Revclip.app'
"$APP/Contents/Helpers/revclip" agent inspect --app Revclip
"$APP/Contents/Helpers/revclip" agent install --app Revclip
"$APP/Contents/Helpers/revclip" --app Revclip folders
"$APP/Contents/Helpers/revclip" --app revclip-demo folders
```

The native CLI defaults to regular `Revclip`. Choose `--app revclip-demo`
explicitly for the running Demo app. The Agent Settings prompt derives its target
from bundle metadata; it does not select a different feature implementation.
Settings schema/read/write, supported UI actions, and consent-based bug reports
use the same services in either distribution. Shortcuts and Panic remain GUI-only.

Agent Settings inspects installed skills and `update_available` when opened or
rechecked. It does not automatically install or overwrite skills. Users copy and
run the setup prompt to install or update validated managed copies; local edits
and conflicts are preserved. See [agent support](AGENT_SUPPORT.md).

Source Python scripts remain developer/compatibility tools only. Their test or
installed-app results are not native CLI acceptance evidence. Verify regular and
Demo targets with the native executable for the release being distributed.

## Native validation status

Local validation recorded 77 CLI tests (40 Python compatibility + 37 native
CLI/installer integration tests) passing in 5.9 seconds, 225 XCTest tests
passing in 24.8 seconds, and 23 Worker tests passing with zero skips. Native Universal Debug compilation passed for arm64 and x86_64; this is
not runtime acceptance on both architectures.

The reporter accepted the Finder file-copy image fix on their Mac. The final
XCTest run includes a passing UI AX (accessibility) text-area reachability test.
Local validation and verification of public distribution artifacts are separate.
These results do not establish public CI or release acceptance. See
[Releases](https://github.com/sasuketorii/rev_clip/releases) for published versions.
A single warm Demo performance run is documented in [performance notes](PERFORMANCE.md);
it does not establish completion of all performance work.

## Preferences

Both distributions use one sidebar-based preferences window. Boolean settings use
native switches; existing controller actions and Cocoa bindings still persist values
and control dependent fields. Pages share a top-aligned, scrolling layout with
subtle grouped surfaces and row separators. macOS 26 adds a clear native glass
layer over the window backdrop; macOS 14–15 use the native visual-effect fallback.
System transparency accessibility settings remain respected. No screen capture,
wallpaper image, or timer is used to render the backdrop.

The template editor uses the same glass backdrop as Preferences. Menu color
customization is separate from both windows. Appearance preferences provide primary
(icon), text, background tint, hover text and hover background colors. Each light/dark
palette is stored separately; reset disables customization and clears both palettes.
HEX input accepts six digits with an optional `#`, normalizes valid values, and never
persists incomplete input. The independent native color panel is positioned within
its screen, including when the triggering control is near the screen bottom.

Default menu backgrounds retain the native material. Custom backgrounds add a fixed
14% tint; hover backgrounds use 85% opacity. Only hover rows are rounded. Template
symbols use the primary color, or hover text color while highlighted; media thumbnails,
color swatches and favicons retain their original colors. Color changes apply when a
menu next opens. Native submenu tracking and key equivalents remain in use, while
custom leaf rows explicitly dispatch the existing action after menu tracking ends.

Standalone shape-only SVG code uses the same bounded hover-preview renderer in
both apps. It follows the resolved menu text color, preserves the copied source,
and falls back to text for unsupported SVG. Rendering begins after the hover
delay; it does not add a startup scan or a polling timer.
