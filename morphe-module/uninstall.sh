#!/system/bin/sh

# Remove the private patched artifact and any one-time cleanup hook. Android's
# original app/data remain untouched because the module only uses bind mounts.
{
	MODDIR=${0%/*}
	MORPHE_APK_DIR=/data/adb/morphe
	. "$MODDIR/config"

	rm -f "$MORPHE_APK_DIR/${MODDIR##*/}.apk"
	rmdir "$MORPHE_APK_DIR" 2>/dev/null || true
	rm -f "/data/adb/post-fs-data.d/$PKG_NAME-uninstall.sh"
} &
