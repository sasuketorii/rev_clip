# Repository split

- Public source: https://github.com/sasuketorii/rev_clip_public
- Frozen public code: v0.0.32, commit 161490e6750060c8a4708c97c6d04e64a41fb2a2.
- Private development: https://github.com/sasuketorii/rev_clip
- Local origin points to private development. The public remote is read-only
  locally (push URL disabled). Never push private commits to the public repo.
- Public releases and tags remain in the renamed public repository.
- Existing v0.0.32 binaries contain the old GitHub update-feed URL. Reusing
  rev_clip for the private repository stops the old repository redirect.
  Existing installations must use the public releases page for downloads.
  A new updater distribution endpoint must be selected before releasing
  another binary; a private GitHub asset is not an anonymous update feed.
- Previously published MIT code retains its license in LICENSE-MIT-LEGACY.
  New original private contributions are governed by LICENSE.
- CI secrets and release signing credentials are not copied between repos.
