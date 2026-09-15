#!/usr/bin/env python3
"""Reject demo-only features; permit only startup and storage isolation."""
from pathlib import Path
import re

root = Path(__file__).resolve().parents[1] / "src/Revclip/Revclip"
allowed = {
    "App/RCAppDelegate.m": [
        {"[[RCMoveToApplicationsService shared] checkAndMoveIfNeeded];"},
        {"[[RCUpdateService shared] setupUpdater];"},
    ],
    "Utilities/RCUtilities.m": [
        {"kRCLoginItem: @NO,", "kRCEnableAutomaticCheckKey: @NO,", "#else",
         "kRCLoginItem: @YES,", "kRCEnableAutomaticCheckKey: @YES,"},
    ],
}
pattern = r"#if[^\n]*RC_DEMO_BUILD[^\n]*\n(.*?)#endif"
errors = []
for path in root.rglob("*"):
    if not path.is_file() or "Vendor" in path.parts or path.suffix not in {".m", ".h", ".swift"}:
        continue
    text = path.read_text()
    relative = str(path.relative_to(root))
    for block in re.findall(pattern, text, re.S):
        lines = {line.strip() for line in block.splitlines()
                 if line.strip() and not line.strip().startswith("//")}
        if lines not in allowed.get(relative, []):
            errors.append(f"{relative}: demo-only feature block")
    stripped = re.sub(pattern, "", text, flags=re.S)
    if re.search(r"revclip-demo|RC_DEMO_BUILD", stripped):
        errors.append(f"{relative}: demo-specific runtime check")
if errors:
    raise SystemExit("\n".join(errors))
print("Demo/regular feature gate audit passed.")
