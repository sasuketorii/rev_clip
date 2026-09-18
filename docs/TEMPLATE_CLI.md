# Template CLI

Use the native CLI bundled at `Contents/Helpers/revclip`. It requires no Python.
Template, settings, and bug-report commands require the updated target app
(`Revclip` or `revclip-demo`) to be running. The CLI connects to the app's private
local socket, uses its encrypted storage, and never opens another app or edits the
DB directly. The native CLI defaults to `Revclip`; select Demo explicitly with
`--app revclip-demo`.

Set `APP` to the application location. The first example uses a relative
placeholder; subsequent examples reuse that variable:

```sh
APP='path/to/Revclip.app'
"$APP/Contents/Helpers/revclip" --app Revclip folders
"$APP/Contents/Helpers/revclip" --app Revclip folder-create --title '撮影素材'
"$APP/Contents/Helpers/revclip" --app Revclip list --folder FOLDER_ID
"$APP/Contents/Helpers/revclip" --app Revclip create --folder FOLDER_ID --title '挨拶' --content 'お世話になっております。'
"$APP/Contents/Helpers/revclip" --app Revclip create --folder FOLDER_ID --title 'メール' --content-file mail.txt
printf '%s' '新しい本文' | "$APP/Contents/Helpers/revclip" --app Revclip update TEMPLATE_ID --content-file -
"$APP/Contents/Helpers/revclip" --app Revclip update TEMPLATE_ID --title '変更後のタイトル'
"$APP/Contents/Helpers/revclip" --app Revclip create --folder FOLDER_ID --title 'ロゴ' --image logo.png
"$APP/Contents/Helpers/revclip" --app Revclip update TEMPLATE_ID --enabled false
"$APP/Contents/Helpers/revclip" --app Revclip get TEMPLATE_ID
"$APP/Contents/Helpers/revclip" --app Revclip delete TEMPLATE_ID
"$APP/Contents/Helpers/revclip" --app Revclip folder-delete EMPTY_FOLDER_ID
```

## Agent setup and status

```sh
"$APP/Contents/Helpers/revclip" agent inspect --app Revclip
"$APP/Contents/Helpers/revclip" agent install --app Revclip
"$APP/Contents/Helpers/revclip" agent inspect --app Revclip
```

These local setup commands do not require the app to be running. Agent Settings
runs inspection on opening and Recheck, showing installed state and
`update_available`. Installation and updates remain manual: copy and run the setup
prompt. Inspection does not overwrite anything; installation preserves unmanaged
or edited copies as conflicts. See [agent support](AGENT_SUPPORT.md).

The repository’s `scripts/revclip` and `agents/AgentSupport/install.py` are Python
compatibility/developer tools only, not prerequisites for native app usage.

## Validation and release status

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

## Template results and limits

Use the `identifier` returned by commands, not the numeric database `id` or title.
Output is JSON (`ok`, `result` or `error`); failures exit with status 1.
Title-only updates preserve body/images. Explicit `--content` / `--content-file`
replaces an image with text; `--image` replaces text with an embedded image.
Image payloads are omitted from list/get; `media_bytes` identifies image templates.
Text is UTF-8, at most 1 MiB; images use the editor's limits (10 MiB,
single frame, 16 megapixels, maximum 8192 pixels per dimension).

For template commands, the app saves any open template-editor draft before processing a request, then refreshes
the editor/menu after mutations. Commands are serialized with UI edits.
Folders must be empty before deletion. A timed-out write may have completed:
check list/get before retrying. Socket access is restricted to the same OS user;
this does not isolate the app from other programs running as that user.

Long menu titles wrap onto multiple lines within a 340pt text area (native menu
within 420pt). No title text is omitted. Stored titles and accessibility labels remain full.

## Link previews

A template containing only a web URL shows a site-provided image on hover, at
16:9 within the menu width, with its title and URL beneath it. Bare domains such
as `rev-c.com` use HTTPS. Leading/trailing whitespace is ignored. Additional
prose, multiple URLs, email addresses, and mailto links use ordinary text previews
and do not trigger link/favicons requests. Explicit HTTP URLs show a yellow warning
icon. Accepted URLs are at most 2,048 characters.

Automatic fetching is the default. Privacy → Links also offers manual fetching and Never fetch. In manual mode, ordinary hovering does not start a request; point at a URL and press Option to request its preview explicitly. Permission changes cancel pending work and clear cached previews. In automatic mode, opening a template folder asynchronously fetches favicons for its link items.
The favicon sits beside the template title, in the same slot as color swatches.
Preview images and favicons share one metadata request and one cache entry.
At most two requests run concurrently, with up to 32 unique URLs pending.
The memory cache holds up to 32 entries / approximately 32 MiB, with a 24-hour
TTL. Failed requests are held for 60 seconds; restarting the app clears the cache.
An explicitly requested fetch, or automatic mode, contacts the URL through macOS LinkPresentation; this can reveal the IP address and full URL to the site. Image retrieval
has an 8-second application deadline; missing images keep the title/URL visible.
This is the site-provided social preview image, not a live webpage screenshot.

## History image previews

History image previews load the hovered item's encrypted clipboard archive after
the hover delay and downsample its saved image to at most 720 pixels per side.
The full image is not decoded on the UI thread or retained in the preview cache.
Opening the menu still uses small thumbnails; they are also the fallback when a
saved full-resolution image is unavailable. For Finder file references, eligible local image files may be reopened for preview. If the source is unavailable, a saved thumbnail or image payload is used as a fallback; the file reference is not a backup of the original file.
Moving off the row before the delay skips archive I/O. The bounded preview is
cached for subsequent hovers (128 menu-cache entries / approximately 32 MiB).
Cache invalidation rejects late image results, and Panic Erase also cancels link
retrieval and clears preview art.

## History deletion

Manual clear stops monitoring, drains pending captures, deletes history rows, then
removes their saved archives/thumbnails before monitoring resumes. Templates stay.
Retention selects and deletes overflow in one database transaction, then removes
those items' files. Cleanup is scheduled approximately five seconds after the first
copy in a burst; later copies do not postpone that deadline. It also runs at startup,
on relevant preference changes, and every 30 minutes. File deletion failures are
logged and orphan cleanup can retry later.

Rows are actually deleted, not hidden in the UI. SQLite secure_delete is enabled;
incremental vacuum and WAL checkpointing are used for maintenance. Database file
size alone does not measure remaining history, and normal deletion does not erase
independent backups or promise forensic erasure on SSDs.


## Preferences CLI (v0.1.6)

```sh
"$APP/Contents/Helpers/revclip" --app Revclip settings-schema
"$APP/Contents/Helpers/revclip" --app Revclip settings-get
"$APP/Contents/Helpers/revclip" --app Revclip settings-get --key appearance
"$APP/Contents/Helpers/revclip" --app Revclip settings-set --json '{"appearance":"dark","max_history_size":30}'
"$APP/Contents/Helpers/revclip" --app Revclip settings-set --file settings.json
"$APP/Contents/Helpers/revclip" --app Revclip app-action permissions
"$APP/Contents/Helpers/revclip" --app Revclip app-action update-check
```

`settings-schema` is the authority for supported keys, types, ranges, enum values,
and actions. A settings file is a UTF-8 JSON object; `--file -` reads stdin.
Duplicate JSON keys and non-finite numbers are rejected by the client. The app
validates all requested settings before writing. Unknown keys and Panic are
rejected; arbitrary defaults mutation is not available. Through 0.1.9 shortcuts are
rejected as well; see the 0.2.0 candidate section below.

Settings use the existing services and storage; open preferences refresh after
changes. The response includes applied keys and read-back values. Retention
changes schedule normal cleanup without an extra confirmation. Cleanup completion
is not awaited. A multi-service write is not a database transaction: login item
registration is attempted first and may require macOS approval. `app-action`
returns `queued`; permission and update UI must be completed by the user. This
is not proof that permission was granted or that an update was installed.

## faster OCR settings and shortcuts (0.2.0 candidate, unreleased)

`settings-schema` lists 44 settings: the 35 above, four faster OCR settings and five
shortcuts. `excluded_groups` is `["panic"]`. No operation starts faster OCR, captures
the screen or returns recognized text (`ocr_boundary` in the schema says so).

```sh
"$APP/Contents/Helpers/revclip" --app Revclip settings-get --key shortcut_ocr
"$APP/Contents/Helpers/revclip" --app Revclip settings-set --json '{"ocr_language":"ja-en","ocr_save_history":false}'
"$APP/Contents/Helpers/revclip" --app Revclip settings-set --json '{"shortcut_ocr":{"key_code":19,"modifiers":["command","shift"]}}'
"$APP/Contents/Helpers/revclip" --app Revclip settings-set --json '{"shortcut_clear_history":{}}'
"$APP/Contents/Helpers/revclip" --app Revclip settings-set --json '{"shortcut_main":{"default":true}}'
```

| Key | Type | Notes |
| --- | --- | --- |
| `ocr_enabled` | boolean | Turning it on is refused when this macOS, or the stored `ocr_language`, cannot be used. Turning it off is always accepted. |
| `ocr_save_history` | boolean | Recognized text is stored only while clipboard access is always allowed and the usual history rules permit it; otherwise it is copied only. |
| `ocr_language_correction` | boolean | Apple Vision language correction. Off keeps URLs, identifiers and code as recognized. |
| `ocr_language` | string | `auto`, `ja-en`, or a language this macOS reports. `allowed_values` in the schema is the list for the running system; other values are rejected, never replaced. |
| `shortcut_main`, `shortcut_history`, `shortcut_snippet`, `shortcut_clear_history`, `shortcut_ocr` | object | `{"key_code": 0-127, "modifiers": [...]}` with at least one of `command`, `shift`, `option`, `control`. On macOS 15 and later `option` needs `command` or `control`. `{}` clears; `{"default": true}` restores the default. |

`settings-get` also returns `display` (for example `⇧⌘2`). It is read-only: `settings-set`
accepts and ignores it, so a value that was read can be written back unchanged.

Shortcuts use the same contract as the preferences window:

- The request is judged against the state it would leave, so two shortcuts can be
  exchanged in one `settings-set`. Each of them alone would be refused.
- A refusal names what Revclip can know: another Revclip shortcut (by key), an enabled
  macOS keyboard shortcut (macOS reports no name), or an OS registration failure with
  its `OSStatus`. **Other applications using the same keys cannot be detected**: hot
  keys are registered non-exclusively and macOS reports no owner, so both applications
  react. Revclip does not register exclusively and does not inspect other applications.
- New combinations are registered before anything else changes. If that, or a login
  item change in the same request, fails, only the registrations prepared for this
  request are released; previous registrations, stored shortcuts and the other settings
  in the request are left as they were. `transactional` stays `false` in the schema:
  this is an ordering of fallible steps, not a transaction across services.
- `ocr_enabled` in the same request decides whether `shortcut_ocr` is registered.

## Standalone SVG previews (v0.1.6)

Supported standalone SVG text can display a tinted, bounded hover preview while
preserving the original text for paste. Rendering is delayed until hover and
performed on a bounded background queue, with cached results. Unsafe or unsupported
SVG falls back to text. External resources, scripts, embedded images, CSS and
animation are not supported. This is a shape/icon preview, not a browser SVG engine.

## History access boundary

The CLI exposes templates and allowlisted settings, not clipboard history.
`list` and `get` read templates only; history enumeration, history payload reads,
clipboard reads and history exports are unsupported. Retention settings can be
changed without returning retained items. Bug reports do not automatically collect
history. At-rest encryption alone is not this API boundary: the running app can
decrypt its data, so the server must continue to reject history operations.

## Bug reports (v0.1.6)

```sh
"$APP/Contents/Helpers/revclip" --app Revclip bug-report --title 'Problem summary' --description-file report.txt --consent-source-info
```

`--description` accepts short text inline; `--description-file -` reads UTF-8 stdin.
`--contact` is optional. Titles are limited to 120 UTF-16 code units, descriptions
to 2,500, and contacts to 200. Consent is required explicitly: the report includes
source IP, region, network, language, timezone, app/OS versions and User-Agent.
This sends information through Cloudflare to the developer's Telegram group.
It does not attach local history or clipboard data. Never infer reporting consent
from a request to perform an unrelated local operation.

Only a successful Telegram send response is reported as sent. No automatic retry
occurs. A timeout can happen after delivery; avoid blindly repeating the command.
See [feedback deployment](FEEDBACK_DEPLOYMENT.md) for limits and privacy details.
