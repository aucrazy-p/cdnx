# cdnx

CDN + VLESS + XHTTP 一键部署脚本。流量走 Cloudflare 橙云中转，客户端不直接接触 VPS IP。

链路：`客户端 -> 优选 CF IP:8443 (TLS) -> CF 边缘 -> VPS Nginx -> Xray`

## 一键安装

VPS 上以 root 运行（Debian / Ubuntu）：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/aucrazy-p/cdnx/main/install.sh)
```

安装过程会交互式询问：

1. CDN 域名（CF 里开了橙云代理的 A 记录）
2. 端口（回车默认 8443，可选 443 / 2053 / 2083 / 2087 / 2096 / 8443）
3. 宽带运营商（用于挑选优选 IP 分组）

脚本自动完成：装 Xray + Nginx、生成 UUID 和随机路径、自签证书、写配置、拉优选 IP 生成订阅和二维码。

**已经部署过的机器再跑这条命令，不会重新安装，而是直接进入管理菜单。** 想改域名 / 端口 / 重挑 IP，在菜单里选「重新运行部署向导」即可，UUID 和订阅地址自动复用，客户端不受影响。

## 安装后还需手动做

- **CF 后台**：DNS 添加 A 记录指向 VPS IP，打开橙云（Proxied）
- **CF 后台**：SSL/TLS 模式选 **Full**（源站为自签证书，不要选 Full Strict）
- **云平台安全组**：放行所选端口的 TCP 入站

## 文件位置

所有可管理文件集中在 `/opt/cdnx/`：

```
/opt/cdnx/
├── node_info.txt    # 域名 / UUID / 路径 / 订阅地址存档
├── links.txt        # 节点链接纯文本
├── sub/             # 订阅文件（Nginx 挂在 /sub/ 路径）
├── qr/              # 节点二维码 + 订阅二维码
├── ssl/             # 自签证书
├── deploy.env       # 运行时配置（自动更新用）
├── update_ips.sh    # 手动立即更新优选 IP
└── uninstall.sh     # 一键卸载
```

系统侧另有：`/usr/local/etc/xray/config.json`、`/etc/nginx/sites-*/cdn-*`、`/etc/cron.d/cdnx-update`。

## 客户端使用

扫 `/opt/cdnx/qr/` 下的订阅二维码导入，或直接把 `node_info.txt` 里的订阅地址填进客户端。之后优选 IP 变化无需重新添加，客户端点「更新订阅」即可。

## 优选 IP 自动更新

每天 04:00 由系统 cron 自动运行 `update_ips.sh`，更换订阅里的优选 IP。只改订阅文件，不重启 Xray / Nginx。日志：`/var/log/cdnx_update.log`。

手动立即更新：

```bash
bash /opt/cdnx/update_ips.sh
```

## 切换运营商

换了宽带或网络环境需要换 IP 来源时，用交互菜单：

```bash
bash /opt/cdnx/menu.sh
```

菜单里选运营商（电信 / 联通 / 移动 / 通用 / 全部）后立即按新运营商更新一批 IP，并作为之后每日自动更新的默认值。菜单里还可以手动触发更新、查看当前 IP 和最近日志。

## 卸载

```bash
bash /opt/cdnx/uninstall.sh
```

清掉 Xray 配置、Nginx 站点、cron 任务和 `/opt/cdnx/` 整个目录，可选连同软件包一起 purge。
