#!/system/bin/sh
# Re-apply the bind mount after Android finishes booting.  The APK stays in a
# private root-owned directory so removing/updating the module never touches
# the user's original application data.

MODDIR=${0%/*}
MORPHE_APK_DIR=/data/adb/morphe
MORPHE_APK_PATH="$MORPHE_APK_DIR/${MODDIR##*/}.apk"

. "$MODDIR/config"

mark_error() {
	[ -f "$MODDIR/err" ] || cp -f "$MODDIR/module.prop" "$MODDIR/err"
	sed -i "s/^description=.*/description=Needs reflash: ${1}/" "$MODDIR/module.prop"
}

until [ "$(getprop sys.boot_completed)" = 1 ]; do sleep 1; done

run() {
	local status base version mount_line mountpoint
	base=$(pm path "$PKG_NAME" 2>/dev/null | head -n 1)
	status=$?
	if [ "$status" != 0 ] || [ -z "$base" ]; then
		mark_error "app not installed"
		return
	fi

	base=${base##*:}
	base=${base%/*}
	version=$(dumpsys package "$PKG_NAME" 2>/dev/null | sed -n 's/.*versionName=//p' | head -n 1)
	if [ -n "$version" ] && [ "$version" != "$PKG_VER" ]; then
		mark_error "version mismatch installed:${version}, module:${PKG_VER}"
		return
	fi
	if [ ! -f "$MORPHE_APK_PATH" ]; then
		mark_error "patched APK is missing"
		return
	fi

	# Drop stale mounts created by an older module version before binding the
	# current artifact. The service already runs in the root namespace.
	grep "$PKG_NAME" /proc/mounts 2>/dev/null | while read -r mount_line; do
		mountpoint=${mount_line#* }
		mountpoint=${mountpoint%% *}
		[ -n "$mountpoint" ] && umount -l "${mountpoint%%\\*}" >/dev/null 2>&1 || true
	done

	if ! chcon u:object_r:apk_data_file:s0 "$MORPHE_APK_PATH" 2>/dev/null; then
		mark_error "could not label patched APK"
		return
	fi
	if ! mount -o bind "$MORPHE_APK_PATH" "$base/base.apk"; then
		mark_error "could not mount patched APK"
		return
	fi

	[ -f "$MODDIR/err" ] && mv -f "$MODDIR/err" "$MODDIR/module.prop"
	am force-stop "$PKG_NAME" >/dev/null 2>&1 || true
}

run
