#!/bin/bash
set -e

VERSION="${1:?usage: bash build.sh VERSION}"
PKG_NAME="luci-app-sdutlogin"

echo "=== Building $PKG_NAME version $VERSION ==="

# 准备 data 目录（安装后的文件树）
rm -rf data control apk-control *.tar.gz debian-binary
mkdir -p data/etc/config
mkdir -p data/etc/init.d
mkdir -p data/etc/hotplug.d/iface
mkdir -p data/usr/lib/lua/luci/model/cbi
mkdir -p data/usr/lib/lua/luci/controller
mkdir -p data/usr/lib/sdutlogin

cp files/root/etc/config/sdutlogin data/etc/config/
cp files/root/etc/init.d/sdutlogin data/etc/init.d/
chmod 755 data/etc/init.d/sdutlogin
cp files/root/etc/hotplug.d/iface/100-sdutlogin data/etc/hotplug.d/iface/
chmod 755 data/etc/hotplug.d/iface/100-sdutlogin
cp login.sh data/usr/lib/sdutlogin/
chmod 755 data/usr/lib/sdutlogin/login.sh
cp aes.lua data/usr/lib/sdutlogin/
cp files/root/usr/lib/lua/luci/controller/sdutlogin.lua data/usr/lib/lua/luci/controller/
cp files/root/usr/lib/lua/luci/model/cbi/sdutlogin.lua data/usr/lib/lua/luci/model/cbi/
cp files/root/usr/lib/lua/luci/model/cbi/sdutloginlog.lua data/usr/lib/lua/luci/model/cbi/

# ===== ipk (OpenWrt 23.05 及更早) =====
echo "--- Building ipk ---"
tar czf data.tar.gz -C data .

mkdir -p control
cat > control/control << EOF
Package: $PKG_NAME
Version: $VERSION
Architecture: all
Maintainer: sggc <sggc@users.noreply.github.com>
Section: luci
Priority: optional
Depends: +openssl-util
Source: https://github.com/sggc/luci-app-sdutlogin
Description: SDUT campus network auto login (AES encrypted portal protocol)
EOF
echo "/etc/config/sdutlogin" > control/conffiles
cat > control/postinst << 'EOF'
#!/bin/sh
[ -x /etc/init.d/sdutlogin ] && /etc/init.d/sdutlogin enable
exit 0
EOF
chmod 755 control/postinst
tar czf control.tar.gz -C control .

echo "2.0" > debian-binary
ar rc ${PKG_NAME}_${VERSION}_all.ipk debian-binary control.tar.gz data.tar.gz
echo "Created ${PKG_NAME}_${VERSION}_all.ipk"

# ===== apk (OpenWrt 24.10+) =====
echo "--- Building apk ---"
PKGVER=$(echo "$VERSION" | sed 's/-/-r/')
mkdir -p apk-control
DATASIZE=$(du -sb data | cut -f1)
cat > apk-control/.PKGINFO << EOF
pkgname = $PKG_NAME
pkgver = $PKGVER
pkgdesc = SDUT campus network auto login
url = https://github.com/sggc/luci-app-sdutlogin
builddate = $(date +%s)
packager = sggc
size = $DATASIZE
arch = all
origin = $PKG_NAME
maintainer = sggc <sggc@users.noreply.github.com>
depend = openssl-util
EOF
cat > apk-control/.post-install << 'EOF'
#!/bin/sh
[ -x /etc/init.d/sdutlogin ] && /etc/init.d/sdutlogin enable
exit 0
EOF
tar cz -C apk-control .PKGINFO .post-install > apk-control.tar.gz
tar cz -C data etc usr > apk-data.tar.gz
cat apk-control.tar.gz apk-data.tar.gz > ${PKG_NAME}-${PKGVER}.apk
echo "Created ${PKG_NAME}-${PKGVER}.apk"

# 清理中间文件
rm -rf data control apk-control *.tar.gz debian-binary

echo "=== Done ==="
ls -lh *.ipk *.apk