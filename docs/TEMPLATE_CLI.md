# Template CLI

Run `scripts/revclip` from the repository. Requires Python 3 and the updated,
running target app (`Revclip` or `revclip-demo`). The CLI connects to the app's private local socket;
it uses the app's encrypted storage and never opens a second app or edits the DB directly.
Both regular and demo builds enable this endpoint from v0.1.0. The default
target remains demo for compatibility. Use `scripts/revclip --app Revclip folders`
for the regular app. No skill is installed.

```sh
scripts/revclip folders
scripts/revclip folder-create --title '撮影素材'
scripts/revclip list --folder FOLDER_ID
scripts/revclip create --folder FOLDER_ID --title '挨拶' --content 'お世話になっております。'
scripts/revclip create --folder FOLDER_ID --title 'メール' --content-file mail.txt
printf '%s' '新しい本文' | scripts/revclip update TEMPLATE_ID --content-file -
scripts/revclip update TEMPLATE_ID --title '変更後のタイトル'
scripts/revclip create --folder FOLDER_ID --title 'ロゴ' --image logo.png
scripts/revclip update TEMPLATE_ID --enabled false
scripts/revclip get TEMPLATE_ID
scripts/revclip delete TEMPLATE_ID
scripts/revclip folder-delete EMPTY_FOLDER_ID
```

Use the `identifier` returned by commands, not the numeric database `id` or title.
Output is JSON (`ok`, `result` or `error`); failures exit with status 1.
Title-only updates preserve body/images. Explicit `--content` / `--content-file`
replaces an image with text; `--image` replaces text with an embedded image.
Image payloads are omitted from list/get; `media_bytes` identifies image templates.
Text is UTF-8, at most 1 MiB; images use the editor's limits (10 MiB,
single frame, 16 megapixels, maximum 8192 pixels per dimension).

The app saves any open editor draft before processing a request, then refreshes
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

Opening a template folder asynchronously fetches favicons for its link items.
The favicon sits beside the template title, in the same slot as color swatches.
Preview images and favicons share one metadata request and one cache entry.
At most two requests run concurrently, with up to 32 unique URLs pending.
The memory cache holds up to 32 entries / approximately 32 MiB, with a 24-hour
TTL. Failed requests are held for 60 seconds; restarting the app clears the cache.
The first folder opening or hover contacts the URL through macOS LinkPresentation. Image retrieval
has an 8-second application deadline; missing images keep the title/URL visible.
This is the site-provided social preview image, not a live webpage screenshot.

## History image previews

History image previews load the hovered item's encrypted clipboard archive after
the hover delay and downsample its saved image to at most 720 pixels per side.
The full image is not decoded on the UI thread or retained in the preview cache.
Opening the menu still uses small thumbnails; they are also the fallback when a
saved full-resolution image is unavailable. Original user files are not reopened.
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
