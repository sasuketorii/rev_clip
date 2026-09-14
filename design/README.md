# Revclip installer

`Revclip-Installer.dmgtemplate` is the approved white installer design created with Rilmazafone 2.6. It includes the original editable background layers and grain settings, a 660 × 400 window, 96-point icons, and 13-point labels.

Open the template in Rilmazafone to edit it. The tracked template deliberately leaves the app source empty; select a built Revclip.app for an interactive preview. `src/Revclip/Scripts/create_dmg.sh` binds the release app in a temporary copy, so releases never package an older app from the developer's Applications folder.

The release workflow downloads the pinned GitHub edition and verifies its SHA-256 and Apple signature. Both local and CI packaging use this template. Background assets are embedded; keep the complete package when saving or copying it.

Finder users who enable hidden files can see the background folder and volume icon below the design. This is expected Finder behavior; the approved design is preserved.

The generated thumbnail is not tracked because it can retain an older application icon. Rilmazafone regenerates it when the template is saved with a selected app. App and volume icons are obtained from the app being packaged.
