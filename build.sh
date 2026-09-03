#!/usr/bin/env bash

set -euo pipefail
shopt -s nullglob
trap 'rm -rf temp/*tmp.* temp/*/*tmp.* temp/*-temporary-files; exit 130' INT TERM

usage() {
	cat <<'EOF'
Morphe Module Builder

Usage:
  ./build.sh [config.toml]
  ./build.sh <config.toml> --config-update
  ./build.sh clean
  ./build.sh --help

Builds APKs and optional Magisk/KernelSU modules with Morphe Desktop and a
Morphe-compatible .mpp patch bundle. The default configuration is config.toml.
EOF
}

if [ "${1-}" = clean ]; then
	rm -rf temp build logs build.md
	exit 0
fi
if [ "${1-}" = --help ] || [ "${1-}" = -h ]; then usage; exit 0; fi
if [ "${1-}" = --version ] || [ "${1-}" = -V ]; then
	echo "Morphe Module Builder"
	exit 0
fi

source utils.sh

CONFIG_FILE="${1:-config.toml}"
if [ ! -f "$CONFIG_FILE" ]; then
	abort "could not find config file '$CONFIG_FILE'\nUsage: $0 <config.toml>"
fi
toml_prep "$(cat "$CONFIG_FILE")" || abort "could not read config file '$CONFIG_FILE'"

# -- Main configuration ------------------------------------------------------
main_config_t=$(toml_get_table "")
COMPRESSION_LEVEL=$(toml_get "$main_config_t" compression-level) || COMPRESSION_LEVEL=9
PARALLEL_JOBS=$(toml_get "$main_config_t" parallel-jobs) || {
	if is_android; then PARALLEL_JOBS=1; else PARALLEL_JOBS=$(nproc 2>/dev/null || echo 1); fi
}
[[ "$PARALLEL_JOBS" =~ ^[1-9][0-9]*$ ]] || abort "parallel-jobs must be a positive integer"
[[ "$COMPRESSION_LEVEL" =~ ^[0-9]+$ ]] || abort "compression-level must be an integer from 0 to 9"
if ((COMPRESSION_LEVEL > 9)); then abort "compression-level must be within 0-9"; fi

DEF_PATCHES_VER=$(toml_get "$main_config_t" patches-version) || DEF_PATCHES_VER=latest
DEF_MORPHE_VER=$(toml_get "$main_config_t" morphe-version) || DEF_MORPHE_VER=latest
DEF_PATCHES_SRC=$(toml_get "$main_config_t" patches-source) || DEF_PATCHES_SRC=MorpheApp/morphe-patches
DEF_MORPHE_SRC=$(toml_get "$main_config_t" morphe-source) || DEF_MORPHE_SRC=MorpheApp/morphe-desktop
DEF_BRAND=$(toml_get "$main_config_t" morphe-brand) || DEF_BRAND=Morphe
DEF_KEYSTORE=$(toml_get "$main_config_t" keystore) || DEF_KEYSTORE=""
DEF_KEYSTORE_PASSWORD=$(toml_get "$main_config_t" keystore-password) || DEF_KEYSTORE_PASSWORD=""
DEF_KEYSTORE_ALIAS=$(toml_get "$main_config_t" keystore-entry-alias) || DEF_KEYSTORE_ALIAS=Morphe
DEF_KEYSTORE_ENTRY_PASSWORD=$(toml_get "$main_config_t" keystore-entry-password) || DEF_KEYSTORE_ENTRY_PASSWORD=Morphe
DEF_SIGNER=$(toml_get "$main_config_t" signer) || DEF_SIGNER="Morphe Module Builder"
# Environment variables are useful for a Morphe Manager key in CI and take
# precedence over values in a checked-in configuration file.
[ -n "${MORPHE_KEYSTORE_PASSWORD-}" ] && DEF_KEYSTORE_PASSWORD="$MORPHE_KEYSTORE_PASSWORD"
[ -n "${MORPHE_KEYSTORE_ALIAS-}" ] && DEF_KEYSTORE_ALIAS="$MORPHE_KEYSTORE_ALIAS"
[ -n "${MORPHE_KEYSTORE_ENTRY_PASSWORD-}" ] && DEF_KEYSTORE_ENTRY_PASSWORD="$MORPHE_KEYSTORE_ENTRY_PASSWORD"
[ -n "${MORPHE_SIGNER-}" ] && DEF_SIGNER="$MORPHE_SIGNER"
DEF_BYTECODE_MODE=$(toml_get "$main_config_t" bytecode-mode) || DEF_BYTECODE_MODE=STRIP_SAFE
DEF_STRIP_LIBS=$(toml_get "$main_config_t" strip-libs) || DEF_STRIP_LIBS=true
DEF_KEEP_ARCHITECTURES=$(toml_get "$main_config_t" keep-architectures) || DEF_KEEP_ARCHITECTURES=""
DEF_FORCE=$(toml_get "$main_config_t" force) || DEF_FORCE=false
DEF_CONTINUE_ON_ERROR=$(toml_get "$main_config_t" continue-on-error) || DEF_CONTINUE_ON_ERROR=false
DEF_OPTIONS_UPDATE=$(toml_get "$main_config_t" options-update) || DEF_OPTIONS_UPDATE=false
DEF_VERIFY_SIGNATURE=$(toml_get "$main_config_t" verify-source-signature) || DEF_VERIFY_SIGNATURE=true

enable_magisk_update=$(toml_get "$main_config_t" enable-magisk-update) || enable_magisk_update=true
vtf "$enable_magisk_update" enable-magisk-update
ENABLE_MAGISK_UPDATE="$enable_magisk_update"
mkdir -p "$TEMP_DIR" "$BUILD_DIR"

if [ "${2-}" = --config-update ]; then
	config_update
	exit 0
fi

find "$BUILD_DIR" -maxdepth 1 -type f \( -name '*.apk' -o -name '*.zip' \) -delete
rm -f "${TEMP_DIR}"/failed-*
: >build.md
if [ "$ENABLE_MAGISK_UPDATE" = true ] && [ -z "${GITHUB_REPOSITORY-}" ]; then
	pr "Local build detected; Magisk update metadata will be omitted."
	ENABLE_MAGISK_UPDATE=false
fi

# -- Dependencies ------------------------------------------------------------
for command in jq java zip unzip wget; do
	command -v "$command" >/dev/null 2>&1 || abort "'$command' is not installed"
done
java_major=$(java -version 2>&1 | sed -n 's/.*version "\([0-9][0-9]*\).*/\1/p' | head -n 1)
if [ -z "$java_major" ]; then
	java_major=$(java -version 2>&1 | sed -n 's/.*openjdk \([0-9][0-9]*\).*/\1/p' | head -n 1)
fi
[[ "$java_major" =~ ^[0-9]+$ ]] && ((java_major >= 21)) || \
	abort "Morphe Desktop requires Java 21 or newer (detected: ${java_major:-unknown})"

rm -f "${TEMP_DIR}"/*tmp.* "${TEMP_DIR}"/*/*tmp.* 2>/dev/null || true
get_prebuilts

# Fail fast with actionable output when an imported keystore cannot be used.
# Morphe signs every patched APK with it, so missing credentials would otherwise
# fail each app separately with an opaque keystore error deep inside the build.
if [ -n "${MORPHE_KEYSTORE-}" ]; then
	if [ ! -f "$MORPHE_KEYSTORE" ]; then
		abort "MORPHE_KEYSTORE is set to '$MORPHE_KEYSTORE' but the file does not exist"
	fi
	if [ -z "${MORPHE_KEYSTORE_PASSWORD-}" ]; then
		abort "MORPHE_KEYSTORE is set but MORPHE_KEYSTORE_PASSWORD is empty. \
Set it (and MORPHE_KEYSTORE_ALIAS / MORPHE_KEYSTORE_ENTRY_PASSWORD when the key uses different values) \
so Morphe can open the keystore, or unset MORPHE_KEYSTORE to use Morphe's default key."
	fi
	if command -v keytool >/dev/null 2>&1; then
		local_keystore_alias="${MORPHE_KEYSTORE_ALIAS-}"
		[ -n "$local_keystore_alias" ] || local_keystore_alias=Morphe
		keystore_list=$(keytool -list -keystore "$MORPHE_KEYSTORE" \
			-storepass "$MORPHE_KEYSTORE_PASSWORD" 2>/dev/null) || keystore_list=""
		if [ -z "$keystore_list" ]; then
			# keytool can only read JKS/PKCS12; Morphe additionally accepts BKS.
			# Only treat the failure as fatal for formats keytool understands.
			keystore_magic=$(od -An -tx1 -N4 "$MORPHE_KEYSTORE" 2>/dev/null | tr -d '[:space:]')
			case "$keystore_magic" in
				feedfeed*|3082*|3080*)
					abort "cannot open MORPHE_KEYSTORE '$MORPHE_KEYSTORE' with the supplied MORPHE_KEYSTORE_PASSWORD" ;;
				*)
					pr "Warning: could not inspect MORPHE_KEYSTORE with keytool (unsupported format); continuing" ;;
			esac
		elif ! grep -q "^${local_keystore_alias}, " <<<"$keystore_list"; then
			abort "alias '${local_keystore_alias}' not found in MORPHE_KEYSTORE '$MORPHE_KEYSTORE'. \
Set MORPHE_KEYSTORE_ALIAS to one of the keystore's aliases."
		fi
	fi
fi

# -- Build each configured app -----------------------------------------------
declare -a table_names=()
mapfile -t table_names < <(toml_get_table_names)
module_build=false
for table_name in "${table_names[@]}"; do
	[ -n "$table_name" ] || continue
	t=$(toml_get_table "$table_name")
	enabled=$(toml_get "$t" enabled) || enabled=true
	[ "$enabled" = false ] && continue
	build_mode=$(toml_get "$t" build-mode) || build_mode=apk
	case "$build_mode" in
		module|both) module_build=true; break ;;
	esac
done
if [ "$module_build" = true ]; then
	get_module_prebuilts || abort "could not download module update helper binaries"
fi

idx=0
for table_name in "${table_names[@]}"; do
	[ -n "$table_name" ] || continue
	t=$(toml_get_table "$table_name")
	enabled=$(toml_get "$t" enabled) || enabled=true
	vtf "$enabled" enabled
	[ "$enabled" = true ] || continue

	if ((idx >= PARALLEL_JOBS)); then
		wait -n || true
		idx=$((idx - 1))
	fi

	declare -A app_args=()
	patches_src=$(toml_get "$t" patches-source) || patches_src="$DEF_PATCHES_SRC"
	patches_ver=$(toml_get "$t" patches-version) || patches_ver="$DEF_PATCHES_VER"
	morphe_src=$(toml_get "$t" morphe-source) || morphe_src="$DEF_MORPHE_SRC"
	morphe_ver=$(toml_get "$t" morphe-version) || morphe_ver="$DEF_MORPHE_VER"

	if ! MORPHE_FILES=$(get_morphe_prebuilts "$morphe_src" "$morphe_ver" "$patches_src" "$patches_ver"); then
		abort "could not download Morphe Desktop or Morphe patches for '$table_name'"
	fi
	IFS=$'\t' read -r morphe_jar morphe_patches <<<"$MORPHE_FILES"
	app_args[morphe_jar]="$morphe_jar"
	app_args[patches_file]="$morphe_patches"
	app_args[patches_source]="$patches_src"

	app_args[excluded_patches]=$(toml_get "$t" excluded-patches) || app_args[excluded_patches]=""
	app_args[included_patches]=$(toml_get "$t" included-patches) || app_args[included_patches]=""
	if [ -n "${app_args[excluded_patches]}" ] && [ "$(list_args "${app_args[excluded_patches]}")" = "${app_args[excluded_patches]}" ]; then
		# An unquoted value can still be a one-word patch name, but whitespace
		# separated names must be quoted to avoid accidental selection changes.
		if [[ "${app_args[excluded_patches]}" == *" "* ]]; then
			abort "patch names inside excluded-patches must be quoted"
		fi
	fi
	if [ -n "${app_args[included_patches]}" ] && [ "$(list_args "${app_args[included_patches]}")" = "${app_args[included_patches]}" ]; then
		if [[ "${app_args[included_patches]}" == *" "* ]]; then
			abort "patch names inside included-patches must be quoted"
		fi
	fi

	app_args[exclusive_patches]=$(toml_get "$t" exclusive-patches) || app_args[exclusive_patches]=false
	vtf "${app_args[exclusive_patches]}" exclusive-patches
	app_args[version]=$(toml_get "$t" version) || app_args[version]=auto
	app_args[app_name]=$(toml_get "$t" app-name) || app_args[app_name]="$table_name"
	app_args[table]="$table_name"
	app_args[build_mode]=$(toml_get "$t" build-mode) || app_args[build_mode]=apk
	isoneof "${app_args[build_mode]}" apk module both || \
		abort "ERROR: build-mode '${app_args[build_mode]}' is not valid for '${table_name}' (use apk, module or both)"

	# Download sources are tried in this order; the first configured one is also
	# used for version discovery when version is latest/beta.
	for source in apkmirror uptodown archive; do
		key="${source}-dlurl"
		app_args[${source}_dlurl]=$(toml_get "$t" "$key") || app_args[${source}_dlurl]=""
		if [ -n "${app_args[${source}_dlurl]}" ]; then
			app_args[${source}_dlurl]="${app_args[${source}_dlurl]%/}"
		fi
	done
	[ -n "${app_args[apkmirror_dlurl]}" ] || [ -n "${app_args[uptodown_dlurl]}" ] || \
		[ -n "${app_args[archive_dlurl]}" ] || abort "no APK download URL set for '$table_name'"

	app_args[arch]=$(toml_get "$t" arch) || app_args[arch]=all
	case "${app_args[arch]}" in
		all|both|arm64-v8a|arm-v7a|armeabi-v7a|x86|x86_64) ;;
		*) abort "wrong arch '${app_args[arch]}' for '$table_name'" ;;
	esac
	app_args[include_stock]=$(toml_get "$t" include-stock) || app_args[include_stock]=true
	vtf "${app_args[include_stock]}" include-stock
	app_args[dpi]=$(toml_get "$t" apkmirror-dpi) || app_args[dpi]=nodpi

	app_name_slug=$(slugify "${app_args[app_name]}")
	app_args[module_prop_name]=$(toml_get "$t" module-prop-name) || {
		app_args[module_prop_name]="${app_name_slug}-morphe"
		case "${app_args[arch]}" in
			arm64-v8a) app_args[module_prop_name]+=-arm64 ;;
			arm-v7a|armeabi-v7a) app_args[module_prop_name]+=-arm ;;
		esac
	}
	app_args[brand]=$(toml_get "$t" morphe-brand) || app_args[brand]="$DEF_BRAND"
	app_args[strip_libs]=$(toml_get "$t" strip-libs) || app_args[strip_libs]="$DEF_STRIP_LIBS"
	vtf "${app_args[strip_libs]}" strip-libs
	app_args[keep_architectures]=$(toml_get "$t" keep-architectures) || app_args[keep_architectures]="$DEF_KEEP_ARCHITECTURES"
	app_args[force]=$(toml_get "$t" force) || app_args[force]="$DEF_FORCE"
	vtf "${app_args[force]}" force
	app_args[continue_on_error]=$(toml_get "$t" continue-on-error) || app_args[continue_on_error]="$DEF_CONTINUE_ON_ERROR"
	vtf "${app_args[continue_on_error]}" continue-on-error
	app_args[options_update]=$(toml_get "$t" options-update) || app_args[options_update]="$DEF_OPTIONS_UPDATE"
	vtf "${app_args[options_update]}" options-update
	app_args[options_file]=$(toml_get "$t" options-file) || app_args[options_file]=""
	if [ -n "${app_args[options_file]}" ] && [[ "${app_args[options_file]}" != /* ]]; then
		app_args[options_file]="${CWD}/${app_args[options_file]}"
	fi
	app_args[bytecode_mode]=$(toml_get "$t" bytecode-mode) || app_args[bytecode_mode]="$DEF_BYTECODE_MODE"
	isoneof "${app_args[bytecode_mode]}" FULL STRIP_SAFE STRIP_FAST || \
		abort "invalid bytecode-mode '${app_args[bytecode_mode]}' for '$table_name'"
	app_args[verify_signature]=$(toml_get "$t" verify-source-signature) || app_args[verify_signature]="$DEF_VERIFY_SIGNATURE"
	vtf "${app_args[verify_signature]}" verify-source-signature

	app_args[keystore]=$(toml_get "$t" keystore) || app_args[keystore]="$DEF_KEYSTORE"
	app_args[keystore_password]=$(toml_get "$t" keystore-password) || app_args[keystore_password]="$DEF_KEYSTORE_PASSWORD"
	app_args[keystore_alias]=$(toml_get "$t" keystore-entry-alias) || app_args[keystore_alias]="$DEF_KEYSTORE_ALIAS"
	app_args[keystore_entry_password]=$(toml_get "$t" keystore-entry-password) || app_args[keystore_entry_password]="$DEF_KEYSTORE_ENTRY_PASSWORD"
	app_args[signer]=$(toml_get "$t" signer) || app_args[signer]="$DEF_SIGNER"

	if [ "${app_args[arch]}" = both ]; then
		base_module_prop_name="${app_args[module_prop_name]}"
		app_args[table]="$table_name (arm64-v8a)"
		app_args[arch]=arm64-v8a
		app_args[module_prop_name]="${base_module_prop_name}-arm64"
		idx=$((idx + 1))
		if ! build_morphe "$(declare -p app_args)"; then touch "${TEMP_DIR}/failed-${app_name_slug}-arm64"; fi &
		app_args[table]="$table_name (arm-v7a)"
		app_args[arch]=arm-v7a
		app_args[module_prop_name]="${base_module_prop_name}-arm"
		if ((idx >= PARALLEL_JOBS)); then wait -n || true; idx=$((idx - 1)); fi
		idx=$((idx + 1))
		if ! build_morphe "$(declare -p app_args)"; then touch "${TEMP_DIR}/failed-${app_name_slug}-arm"; fi &
	else
		idx=$((idx + 1))
		if ! build_morphe "$(declare -p app_args)"; then touch "${TEMP_DIR}/failed-${app_name_slug}"; fi &
	fi
done
wait || true

rm -f "${TEMP_DIR}"/tmp.*
if ! find "$BUILD_DIR" -mindepth 1 -type f -print -quit | grep -q .; then
	abort "All Morphe builds failed. See the errors above."
fi

log ""
log "Built with [Morphe Desktop](https://github.com/MorpheApp/morphe-desktop) and [Morphe patches](https://github.com/MorpheApp/morphe-patches)."
log "Install only APKs you are permitted to modify and use. Keep the original APK for rollback."
log "[Morphe Module Builder](https://github.com/iamsmmh/morphe-module-builder)"

FAILED=$(cat "${TEMP_DIR}"/failed-* 2>/dev/null || true)
if [ -n "$FAILED" ]; then
	log ""
	log "Some configured apps failed; successful outputs are still available in '$BUILD_DIR'."
fi

pr "Done"
