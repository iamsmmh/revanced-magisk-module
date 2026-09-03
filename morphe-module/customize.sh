# shellcheck shell=sh

. "$MODPATH/config"

MORPHE_APK_DIR=/data/adb/morphe
MORPHE_APK_PATH="$MORPHE_APK_DIR/${MODPATH##*/}.apk"

ui_print ""
ui_print "Morphe Module Builder"

if [ -n "${MODULE_ARCH-}" ] && [ "$MODULE_ARCH" != "$ARCH" ]; then
	abort "ERROR: Wrong architecture
Your device: $ARCH
Module: $MODULE_ARCH"
fi

case "$ARCH" in
	arm) ARCH_LIB=armeabi-v7a ;;
	arm64) ARCH_LIB=arm64-v8a ;;
	x86) ARCH_LIB=x86 ;;
	x64) ARCH_LIB=x86_64 ;;
	*) abort "ERROR: unsupported device architecture: $ARCH" ;;
esac

# A Magisk -M namespace keeps the package mount visible to Android's package
# manager. KernelSU devices generally use the init namespace through nsenter.
if su -M -c true >/dev/null 2>&1; then
	root_cmd() { su -M -c "$*"; }
else
	root_cmd() { nsenter -t 1 -m "$@"; }
fi

set_perm_recursive "$MODPATH/bin" 0 0 0755 0777

pmex() {
	local output ret
	output=$(pm "$@" 2>&1 </dev/null)
	ret=$?
	echo "$output"
	return $ret
}

package_path() {
	pm path "$PKG_NAME" 2>/dev/null | sed -n '1p'
}

# Remove a previous bind mount before asking Package Manager to inspect or
# update the application.
root_cmd grep -F "$PKG_NAME" /proc/mounts 2>/dev/null | while read -r line; do
	mountpoint=${line#* }
	mountpoint=${mountpoint%% *}
	[ -n "$mountpoint" ] && root_cmd umount -l "${mountpoint%%\\*}" >/dev/null 2>&1 || true
done
am force-stop "$PKG_NAME" >/dev/null 2>&1 || true

BASEPATH=""
if ! pmex path "$PKG_NAME" >/dev/null 2>&1; then
	if pmex install-existing "$PKG_NAME" >/dev/null 2>&1; then
			BASEPATH=$(package_path)
			[ -n "$BASEPATH" ] || abort "ERROR: pm path failed"
			BASEPATH=${BASEPATH##*:}
		BASEPATH=${BASEPATH%/*}
		if [ "${BASEPATH:1:4}" = data ]; then
			if pmex uninstall -k --user 0 "$PKG_NAME" >/dev/null 2>&1; then
				rm -rf "$BASEPATH" 2>&1 || true
				ui_print "* Cleared the existing $PKG_NAME package"
				ui_print "* Reboot and reflash this module"
				abort
			else
				abort "ERROR: pm uninstall failed"
			fi
		else
			ui_print "* Installed stock $PKG_NAME package"
		fi
	fi
fi

IS_SYSTEM=false
INSTALL_STOCK=true
if BASEPATH=$(package_path) && [ -n "$BASEPATH" ]; then
	BASEPATH=${BASEPATH##*:}
	BASEPATH=${BASEPATH%/*}
	if [ "${BASEPATH:1:4}" != data ]; then
		ui_print "* $PKG_NAME is a system app"
		IS_SYSTEM=true
	elif [ ! -f "$MODPATH/$PKG_NAME.apk" ]; then
		ui_print "* Stock APK was not bundled; keeping the installed version"
		installed_version=$(dumpsys package "$PKG_NAME" | sed -n 's/.*versionName=//p' | head -n 1)
		if [ -z "$installed_version" ] || [ "$installed_version" = "$PKG_VER" ]; then
			INSTALL_STOCK=false
		else
			abort "ERROR: installed version differs
installed: $installed_version
module:    $PKG_VER
Set include-stock = true or install the matching original APK first."
		fi
	elif [ -x "$MODPATH/bin/$ARCH/cmpr" ] && "$MODPATH/bin/$ARCH/cmpr" "$BASEPATH/base.apk" "$MODPATH/$PKG_NAME.apk"; then
		ui_print "* Stock $PKG_NAME is already up to date"
		INSTALL_STOCK=false
	fi
fi

install_stock() {
	[ -f "$MODPATH/$PKG_NAME.apk" ] || abort "ERROR: bundled stock APK was not found"
	ui_print "* Installing original $PKG_NAME $PKG_VER"

	old_verifier=$(settings get global verifier_verify_adb_installs 2>/dev/null || echo 0)
	settings put global verifier_verify_adb_installs 0 >/dev/null 2>&1 || true
	apk_size=$(stat -c "%s" "$MODPATH/$PKG_NAME.apk")
	local session output
	for attempt in 1 2; do
		if ! session=$(pmex install-create --user 0 -i com.android.vending -r -d -S "$apk_size"); then
			settings put global verifier_verify_adb_installs "$old_verifier" >/dev/null 2>&1 || true
			abort "ERROR: install-create failed\n$session"
		fi
		session=${session#*[}
		session=${session%]*}
		set_perm "$MODPATH/$PKG_NAME.apk" 1000 1000 0644 u:object_r:apk_data_file:s0
		if ! output=$(pmex install-write -S "$apk_size" "$session" "$PKG_NAME.apk" "$MODPATH/$PKG_NAME.apk"); then
			settings put global verifier_verify_adb_installs "$old_verifier" >/dev/null 2>&1 || true
			abort "ERROR: install-write failed\n$output"
		fi
		if ! output=$(pmex install-commit "$session"); then
			if echo "$output" | grep -q INSTALL_FAILED_VERSION_DOWNGRADE; then
				if [ "$IS_SYSTEM" = true ]; then
					mkdir -p "$MORPHE_APK_DIR/empty" /data/adb/post-fs-data.d
					uninstall_script="/data/adb/post-fs-data.d/$PKG_NAME-uninstall.sh"
					echo "mount -o bind $MORPHE_APK_DIR/empty $BASEPATH" >"$uninstall_script"
					chmod 0755 "$uninstall_script"
					ui_print "* Created a one-time system-app cleanup"
					ui_print "* Reboot and reflash this module"
					settings put global verifier_verify_adb_installs "$old_verifier" >/dev/null 2>&1 || true
					abort
				fi
				ui_print "* Removing the older user APK and retrying"
				pmex uninstall -k --user 0 "$PKG_NAME" >/dev/null 2>&1 || true
				[ "$attempt" = 2 ] && abort "ERROR: pm uninstall failed\n$output"
				continue
			fi
			settings put global verifier_verify_adb_installs "$old_verifier" >/dev/null 2>&1 || true
			abort "ERROR: install-commit failed\n$output"
		fi
		break
	done
	settings put global verifier_verify_adb_installs "$old_verifier" >/dev/null 2>&1 || true
}

if [ "$INSTALL_STOCK" = true ]; then install_stock; fi

BASEPATH=$(package_path)
[ -n "$BASEPATH" ] || abort "ERROR: $PKG_NAME is not installed"
BASEPATH=${BASEPATH##*:}
BASEPATH=${BASEPATH%/*}

ui_print "* Extracting native libraries"
BASEPATHLIB="$BASEPATH/lib/$ARCH"
mkdir -p "$BASEPATHLIB"
rm -f "$BASEPATHLIB"/* 2>/dev/null || true
if unzip -l "$MODPATH/$PKG_NAME.apk" "lib/$ARCH_LIB/*" 2>/dev/null | grep -q "lib/$ARCH_LIB/"; then
	if ! output=$(unzip -jo "$MODPATH/$PKG_NAME.apk" "lib/$ARCH_LIB/*" -d "$BASEPATHLIB" 2>&1); then
		ui_print "ERROR: extracting native libraries failed"
		abort "$output"
	fi
else
	ui_print "* No native libraries for $ARCH_LIB"
fi
set_perm_recursive "$BASEPATH/lib" 1000 1000 0755 0755 u:object_r:apk_data_file:s0

ui_print "* Mounting patched APK"
mkdir -p "$MORPHE_APK_DIR"
set_perm "$MODPATH/base.apk" 1000 1000 0644 u:object_r:apk_data_file:s0
mv -f "$MODPATH/base.apk" "$MORPHE_APK_PATH"
if ! output=$(root_cmd mount -o bind "$MORPHE_APK_PATH" "$BASEPATH/base.apk" 2>&1); then
	ui_print "WARNING: bind mount failed"
	ui_print "$output"
else
	ui_print "* Mounted Morphe build over $PKG_NAME"
fi

am force-stop "$PKG_NAME" >/dev/null 2>&1 || true
ui_print "* Optimizing $PKG_NAME"
nohup cmd package compile --reset "$PKG_NAME" >/dev/null 2>&1 &

rm -rf "${MODPATH:?}/bin" "$MODPATH/$PKG_NAME.apk"
if [ -n "${KSU-}" ] && [ -d /data/adb/modules/zygisk-assistant ]; then
	ui_print "* Grant root access to $PKG_NAME in zygisk-assistant"
fi

ui_print "* Morphe module installed"
ui_print "  Built by Morphe Module Builder"
ui_print "  No reboot is required for this app"
