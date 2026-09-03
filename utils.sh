#!/usr/bin/env bash

# Shared helpers for Morphe Module Builder.
#
# This file is sourced by build.sh.  Keep it free of commands which only make
# sense in an interactive shell: build.sh also sources it from CI and from
# Termux.

PROJECT_NAME="Morphe Module Builder"
MODULE_TEMPLATE_DIR="morphe-module"
CWD="${CWD:-$(pwd)}"
TEMP_DIR="${TEMP_DIR:-temp}"
BIN_DIR="${BIN_DIR:-bin}"
BUILD_DIR="${BUILD_DIR:-build}"

if [ -n "${GITHUB_TOKEN-}" ]; then
	GH_HEADER="Authorization: Bearer ${GITHUB_TOKEN}"
else
	GH_HEADER=""
fi
NEXT_VER_CODE="${NEXT_VER_CODE:-$(date +'%Y%m%d')}"
OS="$(uname -o 2>/dev/null || uname -s)"

###############################################################################
# Small shell helpers
###############################################################################

is_android() { [ "$OS" = "Android" ] || [ -d /data/adb ]; }

isoneof() {
	local needle="${1-}" value
	shift || true
	for value; do
		[ "$value" = "$needle" ] && return 0
	done
	return 1
}

vtf() {
	if ! isoneof "${1-}" true false; then
		abort "ERROR: '${1-}' is not a valid option for '${2-}': only true or false is allowed"
	fi
}

slugify() {
	local value="${1-}"
	value="${value,,}"
	value="${value// /-}"
	value="${value//[^a-z0-9._-]/-}"
	value="${value##-}"
	value="${value%%-}"
	printf '%s' "${value:-app}"
}

path_from_cwd() {
	case "${1-}" in
		/*) printf '%s' "$1" ;;
		*) printf '%s/%s' "$CWD" "${1-}" ;;
	esac
}

# Print a human-readable progress line. Error output goes to stderr so command
# substitutions can safely consume paths and API responses.
pr() { echo -e "\033[0;32m[+] ${1-}\033[0m"; }
epr() {
	echo >&2 -e "\033[0;31m[-] ${1-}\033[0m"
	if [ -n "${GITHUB_REPOSITORY-}" ]; then
		echo -e "::error::${PROJECT_NAME} [-] ${1-}\n"
	fi
}
abort() {
	epr "ABORT: ${1-}"
	exit 1
}

###############################################################################
# Lightweight TOML reader
###############################################################################
# The project configuration deliberately uses a small, documented subset of
# TOML: tables, comments, booleans, numbers and strings.  These helpers keep
# the builder dependency-free on Android/Termux.  Quoted '#' characters are
# preserved and table names may contain spaces.

toml_prep() {
	__TOML__=$(awk '
		{
			line = $0
			quote = ""
			escaped = 0
			out = ""
			for (i = 1; i <= length(line); i++) {
				c = substr(line, i, 1)
				if (quote != "") {
					out = out c
					if (c == quote && !escaped) quote = ""
					if (c == "\\" && !escaped) escaped = 1
					else escaped = 0
				} else if (c == "\"" || c == "\047") {
					quote = c
					out = out c
				} else if (c == "#") {
					break
				} else {
					out = out c
				}
			}
			gsub(/^[[:space:]]+|[[:space:]]+$/, "", out)
			if (out != "") print out
		}
	' <<<"${1-}" | sed -E 's/[[:space:]]*=[[:space:]]*/=/')
}

toml_get_table_names() {
	local names
	names=$(awk '/^\[[^][]+\]$/ { gsub(/^\[|\]$/, ""); print }' <<<"${__TOML__-}") || return 1
	[ -n "$names" ] || return 0
	if [ "$(sort <<<"$names" | uniq -d | wc -l)" -ne 0 ]; then
		abort "ERROR: duplicate tables in TOML"
	fi
	printf '%s\n' "$names"
}

toml_get_table() {
	local wanted="${1-}"
	awk -v wanted="$wanted" '
		BEGIN { in_table = (wanted == "") }
		/^[[][^][]+[]]$/ {
			name = $0
			gsub(/^\[|\]$/, "", name)
			if (wanted == "") exit
			in_table = (name == wanted)
			next
		}
		in_table { print }
	' <<<"${__TOML__-}"
}

toml_get() {
	local table="${1-}" key="${2-}" value
	value=$(awk -F= -v key="$key" '
		$1 == key {
			value = substr($0, index($0, "=") + 1)
			gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
			print value
			exit
		}
	' <<<"$table") || return 1
	[ -n "$value" ] || return 1
	case "$value" in
		\"*\") value="${value:1:${#value}-2}" ;;
		\'*\') value="${value:1:${#value}-2}" ;;
	esac
	printf '%s' "$value"
}

# Turn a whitespace-separated list of quoted patch names into one name per
# line. Both single and double quotes are accepted in config values, e.g.
# 'Remove ads' 'Custom icon'.
list_args() {
	local input="${1-}" token="" quote="" escaped=false c i
	for ((i = 0; i < ${#input}; i++)); do
		c="${input:i:1}"
		if [ -n "$quote" ]; then
			if [ "$c" = "\\" ] && [ "$escaped" = false ]; then
				escaped=true
				continue
			fi
			if [ "$c" = "$quote" ] && [ "$escaped" = false ]; then
				quote=""
			else
				token+="$c"
			fi
			escaped=false
		elif [ "$c" = "\"" ] || [ "$c" = "'" ]; then
			quote="$c"
		elif [[ "$c" =~ [[:space:]] ]]; then
			if [ -n "$token" ]; then
				printf '%s\n' "$token"
				token=""
			fi
		else
			token+="$c"
		fi
	done
	[ -n "$token" ] && printf '%s\n' "$token"
}

append_patch_names() {
	local selection="${1-}" flag="${2-}" name
	while IFS= read -r name; do
		[ -n "$name" ] && PATCH_ARGS+=("$flag" "$name")
	done < <(list_args "$selection")
}

###############################################################################
# HTTP and GitHub release helpers
###############################################################################

_req() {
	local input_url="${1-}" output="${2-}"
	shift 2
	if [ "$output" = "-" ]; then
		wget -qO- --timeout=30 --tries=3 "$@" "$input_url"
		return
	fi

	if [ -s "$output" ]; then return 0; fi
	mkdir -p "$(dirname "$output")"
	local temporary="$(dirname "$output")/tmp.$(basename "$output")"
	if [ -e "$temporary" ]; then
		# Another parallel app may already be downloading this asset.
		while [ -e "$temporary" ]; do sleep 1; done
		[ -s "$output" ]
		return
	fi
	if ! wget -nv -O "$temporary" --timeout=60 --tries=3 "$@" "$input_url"; then
		rm -f "$temporary"
		return 1
	fi
	[ -s "$temporary" ] || { rm -f "$temporary"; return 1; }
	mv -f "$temporary" "$output"
}

req() {
	_req "$1" "$2" \
		--header="User-Agent: Morphe-Module-Builder/1.0 (https://github.com/iamsmmh/morphe-module-builder)"
}
gh_req() {
	if [ -n "$GH_HEADER" ]; then
		_req "$1" "$2" --header="$GH_HEADER" --header="Accept: application/vnd.github+json"
	else
		_req "$1" "$2" --header="Accept: application/vnd.github+json"
	fi
}
gh_dl() {
	local output="${1-}" url="${2-}"
	if [ ! -s "$output" ]; then
		pr "Getting '$output'" >&2
		if [ -n "$GH_HEADER" ]; then
			_req "$url" "$output" --header="$GH_HEADER" --header="Accept: application/octet-stream" || return 1
		else
			_req "$url" "$output" --header="Accept: application/octet-stream" || return 1
		fi
	fi
}

repo_cache_name() {
	printf '%s' "${1,,}" | sed 's#[^a-z0-9._-]#-#g'
}

# Resolve one asset from a Morphe-compatible GitHub release.  The result is a
# local path.  `version` accepts latest, dev, or an exact release tag.
get_release_asset() {
	local repo="$1" version="$2" suffix="$3" label="$4"
	local release_url="https://api.github.com/repos/${repo}/releases" response release tag asset
	case "$version" in
		latest) release_url+="/latest" ;;
		dev) ;;
		*) release_url+="/tags/${version}" ;;
	esac
	response=$(gh_req "$release_url" -) || return 1
	if [ "$version" = dev ]; then
		response=$(jq -e -c 'map(select(.draft == false and .prerelease == true))[0]' <<<"$response") || return 1
	fi
	[ "$response" != null ] || return 1
	tag=$(jq -e -r '.tag_name' <<<"$response") || return 1
	asset=$(jq -e -r --arg suffix "$suffix" \
		'[.assets[] | select(.name | endswith($suffix))] |
			if length == 0 then error("release asset not found") else .[0] | [.name, .url] | @tsv end' \
		<<<"$response") || return 1
	local asset_name="${asset%%$'\t'*}" api_url="${asset#*$'\t'}"
	local cache_dir="${TEMP_DIR}/morphe/$(repo_cache_name "$repo")"
	local target="${cache_dir}/${asset_name}"
	mkdir -p "$cache_dir"
	if [ ! -s "$target" ]; then
		pr "Getting ${label} ${repo}@${tag}" >&2
		gh_dl "$target" "$api_url" || return 1
	fi
	printf '%s' "$target"
}

get_morphe_prebuilts() {
	local desktop_source="$1" desktop_version="$2" patches_source="$3" patches_version="$4"
	local desktop patches
	desktop=$(get_release_asset "$desktop_source" "$desktop_version" "-all.jar" "Morphe Desktop") || return 1
	patches=$(get_release_asset "$patches_source" "$patches_version" ".mpp" "Morphe patches") || return 1
	printf '%s\t%s\n' "$desktop" "$patches"
}

###############################################################################
# Download helper binaries
###############################################################################

get_prebuilts() {
	APKSIGNER="${BIN_DIR}/apksigner.jar"
	if is_android; then
		if [ "$(uname -m)" = aarch64 ]; then
			HTMLQ="${BIN_DIR}/htmlq/htmlq-arm64"
		else
			HTMLQ="${BIN_DIR}/htmlq/htmlq-arm"
		fi
	else
		if [ "$(uname -m)" = aarch64 ]; then HTMLQ="${BIN_DIR}/htmlq/htmlq-arm64"; else HTMLQ="${BIN_DIR}/htmlq/htmlq-x86_64"; fi
	fi
	[ -x "$HTMLQ" ] || abort "htmlq helper is missing or not executable: $HTMLQ"

	# cmpr is executed on the Android device by the generated module.  Keep the
	# four architecture-specific copies in the template, but download them only
	# when a build actually needs to package a module.
	mkdir -p "${MODULE_TEMPLATE_DIR}/bin/arm64" "${MODULE_TEMPLATE_DIR}/bin/arm" \
		"${MODULE_TEMPLATE_DIR}/bin/x86" "${MODULE_TEMPLATE_DIR}/bin/x64"
	gh_dl "${MODULE_TEMPLATE_DIR}/bin/arm64/cmpr" "https://github.com/j-hc/cmpr/releases/latest/download/cmpr-arm64-v8a"
	gh_dl "${MODULE_TEMPLATE_DIR}/bin/arm/cmpr" "https://github.com/j-hc/cmpr/releases/latest/download/cmpr-armeabi-v7a"
	gh_dl "${MODULE_TEMPLATE_DIR}/bin/x86/cmpr" "https://github.com/j-hc/cmpr/releases/latest/download/cmpr-x86"
	gh_dl "${MODULE_TEMPLATE_DIR}/bin/x64/cmpr" "https://github.com/j-hc/cmpr/releases/latest/download/cmpr-x86_64"
	chmod 0755 "${MODULE_TEMPLATE_DIR}"/bin/*/cmpr 2>/dev/null || true
}

###############################################################################
# Release/update bookkeeping
###############################################################################

log() { printf '%b  \n' "${1-}" >>"build.md"; }

get_highest_ver() {
	local versions
	versions=$(awk 'NF { print $1 }' | sort -u)
	[ -n "$versions" ] || return 1
	# sort -V handles normal Android version names and Morphe's occasional
	# prerelease suffixes. If the first item is not version-shaped, keep it.
	local first="$(head -n 1 <<<"$versions")"
	if semver_validate "$first"; then
		sort -rV <<<"$versions" | head -n 1
	else
		printf '%s\n' "$first"
	fi
}

semver_validate() {
	[[ "${1-}" =~ ^v?[0-9]+([.][0-9]+)*([_-][A-Za-z0-9.+_-]+)?$ ]]
}

# Morphe Desktop prints, for example:
#   Package name: com.google.android.youtube
#   Most common compatible versions:
#       20.10.40 (8 patches)
# Read only the requested package and choose the newest compatible version.
get_patch_last_supported_ver() {
	local morphe_jar="$1" patches_file="$2" pkg_name="$3"
	local included="$4" exclusive="$5" output versions
	local version_args=(list-versions --patches "$patches_file" --filter-package-names "$pkg_name")
	# Explicitly selected patches may not be enabled by default. Ask Morphe to
	# count those too; the final patch command still performs the exact selection.
	if [ -n "$included" ] || [ "$exclusive" = true ]; then
		version_args+=(--count-unused-patches)
	fi
	if ! output=$(java -jar "$morphe_jar" "${version_args[@]}" 2>&1); then
		epr "Morphe list-versions failed for '$pkg_name': $output"
		return 1
	fi
	versions=$(awk -v package="$pkg_name" '
		index($0, "Package name: " package) { inside = 1; next }
		inside && /Package name:/ { exit }
		inside && /(^|[^0-9])Any([^A-Za-z0-9]|$)/ { print "Any"; exit }
		inside {
			line = $0
			# Ignore logger prefixes and capture the first Android-like version.
			if (match(line, /v?[0-9]+([.][0-9]+)+([_-][A-Za-z0-9.+_-]+)?/)) print substr(line, RSTART, RLENGTH)
		}
	' <<<"$output" | sort -u)
	[ -n "$versions" ] || return 0
	if grep -qx Any <<<"$versions"; then return 0; fi
	get_highest_ver <<<"$versions"
}

###############################################################################
# APK downloads
###############################################################################

merge_splits() {
	local bundle="$1" output="$2"
	local apkeditor="${TEMP_DIR}/apkeditor.jar"
	pr "Merging split APK bundle"
	if [ ! -s "$apkeditor" ]; then
		gh_dl "$apkeditor" "https://github.com/REAndroid/APKEditor/releases/download/V1.3.9/APKEditor-1.3.9.jar" || return 1
	fi
	local merged="${bundle}.mzip" unpack="${bundle}-zip"
	rm -rf "$merged" "$unpack"
	if ! OP=$(java -jar "$apkeditor" merge -i "$bundle" -o "$merged" -clean-meta -f 2>&1); then
		epr "APKEditor merge failed: $OP"
		return 1
	fi
	mkdir -p "$unpack"
	unzip -qo "$merged" -d "$unpack" || return 1
	(
		cd "$unpack" || exit 1
		zip -0rq "$(path_from_cwd "$output")" .
	) || return 1
	rm -rf "$merged" "$unpack"
	[ -s "$output" ]
}

# -------------------- APKMirror --------------------
apk_mirror_search() {
	local response="$1" dpi="$2" arch="$3" apk_bundle="$4"
	local -a apparch
	if [ "$arch" = all ]; then
		apparch=(universal noarch 'arm64-v8a + armeabi-v7a')
	else
		apparch=("$arch" universal noarch 'arm64-v8a + armeabi-v7a')
	fi
	local node app_table dlurl n
	for ((n = 1; n < 40; n++)); do
		node=$("$HTMLQ" "div.table-row.headerFont:nth-last-child($n)" -r "span:nth-child(n+3)" <<<"$response")
		[ -n "$node" ] || break
		app_table=$("$HTMLQ" --text --ignore-whitespace <<<"$node")
		if [ "$(sed -n 3p <<<"$app_table")" = "$apk_bundle" ] && \
			[ "$(sed -n 6p <<<"$app_table")" = "$dpi" ] && \
			isoneof "$(sed -n 4p <<<"$app_table")" "${apparch[@]}"; then
			dlurl=$("$HTMLQ" --base https://www.apkmirror.com --attribute href \
				"div:nth-child(1) > a:nth-child(1)" <<<"$node")
			printf '%s\n' "$dlurl"
			return 0
		fi
	done
	return 1
}

dl_apkmirror() {
	local base_url="${1%/}" version="${2// /-}" output="$3" arch="$4" dpi="$5"
	[ "$arch" = arm-v7a ] && arch=armeabi-v7a
	local page_url="${base_url}/${base_url##*/}-${version//./-}-release/"
	local response node download_page download_url bundle=false
	response=$(req "$page_url" -) || return 1
	node=$("$HTMLQ" "div.table-row.headerFont:nth-last-child(1)" -r "span:nth-child(n+3)" <<<"$response")
	if [ -n "$node" ]; then
		if ! download_page=$(apk_mirror_search "$response" "$dpi" "$arch" APK); then
			download_page=$(apk_mirror_search "$response" "$dpi" "$arch" BUNDLE) || return 1
			bundle=true
		fi
		response=$(req "$download_page" -) || return 1
	fi
	download_url=$("$HTMLQ" --base https://www.apkmirror.com --attribute href "a.btn" <<<"$response") || return 1
	download_url=$(req "$download_url" - | "$HTMLQ" --base https://www.apkmirror.com \
		--attribute href "span > a[rel = nofollow]") || return 1
	[ -n "$download_url" ] || return 1
	if [ "$bundle" = true ]; then
		req "$download_url" "${output}.apkm" || return 1
		merge_splits "${output}.apkm" "$output"
		rm -f "${output}.apkm"
	else
		req "$download_url" "$output"
	fi
}

get_apkmirror_resp() {
	local url="${1%/}"
	__APKMIRROR_RESP__=$(req "$url" -) || return 1
	__APKMIRROR_CAT__="${url##*/}"
}
get_apkmirror_pkg_name() {
	sed -n 's;.*id=\([^" ]*\)" class="accent_color.*;\1;p' <<<"${__APKMIRROR_RESP__-}" | head -n 1
}
get_apkmirror_vers() {
	local response
	response=$(req "https://www.apkmirror.com/uploads/?appcategory=${__APKMIRROR_CAT__}" -) || return 1
	local versions
	versions=$(sed -n 's;.*Version:</span><span class="infoSlide-value">\(.*\) </span>.*;\1;p' <<<"$response" | awk '{$1=$1}1')
	if [ "${__AAV__:-false}" = false ]; then
		versions=$(grep -Eiv '(beta|alpha)' <<<"$versions" || true)
	fi
	printf '%s\n' "$versions"
}

# -------------------- Uptodown --------------------
get_uptodown_resp() {
	local url="${1%/}"
	__UPTODOWN_RESP__=$(req "${url}/versions" -) || return 1
	__UPTODOWN_RESP_PKG__=$(req "${url}/download" -) || return 1
	__UPTODOWN_URL__="$url"
}
get_uptodown_pkg_name() { "$HTMLQ" --text "tr.full:nth-child(1) > td:nth-child(3)" <<<"${__UPTODOWN_RESP_PKG__-}"; }
get_uptodown_vers() { "$HTMLQ" --text ".version" <<<"${__UPTODOWN_RESP__-}"; }
dl_uptodown() {
	local uptodown_url="${1%/}" version="$2" output="$3" arch="$4" _dpi="$5" latest="$6"
	local url=""
	if [ "$latest" = false ]; then
		url=$(grep -F "${version}</span>" -B 2 <<<"${__UPTODOWN_RESP__-}" | head -n 1 | \
			sed -n 's;.*data-url=".*download/\(.*\)".*;\1;p') || return 1
		url="/${url#/}"
	fi
	if [ "$arch" != all ]; then
		local response app_code data_version files node_arch content n
		if [ "$latest" = false ]; then response=$(req "${uptodown_url}/download${url}" -); else response="${__UPTODOWN_RESP_PKG__}"; fi
		app_code=$("$HTMLQ" "#detail-app-name" --attribute code <<<"$response")
		data_version=$("$HTMLQ" "button.button:nth-child(2)" --attribute data-version <<<"$response")
		files=$(req "${uptodown_url%/*}/app/${app_code}/version/${data_version}/files" - | jq -r .content) || return 1
		for ((n = 1; n < 40; n++)); do
			node_arch=$("$HTMLQ" ".content > p:nth-child($n)" --text <<<"$files" | xargs) || return 1
			[ -n "$node_arch" ] || return 1
			[ "$node_arch" = "$arch" ] || continue
			content=$("$HTMLQ" "div.variant:nth-child($((n + 1)))" <<<"$files")
			url=$(sed -n "s;.*'.*android/post-download/\(.*\)'.*;\1;p" <<<"$content" | head -n 1)
			url="/${url#/}"
			break
		done
	fi
	local token
	token=$(req "${uptodown_url}/post-download${url}" - | \
		sed -n 's;.*class="post-download" data-url="\([^"]*\)".*;\1;p') || return 1
	[ -n "$token" ] || return 1
	req "https://dw.uptodown.com/dwn/${token}" "$output"
}

# -------------------- Internet Archive --------------------
get_archive_resp() {
	local url="${1%/}" response
	response=$(req "$url" -) || return 1
	__ARCHIVE_RESP__=$(sed -n 's;^<a href="\([^"]*\.apk\)"[^>]*>.*;\1;p' <<<"$response")
	[ -n "$__ARCHIVE_RESP__" ] || return 1
	__ARCHIVE_URL__="$url"
	__ARCHIVE_PKG_NAME__="${url##*/}"
}
get_archive_pkg_name() { printf '%s\n' "${__ARCHIVE_PKG_NAME__-}"; }
get_archive_vers() {
	sed -E 's/^[^-]*-//; s/-((all|arm64-v8a|arm-v7a|armeabi-v7a))\.apk$//' <<<"${__ARCHIVE_RESP__-}"
}
dl_archive() {
	local url="${1%/}" version="${2// /}" output="$3" arch="$4"
	local archive_arch="$arch"
	[ "$archive_arch" = all ] && archive_arch=all
	local path
	path=$(grep -E "${version//./\.}-${archive_arch//./\.}\.apk$" <<<"${__ARCHIVE_RESP__-}" | head -n 1) || return 1
	path="${path##*/}"
	req "${url}/${path}" "$output"
}

###############################################################################
# Morphe patching and output packaging
###############################################################################

check_sig() {
	local file="$1" pkg_name="$2" expected signature
	expected=$(awk -v pkg="$pkg_name" '$2 == pkg { print tolower($1); exit }' source-signatures.txt 2>/dev/null || true)
	[ -z "$expected" ] && return 0
	signature=$(java -jar "$APKSIGNER" verify --print-certs "$file" 2>/dev/null | \
		grep -E '^Signer.*SHA-256' | tail -n 1 | awk '{print tolower($NF)}')
	if [ -z "$signature" ] || [ "$signature" != "$expected" ]; then
		epr "source signature mismatch for '$pkg_name' (expected $expected, got ${signature:-unknown})"
		return 1
	fi
	return 0
}

patch_apk() {
	local input="$1" output="$2" morphe_jar="$3" patches_file="$4" key_store="$5" store_password="$6"
	local key_alias="$7" entry_password="$8" signer="$9" temporary="${10}" result_file="${11}"
	shift 11
	local -a patch_args=("$@")
	local -a command=(java -jar "$morphe_jar" patch --patches "$patches_file" --out "$output" \
		--temporary-files-path "$temporary" --result-file "$result_file")

	if [ -n "$key_store" ]; then
		[ -f "$key_store" ] || { epr "keystore not found: $key_store"; return 1; }
		command+=(--keystore "$key_store")
	fi
	[ -n "$store_password" ] && command+=(--keystore-password "$store_password")
	[ -n "$key_alias" ] && command+=(--keystore-entry-alias "$key_alias")
	[ -n "$entry_password" ] && command+=(--keystore-entry-password "$entry_password")
	[ -n "$signer" ] && command+=(--signer "$signer")
	command+=("${patch_args[@]}" "$input")

	pr "Patching $(basename "$input") with Morphe Desktop"
	# The data directory keeps CI/Termux runs self-contained and prevents the
	# desktop CLI from writing into a read-only home directory.
	MORPHE_DATA_DIR="${TEMP_DIR}/morphe-data" "${command[@]}"
	[ -s "$output" ]
}

build_morphe() {
	eval "declare -A args=${1#*=}"
	local table="${args[table]}" app_name="${args[app_name]}" app_slug
	app_slug=$(slugify "$app_name")
	local app_name_l="$app_slug"
	local arch="${args[arch]}"
	local arch_f="${arch// /}"
	local mode_arg="${args[build_mode]}" version_mode="${args[version]}"
	local morphe_jar="${args[morphe_jar]}" patches_file="${args[patches_file]}"
	local download_source="" pkg_name="" version="" latest=false force_version=false
	local -a tried_sources=()

	case "$mode_arg" in
		apk) build_mode_arr=(apk) ;;
		module) build_mode_arr=(module) ;;
		both) build_mode_arr=(apk module) ;;
		*) epr "invalid build mode '$mode_arg' for '$table'"; return 1 ;;
	esac

	# Locate the package and retain the first working source for version lookup.
	local source
	for source in apkmirror uptodown archive; do
		[ -n "${args[${source}_dlurl]-}" ] || continue
		if ! get_${source}_resp "${args[${source}_dlurl]}" || ! pkg_name=$(get_${source}_pkg_name); then
			epr "Could not find '$table' in $source"
			continue
		fi
		tried_sources+=("$source")
		download_source="$source"
		break
	done
	if [ -z "$pkg_name" ]; then
		epr "empty package name; skipping '$table'"
		return 1
	fi

	case "$version_mode" in
		auto)
			version=$(get_patch_last_supported_ver "$morphe_jar" "$patches_file" "$pkg_name" \
				"${args[included_patches]}" "${args[exclusive_patches]}") || return 1
			[ -n "$version" ] || latest=true
			;;
		latest|beta)
			latest=true
			force_version=true
			[ "$version_mode" = beta ] && __AAV__=true || __AAV__=false
			;;
		*)
			version="$version_mode"
			;;
	esac

	if [ "$latest" = true ]; then
		version=$(get_${download_source}_vers | get_highest_ver) || true
		if [ -z "$version" ]; then
			epr "could not determine latest version for '$table'"
			return 1
		fi
	fi
	[ -n "$version" ] || { epr "empty version for '$table'"; return 1; }
	pr "Choosing version '$version' for $table"
	local version_f="${version// /}"
	version_f="${version_f#v}"
	local stock_apk="${TEMP_DIR}/${pkg_name}-${version_f}-${arch_f}.apk"

	if [ ! -s "$stock_apk" ]; then
		for source in apkmirror uptodown archive; do
			[ -n "${args[${source}_dlurl]-}" ] || continue
			pr "Downloading '$table' from $source"
			if ! isoneof "$source" "${tried_sources[@]}"; then
				get_${source}_resp "${args[${source}_dlurl]}" || continue
			fi
			if dl_${source} "${args[${source}_dlurl]}" "$version" "$stock_apk" "$arch" \
				"${args[dpi]}" "$latest"; then
				download_source="$source"
				break
			fi
			epr "Could not download '$table' from $source at version '$version'"
		done
	fi
	[ -s "$stock_apk" ] || return 1

	if [ "${args[verify_signature]}" = true ] && ! check_sig "$stock_apk" "$pkg_name"; then
		return 1
	fi
	log "${table}: ${version}"
	log "Morphe Desktop: $(basename "$morphe_jar")"
	log "Morphe Patches: ${args[patches_source]}/$(basename "$patches_file")"

	local key_store="${args[keystore]}" store_password="${args[keystore_password]}"
	local key_alias="${args[keystore_alias]}" entry_password="${args[keystore_entry_password]}" signer="${args[signer]}"
	if [ -n "${MORPHE_KEYSTORE-}" ]; then key_store="$MORPHE_KEYSTORE"; fi
	if [ -n "$key_store" ] && [ ! -f "$key_store" ]; then
		# Morphe can create and reuse its own default key when no explicit key is
		# supplied. This is useful for clean clones; CI users should cache/export a
		# key when they need APK updates to retain the same signature.
		pr "Configured keystore '$key_store' is unavailable; using Morphe's default keystore"
		key_store=""
		store_password=""
		key_alias="Morphe"
		entry_password="Morphe"
	fi
	[[ "$key_store" = /* ]] || [ -z "$key_store" ] || key_store="${CWD}/${key_store}"

	local -a base_patch_args=()
	PATCH_ARGS=()
	append_patch_names "${args[excluded_patches]}" --disable
	append_patch_names "${args[included_patches]}" --enable
	base_patch_args=("${PATCH_ARGS[@]}")
	[ "${args[exclusive_patches]}" = true ] && base_patch_args+=(--exclusive)
	if [ "${args[force]}" = true ] || [ "$force_version" = true ]; then base_patch_args+=(--force); fi
	[ "${args[continue_on_error]}" = true ] && base_patch_args+=(--continue-on-error)
	[ -n "${args[options_file]}" ] && base_patch_args+=(--options-file "${args[options_file]}")
	[ "${args[options_update]}" = true ] && base_patch_args+=(--options-update)
	[ -n "${args[bytecode_mode]}" ] && base_patch_args+=(--bytecode-mode "${args[bytecode_mode]}")

	local keep_architectures="${args[keep_architectures]}"
	if [ "${args[strip_libs]}" = true ]; then
		if [ -z "$keep_architectures" ]; then
			case "$arch" in
				arm64-v8a) keep_architectures=arm64-v8a ;;
				arm-v7a) keep_architectures=armeabi-v7a ;;
				all) keep_architectures=arm64-v8a,armeabi-v7a ;;
				*) keep_architectures="$arch" ;;
			esac
		fi
		base_patch_args+=(--striplibs "$keep_architectures")
	fi

	local build_mode patched_apk apk_output module_output base_template update_json
	local brand="${args[brand]}" brand_slug
	brand_slug=$(slugify "${brand:-morphe}")
	for build_mode in "${build_mode_arr[@]}"; do
		patched_apk="${TEMP_DIR}/${app_name_l}-${brand_slug}-${version_f}-${arch_f}-${build_mode}.apk"
		local -a patch_args=("${base_patch_args[@]}")
		local run_temp="${TEMP_DIR}/morphe-tmp/${app_slug}-${arch_f}-${build_mode}"
		local result_file="${TEMP_DIR}/${app_slug}-${arch_f}-${build_mode}-result.json"
		mkdir -p "$run_temp"
		if ! patch_apk "$stock_apk" "$patched_apk" "$morphe_jar" "$patches_file" "$key_store" \
			"$store_password" "$key_alias" "$entry_password" \
			"$signer" "$run_temp" "$result_file" "${patch_args[@]}"; then
			epr "Morphe patching failed for '$table' ($build_mode)"
			return 1
		fi

		if [ "$build_mode" = apk ]; then
			apk_output="${BUILD_DIR}/${app_name_l}-${brand_slug}-v${version_f}-${arch_f}.apk"
			mv -f "$patched_apk" "$apk_output"
			pr "Built $table APK: '$apk_output'"
			continue
		fi

		base_template=$(mktemp -d -p "$TEMP_DIR")
		cp -a "${MODULE_TEMPLATE_DIR}/." "$base_template/"
		update_json="${app_slug}-${arch_f}-update.json"
		module_config "$base_template" "$pkg_name" "$version" "$arch"
		module_prop \
			"${args[module_prop_name]}" \
			"${app_name} ${brand}" \
			"$version" \
			"${app_name} ${brand} Magisk/KernelSU module built by ${PROJECT_NAME}" \
			"https://raw.githubusercontent.com/${GITHUB_REPOSITORY-}/update/${update_json}" \
			"$base_template"
			module_output="${BUILD_DIR}/${app_name_l}-${brand_slug}-module-v${version_f}-${arch_f}.zip"
		cp -f "$patched_apk" "${base_template}/base.apk"
		if [ "${args[include_stock]}" = true ]; then cp -f "$stock_apk" "${base_template}/${pkg_name}.apk"; fi
		pr "Packing $table module"
			(
				cd "$base_template" || exit 1
				zip -"$COMPRESSION_LEVEL" -FSqr "$(path_from_cwd "$module_output")" .
			) || { rm -rf "$base_template"; return 1; }
		rm -rf "$base_template"
		pr "Built $table module: '$module_output'"
	done
}

###############################################################################
# Generated module metadata
###############################################################################

module_config() {
	local module_dir="$1" pkg="$2" version="$3" arch="$4" module_arch=""
	case "$arch" in
		arm64-v8a) module_arch=arm64 ;;
		arm-v7a|armeabi-v7a) module_arch=arm ;;
		x86) module_arch=x86 ;;
		x86_64|x64) module_arch=x64 ;;
	esac
	cat >"${module_dir}/config" <<EOF
PKG_NAME=${pkg}
PKG_VER=${version}
MODULE_ARCH=${module_arch}
EOF
}

module_prop() {
	local module_id="$1" name="$2" app_version="$3" description="$4" update_json="$5" module_dir="$6"
	cat >"${module_dir}/module.prop" <<EOF
id=${module_id}
name=${name}
version=v${app_version} (${NEXT_VER_CODE})
versionCode=${NEXT_VER_CODE}
author=${PROJECT_NAME}
description=${description}
EOF
	if [ "$ENABLE_MAGISK_UPDATE" = true ]; then
		printf 'updateJson=%s\n' "$update_json" >>"${module_dir}/module.prop"
	fi
}

config_update() {
	[ -f build.md ] || return 0
	local -A seen_patches=() seen_desktop=()
	local table t enabled patches_source patches_version morphe_source morphe_version asset expected source_key
	while IFS= read -r table; do
		[ -n "$table" ] || continue
		t=$(toml_get_table "$table")
		enabled=$(toml_get "$t" enabled) || enabled=true
		[ "$enabled" = false ] && continue

		morphe_source=$(toml_get "$t" morphe-source) || morphe_source="$DEF_MORPHE_SRC"
		morphe_version=$(toml_get "$t" morphe-version) || morphe_version="$DEF_MORPHE_VER"
		source_key="${morphe_source}/${morphe_version}"
		if [ -z "${seen_desktop[$source_key]+x}" ]; then
			seen_desktop[$source_key]=1
			asset=$(get_release_asset "$morphe_source" "$morphe_version" "-all.jar" "Morphe Desktop" 2>/dev/null) || asset=""
			if [ -n "$asset" ]; then
				expected="Morphe Desktop: $(basename "$asset")"
				if ! grep -qF "$expected" build.md; then
					pr "New Morphe Desktop release detected for ${morphe_source}" >&2
					cat "${CONFIG_FILE:-config.toml}"
					return 0
				fi
			fi
		fi

		patches_source=$(toml_get "$t" patches-source) || patches_source="$DEF_PATCHES_SRC"
		patches_version=$(toml_get "$t" patches-version) || patches_version="$DEF_PATCHES_VER"
		source_key="${patches_source}/${patches_version}"
		[ -n "${seen_patches[$source_key]+x}" ] && continue
		seen_patches[$source_key]=1
		asset=$(get_release_asset "$patches_source" "$patches_version" ".mpp" "Morphe patches" 2>/dev/null) || continue
		expected="Morphe Patches: ${patches_source}/$(basename "$asset")"
		if ! grep -qF "$expected" build.md; then
			pr "New Morphe patch release detected for ${patches_source}" >&2
			# Returning the original config is enough to signal the scheduled CI
			# workflow. It also preserves comments and disabled app tables.
			cat "${CONFIG_FILE:-config.toml}"
			return 0
		fi
	done < <(toml_get_table_names)
}
