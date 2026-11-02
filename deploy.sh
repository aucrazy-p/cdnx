#!/usr/bin/env bash
# ============================================================================
# 独立部署脚本：CDN + VLESS + XHTTP（不依赖 S-UI，不依赖任何面板）
# 跑在：你的 VPS 上（Debian / Ubuntu，root 运行）
# 跑的时候只填一个域名，其他自动生成：
#   chmod +x deploy_cdn_xhttp.sh
#   ./deploy_cdn_xhttp.sh
#
# 它会做这些事（按顺序）：
#   1. 装 Xray + Nginx（已有就跳过，不会把你现有的配置全删了）
#   2. 建一个 VLESS 入站：XHTTP + packet-up，监听本地 127.0.0.1:10000
#   3. Nginx 监听你选的端口（默认 8443，不用 443），TLS 证书默认自签，
#      把 /你的路径 转发给 Xray，把 /sub/ 用来挂订阅文件
#   4. 从 https://bestcf.pages.dev/wetest/ipv4.txt 拉优选 IP，
#      按运营商分组让你挑（电信 / 联通 / 移动）
#   5. 生成订阅文件 + 每个节点的二维码 + 订阅二维码
#
# 集中管理：所有可删的东西都在 /opt/cdnx/ 里
#   /opt/cdnx/node_info.txt   域名/UUID/路径/订阅地址存档
#   /opt/cdnx/links.txt       节点链接纯文本（Karing 可直接导入）
#   /opt/cdnx/sub/            订阅文件（Nginx alias 到 /sub/）
#   /opt/cdnx/qr/             节点二维码 + 订阅二维码
#   /opt/cdnx/ssl/            自签证书
#   /opt/cdnx/uninstall.sh    一键卸载（stop 服务 + 清配置 + 删本目录）
#   /opt/cdnx/update_ips.sh   每天自动更新优选 IP（非交互，只改订阅文件，
#                             不动 Xray/Nginx，不用重启任何服务）
#   系统侧只留三样：Xray 配置、Nginx 站点文件、cron 定时任务
#   （/etc/cron.d/cdnx-update，每天 04:00 跑 update_ips.sh），卸载脚本会一并清掉
#
# CF 端你还要手动做两步（脚本做不了 CF 后台的操作）：
#   A. 域名托管到 CF，DNS 加 A 记录：域名 -> VPS IP，打开橙云（Proxied）
#   B. SSL/TLS 选 Full（不是 Full Strict），因为源站默认是自签证书；
#      如果你已经在 CF 后台生成了 Origin Certificate 并放到 VPS 上，
#      再把 SSL 改回 Full (Strict)，并把证书路径填到脚本的 CERT_FILE 处
#
# 链路：Karing -> 优选 IP:你选的端口 (TLS, SNI=域名) -> CF 边缘 -> VPS Nginx -> Xray
#       客户端永远不直接碰 VPS IP，所以 VPS IP 的 TCP 被封也不影响这条路
# 注意：CF 免费代理只支持这几个 HTTPS 端口，客户端和源站必须用同一个端口，
#       CF 不会把 8443 转成 443：443、2053、2083、2087、2096、8443
#       bestcf 列表里写的 :443 只是它测速用的端口，IP 本身换到上面任一端口都能用
# ============================================================================
set -e

if [ "$(id -u)" != "0" ]; then
  echo "请用 root 运行：sudo ./deploy_cdn_xhttp.sh"
  exit 1
fi

BESTCF_URL="https://bestcf.pages.dev/wetest/ipv4.txt"
XRAY_PORT=10000
DEPLOY_DIR="/opt/cdnx"
SUB_DIR="$DEPLOY_DIR/sub"
QR_DIR="$DEPLOY_DIR/qr"
SSL_DIR="$DEPLOY_DIR/ssl"
INFO_FILE="$DEPLOY_DIR/node_info.txt"

echo "=== 独立部署：CDN + VLESS + XHTTP（不依赖 S-UI）==="
echo ""
read -r -p "CDN 域名（CF 里开橙云的那个，例如 cdn.example.com）： " DOMAIN
if [ -z "$DOMAIN" ]; then
  echo "域名不能为空，这是 SNI 和 Host，必须填。"
  exit 1
fi

# ---- 端口：不用 443，默认 8443；只能选 CF 支持的 HTTPS 端口 ----
while true; do
  read -r -p "CDN 端口（回车=8443，可选：443、2053、2083、2087、2096、8443）： " CDN_PORT
  CDN_PORT=${CDN_PORT:-8443}
  case "$CDN_PORT" in
    443|2053|2083|2087|2096|8443) break ;;
    *) echo "CF 不代理这个端口，换一个上面列表里的端口。" ;;
  esac
done
if ss -tln 2>/dev/null | grep -q ":$CDN_PORT "; then
  echo "警告：$CDN_PORT 端口在 VPS 上已经被占用了，Nginx 起不来，换一个端口再跑。"
  exit 1
fi
echo "用端口：$CDN_PORT（客户端、CF、源站 Nginx 都用这一个端口）"

# ---- UUID / 路径：如果已有 Xray 配置就复用，没有就自动生成 ----
UUID=""
XHTTP_PATH=""
XRAY_CONF="/usr/local/etc/xray/config.json"
if [ -f "$XRAY_CONF" ]; then
  OLD_UUID=$(python3 -c "import json,sys; d=json.load(open('$XRAY_CONF')); print(d['inbounds'][0]['settings']['clients'][0]['id'])" 2>/dev/null || true)
  OLD_PATH=$(python3 -c "import json,sys; d=json.load(open('$XRAY_CONF')); print(d['inbounds'][0]['streamSettings']['xhttpSettings']['path'])" 2>/dev/null || true)
  if [ -n "$OLD_UUID" ] && [ -n "$OLD_PATH" ]; then
    echo "检测到已有 Xray 配置：UUID=$OLD_UUID 路径=$OLD_PATH"
    read -r -p "复用它吗？回车=复用，输入 n=重新生成： " REUSE
    if [ "$REUSE" != "n" ]; then
      UUID="$OLD_UUID"
      XHTTP_PATH="$OLD_PATH"
    fi
  fi
fi
if [ -z "$UUID" ]; then
  UUID=$(cat /proc/sys/kernel/random/uuid)
  echo "自动生成 UUID：$UUID"
fi
if [ -z "$XHTTP_PATH" ]; then
  XHTTP_PATH="/$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  echo "自动生成 XHTTP 路径：$XHTTP_PATH"
fi

# ---- 装依赖 ----
echo ""
echo "[1/5] 装依赖：curl / nginx / qrencode / python3 ..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl nginx qrencode python3 openssl ca-certificates >/dev/null 2>&1 || apt-get install -y curl nginx qrencode python3 openssl ca-certificates

# ---- 装 Xray ----
if ! command -v xray >/dev/null 2>&1; then
  echo "[2/5] 装 Xray ..."
  bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
else
  echo "[2/5] Xray 已装，跳过"
fi

# ---- 写 Xray 配置（只监听本地，TLS 由 Nginx 做）----
echo "[3/5] 写 Xray 配置 ..."
mkdir -p /usr/local/etc/xray
if [ -f "$XRAY_CONF" ]; then
  cp "$XRAY_CONF" "$XRAY_CONF.bak.$(date +%Y%m%d%H%M%S)"
fi
cat > "$XRAY_CONF" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": $XRAY_PORT,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "$UUID", "flow": "" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "none",
        "xhttpSettings": {
          "path": "$XHTTP_PATH",
          "host": "$DOMAIN",
          "mode": "packet-up"
        }
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ]
}
EOF

# ---- 证书：默认自签（CF 选 Full 就行）；已有 Origin Cert 就手动替换这两个文件 ----
mkdir -p "$SSL_DIR"
if [ ! -f "$SSL_DIR/$DOMAIN.crt" ]; then
  echo "生成自签证书（CF 端请选 Full，不要选 Full Strict）..."
  openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout "$SSL_DIR/$DOMAIN.key" -out "$SSL_DIR/$DOMAIN.crt" \
    -subj "/CN=$DOMAIN" -addext "subjectAltName=DNS:$DOMAIN" 2>/dev/null
else
  echo "已有证书，复用 $SSL_DIR/$DOMAIN.crt（如果你换成了 CF Origin Cert，CF 端可改回 Full Strict）"
fi

# ---- 写 Nginx 配置 ----
echo "[4/5] 写 Nginx 配置 ..."
mkdir -p "$SUB_DIR"
cat > "/etc/nginx/sites-available/cdn-$DOMAIN" <<EOF
server {
    listen $CDN_PORT ssl;
    server_name $DOMAIN;
    ssl_certificate $SSL_DIR/$DOMAIN.crt;
    ssl_certificate_key $SSL_DIR/$DOMAIN.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    client_max_body_size 0;

    location $XHTTP_PATH {
        proxy_pass http://127.0.0.1:$XRAY_PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_buffering off;
        proxy_read_timeout 300s;
    }

    location /sub/ {
        alias $SUB_DIR/;
        add_header Cache-Control "no-store";
        autoindex off;
    }

    location / {
        return 404;
    }
}
EOF
ln -sf "/etc/nginx/sites-available/cdn-$DOMAIN" "/etc/nginx/sites-enabled/cdn-$DOMAIN"
# 删掉发行版自带的默认站点，避免以后切 443 时端口冲突
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl enable --now xray nginx >/dev/null 2>&1 || true
systemctl restart xray
systemctl reload nginx || systemctl restart nginx

# 防火墙：本脚本不做任何放行操作，由使用者自行在系统防火墙
# 和云平台安全组（甲骨文 OCI Security List / NSG）里放行 $CDN_PORT/tcp

# ---- 拉 bestcf 优选 IP，按运营商分组让你挑 ----
echo ""
echo "[5/5] 拉优选 IP：$BESTCF_URL"
curl -fsSL "$BESTCF_URL" -o /tmp/bestcf.txt || { echo "拉取失败，请检查 VPS 能不能访问这个站，或稍后再跑一次。"; exit 1; }
echo "这个站的格式是：IP:443#微测优选 | 运营商 | 地区 | IP"
echo "例如：104.17.113.19:443#微测优选 | 移动 | HKG | 104.17.113.19"
echo ""
echo "分组统计："
echo "  电信：$(grep -c '电信' /tmp/bestcf.txt || true) 条"
echo "  联通：$(grep -c '联通' /tmp/bestcf.txt || true) 条"
echo "  移动：$(grep -c '移动' /tmp/bestcf.txt || true) 条"
echo "  通用（WeTest）：$(grep -c 'WeTest' /tmp/bestcf.txt || true) 条"
echo ""
echo "你是哪家宽带？输入序号：1=电信 2=联通 3=移动 4=通用 5=全部"
read -r -p "选运营商： " ISP_CHOICE
case "$ISP_CHOICE" in
  1) grep '电信' /tmp/bestcf.txt | awk -F: '{print $1}' > /tmp/picked_group.txt ;;
  2) grep '联通' /tmp/bestcf.txt | awk -F: '{print $1}' > /tmp/picked_group.txt ;;
  3) grep '移动' /tmp/bestcf.txt | awk -F: '{print $1}' > /tmp/picked_group.txt ;;
  4) grep 'WeTest' /tmp/bestcf.txt | awk -F: '{print $1}' > /tmp/picked_group.txt ;;
  *) awk -F: '{print $1}' /tmp/bestcf.txt | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' > /tmp/picked_group.txt ;;
esac
# 去重
awk '!seen[$0]++' /tmp/picked_group.txt > /tmp/picked_unique.txt
mv /tmp/picked_unique.txt /tmp/picked_group.txt

echo ""
echo "这组里的 IP："
nl -w2 -s'. ' /tmp/picked_group.txt
echo ""
echo "挑法：直接回车 = 取前 5 个；输入序号如 1,3,5 = 只取这几个"
read -r -p "怎么挑： " PICK
SELECTED=""
if [ -z "$PICK" ]; then
  SELECTED=$(head -n 5 /tmp/picked_group.txt | tr '\n' ' ')
else
  for N in $(echo "$PICK" | tr ',' ' '); do
    IP=$(sed -n "${N}p" /tmp/picked_group.txt)
    if [ -n "$IP" ]; then SELECTED="$SELECTED $IP"; fi
  done
fi
if [ -z "$SELECTED" ]; then
  echo "没挑到 IP，退出。"
  exit 1
fi
echo "已挑：$SELECTED"

# ---- 存一份机器可读的配置，给每天自动更新 IP 的 update_ips.sh 用 ----
cat > "$DEPLOY_DIR/deploy.env" <<ENVEOF
DOMAIN=$DOMAIN
CDN_PORT=$CDN_PORT
UUID=$UUID
XHTTP_PATH=$XHTTP_PATH
ISP=${ISP_CHOICE:-5}
COUNT=5
BESTCF_URL=$BESTCF_URL
ENVEOF
chmod 600 "$DEPLOY_DIR/deploy.env"

# ---- 生成订阅 + 二维码（Python，只做拼链接，不依赖 S-UI）----
# token 只生成一次、之后复用，这样以后更新优选 IP 时订阅地址不变，
# Karing 点更新订阅就能拉到新 IP，不用每次都重新填地址
TOKEN_FILE="$DEPLOY_DIR/sub_token.txt"
if [ -f "$TOKEN_FILE" ]; then
  TOKEN=$(cat "$TOKEN_FILE")
else
  TOKEN=$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')
  echo "$TOKEN" > "$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE"
fi
export DOMAIN UUID XHTTP_PATH SELECTED TOKEN SUB_DIR CDN_PORT DEPLOY_DIR
python3 <<'PYEOF'
import base64, json, os, urllib.parse
domain = os.environ["DOMAIN"]
uid = os.environ["UUID"]
path = os.environ["XHTTP_PATH"]
port = os.environ["CDN_PORT"]
ips = os.environ["SELECTED"].split()
token = os.environ["TOKEN"]
sub_dir = os.environ["SUB_DIR"]
os.makedirs(sub_dir, exist_ok=True)
links = []
for i, ip in enumerate(ips, 1):
    extra = json.dumps({"mode": "packet-up", "path": path, "host": domain}, separators=(",", ":"))
    params = {
        "encryption": "none", "security": "tls", "sni": domain, "fp": "chrome",
        "alpn": "h2,http/1.1", "type": "xhttp", "host": domain,
        "path": path, "mode": "packet-up", "extra": extra,
    }
    q = urllib.parse.urlencode(params, safe="")
    name = f"CF-XHTTP-{i}-{ip}"
    links.append(f"vless://{uid}@{ip}:{port}?{q}#{urllib.parse.quote(name)}")
sub_txt = "\n".join(links) + "\n"
open(os.path.join(sub_dir, f"sub_{token}.txt"), "w", encoding="utf-8").write(sub_txt)
open(os.path.join(sub_dir, f"sub_{token}_base64.txt"), "w", encoding="utf-8").write(
    base64.b64encode(sub_txt.encode("utf-8")).decode("ascii"))
open(os.path.join(os.environ["DEPLOY_DIR"], "links.txt"), "w", encoding="utf-8").write(sub_txt)
print("\n".join(links))
PYEOF

# 二维码：每个节点一张 + 订阅地址一张
# 注意：订阅地址也要带端口，不然 Karing 默认走 443 拉订阅，而 Nginx 根本没监听 443
if [ "$CDN_PORT" = "443" ]; then
  SUB_URL="https://$DOMAIN/sub/sub_${TOKEN}_base64.txt"
else
  SUB_URL="https://$DOMAIN:$CDN_PORT/sub/sub_${TOKEN}_base64.txt"
fi
mkdir -p "$QR_DIR"
i=0
while IFS= read -r LINK; do
  i=$((i+1))
  qrencode -o "$QR_DIR/node_${i}.png" -s 8 "$LINK" 2>/dev/null || true
done < "$SUB_DIR/sub_${TOKEN}.txt"
qrencode -o "$QR_DIR/sub_qr.png" -s 8 "$SUB_URL" 2>/dev/null || true

# ---- 生成每天自动更新优选 IP 的脚本（非交互，挂 cron / 1Panel 定时任务都行）----
cat > "$DEPLOY_DIR/update_ips.sh" <<'UIPS'
#!/usr/bin/env bash
# 自动更新优选 IP：只改订阅文件和二维码，不动 Xray/Nginx，无需重启任何服务
set -e
DEPLOY_DIR="/opt/cdnx"
[ -f "$DEPLOY_DIR/deploy.env" ] || { echo "找不到 deploy.env，请先跑部署脚本"; exit 1; }
source "$DEPLOY_DIR/deploy.env"
[ -f "$DEPLOY_DIR/sub_token.txt" ] || { echo "找不到 sub_token.txt，请先跑部署脚本"; exit 1; }
TOKEN=$(cat "$DEPLOY_DIR/sub_token.txt")
SUB_DIR="$DEPLOY_DIR/sub"
QR_DIR="$DEPLOY_DIR/qr"
mkdir -p "$SUB_DIR" "$QR_DIR"

TMP=$(mktemp)
trap 'rm -f "$TMP" "$TMP.picked" "$TMP.picked2"' EXIT
curl -fsSL "$BESTCF_URL" -o "$TMP" || { echo "拉取优选 IP 失败"; exit 1; }

case "$ISP" in
  1) grep '电信' "$TMP" | awk -F: '{print $1}' > "$TMP.picked" ;;
  2) grep '联通' "$TMP" | awk -F: '{print $1}' > "$TMP.picked" ;;
  3) grep '移动' "$TMP" | awk -F: '{print $1}' > "$TMP.picked" ;;
  4) grep 'WeTest' "$TMP" | awk -F: '{print $1}' > "$TMP.picked" ;;
  *) awk -F: '{print $1}' "$TMP" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' > "$TMP.picked" ;;
esac
if [ ! -s "$TMP.picked" ]; then echo "这个分组没拿到 IP，本次跳过"; exit 1; fi
awk '!seen[$0]++' "$TMP.picked" | head -n "${COUNT:-5}" > "$TMP.picked2"
mv "$TMP.picked2" "$TMP.picked"
SELECTED=$(tr '\n' ' ' < "$TMP.picked")

export DOMAIN UUID XHTTP_PATH CDN_PORT DEPLOY_DIR SELECTED TOKEN
python3 <<'PYEOF'
import base64, json, os, urllib.parse
domain = os.environ["DOMAIN"]
uid = os.environ["UUID"]
path = os.environ["XHTTP_PATH"]
port = os.environ["CDN_PORT"]
ips = os.environ["SELECTED"].split()
token = os.environ["TOKEN"]
deploy_dir = os.environ["DEPLOY_DIR"]
sub_dir = os.path.join(deploy_dir, "sub")
links = []
for i, ip in enumerate(ips, 1):
    extra = json.dumps({"mode": "packet-up", "path": path, "host": domain}, separators=(",", ":"))
    params = {
        "encryption": "none", "security": "tls", "sni": domain, "fp": "chrome",
        "alpn": "h2,http/1.1", "type": "xhttp", "host": domain,
        "path": path, "mode": "packet-up", "extra": extra,
    }
    q = urllib.parse.urlencode(params, safe="")
    name = f"CF-XHTTP-{i}-{ip}"
    links.append(f"vless://{uid}@{ip}:{port}?{q}#{urllib.parse.quote(name)}")
sub_txt = "\n".join(links) + "\n"
open(os.path.join(sub_dir, f"sub_{token}.txt"), "w", encoding="utf-8").write(sub_txt)
open(os.path.join(sub_dir, f"sub_{token}_base64.txt"), "w", encoding="utf-8").write(
    base64.b64encode(sub_txt.encode("utf-8")).decode("ascii"))
open(os.path.join(deploy_dir, "links.txt"), "w", encoding="utf-8").write(sub_txt)
PYEOF

# 重新生成节点二维码（订阅地址没变，sub_qr 不用动）
i=0
while IFS= read -r LINK; do
  i=$((i+1))
  qrencode -o "$QR_DIR/node_${i}.png" -s 8 "$LINK" 2>/dev/null || true
done < "$SUB_DIR/sub_${TOKEN}.txt"

# 刷新存档里的优选 IP 一行
if [ -f "$DEPLOY_DIR/node_info.txt" ]; then
  sed -i "s|^优选 IP：.*|优选 IP：$SELECTED|" "$DEPLOY_DIR/node_info.txt"
fi
echo "$(date '+%F %T') 优选 IP 已更新：$SELECTED"
UIPS
chmod +x "$DEPLOY_DIR/update_ips.sh"

# ---- 注册系统 cron：每天凌晨 4 点自动更新（不依赖 1Panel）----
cat > /etc/cron.d/cdnx-update <<CRONEOF
0 4 * * * root $DEPLOY_DIR/update_ips.sh >> /var/log/cdnx_update.log 2>&1
CRONEOF
chmod 644 /etc/cron.d/cdnx-update
systemctl enable --now cron >/dev/null 2>&1 || true

# ---- 生成一键卸载脚本（清配置 + 删 /opt/cdnx，可选 purge 软件包）----
cat > "$DEPLOY_DIR/uninstall.sh" <<'UNINST'
#!/usr/bin/env bash
# 一键卸载：清掉本次部署产生的所有东西
set -e
if [ "$(id -u)" != "0" ]; then echo "请用 root 运行"; exit 1; fi
echo "=== 卸载 CDN VLESS 部署 ==="
echo "将删除：Xray 配置、本次部署的 Nginx 站点配置、cron 定时任务、/opt/cdnx 整个目录"
read -r -p "软件包（xray / qrencode）也用 apt purge 删掉吗？y=删 n=只清配置 [n]： " PURGE
PURGE=${PURGE:-n}
systemctl stop xray 2>/dev/null || true
systemctl disable xray 2>/dev/null || true
rm -f /usr/local/etc/xray/config.json
rm -f /etc/cron.d/cdnx-update /var/log/cdnx_update.log
rm -f /etc/nginx/sites-enabled/cdn-* /etc/nginx/sites-available/cdn-*
if command -v nginx >/dev/null 2>&1; then
  nginx -t 2>/dev/null && systemctl reload nginx || systemctl stop nginx || true
fi
if [ "$PURGE" = "y" ]; then
  apt-get purge -y xray qrencode || true
  apt-get autoremove -y || true
fi
cd /
rm -rf /opt/cdnx
echo "=== 卸载完成，系统已无残留 ==="
UNINST
chmod +x "$DEPLOY_DIR/uninstall.sh"

# 私有信息存档（不要把这个文件挂到 Nginx 上）
cat > "$INFO_FILE" <<EOF
域名：$DOMAIN
端口：$CDN_PORT
UUID：$UUID
XHTTP 路径：$XHTTP_PATH
优选 IP：$SELECTED
订阅地址：$SUB_URL
订阅文件：$SUB_DIR/sub_${TOKEN}_base64.txt
节点链接：$DEPLOY_DIR/links.txt
节点二维码：$QR_DIR/node_*.png
订阅二维码：$QR_DIR/sub_qr.png
定时更新：每天 04:00 自动换优选 IP（cron：/etc/cron.d/cdnx-update）
卸载脚本：$DEPLOY_DIR/uninstall.sh
EOF

echo ""
echo "=== 完成 ==="
echo "域名：$DOMAIN"
echo "端口：$CDN_PORT"
echo "UUID：$UUID"
echo "路径：$XHTTP_PATH"
echo "优选 IP：$SELECTED"
echo "订阅地址：$SUB_URL"
echo "订阅二维码：$QR_DIR/sub_qr.png"
echo "节点二维码：$QR_DIR/node_*.png"
echo "节点链接：$DEPLOY_DIR/links.txt"
echo "私有信息已存到：$INFO_FILE（别公开这个文件）"
echo "以后不想用了：bash $DEPLOY_DIR/uninstall.sh 一键卸载"
echo ""
echo "定时更新：每天 04:00 由系统 cron 自动跑 $DEPLOY_DIR/update_ips.sh"
echo "  更新只改订阅文件，不用重启 Xray；Karing 点「更新订阅」就能拿到新 IP"
echo "  日志：/var/log/cdnx_update.log；手动立刻更新：bash $DEPLOY_DIR/update_ips.sh"
echo ""
echo "CF 端还没做的两步（必须做，不然客户端连不上）："
echo "  1. DNS：$DOMAIN 的 A 记录 -> VPS IP，打开橙云（Proxied）"
echo "  2. SSL/TLS：选 Full（自签证书）；如果你换成了 CF Origin Cert，再改回 Full (Strict)"
echo ""
echo "Karing 里：先扫 $QR_DIR/node_*.png 直接导入单个节点测通，"
echo "通了再用上面的订阅地址做长期更新。"
