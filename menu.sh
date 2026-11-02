#!/usr/bin/env bash
# cdnx 管理菜单：切换运营商（换宽带/换地方时用）、立即更新、查看状态
set -e
DEPLOY_DIR="/opt/cdnx"
ENV_FILE="$DEPLOY_DIR/deploy.env"
REPO_RAW="https://raw.githubusercontent.com/aucrazy-p/cdnx/main"
[ -f "$ENV_FILE" ] || { echo "找不到 deploy.env，请先跑部署脚本"; exit 1; }

isp_name() {
  case "$1" in
    1) echo "电信" ;;
    2) echo "联通" ;;
    3) echo "移动" ;;
    4) echo "通用(WeTest)" ;;
    5) echo "全部" ;;
    *) echo "未知" ;;
  esac
}

while true; do
  source "$ENV_FILE"
  echo ""
  echo "=== cdnx 管理菜单 ==="
  echo "当前运营商：$(isp_name "${ISP:-5}")    每次取 ${COUNT:-5} 个 IP"
  echo "--------------------------------"
  echo "  1) 电信            2) 联通"
  echo "  3) 移动            4) 通用(WeTest)"
  echo "  5) 全部"
  echo "  6) 按当前运营商立即更新一次 IP"
  echo "  7) 查询订阅（地址 + 二维码直接显示在终端）"
  echo "  8) 查看当前优选 IP 和最近日志"
  echo "  9) 重新运行部署向导（改域名 / 端口 / 重挑 IP）"
  echo "  10) 一键卸载"
  echo "  0) 退出"
  echo "--------------------------------"
  read -r -p "选择： " C
  case "$C" in
    1|2|3|4|5)
      sed -i "s/^ISP=.*/ISP=$C/" "$ENV_FILE"
      echo "已切换为：$(isp_name "$C")，正在按新运营商更新优选 IP..."
      bash "$DEPLOY_DIR/update_ips.sh" || echo "更新失败，可稍后选 6 重试"
      echo "记得在客户端点「更新订阅」拿新 IP"
      ;;
    6)
      bash "$DEPLOY_DIR/update_ips.sh" || echo "更新失败，稍后再试"
      ;;
    7)
      SUB_URL=$(sed -n 's/^订阅地址：//p' "$DEPLOY_DIR/node_info.txt" 2>/dev/null | head -n 1)
      if [ -z "$SUB_URL" ]; then
        echo "找不到订阅地址，请先完整部署一次"
      else
        echo ""
        echo "订阅地址（复制进 Karing / 客户端的订阅栏）："
        echo "$SUB_URL"
        echo ""
        echo "订阅二维码（手机扫这个就行，不用去文件夹找）："
        qrencode -t UTF8 -m 2 "$SUB_URL" 2>/dev/null || echo "(本机终端显示二维码失败，用上面的地址手动添加)"
      fi
      ;;
    8)
      grep '优选 IP' "$DEPLOY_DIR/node_info.txt" 2>/dev/null || true
      tail -n 3 /var/log/cdnx_update.log 2>/dev/null || echo "暂无更新日志"
      ;;
    9)
      echo "重新运行部署向导（UUID 与订阅地址自动复用，客户端不受影响）..."
      TMPD=$(mktemp)
      curl -fsSL "$REPO_RAW/deploy.sh" -o "$TMPD" && bash "$TMPD" || echo "部署未完成，可稍后重试"
      rm -f "$TMPD"
      ;;
    10)
      bash "$DEPLOY_DIR/uninstall.sh" || true
      exit 0
      ;;
    0) exit 0 ;;
    *) echo "无效选择" ;;
  esac
done
