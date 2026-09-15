#!/bin/bash
# Launch the isolated recording build after gracefully stopping the regular app.
set -euo pipefail

demo_app_path="${1:?usage: run_demo.sh /path/to/revclip-demo.app}"
regular_bundle_identifier="com.revclip.Revclip"
regular_process_name="Revclip"

if [[ ! -d "$demo_app_path" ]]; then
  printf 'Demo app not found: %s\n' "$demo_app_path" >&2
  exit 1
fi

# The regular build owns the same user-facing shortcut. Stop it before the
# demo starts so the recording build receives the shortcut deterministically.
/usr/bin/osascript -e "tell application id \"$regular_bundle_identifier\" to quit" >/dev/null 2>&1 || true

for _ in {1..50}; do
  if ! /usr/bin/pgrep -x "$regular_process_name" >/dev/null 2>&1; then
    break
  fi
  /bin/sleep 0.1
done

if /usr/bin/pgrep -x "$regular_process_name" >/dev/null 2>&1; then
  printf 'The regular Revclip instance did not quit; demo launch was cancelled.\n' >&2
  exit 1
fi

/usr/bin/open "$demo_app_path"
