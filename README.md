# ADIN1100 PHY Long-Reach Initialization Script

## 概要
このスクリプトは、ADIN1100 PHYのロングリーチ設定およびリンク確立を自動化します。  
3kmまでの長距離イーサネットケーブルでの使用を想定し、ケーブル診断、校正、SNRチェックを行います。

## 動作環境
- Linux環境（例: Ubuntu, Debian等）
- `mdio-tools` コマンド (`mdio`)、`ethtool`、`ip` コマンドが必要
- root 権限での実行推奨

## 依存パッケージのインストール例 (Debian/Ubuntu)

```bash
sudo apt update
sudo apt install mdio-tools ethtool iproute2
```

## ファイル構成

adin1100_init.sh : 初期化スクリプト本体
README.md : 本ドキュメント
logrotate_adin1100 : ログローテート設定例
ログファイル

デフォルトで /var/log/adin1100_init.log にログを出力します。
ログファイルの肥大化防止には、付属の logrotate_adin1100 設定ファイルを /etc/logrotate.d/ に配置してください。

## 起動方法

標準実行例
```
sudo ./adin1100_init.sh eth0 0
```
eth0: 使用するネットワークインターフェース名
0: PHYアドレス（0-31の範囲）
リピータPHYを使用する場合
```
sudo ./adin1100_init.sh eth0 0 1
```
3つ目の引数はリピータのPHYアドレス
ドライランモード（動作検証のみ）
```
./adin1100_init.sh --dry-run eth0 0
```

## 注意点

スクリプトは root または相応の権限で実行してください。
3kmを超えるケーブルではリピータの使用を推奨します。
ログの出力先ディレクトリに書き込み権限が必要です。


### logrotate_adin1100（ログローテート設定例）

```bash
/var/log/adin1100_init.log {
    daily
    rotate 7
    compress
    missingok
    notifempty
    create 644 root root
}
```
