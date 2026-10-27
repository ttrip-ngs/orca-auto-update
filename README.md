# orca-auto-update

Linux(x86_64)で headless 運用している [Orca](https://github.com/stablyai/orca) の `orca serve` を、
systemd timer で毎日自動更新するスクリプト一式。

## なぜ必要か

- **Linux の headless serve は Orca の画面から更新できない。** Orca のサーバ更新機能は
  `resolveUpdateInstallMode` が macOS(`--supervise`)のときだけ有効で、Linux では常に
  `unsupported-headless-serve` になり、`remote_update_manual_required`(「This server must be updated
  manually through its service manager.」)が返る(1.4.230〜1.4.242 で確認)。
- **libfuse2 が無いホストでは AppImage を直接実行できない。** そのため展開済みツリー
  (`/opt/orca/squashfs-root/AppRun`)を `ExecStart` にする構成が多く、AppImage を差し替えても何も変わらない。
- **linger が無効だと、再起動のたびに全ターミナル(claude セッション等)が落ちる。** Orca は起動時に
  `daemon-scope-unavailable: linger off; the terminal daemon stays in this process's cgroup` と警告する。
  linger を有効にすると、Orca は terminal daemon を `orca-daemon-*.scope`、各ターミナルを
  `orca_pty_*.scope`(`user@<uid>.service` 配下)へ移すため、サービスの停止・版の更新をまたいで
  ターミナルが生き残る。新版は新しい daemon を起動し、旧 daemon は既存セッションを持ったまま並走する。

## やること

毎日 04:00 JST に次を行う(`orca-auto-update.timer`)。

1. GitHub の最新リリースを確認する。公開から 24 時間たっていない版、見送り中の版、保留中なら何もしない
2. `orca-linux.AppImage` を取得し、同じリリースの `latest-linux.yml` のサイズ・sha512 と照合する
3. **稼働中に** AppImage を実行せずに `unsquashfs` で展開し、`<BASE>/squashfs-root.<新版>` に置く
   (root 所有。ツリー外を指す symlink があれば拒否)。サービスユーザで `AppRun --version` を確認する
4. サービスを停止し、プロファイルを `<profile>.bak-<旧版>` へ複製し、`squashfs-root` を mv 2 本で入れ替えて起動する
5. 起動を確認する(active / NRestarts=0 / ポートが LISTEN / MainPID の exe が新ツリーの `orca-ide` と同じ inode / 版)
6. 失敗したら旧ツリーへ戻して起動し直す。旧版も起動しなければプロファイルを退避から戻して再試行する。
   失敗した版は `failed-<版>` として以後見送る
7. 成功したら旧ツリーとプロファイル退避を新しい 2 つだけ残して削除する

停止から起動確認までの間に強制終了された場合は、EXIT トラップで `squashfs-root` を戻して起動する。

## 前提

- `orca serve` が system unit(既定 `orca-serve.service`)として、`<BASE>/squashfs-root/AppRun serve ...`
  を `ExecStart` にして動いていること。初回構築は [docs/setup.md](docs/setup.md)
- Ubuntu 24.04 で確認。`squashfs-tools` `binutils` `curl` `openssl` `python3` `util-linux` が必要

## 導入

```bash
git clone https://github.com/ttrip-ngs/orca-auto-update.git
cd orca-auto-update
sudo bash install.sh --user <orca serve を動かすユーザ> --update-now
```

- `/etc/default/orca-auto-update` を作り(既にあればそのまま使う)、linger を有効にし、
  `/usr/local/sbin/orca-auto-update` と unit を入れて timer を有効にする。設定項目は [config.example](config.example)
- `--update-now` はその場で最新版へ更新する(公開からの待ち時間を飛ばす)。**SSH 端末から実行すること。**
  Orca のターミナル内では中断する
- linger を有効にする前から動いている daemon はサービスの cgroup 内にいるので、導入後最初の再起動でだけ、
  その時点のターミナルが落ちる。結果の最後に表示される daemon の cgroup が `user.slice` 配下なら、以後は落ちない

## 運用

```bash
journalctl -u orca-auto-update                 # 結果
systemctl list-timers orca-auto-update.timer   # 次回の実行

# 今すぐ確認・更新(公開からの待ち時間は有効)
sudo systemctl start orca-auto-update.service
# 待ち時間を飛ばして今すぐ更新
sudo systemd-run --wait --collect -u orca-auto-update-now /usr/local/sbin/orca-auto-update --no-wait
# 旧版へ戻す(戻した元の版を見送り、自動更新を保留する)
sudo systemd-run --wait --collect -u orca-auto-update-rb /usr/local/sbin/orca-auto-update --rollback <版>

sudo rm /var/lib/orca-auto-update/hold             # 保留を解除する
sudo rm /var/lib/orca-auto-update/failed-<版>      # 見送った版を再試行させる
```

手動操作も `systemd-run` 経由で行う。端末から直接 `sudo orca-auto-update` すると、端末切断の SIGHUP で
停止と起動の間に中断することがある(その場合も EXIT トラップで起動し直すが、避けた方がよい)。

## セキュリティ上の注意

- sha512 は同じリリースから取るので、保証するのは転送の完全性だけで真正性ではない(Orca は署名を配布していない)。
  リリース元のアカウントが侵害された場合は防げない。公開から 24 時間待つことで、不良版・取り下げ版を避ける
- 取得した AppImage は root で実行しない(展開は `unsquashfs`、版の確認はサービスユーザ)
- journal に `Web client URL` / `Pairing URL` 行(deviceToken を含む)を出さない
- 失敗は journal に残るだけなので、`systemctl is-failed orca-auto-update` と `orca-serve` の稼働を
  監視システムで見ることを推奨する

## テスト

```bash
pre-commit run --all-files
docker run --rm -v "$PWD":/src:ro ubuntu:24.04 bash /src/tests/failure-paths.sh
```

`tests/failure-paths.sh` は systemctl をスタブにして、ロールバック・新版の起動失敗・プロファイル移行後の復旧・
停止中の強制終了・引数検証を確かめる。

## License

MIT
