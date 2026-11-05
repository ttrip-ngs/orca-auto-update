#!/usr/bin/env bash
# Orca headless server と自動更新の導入。まっさらな Ubuntu でも既存ホストでも同じコマンドでよい
#
# 実行: sudo bash install.sh --user <orca serve を動かすユーザ> [--pairing-address <アドレス>] [--update-now]
#   --user             /etc/default/orca-auto-update が無いときに作る設定の ORCA_SVC_USER
#                      (既にあれば省略可。値が食い違えば中断する)
#   --pairing-address  orca serve の unit を新規に作るときの、クライアントから到達できるアドレス
#                      (既定は既定経路のアドレス。既存の unit は変更しない)
#   --update-now       導入後すぐに最新版へ更新する(公開からの待ち時間を飛ばす)
#
# 行うこと(揃っているものには触らない):
#   1. 足りないコマンドを apt で入れる。Orca が未配置なら実行に必要なライブラリも入れる
#   2. サービスユーザの linger を有効化(terminal daemon が user scope に移り、以後の再起動でセッションが落ちない)
#   3. /usr/local/sbin/orca-auto-update と orca-auto-update.{service,timer} を配置
#   4. Orca が未配置なら配置し、orca serve の unit が無ければ作って起動する
#   5. timer を有効化
#   6. (--update-now) 更新を専用 unit で実行し、進行を表示する
#   7. 接続情報を表示する(起動・更新した場合は接続用 URL、そうでなければ URL を確認するコマンド)
#
# 注意: linger を有効にする前から動いている daemon は orca serve の cgroup 内にいるので、
#       導入後の最初の再起動(--update-now か、初回の自動更新)でだけ、その時点のセッションが落ちる。
set -euo pipefail

SRC=$(cd "$(dirname "$0")" && pwd)
CONFIG=/etc/default/orca-auto-update
USER_ARG=""
PAIRING_ADDRESS=""
UPDATE_NOW=0
while [ $# -gt 0 ]; do
  case "$1" in
    --user) USER_ARG=${2:-}; shift 2 ;;
    --pairing-address) PAIRING_ADDRESS=${2:-}; shift 2 ;;
    --update-now) UPDATE_NOW=1; shift ;;
    *) echo "usage: $0 --user <name> [--pairing-address <address>] [--update-now]"; exit 2 ;;
  esac
done

[ "$(id -u)" -eq 0 ] || { echo "ERROR: root で実行すること (sudo bash $0)"; exit 1; }
for f in orca-auto-update orca-auto-update.service orca-auto-update.timer config.example; do
  [ -f "$SRC/$f" ] || { echo "ERROR: $SRC/$f が無い"; exit 1; }
done
bash -n "$SRC/orca-auto-update"

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
read -r SVC BASE PORT < <( [ -f "$CONFIG" ] && . "$CONFIG"; echo "${ORCA_SERVICE:-orca-serve} ${ORCA_BASE:-/opt/orca} ${ORCA_PORT:-6768}")
if [ "$UPDATE_NOW" -eq 1 ] && grep -q "$SVC\.service" /proc/self/cgroup; then
  echo "ERROR: Orca のターミナル内では --update-now を使えない(更新の停止でこの端末が落ち、結果を表示できない)。"
  echo "       SSH 端末から実行するか、--update-now 無しで導入して初回の自動更新に任せること。"
  exit 1
fi

NEED_TREE=0
[ -e "$BASE/squashfs-root" ] || NEED_TREE=1
NEED_UNIT=0
systemctl cat "$SVC.service" >/dev/null 2>&1 || NEED_UNIT=1
# unit の 1 行に埋め込むので、アドレスとして使う文字だけを許す
[ -z "$PAIRING_ADDRESS" ] || [[ "$PAIRING_ADDRESS" =~ ^[A-Za-z0-9.:_-]+$ ]] || { echo "ERROR: --pairing-address の値が不正: $PAIRING_ADDRESS"; exit 1; }
[ "$NEED_UNIT" -eq 1 ] || [ -z "$PAIRING_ADDRESS" ] || echo "WARN: $SVC の unit は既にあるので --pairing-address は使わない"

echo "=== 1. 必要なパッケージ ==="
PKGS=()
while read -r c p; do
  command -v "$c" >/dev/null || PKGS+=("$p")
done <<'EOF'
unsquashfs squashfs-tools
readelf binutils
curl curl
openssl openssl
python3 python3
flock util-linux
runuser util-linux
ss iproute2
EOF
if [ "$NEED_TREE" -eq 1 ]; then
  # orca-ide(Electron)の実行に必要なライブラリと、Orca が作業に使う git
  PKGS+=(ca-certificates git libnss3 libatk1.0-0t64 libatk-bridge2.0-0t64 libcups2t64 libgtk-3-0t64 libgbm1 libasound2t64 libxss1 libxtst6)
fi
if [ "${#PKGS[@]}" -gt 0 ]; then
  command -v apt-get >/dev/null || { echo "ERROR: apt-get が無いので入れられない: ${PKGS[*]}"; exit 1; }
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${PKGS[@]}"
fi

if [ "$NEED_UNIT" -eq 1 ] && [ -z "$PAIRING_ADDRESS" ]; then
  PAIRING_ADDRESS=$(ip route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([^ ]*\).*/\1/p')
  [ -n "$PAIRING_ADDRESS" ] || { echo "ERROR: 既定経路のアドレスを判定できない。--pairing-address を指定すること"; exit 1; }
fi

echo "=== 2. 設定と linger ==="
if [ ! -f "$CONFIG" ]; then
  sed "s/^ORCA_SVC_USER=$/ORCA_SVC_USER=$SVCUSER/" "$SRC/config.example" > "$CONFIG"
  chmod 0644 "$CONFIG"
  echo "作成: $CONFIG (ORCA_SVC_USER=$SVCUSER)"
fi
loginctl enable-linger "$SVCUSER"
echo "Linger: $(loginctl show-user "$SVCUSER" -p Linger --value)"

echo "=== 3. 配置 ==="
install -o root -g root -m 0755 "$SRC/orca-auto-update" /usr/local/sbin/orca-auto-update
install -o root -g root -m 0644 "$SRC/orca-auto-update.service" /etc/systemd/system/orca-auto-update.service
install -o root -g root -m 0644 "$SRC/orca-auto-update.timer" /etc/systemd/system/orca-auto-update.timer
install -d -o root -g root -m 0700 /var/lib/orca-auto-update
systemctl daemon-reload

echo "=== 4. Orca ==="
[ "$NEED_TREE" -eq 0 ] || /usr/local/sbin/orca-auto-update --bootstrap
if [ "$NEED_UNIT" -eq 1 ]; then
  SVCHOME=$(getent passwd "$SVCUSER" | cut -d: -f6)
  cat > "/etc/systemd/system/$SVC.service" <<EOF
[Unit]
Description=Orca runtime server
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=simple
User=$SVCUSER
WorkingDirectory=$SVCHOME
Environment=LIBGL_ALWAYS_SOFTWARE=1
ExecStart=$BASE/squashfs-root/AppRun serve --port $PORT --pairing-address $PAIRING_ADDRESS
KillMode=mixed
Restart=on-failure
RestartPreventExitStatus=3
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  echo "作成: /etc/systemd/system/$SVC.service (User=$SVCUSER, pairing-address=$PAIRING_ADDRESS)"
  systemctl daemon-reload
fi
SHOW_URL=$UPDATE_NOW
if [ "$NEED_TREE" -eq 1 ] || [ "$NEED_UNIT" -eq 1 ]; then
  SHOW_URL=1
  systemctl enable --now "$SVC"
  for _ in $(seq 1 60); do
    ss -Hltn "sport = :$PORT" | grep -q LISTEN && break
    sleep 1
  done
  ss -Hltn "sport = :$PORT" | grep -q LISTEN || { echo "ERROR: :$PORT が LISTEN しない。確認: systemctl status $SVC"; exit 1; }
  echo "$SVC は :$PORT で稼働中"
else
  echo "既存の Orca と $SVC をそのまま使う"
fi

echo "=== 5. timer ==="
systemctl enable --now orca-auto-update.timer
systemctl list-timers --no-pager orca-auto-update.timer

if [ "$UPDATE_NOW" -eq 1 ]; then
  echo "=== 6. 今すぐ更新(専用 unit で実行。この端末が切れても更新は続く) ==="
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

echo "=== 7. 接続 ==="
URL_CMD="sudo journalctl -u $SVC -o cat | grep -E 'Web client URL|Pairing URL' | tail -2"
URLS=""
if [ "$SHOW_URL" -eq 1 ]; then
  # 今回の起動が出したものだけを見る。ready の表示は LISTEN より少し遅れることがある
  INVOCATION=$(systemctl show -p InvocationID --value "$SVC")
  for _ in $(seq 1 30); do
    URLS=$(journalctl "_SYSTEMD_INVOCATION_ID=$INVOCATION" -o cat --no-pager | grep -E '^(Web client URL|Pairing URL):' || true)
    [ -z "$URLS" ] || break
    sleep 1
  done
fi
if [ -n "$URLS" ]; then
  echo "次のどちらかで接続する(ブラウザなら Web client URL、Orca アプリなら Pairing URL):"
  printf '%s\n' "$URLS" | sed 's/^/  /'
  echo "この URL は資格情報を含むので、チャットやチケットに貼らないこと。再表示: $URL_CMD"
else
  echo "接続用 URL の確認: $URL_CMD"
fi
if [ "$NEED_UNIT" -eq 1 ]; then
  echo "接続先アドレスは $PAIRING_ADDRESS にした。クライアントから届かないアドレスなら、"
  echo "/etc/systemd/system/$SVC.service の --pairing-address を直して daemon-reload と restart をすること"
fi
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active' && ! ufw status 2>/dev/null | grep -q "\b$PORT\b"; then
  echo "WARN: ufw が有効で :$PORT を許可していないので、このままでは接続できない。許可の例:"
  echo "  sudo ufw allow from <クライアントの CIDR> to any port $PORT proto tcp"
fi
echo "注意: :$PORT は全インタフェースで待ち受ける。届く範囲はファイアウォールで絞ること。Orca のエージェントは $SVCUSER の権限で動く"
