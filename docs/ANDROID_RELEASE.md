# Signed Android releases

The `PadLink release` workflow runs when a `v*` tag is pushed. It builds and
tests the Android app and four Rust JNI ABIs, signs the release APK, verifies
the signing certificate and 16 KiB native-library alignment, and publishes:

- `padlink-VERSION-android.apk`
- `padlink-VERSION-android.apk.sha256`

The APK and desktop binaries are published together only after their release
checks pass. The tag's version must match `[workspace.package].version` in
`Cargo.toml`. Android `versionName` is the release version; `versionCode` is
`major * 1,000,000 + minor * 1,000 + patch`. Minor and patch must be below 1,000,
and the resulting code must be between 1 and 2,100,000,000. Keep release versions
increasing so Android can upgrade an existing installation with the same key.

## Signing settings

Configure repository-level GitHub Actions settings with:

```sh
python3 packaging/configure_android_signing.py --keystore /path/to/padlink.jks --repo sam-eer12/prod --alias padlink
```

The script prompts for passwords without displaying them, verifies that the
private key can be unlocked, and uploads the following settings with `gh`:

| Setting | Storage | Value |
| :--- | :--- | :--- |
| `PADLINK_ANDROID_KEYSTORE_BASE64` | Actions secret | Base64-encoded keystore |
| `PADLINK_ANDROID_STORE_PASSWORD` | Actions secret | Keystore password |
| `PADLINK_ANDROID_KEY_PASSWORD` | Actions secret | Signing-key password |
| `PADLINK_ANDROID_KEY_ALIAS` | Actions variable | Signing-key alias (`padlink`) |
| `PADLINK_ANDROID_CERT_SHA256` | Actions variable | Expected signing certificate SHA-256 fingerprint |

Keep the keystore and passwords outside Git. Existing `.gitignore` rules exclude
`*.jks`, `*.keystore`, and `keystore.properties`. Preserve an offline backup of
the keystore to sign future upgrades with the same identity.

The keystore is decoded to a private temporary directory only for signing and
removed when the signing tool finishes, including on failure. Passwords are
passed to Android `apksigner` through environment variables. Signing runs after
Gradle, so signing material is absent from Gradle build configuration and caches.
Only the verified APK, checksum, and test reports are uploaded as artifacts.

## Attach an APK to an existing release

The standalone `Android release` workflow also supports manual runs. It builds
the selected workflow ref, checks its version against `Cargo.toml`, and attaches
the verified APK and checksum to an existing `vVERSION` release. It leaves the
desktop release assets intact.

```sh
gh workflow run android-release.yml --repo sam-eer12/prod --ref main -f version=0.1.1 -f publish=true
```

Set `publish=false` to build and verify an Actions artifact without publishing.
Manual publication requires the corresponding GitHub Release to exist already.
Rerunning publication replaces the APK and checksum with the same filenames.
Local `:app:assembleRelease` remains unsigned; production signing is performed by
`packaging/sign_android_release.py` after assembly.

## Verify the downloaded APK

```sh
sha256sum -c padlink-VERSION-android.apk.sha256
"$ANDROID_HOME/build-tools/36.0.0/apksigner" verify --verbose --print-certs padlink-VERSION-android.apk
```

Compare the printed certificate SHA-256 digest with `PADLINK_ANDROID_CERT_SHA256`.
On macOS, use `shasum -a 256 -c` instead of `sha256sum -c`.
