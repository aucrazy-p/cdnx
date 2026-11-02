#!/usr/bin/env bash
# ============================================================================
# cdnx 一键安装：在 VPS 上拉取最新部署脚本并执行
# 用法（VPS 上 root 运行）：
#   bash <(curl -fsSL https://raw.githubusercontent.com/aucrazy-p/cdnx/main/install.sh)
# 已部署过的机器再跑这条命令，不会重新安装，而是直接进入管理菜单
# ============================================================================
set -e

REPO_RAW="https://raw.githubusercontent.com/aucrazy-p/cdnx/main"

# 已有部署：直接进管理菜单，不重装
if [ -f /opt/cdnx/menu.sh ]; then
  echo "检测到本机已有 cdnx 部署，进入管理菜单..."
  exec bash /opt/cdnx/menu.sh
fi
# 旧版部署（还没有菜单脚本）：补一个菜单再进入
if [ -d /opt/cdnx ]; then
  echo "检测到旧版 cdnx 部署，补装管理菜单..."
  curl -fsSL "$REPO_RAW/menu.sh" -o /opt/cdnx/menu.sh \
    && chmod +x /opt/cdnx/menu.sh \
    && exec bash /opt/cdnx/menu.sh
fi

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

echo "=== cdnx 一键安装：下载最新部署脚本 ==="
curl -fsSL "$REPO_RAW/deploy.sh" -o "$TMP" || { echo "下载失败，检查 VPS 能否访问 raw.githubusercontent.com"; exit 1; }
echo "下载完成，开始部署..."
echo ""
exec bash "$TMP"
