#!/usr/bin/env bash

# First-run helper for Termux.  It keeps the builder checkout and its output in
# ~/storage/downloads so APKs/modules are easy to install from Android.
set -euo pipefail

PROJECT_NAME="morphe-module-builder"
REPO_URL="https://github.com/iamsmmh/${PROJECT_NAME}.git"
DOWNLOAD_DIR="$HOME/storage/downloads/${PROJECT_NAME}"
CHECK_FILE="$HOME/.${PROJECT_NAME}-$(date '+%Y%m')"

pr() { echo -e "\033[0;32m[+] ${1-}\033[0m"; }
ask() {
	local answer
	for _ in 1 2 3; do
		pr "${1-} [y/n]"
		if read -r answer; then
			case "$answer" in
				y|Y) return 0 ;;
				n|N) return 1 ;;
			esac
		fi
		pr "Please answer y or n."
	done
	return 1
}

command -v termux-setup-storage >/dev/null 2>&1 || {
	echo "Run this script inside Termux." >&2
	exit 1
}

pr "Requesting shared-storage permission"
yes | termux-setup-storage >/dev/null 2>&1 || true
until [ -d "$HOME/storage/downloads" ]; do sleep 1; done

if [ ! -f "$CHECK_FILE" ]; then
	pr "Installing Termux dependencies"
	pkg update -y
	pkg install -y git jq wget openssl openjdk-21 zip unzip
	: >"$CHECK_FILE"
fi
mkdir -p "$HOME/storage/downloads"

if [ ! -d "$HOME/${PROJECT_NAME}/.git" ]; then
	pr "Cloning ${PROJECT_NAME}"
	git clone --depth 1 "$REPO_URL" "$HOME/${PROJECT_NAME}"
else
	cd "$HOME/${PROJECT_NAME}"
	pr "Checking for ${PROJECT_NAME} updates"
	git pull --ff-only || pr "Local changes prevented an update; keeping the current checkout."
fi
cd "$HOME/${PROJECT_NAME}"

mkdir -p "$DOWNLOAD_DIR"
if [ ! -f "$DOWNLOAD_DIR/config.toml" ]; then
	cp config.toml "$DOWNLOAD_DIR/config.toml"
fi

if ask "Open config.toml before building?"; then
	am start -a android.intent.action.VIEW \
		-d "file://${DOWNLOAD_DIR}/config.toml" -t text/plain >/dev/null 2>&1 || true
	pr "Edit ${DOWNLOAD_DIR}/config.toml, then press Enter to continue."
	read -r
fi
cp -f "$DOWNLOAD_DIR/config.toml" config.toml

if ! ask "Start the Morphe build now?"; then
	pr "Configuration saved. Run ./build.sh when you are ready."
	exit 0
fi

./build.sh config.toml

for output in build/*; do
	[ -f "$output" ] || continue
	cp -f "$output" "$DOWNLOAD_DIR/$(basename "$output")"
done
cp -f build.md "$DOWNLOAD_DIR/build.md"

pr "Outputs are available in ${DOWNLOAD_DIR}"
am start -a android.intent.action.VIEW \
	-d "file://${DOWNLOAD_DIR}" -t resource/folder >/dev/null 2>&1 || true
