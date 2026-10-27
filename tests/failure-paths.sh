#!/usr/bin/env bash
# orca-auto-update の入れ替え・失敗時の復旧を検証する。使い捨てコンテナ内で root として実行すること:
#   docker run --rm -v "$PWD":/src:ro ubuntu:24.04 bash /src/tests/failure-paths.sh
# systemctl / ss / journalctl はスタブ。orca-ide は sleep のコピーで、ツリー内の目印ファイルで挙動を変える:
#   BROKEN             起動に失敗する
#   MIGRATES           起動時にプロファイルへ MIGRATED を作る(新版のプロファイル移行を模擬)
#   NEEDS_OLD_PROFILE  プロファイルに MIGRATED があると起動に失敗する
set -u
[ "$(id -u)" -eq 0 ] && [ -f /.dockerenv ] || { echo "使い捨てコンテナ内で root として実行すること"; exit 1; }
SRC=$(cd "$(dirname "$0")/.." && pwd)
FAKE=/run/fake
FAILS=0

useradd -m orca 2>/dev/null || true
PROFILE=/home/orca/.config/orca
echo "ORCA_SVC_USER=orca" > /etc/default/orca-auto-update
mkdir -p $FAKE /usr/local/stub

cat > /usr/local/stub/systemctl <<'EOF'
#!/bin/bash
pidf=/run/fake/pid
running() { [ -f $pidf ] && kill -0 "$(cat $pidf)" 2>/dev/null; }
tree=/opt/orca/squashfs-root
broken() { [ -e $tree/BROKEN ] || { [ -e $tree/NEEDS_OLD_PROFILE ] && [ -e /home/orca/.config/orca/MIGRATED ]; }; }
case "$1" in
  stop) [ -n "${STUB_SLOW_STOP:-}" ] && sleep 5; running && kill "$(cat $pidf)"; rm -f $pidf ;;
  start)
    [ -x $tree/orca-ide ] || exit 1
    [ -e $tree/MIGRATES ] && touch /home/orca/.config/orca/MIGRATED
    broken && exit 1
    # fd 9(ロック)を引き継がない: 本物の systemd はサービスに fd を渡さない
    setsid $tree/orca-ide 9999 >/dev/null 2>&1 9>&- & echo $! > $pidf ;;
  is-active) running && echo active || echo failed ;;
  show) case "$*" in *MainPID*) if running; then cat $pidf; else echo 0; fi ;; *NRestarts*) echo 0 ;; esac ;;
esac
exit 0
EOF
cat > /usr/local/stub/ss <<'EOF'
#!/bin/bash
[ -f /run/fake/pid ] && kill -0 "$(cat /run/fake/pid)" 2>/dev/null && echo "LISTEN 0 511 0.0.0.0:6768 0.0.0.0:*"
exit 0
EOF
printf '#!/bin/bash\nexit 0\n' > /usr/local/stub/journalctl
printf '#!/bin/bash\nexit 1\n' > /usr/local/stub/pgrep
chmod +x /usr/local/stub/*
export PATH=/usr/local/stub:$PATH
# 起動確認の固定待ち(10秒)だけ短くしたコピーを使う
U=/usr/local/sbin/orca-auto-update
sed 's/sleep 10   # 起動直後/sleep 1   # 起動直後/' "$SRC/orca-auto-update" > $U
chmod +x $U

mktree() { # $1=dir $2=version [目印...]
  local d=$1 v=$2; shift 2
  mkdir -p "$d"; cp /bin/sleep "$d/orca-ide"; echo "X-AppImage-Version=$v" > "$d/orca-ide.desktop"
  for m in "$@"; do touch "$d/$m"; done
}
reset() {
  [ -f $FAKE/pid ] && kill "$(cat $FAKE/pid)" 2>/dev/null
  rm -rf /opt/orca /var/lib/orca-auto-update /home/orca/.config $FAKE/pid
  mkdir -p /opt/orca $PROFILE
}
running_ver() { [ "$(systemctl is-active)" = active ] && grep -o '[0-9.]*$' /opt/orca/squashfs-root/orca-ide.desktop; }
check() { # $1=説明 $2=条件(eval)
  if eval "$2"; then echo "  ok: $1"; else echo "  NG: $1"; FAILS=$((FAILS + 1)); fi
}
run() { "$U" "$@" 2>&1 | sed 's/^/    /'; return "${PIPESTATUS[0]}"; }

echo "=== A. ロールバック成功 ==="
reset; mktree /opt/orca/squashfs-root 1.4.240; mktree /opt/orca/squashfs-root.1.4.230 1.4.230; systemctl start
run --rollback 1.4.230; rc=$?
check "rc=0" "[ $rc -eq 0 ]"
check "1.4.230 で稼働" '[ "$(running_ver)" = 1.4.230 ]'
check "hold と failed-1.4.240 ができる" '[ -e /var/lib/orca-auto-update/hold ] && [ -e /var/lib/orca-auto-update/failed-1.4.240 ]'
check "1.4.240 のツリーは残す" '[ -d /opt/orca/squashfs-root.1.4.240 ]'

echo "=== B. 新版が起動しない -> 旧版へ自動で戻る ==="
reset; mktree /opt/orca/squashfs-root 1.4.230; mktree /opt/orca/squashfs-root.1.4.240 1.4.240 BROKEN; systemctl start
run --rollback 1.4.240; rc=$?
check "rc=1" "[ $rc -eq 1 ]"
check "1.4.230 で稼働" '[ "$(running_ver)" = 1.4.230 ]'
check "hold は作らない" '[ ! -e /var/lib/orca-auto-update/hold ]'

echo "=== C. 新版がプロファイルを移行し、旧版が起動しない -> プロファイルを退避から戻す ==="
reset; mktree /opt/orca/squashfs-root 1.4.230 NEEDS_OLD_PROFILE; mktree /opt/orca/squashfs-root.1.4.240 1.4.240 BROKEN MIGRATES
echo v1 > $PROFILE/state; systemctl start
run --rollback 1.4.240; rc=$?
check "rc=1" "[ $rc -eq 1 ]"
check "1.4.230 で稼働" '[ "$(running_ver)" = 1.4.230 ]'
check "稼働中のプロファイルは移行前" '[ ! -e $PROFILE/MIGRATED ] && [ "$(cat $PROFILE/state)" = v1 ]'
check "移行されたプロファイルは failed として残す" '[ -e $PROFILE.failed-1.4.240/MIGRATED ]'

echo "=== D. 停止中に SIGTERM -> EXIT トラップで起動し直す ==="
reset; mktree /opt/orca/squashfs-root 1.4.240; mktree /opt/orca/squashfs-root.1.4.230 1.4.230; systemctl start
STUB_SLOW_STOP=1 "$U" --rollback 1.4.230 > $FAKE/d.out 2>&1 &
P=$!; sleep 2; kill -TERM $P; wait $P; rc=$?
sed 's/^/    /' $FAKE/d.out
check "rc=143" "[ $rc -eq 143 ]"
check "サービスが動いている" '[ -n "$(running_ver)" ]'

echo "=== E. 不正な引数を拒否する ==="
reset; mktree /opt/orca/squashfs-root 1.4.240; systemctl start
run --rollback '../../etc'; rc=$?
check "rc=2" "[ $rc -eq 2 ]"
check "稼働は変わらない" '[ "$(running_ver)" = 1.4.240 ]'

echo "=== F. ORCA_SVC_USER 未設定なら何もしない ==="
echo "ORCA_SVC_USER=" > /etc/default/orca-auto-update
run; rc=$?
check "rc=1" "[ $rc -eq 1 ]"
check "稼働は変わらない" '[ "$(running_ver)" = 1.4.240 ]'

echo
if [ "$FAILS" -eq 0 ]; then echo "ALL PASSED"; else echo "$FAILS 件失敗"; exit 1; fi
