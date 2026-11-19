#!/bin/sh
# SmartDNS Manager public bootstrap. SPDX-License-Identifier: MIT
set -eu
PATH=/opt/sbin:/opt/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH
VERSION=0.5.1
REPO=shurshick/SmartDNS_Manager
check=0
action=install
replace_dns=${SDM_REPLACE_DNS:-}
restore_dns=0
case "${1:-}" in
 --check) check=1; shift;;
 --update) action=update; shift;;
 --uninstall) action=uninstall; shift;;
 --help|-h) echo 'sh install.sh [--check|--update|--uninstall] [LAN_IPV4]; SDM_LAN_IP overrides LAN detection; SDM_REPLACE_DNS=IPv4 replaces a manual DNS on clean Keenetic installation'; exit 0;;
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
 case "$replace_dns" in *[!0-9.]*) die 'SDM_REPLACE_DNS должен быть IPv4-адресом';; esac
 printf '%s\n' "$replace_dns" | awk -F. 'NF!=4{exit 1} {for(i=1;i<=4;i++)if($i!~/^(0|[1-9][0-9]?[0-9]?)$/||$i>255)exit 1}' ||
  die 'SDM_REPLACE_DNS должен быть IPv4-адресом'
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
keenetic_cli() {
 output=$(/bin/ndmc -c "$1") || { printf '%s\n' "$output" >&2; return 1; }
 if printf '%s\n' "$output" | awk 'tolower($0) ~ /failed|error|not found/ {found=1} END{exit !found}'; then
  printf '%s\n' "$output" >&2
  return 1
 fi
 printf '%s\n' "$output"
}
manual_dns_present() {
 awk -v ip="$replace_dns" '
 function check() {if (address==ip && service=="Dns::Manager" && domain=="" && iface=="" && (port=="" || port=="53")) found=1}
 /^[[:space:]]*server:/ {check(); address=service=domain=iface=port=""}
 $1=="address:" {address=$2}
 $1=="port:" {port=$2}
 $1=="service:" {service=$2}
 $1=="domain:" {domain=$2}
 $1=="interface:" {iface=$2}
 END {check(); exit !found}'
}
cleanup() {
 rc=$?
 if [ "$restore_dns" = 1 ]; then
  if ! servers=$(keenetic_cli 'show ip name-server') || ! printf '%s\n' "$servers" | manual_dns_present; then
   if keenetic_cli "ip name-server $replace_dns" && keenetic_cli 'system configuration save'; then
    echo "Восстановлен исходный DNS: $replace_dns" >&2
   else
    echo "Не удалось восстановить $replace_dns. Верните запись через CLI Keenetic." >&2
   fi
  fi
 fi
 rm -rf -- "$temp"
 exit "$rc"
}
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
 keenetic-arm64) echo '9347cc9401fea3a1bfcca9a6c0a388862c519aadc3739bd3a1740e1d808dc122';;
 keenetic-mips) echo 'c8001578fd15f00495a9869b4958324f20120b869de82bcc28a875ebd1c22f7d';;
 keenetic-mipsle) echo 'c031b9d635bf8c25c29ae1e4713c3fad443bc59b6e563f2dfb59bc63b7812e52';;
 openwrt-amd64) echo 'ccc558d6d19fa43a6b76260e0f06044a1014e2ae8bdd6564388992fb326c31d1';;
 openwrt-arm64) echo 'c43c35fcc6c308aaad03d8f07be46a3ec0649e54039ca45d214d6548393c039d';;
 openwrt-armv7) echo '4d33b59d909c525b6aa03a9f6a1b6eec62f4436bea7daf0579f314bcfb226cd5';;
 openwrt-mips) echo '8a51d44e1d9018091dcd7658d2c29d2af7e1e5bfc255dfd2c5bd3e42d1651168';;
 openwrt-mipsle) echo '968326ef7ca58244adc6fa92687b3fbb45a25938801021187d54df879b657f67';;
 *) die 'для этой платформы и архитектуры нет сборки';;
esac)
temp=$(mktemp -d /tmp/smartdns-online.XXXXXX) || exit 1
trap cleanup EXIT
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
  servers=$(keenetic_cli 'show ip name-server') || die 'не удалось прочитать список DNS Keenetic'
  printf '%s\n' "$servers" | manual_dns_present ||
   die "$replace_dns не найден среди глобальных ручных DNS Keenetic"
  restore_dns=1
  sh "$temp/package/install.sh" --lan-ip "$lan" --remove-temporary-dns "$replace_dns"
  restore_dns=0
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
