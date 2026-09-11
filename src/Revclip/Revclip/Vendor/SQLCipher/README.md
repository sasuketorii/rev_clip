# SQLCipher vendor

Revclip vendors the SQLCipher 4.19.0 amalgamation generated from the official
[`v4.19.0` source tag](https://github.com/sqlcipher/sqlcipher/tree/v4.19.0)
and [release archive](https://github.com/sqlcipher/sqlcipher/archive/refs/tags/v4.19.0.tar.gz).
The tag was verified as the latest non-prerelease release on 2026-09-08.
The archive is verified by

```text
SHA-256 7075f96cbabe45b4ecfc2e6b1745a625f856f695b0827a5506ce9ed85b906aa0
```

Generated artifact hashes:

```text
sqlite3.c     8640c653acadf665cce6331646f60b5b74a4690746f2c4a2d8f688a0570a0c0c
sqlite3.h     8a9d1bff44d75174ca6dea3ea9bac50a6104d86facb566647b8bb839375b7b3a
sqlite3ext.h  ac9645e5c9ff0cf176efdd6e75cb5e98f46295d38e02db5c4d208826a39ab4be
```

The checked-in amalgamation is regenerated with
[`scripts/vendor_sqlcipher.sh`](../../../../../scripts/vendor_sqlcipher.sh).
The script runs SQLCipher's own amalgamation generators with these build
settings:

```text
--disable-tcl --disable-readline --disable-shared --enable-static
--with-tempstore=yes
-DSQLITE_HAS_CODEC
-DSQLITE_EXTRA_INIT=sqlcipher_extra_init
-DSQLITE_EXTRA_SHUTDOWN=sqlcipher_extra_shutdown
-DSQLCIPHER_CRYPTO_CC
-DSQLITE_THREADSAFE=2
-DSQLITE_TEMP_STORE=2
```

XcodeGen adds `-DNDEBUG` only to the `sqlite3.c` source build entry. The app
prefix header imports `assert.h` before the amalgamation selects its SQLite
assert mode; this per-file flag keeps those modes consistent without disabling
C assertions in the rest of the app or its tests.

The runtime crypto provider is Apple's CommonCrypto and Security framework.
OpenSSL is not a build or runtime dependency. The header is generated with
SQLCipher's codec declarations enabled, including `sqlite3_key` and
`sqlite3_rekey`, so FMDB and the application use the same SQLCipher ABI.

SQLCipher preserves ordinary SQLite compatibility when no key is supplied;
database migration code can therefore inspect an existing plaintext database
before an encrypted copy is created. This vendor step does not open, rewrite,
or encrypt any application database.

The amalgamation contains public-domain SQLite code and SQLCipher code under
the BSD-style license. See [LICENSE.md](LICENSE.md) and
[SQLITE_LICENSE.md](SQLITE_LICENSE.md).
