#!/bin/sh
# SmartDNS Manager public bootstrap. SPDX-License-Identifier: MIT
set -eu
PATH=/opt/sbin:/opt/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH
VERSION=0.4.2
REPO=shurshick/SmartDNS_Manager
check=0
action=install
case "${1:-}" in
 --check) check=1; shift;;
 --update) action=update; shift;;
 --uninstall) action=uninstall; shift;;
 --help|-h) echo 'sh install.sh [--check|--update|--uninstall] [LAN_IPV4]; SDM_LAN_IP overrides LAN detection'; exit 0;;
esac
[ "$#" -le 1 ] || { echo 'Укажите одно действие и необязательный LAN IPv4' >&2; exit 2; }
die() { echo "SmartDNS Manager: $*" >&2; exit 1; }
case "${1:-}" in -*) die 'неизвестное действие; используйте --help';; esac
for cmd in awk uname; do command -v "$cmd" >/dev/null 2>&1 || die "нужна команда $cmd"; done
if [ -f /etc/openwrt_release ]; then platform=openwrt
elif [ -f /opt/etc/init.d/rc.func ]; then platform=keenetic
else die 'нужен OpenWrt или Keenetic/Netcraze с уже установленным Entware'; fi
if [ "$platform" = keenetic ]; then
 owner=/opt/var/lib/smartdns-manager-install/owner.json
 runtime=/opt/sbin/smartdns-manager
else
 owner=/etc/smartdns-manager-install/owner.json
 runtime=/usr/sbin/smartdns-manager
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
 keenetic-arm64) echo 'fafb51d95835bbdd63b4cd2b1cfab4dfbed5f865858a13ed947064f0a8975442';;
 keenetic-mips) echo '5aad7b46b132162b91610d8fe27ff4d906e7b15548303998d5dd13ac6f546356';;
 keenetic-mipsle) echo '8faf9587c21496326ba873490c0aa4c1d4bd89153018902a61292df54894581b';;
 openwrt-amd64) echo '80a8e0e5ee676842d2277520a46403c44ae973daca6247d42d6ba919f3f8e9fb';;
 openwrt-arm64) echo '6fa465ad70ce8e8ca9186b4bed73df8b1b46ac5e36153b14fa1cbef718ca5016';;
 openwrt-armv7) echo '5ef54419fe05ed490e5c2d759579aa088c0e634d9cd3f713f857d7eee2f9f5bd';;
 openwrt-mips) echo 'fc4e1e11602d337bfbc9359436e5872808071a82ba50e2e43bdd9ac97e4da021';;
 openwrt-mipsle) echo 'd98f287e8021c032a74d51590fe9bda239479190dfbcc61c42ace9658b84433a';;
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
 sh "$temp/package/install.sh" --lan-ip "$lan"
 echo "Панель: http://$lan:8092/"
else
 [ "$#" = 0 ] || die 'для OpenWrt LAN IPv4 указывать не нужно'
 sh "$temp/package/install.sh"
 echo 'Панель: http://LAN_IP_РОУТЕРА:8092/'
fi
