# Third-party notices

Revclip's own code and artwork are available under the [MIT License](LICENSE).
Vendored dependencies retain their original copyright notices and licenses.

| Direct dependency | Included version | Purpose | License |
| --- | --- | --- | --- |
| [FMDB](https://github.com/ccgus/fmdb) | 2.7.12, as reported by the included source | SQLite wrapper | [MIT](src/Revclip/Revclip/Vendor/FMDB/LICENSE.txt) |
| [Sparkle](https://github.com/sparkle-project/Sparkle) | 2.9.6 | App updates | [MIT and bundled third-party notices](src/Revclip/Revclip/Vendor/Sparkle/LICENSE) |

Sparkle contains additional components whose notices are included in its license
file. The vendored framework is retained as supplied, including its signatures.
SQLite and the Apple frameworks are provided by macOS, not separate vendored
runtime dependencies. XcodeGen is a build tool; Pillow is optional for regenerating icons.

The same dependency license text is included in the app's resources as
`ThirdPartyNotices.txt`.
