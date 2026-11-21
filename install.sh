#!/bin/sh
# SmartDNS Manager clean installer. SPDX-License-Identifier: MIT
set -eu
PATH=/opt/sbin:/opt/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH
VERSION=0.6.0
REPO=shurshick/SmartDNS_Manager
action=install
case "${1:-}" in
 --check) action=check; shift;;
 --uninstall) action=uninstall; shift;;
 --help|-h) echo 'sh install.sh [--check|--uninstall] [LAN_IPV4]; SDM_LAN_IP selects the Keenetic LAN address'; exit 0;;
esac
die() { echo "SmartDNS Manager: $*" >&2; exit 1; }
[ "$#" -le 1 ] || die 'укажите одно действие и необязательный LAN IPv4'
case "${1:-}" in -*) die 'неизвестное действие; используйте --help';; esac
if [ -f /etc/openwrt_release ]; then
 platform=openwrt; runtime=/usr/sbin/smartdns-manager; owner=/etc/smartdns-manager-install/owner.json
elif [ -f /opt/etc/init.d/rc.func ]; then
 platform=keenetic; runtime=/opt/sbin/smartdns-manager; owner=/opt/var/lib/smartdns-manager-install/owner.json
else die 'нужен OpenWrt или Keenetic / Netcraze с установленным Entware'; fi
if [ "$action" = uninstall ]; then
 [ "$(id -u)" = 0 ] || die 'запустите от root'
 [ -f "$owner" ] && [ -x "$runtime" ] || die 'установленный менеджер не найден'
 exec "$runtime" uninstall --yes
fi
if [ "$action" = install ]; then
 [ "$(id -u)" = 0 ] || die 'запустите от root'
 [ ! -e "$owner" ] && [ ! -e "$runtime" ] || die 'менеджер уже установлен; сначала выполните полное удаление (настройки будут удалены)'
fi
for cmd in awk uname curl sha256sum tar mktemp df; do command -v "$cmd" >/dev/null 2>&1 || die "нужна команда $cmd"; done
case "$(uname -m)" in
 aarch64|arm64) arch=arm64;;
 armv7l|armv7*) arch=armv7;;
 x86_64|amd64) arch=amd64;;
 mips|mipsel|mipsle)
  for cmd in od dd tr; do command -v "$cmd" >/dev/null 2>&1 || die "нужна команда $cmd"; done
  endian=$(dd if=/bin/sh bs=1 skip=5 count=1 2>/dev/null | od -An -tu1 | tr -d ' \n')
  case "$endian" in 1) arch=mipsle;; 2) arch=mips;; *) die 'не определён порядок байтов MIPS';; esac;;
 *) die 'процессор не поддерживается';;
esac
expected=$(case "$platform-$arch" in
 keenetic-arm64) echo '51558a18ea826a047a6d237dcc48a9207322fb402e818ba213c2c9adf8725d3f';;
 keenetic-mips) echo '722621e94b918491aa1675d230a5c0605676c9a20b2e32270b9770d40cd916c8';;
 keenetic-mipsle) echo 'c0c3cb9ff5e66ce0f4dbc7c0c2f156dc0b146d7f9de4f6613ca6fb1cdaef8c87';;
 openwrt-amd64) echo '9f8eb9ee79ece0fe4925f444a5632f82418a31a9209d94cc60c5bf1111f61dca';;
 openwrt-arm64) echo '87b1408aeca9ea8ca2eeeb2b31c9ac5c6fd301b62cc804c067de1e799cd90f18';;
 openwrt-armv7) echo 'c09446d27d198642083b5013d6903436abf25e80db524691b5038036274113e0';;
 openwrt-mips) echo 'f78640df15704794c453696566318fe5d23bd80f925fec0485e71fb88e8d87c9';;
 openwrt-mipsle) echo 'd9fcf3c8537a88484a5844a3db432e56106c0163f044ace451d1ecefec22d47c';;
 *) die 'для этой платформы и архитектуры нет пакета';;
esac)
lan=${SDM_LAN_IP:-${1:-}}
if [ "$platform" = keenetic ] && [ "$action" = install ]; then
 if [ -z "$lan" ] && command -v ip >/dev/null 2>&1; then
  for dev in br0 br-lan; do
   lan=$(ip -4 addr show dev "$dev" 2>/dev/null | awk '$1=="inet" {split($2,a,"/"); print a[1]; exit}')
   [ -z "$lan" ] || break
  done
 fi
 printf '%s\n' "$lan" | awk -F. 'NF!=4{exit 1} {for(i=1;i<=4;i++)if($i!~/^[0-9]+$/||$i>255)exit 1; if($1==0||$1==127)exit 1}' || die 'не определён LAN IPv4; укажите SDM_LAN_IP=192.168.1.1 перед sh'
elif [ "$platform" = openwrt ]; then
 [ "$#" = 0 ] || die 'для OpenWrt LAN IPv4 не нужен'
fi
free_tmp=$(df -Pk /tmp | awk 'NR==2{print $4}')
case "$free_tmp" in ''|*[!0-9]*) die 'не удалось проверить свободное место в /tmp';; esac
[ "$free_tmp" -ge 8192 ] || die 'нужно не менее 8 МиБ свободного места в /tmp'
temp=$(mktemp -d /tmp/smartdns-online.XXXXXX) || exit 1
trap 'rm -rf -- "$temp"' EXIT
trap 'exit 1' HUP INT TERM
name=smartdns-manager-v$VERSION-$platform-$arch.tar.gz
echo "SmartDNS Manager $VERSION: $platform / $arch"
# Existing DNS stays active throughout download and verification.
url=https://github.com/$REPO/releases/download/v$VERSION/$name
curl --proto '=https' --proto-redir '=https' -fLsS --connect-timeout 15 --max-time 180 --retry 2 "$url" -o "$temp/package.tar.gz" || die 'пакет не скачан; проверьте интернет, время и доступ к GitHub'
actual=$(sha256sum "$temp/package.tar.gz" | awk '{print $1}')
[ "$actual" = "$expected" ] || die 'контрольная сумма не совпала; установка не начата'
mkdir "$temp/package"
tar -xzf "$temp/package.tar.gz" -C "$temp/package" || die 'пакет не распакован'
(cd "$temp/package" && sha256sum -c SHA256SUMS >/dev/null) || die 'внутренние файлы повреждены'
[ "$(cat "$temp/package/platform.txt")" = "$platform $arch" ] || die 'неверная платформа пакета'
[ "$("$temp/package/bin/smartdns-manager" -version)" = "SmartDNS Manager $VERSION" ] || die 'неверная версия или ABI'
if [ "$action" = check ]; then echo 'Пакет проверен. Службы и настройки не изменялись.'; exit 0; fi
if [ "$platform" = keenetic ]; then
 sh "$temp/package/install.sh" --lan-ip "$lan"
else
 sh "$temp/package/install.sh"
fi
[ "$("$runtime" -version)" = "SmartDNS Manager $VERSION" ] || die 'версия установленного файла не совпадает с пакетом'
echo "Установлен SmartDNS Manager $VERSION"
