# Revclip 0.1.1 (build 34)

## Production/demo parity repair

Version 0.1.0 retained four `RC_DEMO_BUILD` feature blocks in the menu manager and a demo bundle-ID condition in the template editor. These incorrectly disabled production template favicons, color/image icons, image paste, and the media button while leaving link hover previews enabled. All five feature conditions are removed. Demo now uses Release optimization too.

Only application identity, separate storage, signing, startup installation/login behavior, and updater isolation differ. Template data stays separate. `scripts/check_demo_parity.py` rejects new demo-specific feature conditions; CI runs it before builds.

## Hover stability

Every defaults notification previously rebuilt the native menu, including unrelated framework preferences. Rebuilding hides the preview and replaces the tracked menu. Clipboard notifications could do the same. Menu preferences are now compared before invalidation, and rebuilds wait until all open menus close. Updating an already visible preview no longer orders its panel forward again.

## Validation

- 130 tests passed in the optimized regular Release configuration, including production link/color/media construction, image paste, unrelated defaults, and nested-menu invalidation.
- Optimized tests explicitly enable `RC_TESTING` for isolated storage. Distributed builds do not enable test hooks.
- CI runs both Debug and optimized Release tests, followed by a universal production build.
- Menu lifecycle fixtures now retain their fake menus through optimized ARC and model open/close callbacks.
- Codebase graph discovery was attempted alongside source inspection. Objective-C graph completeness is not assumed; feature gates and rebuild callers were checked directly.

Release artifacts use version 0.1.1/build 34. The existing Sparkle feed and production bundle identity are preserved.
