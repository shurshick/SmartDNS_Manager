#!/bin/sh
# SmartDNS Manager installer. SPDX-License-Identifier: MIT
set -eu
PATH=/opt/sbin:/opt/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH
VERSION=0.6.9
REPO=shurshick/SmartDNS_Manager
action=install
case "${1:-}" in
 --check) action=check; shift;;
 --update) action=update; shift;;
 --uninstall) action=uninstall; shift;;
 --help|-h) echo 'sh install.sh [--check|--update|--uninstall] [LAN_IPV4]; SDM_LAN_IP selects the Keenetic LAN address'; exit 0;;
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
 if [ "$platform" = keenetic ]; then
  lan=${SDM_LAN_IP:-${1:-}}
  if [ -z "$lan" ]; then
   for config in /opt/etc/smartdns.conf /opt/etc/doqd.conf; do
    [ -f "$config" ] || continue
    lan=$(awk '$1=="listen" {split($2,a,":"); print a[1]; exit}' "$config")
    [ -z "$lan" ] || break
   done
  fi
  printf '%s\n' "$lan" | awk -F. 'NF!=4{exit 1} {for(i=1;i<=4;i++)if($i!~/^[0-9]+$/||$i>255)exit 1; if($1==0||$1==127)exit 1}' || die 'для удаления укажите SDM_LAN_IP с LAN IPv4 роутера'
  exec "$runtime" uninstall --platform keenetic --lan-ip "$lan" --yes
 fi
 exec "$runtime" uninstall --yes
fi
if [ "$action" = install ]; then
 [ "$(id -u)" = 0 ] || die 'запустите от root'
 [ ! -e "$owner" ] && [ ! -e "$runtime" ] || die 'менеджер уже установлен; для обновления используйте --update'
fi
if [ "$action" = update ]; then
 [ "$#" = 0 ] || die 'обновление использует текущий LAN IPv4'
 [ "$(id -u)" = 0 ] || die 'запустите от root'
 [ -f "$owner" ] && [ -x "$runtime" ] || die 'установленный менеджер не найден'
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
 keenetic-arm64) echo '45018a499eb7b15480bc831073543a123e9dafed8310379659d1590abb56c1c5';;
 keenetic-mips) echo 'bc2d7be9b0530bc930972e53f82bab93e2ab2d806fdec0dd1fa6ce1b29025af8';;
 keenetic-mipsle) echo 'ba6d327ced33254dd20316ea22cfbc72187a134b71e1418a2e16f4db75d51cff';;
 openwrt-amd64) echo '0b2384081c29c95100803239d5a1db06a971b9e25da49ee0ad98f29885f60e21';;
 openwrt-arm64) echo '692c448836e5832caa8af05aa79c26adff329b8fd4385b208d58fa84efc94d50';;
 openwrt-armv7) echo 'f925bb2944cbcbf1e15eff79da395761bbfe78ef16b9bb17cc814511b6d4a5f3';;
 openwrt-mips) echo '0befdab8922b73d3ed262003fc1e43d86342b6a62e2cdccd8d0915579087473d';;
 openwrt-mipsle) echo 'd5bf8a5ae9ee7af2a3df65a235a0de841b808053b7987d0aaa71771130013a92';;
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
if [ "$action" = update ]; then
 sh "$temp/package/install.sh" --update
elif [ "$platform" = keenetic ]; then
 sh "$temp/package/install.sh" --lan-ip "$lan"
else
 sh "$temp/package/install.sh"
fi
[ "$("$runtime" -version)" = "SmartDNS Manager $VERSION" ] || die 'версия установленного файла не совпадает с пакетом'
echo "Установлен SmartDNS Manager $VERSION"
