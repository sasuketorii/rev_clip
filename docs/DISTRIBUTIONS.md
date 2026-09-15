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
