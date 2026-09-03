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

echo "All Morphe Module Builder helper tests passed."
