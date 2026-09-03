# Contributing to Morphe Module Builder

Thanks for helping improve the builder. Changes should keep the project a thin,
reliable automation layer around Morphe Desktop and published Morphe patch
bundles.

## Before opening a pull request

1. Run `bash -n build.sh utils.sh build-termux.sh`.
2. Run `tests/test_utils.sh`.
3. Run `git diff --check`.
4. Test a small `build-mode = "apk"` configuration when changing download or
   patch arguments. Do not commit APKs, patch bundles, logs, or personal
   keystores.

## Scope

- Builder bugs belong here.
- Patch behavior, compatibility, and new patch requests belong in the relevant
  Morphe patch repository.
- Morphe Manager UI or Android installer issues belong in the
  [Morphe Manager repository](https://github.com/MorpheApp/morphe-manager).

When adding a source adapter, keep network requests cached, avoid logging
credentials, and document its configuration in `CONFIG.md`. When changing the
module template, test both a Magisk install and a KernelSU install if possible;
the template must not delete application data.
