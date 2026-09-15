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

The CLI uses the same endpoint and command implementation. Select the running target
with `scripts/revclip --app Revclip` or `scripts/revclip --app revclip-demo`.
The default is demo for compatibility. Text/image create, read, update, delete, list,
stdin input, visibility updates, title-only media preservation, and nonempty-folder
protection were exercised against the installed regular app; temporary test data was
removed afterward.

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
