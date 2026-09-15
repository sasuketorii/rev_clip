#!/usr/bin/env python3
"""Reject distribution-specific identity and feature checks in product source."""
from pathlib import Path
import re

root = Path(__file__).resolve().parents[1] / "src/Revclip/Revclip"
errors = []
for path in root.rglob("*"):
    if not path.is_file() or "Vendor" in path.parts or path.suffix not in {".m", ".h", ".swift"}:
        continue
    text = path.read_text()
    relative = str(path.relative_to(root))
    if re.search(r"revclip-demo|RC_DEMO_BUILD", text):
        errors.append(f"{relative}: demo-specific feature condition or identity")
if errors:
    raise SystemExit("\n".join(errors))
print("Demo/regular feature gate audit passed.")
