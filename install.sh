#!/bin/sh
# SmartDNS Manager public bootstrap. SPDX-License-Identifier: MIT
set -eu
PATH=/opt/sbin:/opt/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH
VERSION=0.5.3
REPO=shurshick/SmartDNS_Manager
check=0
action=install
replace_dns=${SDM_REPLACE_DNS:-}
case "${1:-}" in
 --check) check=1; shift;;
 --update) action=update; shift;;
 --uninstall) action=uninstall; shift;;
 --help|-h) echo 'sh install.sh [--check|--update|--uninstall] [LAN_IPV4]; SDM_LAN_IP overrides LAN detection; SDM_REPLACE_DNS=auto (or IPv4) replaces manual DNS on clean Keenetic installation'; exit 0;;
esac
[ "$#" -le 1 ] || { echo 'Укажите одно действие и необязательный LAN IPv4' >&2; exit 2; }
die() { echo "SmartDNS Manager: $*" >&2; exit 1; }
case "${1:-}" in -*) die 'неизвестное действие; используйте --help';; esac
for cmd in awk uname; do command -v "$cmd" >/dev/null 2>&1 || die "нужна команда $cmd"; done
if [ -f /etc/openwrt_release ]; then platform=openwrt
elif [ -f /opt/etc/init.d/rc.func ]; then platform=keenetic
else die 'нужен OpenWrt или Keenetic/Netcraze с уже установленным Entware'; fi
if [ -n "$replace_dns" ]; then
 [ "$platform" = keenetic ] && [ "$action" = install ] && [ "$check" = 0 ] ||
  die 'SDM_REPLACE_DNS поддерживается только при чистой установке на Keenetic'
 if [ "$replace_dns" != auto ]; then
  case "$replace_dns" in *[!0-9.]*) die 'SDM_REPLACE_DNS должен быть auto или IPv4-адресом';; esac
  printf '%s\n' "$replace_dns" | awk -F. 'NF!=4{exit 1} {for(i=1;i<=4;i++)if($i!~/^(0|[1-9][0-9]?[0-9]?)$/||$i>255)exit 1}' ||
   die 'SDM_REPLACE_DNS должен быть auto или IPv4-адресом'
 fi
fi
if [ "$platform" = keenetic ]; then
 owner=/opt/var/lib/smartdns-manager-install/owner.json
 runtime=/opt/sbin/smartdns-manager
else
 owner=/etc/smartdns-manager-install/owner.json
 runtime=/usr/sbin/smartdns-manager
fi
if [ -n "$replace_dns" ] && [ -f "$owner" ]; then
 die 'менеджер уже установлен; для обновления используйте --update без SDM_REPLACE_DNS'
fi
resolve_lan() {
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
}
if [ "$action" = uninstall ]; then
 [ "$(id -u)" = 0 ] || die 'запустите удаление от root'
 [ -f "$owner" ] && [ -x "$runtime" ] || die 'собственный установленный менеджер не найден'
 echo 'Полное удаление SmartDNS Manager: службы, бинарник, конфиг, HOSTS, кэши и резервные копии менеджера.'
 if [ "$platform" = keenetic ]; then
  resolve_lan "$@"
  exec "$runtime" uninstall --platform keenetic --lan-ip "$lan" --yes
 else
  [ "$#" = 0 ] || die 'для OpenWrt LAN IPv4 не нужен'
  exec "$runtime" uninstall --platform openwrt --yes
 fi
fi
if [ "$action" = update ]; then
 [ -f "$owner" ] || die 'установка не найдена: для чистой установки запустите без --update'
fi
for cmd in curl sha256sum tar mktemp; do command -v "$cmd" >/dev/null 2>&1 || die "нужна команда $cmd"; done
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
 keenetic-arm64) echo '9ff18c6f3ba40e75ea021e63496a3d70f661957b9d9f8fc5ef4ac59bed020c82';;
 keenetic-mips) echo '58ba9a7a5d22d6882d415445bb5602f5a9a3a44e042d0e69469fa5428fca446f';;
 keenetic-mipsle) echo 'dccb039f3c7c204102e6834efc8445489c5b8b5f0c693b8b7840fedafbfce4b4';;
 openwrt-amd64) echo '030be808ebb449039dfe3aaa3180e5425dec6ec960bbf4428359db19d9eaccb3';;
 openwrt-arm64) echo 'f215a2e03fb20dbc3c60ef1926fdedd542eb4e3e9c31678709144c81ecfddffe';;
 openwrt-armv7) echo '524f73db4d1c536819eb7d8967b32493d8d61548dc51691bb5ccf9bf87b15a9f';;
 openwrt-mips) echo 'ad1a98fea1a69b0c3e93af2d9e95e44ff51a50525ef14b4b2caedfe68e06654f';;
 openwrt-mipsle) echo 'f7e2530143ead15f9f2a7a67b77399c65701f557a0b3fe4c8fc744bb8e38b6a7';;
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
 resolve_lan "$@"
 if [ -n "$replace_dns" ]; then
  sh "$temp/package/install.sh" --lan-ip "$lan" --remove-temporary-dns "$replace_dns"
 else
  sh "$temp/package/install.sh" --lan-ip "$lan" ||
   die 'установка не завершена; при конфликте с ручным DNS см. SDM_REPLACE_DNS в README'
 fi
 echo "Панель: http://$lan:8092/"
else
 [ "$#" = 0 ] || die 'для OpenWrt LAN IPv4 указывать не нужно'
 sh "$temp/package/install.sh"
 echo 'Панель: http://LAN_IP_РОУТЕРА:8092/'
fi
installed=$("$runtime" -version) || die 'не удалось проверить установленный бинарник'
[ "$installed" = "SmartDNS Manager $VERSION" ] || die "установленная версия не совпадает с пакетом: $installed"
echo "Установлено: $installed"
