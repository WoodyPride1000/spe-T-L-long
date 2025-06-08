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
