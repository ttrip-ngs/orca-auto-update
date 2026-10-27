#!/usr/bin/env bash
# orca-auto-update の導入
#
# 実行: sudo bash install.sh --user <orca serve を動かすユーザ> [--update-now]
#   --user        /etc/default/orca-auto-update が無いときに作る設定の ORCA_SVC_USER
#                 (既にあれば省略可。値が食い違えば中断する)
#   --update-now  導入後すぐに最新版へ更新する(公開からの待ち時間を飛ばす)
#
# 行うこと:
#   1. サービスユーザの linger を有効化(terminal daemon が user scope に移り、以後の再起動でセッションが落ちない)
#   2. /usr/local/sbin/orca-auto-update と orca-auto-update.{service,timer} を配置し timer を有効化
#   3. (--update-now) 更新を専用 unit で実行し、進行を表示する
#
# 注意: linger を有効にする前から動いている daemon は orca serve の cgroup 内にいるので、
#       導入後の最初の再起動(--update-now か、初回の自動更新)でだけ、その時点のセッションが落ちる。
set -euo pipefail

SRC=$(cd "$(dirname "$0")" && pwd)
CONFIG=/etc/default/orca-auto-update
USER_ARG=""
UPDATE_NOW=0
while [ $# -gt 0 ]; do
  case "$1" in
    --user) USER_ARG=${2:-}; shift 2 ;;
    --update-now) UPDATE_NOW=1; shift ;;
    *) echo "usage: $0 --user <name> [--update-now]"; exit 2 ;;
  esac
done

[ "$(id -u)" -eq 0 ] || { echo "ERROR: root で実行すること (sudo bash $0)"; exit 1; }
for f in orca-auto-update orca-auto-update.service orca-auto-update.timer config.example; do
  [ -f "$SRC/$f" ] || { echo "ERROR: $SRC/$f が無い"; exit 1; }
done
bash -n "$SRC/orca-auto-update"
for c in unsquashfs readelf curl openssl python3 flock runuser; do
  command -v "$c" >/dev/null || { echo "ERROR: $c が無い(unsquashfs は squashfs-tools、readelf は binutils)"; exit 1; }
done

if [ -f "$CONFIG" ]; then
  # shellcheck source=config.example
  SVCUSER=$(. "$CONFIG"; echo "${ORCA_SVC_USER:-}")
  [ -z "$USER_ARG" ] || [ "$USER_ARG" = "$SVCUSER" ] || { echo "ERROR: --user $USER_ARG と $CONFIG の ORCA_SVC_USER=$SVCUSER が違う"; exit 1; }
else
  [ -n "$USER_ARG" ] || { echo "ERROR: $CONFIG が無いので --user が必要"; exit 1; }
  SVCUSER=$USER_ARG
fi
id "$SVCUSER" >/dev/null 2>&1 || { echo "ERROR: ユーザ $SVCUSER が存在しない"; exit 1; }
# shellcheck source=config.example
SVC=$( [ -f "$CONFIG" ] && . "$CONFIG"; echo "${ORCA_SERVICE:-orca-serve}")
if [ "$UPDATE_NOW" -eq 1 ] && grep -q "$SVC\.service" /proc/self/cgroup; then
  echo "ERROR: Orca のターミナル内では --update-now を使えない(更新の停止でこの端末が落ち、結果を表示できない)。"
  echo "       SSH 端末から実行するか、--update-now 無しで導入して初回の自動更新に任せること。"
  exit 1
fi

echo "=== 1. 設定と linger ==="
if [ ! -f "$CONFIG" ]; then
  sed "s/^ORCA_SVC_USER=$/ORCA_SVC_USER=$SVCUSER/" "$SRC/config.example" > "$CONFIG"
  chmod 0644 "$CONFIG"
  echo "作成: $CONFIG (ORCA_SVC_USER=$SVCUSER)"
fi
loginctl enable-linger "$SVCUSER"
echo "Linger: $(loginctl show-user "$SVCUSER" -p Linger --value)"

echo "=== 2. 配置 ==="
install -o root -g root -m 0755 "$SRC/orca-auto-update" /usr/local/sbin/orca-auto-update
install -o root -g root -m 0644 "$SRC/orca-auto-update.service" /etc/systemd/system/orca-auto-update.service
install -o root -g root -m 0644 "$SRC/orca-auto-update.timer" /etc/systemd/system/orca-auto-update.timer
install -d -o root -g root -m 0700 /var/lib/orca-auto-update
systemctl daemon-reload
systemctl enable --now orca-auto-update.timer
systemctl list-timers --no-pager orca-auto-update.timer

if [ "$UPDATE_NOW" -eq 1 ]; then
  echo "=== 3. 今すぐ更新(専用 unit で実行。この端末が切れても更新は続く) ==="
  journalctl -f -n 0 -o cat -u orca-auto-update-now &
  JPID=$!
  rc=0
  systemd-run --wait --collect -u orca-auto-update-now /usr/local/sbin/orca-auto-update --no-wait || rc=$?
  sleep 1
  kill "$JPID" 2>/dev/null || true
  echo "############ 結果 rc=$rc(0 なら成功) ############"
  systemctl show -p ActiveState -p NRestarts "$SVC"
  echo "terminal daemon の cgroup(user.slice 配下なら以後の再起動でセッションが落ちない):"
  for d in $(pgrep -u "$SVCUSER" -f '/orcad-artifacts/.*/daemon-entry.js' || true); do
    echo "  pid $d: $(cat "/proc/$d/cgroup" 2>/dev/null)"
  done
fi
