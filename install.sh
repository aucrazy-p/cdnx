#!/usr/bin/env bash
# ============================================================================
# cdnx 一键安装：在 VPS 上拉取最新部署脚本并执行
# 用法（甲骨文 VPS 上 root 运行）：
#   bash <(curl -fsSL https://raw.githubusercontent.com/aucrazy-p/cdnx/main/install.sh)
# 过程会交互式问你：CDN 域名、端口、运营商、挑哪几个优选 IP
# ============================================================================
set -e

REPO_RAW="https://raw.githubusercontent.com/aucrazy-p/cdnx/main"
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

echo "=== cdnx 一键安装：下载最新部署脚本 ==="
curl -fsSL "$REPO_RAW/deploy.sh" -o "$TMP" || { echo "下载失败，检查 VPS 能否访问 raw.githubusercontent.com"; exit 1; }
echo "下载完成，开始部署..."
echo ""
exec bash "$TMP"
