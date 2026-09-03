#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"
# shellcheck source=../utils.sh
source ./utils.sh

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() {
	[ "$1" = "$2" ] || fail "expected '$1', got '$2'"
}

# TOML parsing must retain spaces inside table names and patch selections.
toml_prep "$(cat config.toml)"
tables=$(toml_get_table_names | paste -sd, -)
assert_eq "$tables" "YouTube,YouTube-Music,Reddit"
# STRIP_SAFE aborts Morphe Patcher mid-build; the shipped configs must use FULL.
assert_eq "$(toml_get "$(toml_get_table '')" bytecode-mode)" FULL
assert_eq "$(toml_get "$(toml_get_table YouTube)" build-mode)" both
assert_eq "$(toml_get "$(toml_get_table YouTube-Music)" app-name)" "YouTube Music"

# Patch names are passed as separate argv entries, never through eval/word
# splitting. This is important for names containing spaces.
PATCH_ARGS=()
append_patch_names "'Remove ads' 'Custom branding'" --disable
assert_eq "${#PATCH_ARGS[@]}" 4
assert_eq "${PATCH_ARGS[1]}" "Remove ads"
assert_eq "${PATCH_ARGS[3]}" "Custom branding"

assert_eq "$(printf '%s\n' 1.9.0 1.10.0 1.9.0-dev.2 | get_highest_ver)" 1.10.0

# Exercise the Morphe list-versions parser without downloading Java or patches.
fake_bin=$(mktemp -d)
trap 'rm -rf "$fake_bin"' EXIT
cat >"$fake_bin/java" <<'EOF'
#!/usr/bin/env bash
cat <<'OUT'
Sep 03, 2026  INFO: Package name: com.example.app
Sep 03, 2026  INFO: Most common compatible versions:
Sep 03, 2026  INFO: 	1.9.0 (2 patches)
Sep 03, 2026  INFO: 	1.10.0 (3 patches)
OUT
EOF
chmod +x "$fake_bin/java"
PATH="$fake_bin:$PATH"
assert_eq "$(get_patch_last_supported_ver fake.jar patches.mpp com.example.app '' false)" 1.10.0

# Module helper binaries are fetched only for module builds and are made
# executable before the template is copied into a ZIP.
module_bin=$(mktemp -d)
trap 'rm -rf "$fake_bin" "$module_bin"' EXIT
MODULE_TEMPLATE_DIR="$module_bin/template"
MODULE_PREBUILTS_READY=false
gh_dl() { printf cmpr >"$1"; }
get_module_prebuilts
for arch in arm64 arm x86 x64; do
	[ -x "$MODULE_TEMPLATE_DIR/bin/$arch/cmpr" ] || fail "missing cmpr helper for $arch"
done
assert_eq "$MODULE_PREBUILTS_READY" true

assert_eq "$(path_from_cwd build/output.apk)" "$CWD/build/output.apk"
assert_eq "$(path_from_cwd /tmp/output.apk)" /tmp/output.apk

# APKMirror variant matching: generic dpi values are accepted and a release
# page with a single variant is used even when its columns do not match.
if [ "$(uname -m)" = x86_64 ] && [ -x "$ROOT_DIR/bin/htmlq/htmlq-x86_64" ]; then
	HTMLQ="$ROOT_DIR/bin/htmlq/htmlq-x86_64"
	variant_row() {
		cat <<EOF
<div class="table-row headerFont">
  <div class="table-cell">
    <a href="$1">
      <div><span>get_app</span></div>
      <div><span>App $2</span></div>
      <div><span>$3</span></div>
      <div><span>$4</span></div>
      <div><span>10 MB</span></div>
      <div><span>$5</span></div>
      <div><span>Android 9+</span></div>
    </a>
  </div>
</div>
EOF
	}
	resp=$(printf '<div class="variants">%s%s</div>' \
		"$(variant_row '/apk/x/app/app-1-0-android-apk-download/' 1.0 APK universal nodpi)" \
		"$(variant_row '/apk/x/app/app-1-0-2-android-apk-download/' 1.0 BUNDLE 'arm64-v8a + armeabi-v7a' anydpi)")
	assert_eq "$(apk_mirror_search "$resp" nodpi all APK)" "https://www.apkmirror.com/apk/x/app/app-1-0-android-apk-download/"
	assert_eq "$(apk_mirror_search "$resp" nodpi all BUNDLE)" "https://www.apkmirror.com/apk/x/app/app-1-0-2-android-apk-download/"
	assert_eq "$(apk_mirror_search "$resp" 420dpi arm64-v8a BUNDLE)" "https://www.apkmirror.com/apk/x/app/app-1-0-2-android-apk-download/"
	x86_only=$(printf '<div class="variants">%s%s</div>' \
		"$(variant_row '/apk/x/app/app-1-0-3-android-apk-download/' 1.0 APK x86 nodpi)" \
		"$(variant_row '/apk/x/app/app-1-0-4-android-apk-download/' 1.0 BUNDLE 'arm64-v8a + armeabi-v7a' nodpi)")
	if apk_mirror_search "$x86_only" nodpi armeabi-v7a APK >/dev/null; then
		fail "expected no armeabi-v7a APK variant to match"
	fi
	single=$(variant_row '/apk/x/solo/solo-2-0-android-apk-download/' 2.0 APK universal 420dpi)
	assert_eq "$(apk_mirror_search "$single" nodpi arm64-v8a APK)" "https://www.apkmirror.com/apk/x/solo/solo-2-0-android-apk-download/"

	# Density ranges (universal BUNDLE variants) must match when the config asks
	# for the generic nodpi, and a configured numeric dpi must be inside the range.
	# nth-last-child(1) is the row shown last on the page (the newest upload),
	# which is the variant the builder prefers.
	range_page=$(printf '<div class="variants">%s%s</div>' \
		"$(variant_row '/apk/x/reddit/reddit-2026-14-0-android-apk-download/' 2026.14.0 BUNDLE universal 120-640dpi)" \
		"$(variant_row '/apk/x/reddit/reddit-2026-14-0-2-android-apk-download/' 2026.14.0 BUNDLE universal 120-640dpi)")
	assert_eq "$(apk_mirror_search "$range_page" nodpi all BUNDLE)" "https://www.apkmirror.com/apk/x/reddit/reddit-2026-14-0-2-android-apk-download/"
	assert_eq "$(apk_mirror_search "$range_page" 420dpi all BUNDLE)" "https://www.apkmirror.com/apk/x/reddit/reddit-2026-14-0-2-android-apk-download/"
	if apk_mirror_search "$range_page" 900dpi all BUNDLE >/dev/null; then
		fail "expected a dpi outside the 120-640 range not to match"
	fi
	apkmirror_dpi_matches 120-640dpi nodpi || fail "expected dpi range to match generic nodpi"
	apkmirror_dpi_matches 120-640dpi 420dpi || fail "expected configured dpi inside range to match"
	apkmirror_dpi_matches 120-640dpi 900dpi && fail "expected dpi outside range not to match"
	apkmirror_dpi_matches 160dpi 160dpi || fail "expected identical single densities to match"
	apkmirror_dpi_matches 160dpi 420dpi && fail "expected different single densities not to match"
else
	echo "skipping htmlq-based APKMirror tests (no x86_64 htmlq binary)"
fi

echo "All Morphe Module Builder helper tests passed."
