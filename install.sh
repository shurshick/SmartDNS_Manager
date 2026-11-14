#!/bin/sh
# SmartDNS Manager public bootstrap. SPDX-License-Identifier: GPL-3.0-or-later
set -eu
PATH=/opt/sbin:/opt/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH
VERSION=0.3.2
REPO=shurshick/SmartDNS_Manager
check=0
case "${1:-}" in --check) check=1; shift;; --help|-h) echo 'sh install.sh [--check] [LAN_IPV4]; SDM_LAN_IP overrides LAN detection'; exit 0;; esac
[ "$#" -le 1 ] || { echo 'Укажите только LAN IPv4 или --check' >&2; exit 2; }
die() { echo "SmartDNS Manager: $*" >&2; exit 1; }
for cmd in curl sha256sum tar mktemp awk uname; do command -v "$cmd" >/dev/null 2>&1 || die "нужна команда $cmd"; done
if [ -f /etc/openwrt_release ]; then platform=openwrt
elif [ -f /opt/etc/init.d/rc.func ]; then platform=keenetic
else die 'нужен OpenWrt или Keenetic/Netcraze с уже установленным Entware'; fi
case "$(uname -m)" in
 aarch64|arm64) arch=arm64;;
 armv7l|armv7*) arch=armv7;;
 x86_64|amd64) arch=amd64;;
 mips|mipsel|mipsle)
  command -v od >/dev/null 2>&1 || die 'нужна команда od'
  endian=$(dd if=/bin/sh bs=1 skip=5 count=1 2>/dev/null | od -An -tu1 | tr -d ' \n')
  case "$endian" in 1) arch=mipsle;; 2) arch=mips;; *) die 'не определён порядок байтов MIPS';; esac;;
 *) die 'процессор не поддерживается';;
esac
name=smartdns-manager-v$VERSION-$platform-$arch.tar.gz
# Checksums are pinned in this installer, not trusted from an unchecked package.
expected=$(case "$platform-$arch" in
 keenetic-arm64) echo 'b0ac51cfb76f650ac177ccc48d6e28457a19f4bf9d8889b5efdcffdcdd100603';;
 keenetic-mips) echo '8f7a10b9d5efb6b6be3dd11d107cd64778c27e5d5d7904661f41bf1184b6de67';;
 keenetic-mipsle) echo '69dddc2eefdf49452eebcb9f8e1f3fd6f2807f2e395828fb88a8569099855f7e';;
 openwrt-amd64) echo '0cd5dc638e89f81770261507f8e0c66ec5818a6dca800479ff61c9e44facc94c';;
 openwrt-arm64) echo '93a3269f02c3e15db98079641cf7d851cb91817b4f9c53f8976f693694341946';;
 openwrt-armv7) echo '8ac5c07da83791d29053127491e10fe5cc415138f99fa8717e21fa9195a3c990';;
 openwrt-mips) echo '843a6ef45bc081ae0b518e959ef66f5642116a53a5f59191a7fd4ece6c2928ad';;
 openwrt-mipsle) echo '3d37cea579155c7cbd6db1f1618e73d73f4056e088099af05bd1860c8b8ae333';;
 *) die 'для этой платформы и архитектуры нет сборки';;
esac)
temp=$(mktemp -d /tmp/smartdns-online.XXXXXX) || exit 1
trap 'rm -rf -- "$temp"' EXIT
trap 'exit 1' HUP INT TERM
url=https://github.com/$REPO/releases/download/v$VERSION/$name
echo "SmartDNS Manager $VERSION: $platform / $arch"
curl --proto '=https' --proto-redir '=https' -fLsS --connect-timeout 15 --max-time 180 --retry 2 "$url" -o "$temp/package.tar.gz" || die 'выпуск не скачан; проверьте интернет, время и доступ к GitHub'
actual=$(sha256sum "$temp/package.tar.gz" | awk '{print $1}')
[ "$actual" = "$expected" ] || die 'контрольная сумма не совпала, установка не начата'
mkdir "$temp/package"
tar -xzf "$temp/package.tar.gz" -C "$temp/package" || die 'не распакован пакет'
(cd "$temp/package" && sha256sum -c SHA256SUMS >/dev/null) || die 'внутренние файлы повреждены'
[ "$(cat "$temp/package/platform.txt")" = "$platform $arch" ] || die 'неверная платформа пакета'
[ "$("$temp/package/bin/smartdns-manager" -version)" = "SmartDNS Manager $VERSION" ] || die 'неверная версия или ABI'
if [ "$check" = 1 ]; then echo 'Пакет проверен. Службы и настройки не изменялись.'; exit 0; fi
[ "$(id -u)" = 0 ] || die 'запустите установку от root'
if [ "$platform" = keenetic ]; then
 lan=${SDM_LAN_IP:-${1:-}}
 if [ -z "$lan" ] && [ -f /opt/var/lib/smartdns-manager-install/owner.json ]; then
  lan=$(awk '$1=="listen" {split($2,a,":"); print a[1]; exit}' /opt/etc/doqd.conf)
 fi
 if [ -z "$lan" ] && command -v ip >/dev/null 2>&1; then
  for dev in br0 br-lan; do
   lan=$(ip -4 addr show dev "$dev" 2>/dev/null | awk '$1=="inet" {split($2,a,"/"); print a[1]; exit}')
   [ -z "$lan" ] || break
  done
 fi
 echo "$lan" | awk -F. 'NF!=4{exit 1} {for(i=1;i<=4;i++)if($i!~/^[0-9]+$/||$i>255)exit 1; if($1==0||$1==127)exit 1}' || die 'не определён LAN IPv4; повторите с SDM_LAN_IP=192.168.1.1 перед sh'
 sh "$temp/package/install.sh" --lan-ip "$lan"
 echo "Панель: http://$lan:8092/"
else
 [ "$#" = 0 ] || die 'для OpenWrt LAN IPv4 указывать не нужно'
 sh "$temp/package/install.sh"
 echo 'Панель: http://LAN_IP_РОУТЕРА:8092/'
fi
