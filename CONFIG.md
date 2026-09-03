# Morphe Module Builder configuration

Morphe Module Builder is a non-interactive builder around **Morphe Desktop's
CLI**. It downloads the same `.mpp` bundles used by [Morphe
Manager](https://github.com/MorpheApp/morphe-manager), applies the selected
patches to an original APK, and can package the result as a standalone APK or
a mount-based Magisk/KernelSU module.

Start with [`config.toml`](./config.toml). The parser intentionally supports a
small TOML subset so it works on desktop Linux, macOS, Windows environments
with Bash, and Termux. Strings use double quotes; patch selections inside a
string use single or double quotes.

## Main settings

```toml
enable-magisk-update = true       # add updateJson to generated modules
parallel-jobs = 1                 # concurrent app builds; default is nproc
compression-level = 9              # module ZIP compression, 0 through 9

morphe-source = "MorpheApp/morphe-desktop"
morphe-version = "latest"         # latest, dev, or an exact tag such as v1.14.0
patches-source = "MorpheApp/morphe-patches"
patches-version = "latest"        # latest, dev, or an exact tag such as v1.41.0
morphe-brand = "Morphe"            # output/module label

bytecode-mode = "FULL"             # FULL (default), STRIP_FAST, or STRIP_SAFE
strip-libs = true                   # remove native libraries not needed by the target arch
keep-architectures = ""             # e.g. "arm64-v8a,armeabi-v7a"
verify-source-signature = true       # verify hashes listed in source-signatures.txt

# Optional: set these for a key exported from Morphe Manager. If omitted,
# Morphe creates/reuses temp/morphe-data/morphe.keystore locally.
# keystore = "Morphe.keystore"
# keystore-password = ""
# keystore-entry-alias = "Morphe"
# keystore-entry-password = "Morphe"
signer = "Morphe Module Builder"
```

`MORPHE_KEYSTORE` overrides `keystore` without changing the file. The
`MORPHE_KEYSTORE_PASSWORD`, `MORPHE_KEYSTORE_ALIAS`,
`MORPHE_KEYSTORE_ENTRY_PASSWORD`, and `MORPHE_SIGNER` environment variables
similarly override the corresponding signing settings. This is recommended
for CI secrets and personal keys. If the configured file is not present, the
builder lets Morphe create/use its default key in `temp/morphe-data`.

`bytecode-mode` controls how patched DEX files are compiled:

- `FULL` (default) rewrites all DEX files through DexPool. Slowest, but the
  most reliable and produces the cleanest output.
- `STRIP_FAST` is Morphe Desktop's own default. Faster, but leaves dead data
  in the original DEX files.
- `STRIP_SAFE` should be avoided for automated builds: current Morphe Patcher
  versions can abort mid-build with `An unexpected error occurred: null`
  (a `ConcurrentModificationException` while rebuilding DEX), and the Morphe
  team plans to remove the mode.

## App settings

Every table describes one app. `enabled` defaults to `true`; all other fields
inherit the main settings.

```toml
[YouTube]
enabled = true
app-name = "YouTube"                    # output label; defaults to table name
build-mode = "both"                     # apk, module, or both
version = "auto"                        # auto, latest, beta, or exact version
apkmirror-dlurl = "https://www.apkmirror.com/apk/google-inc/youtube"
# uptodown-dlurl = "https://youtube.en.uptodown.com/android"
# archive-dlurl = "https://archive.org/download/jhc-apks/apks/com.google.android.youtube"
arch = "all"                            # all, both, arm64-v8a, arm-v7a, x86, x86_64
apkmirror-dpi = "nodpi"
include-stock = true                    # bundle the original APK in modules
module-prop-name = "youtube-morphe"     # optional Magisk module id

included-patches = "'Remove ads' 'Custom branding'"
excluded-patches = "'Experimental patch'"
exclusive-patches = false                # only apply included-patches
options-file = "options/youtube.json"   # optional Morphe options JSON
options-update = false
force = false                            # pass Morphe's --force
continue-on-error = false
bytecode-mode = "FULL"
strip-libs = true
keep-architectures = "arm64-v8a,armeabi-v7a"
verify-source-signature = true
```

### Patch sources

A source must be a GitHub repository that publishes a `.mpp` asset.
`patches-source` and `patches-version` can be set per
app, which makes it possible to combine official and community Morphe bundles.
The builder never edits a patch bundle. Use Morphe Manager or Morphe Desktop
for interactive patch selection; use `included-patches`, `excluded-patches`,
and an `options-file` for repeatable CI builds.

### Version selection

- `auto` asks Morphe Desktop for the newest commonly compatible version for the
  package. If Morphe reports that patches work with any version, the newest
  stable version from the selected download source is used.
- `latest` selects the newest stable version from the download source and
  passes Morphe's `--force`, because the newest APK may not be listed in the
  bundle yet. Use `auto` for a compatibility-first build.
- `beta` selects the newest beta/alpha version where the download source exposes
  one and also passes `--force`.
- An exact version such as `20.10.40` selects that version. Morphe performs its
  normal compatibility check unless `force = true`.

`auto` is the recommended setting. Patch compatibility belongs to the `.mpp`
bundle, not to the builder.

### Architecture and split APKs

`both` builds separate arm64-v8a and arm-v7a outputs. `all` prefers a universal
APK and retains both common ARM architectures when `strip-libs = true`.
APKMirror `.apkm` downloads are merged for the stock/module payload before
patching; Morphe Desktop also supports `.apk`, `.apkm`, `.xapk`, and `.apks`
inputs when used directly.

## Signing

Morphe Desktop signs standalone APKs. A module is mount-based and does not
replace the package's installed signature, but its standalone APK is still
signed for integrity and debugging.

For best update compatibility:

1. Export the keystore from **Morphe Manager → Settings → Export keystore**.
2. Set `MORPHE_KEYSTORE` to that file, or set `keystore` in a private config.
3. Set the matching store password, entry alias, and entry password.
4. Do not commit a personal keystore. This repository intentionally ships no
   private signing material.

When `MORPHE_KEYSTORE` is set the builder validates before building that the
file exists, opens with `MORPHE_KEYSTORE_PASSWORD`, and contains the configured
alias. A keystore that cannot be opened fails the build immediately with the
missing setting named in the error instead of failing every app during patching.

## Output files

Successful builds are written to `build/`:

- `<app>-morphe-v<version>-<arch>.apk` — standalone patched APK
- `<app>-morphe-module-v<version>-<arch>.zip` — Magisk/KernelSU module

`build.md` records the Morphe Desktop version, patch bundle, app version, and
successful/failed outputs. `temp/` contains cached tools and patching reports
and is ignored by Git.
