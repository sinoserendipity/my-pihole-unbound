# Pi-hole Unbound s6

一个面向 Pi-hole v6 的单容器 DNS 镜像：基于官方 `pihole/pihole` 镜像，内置 Unbound 递归解析器，并使用 s6-overlay 作为 PID 1 管理 `pihole-FTL` 与 `unbound` 两个长期进程。

当前基础镜像固定为：

```text
pihole/pihole:2026.05.0
```

## 特性

- 基于官方 Pi-hole v6 Docker 镜像构建。
- 使用 s6-overlay 监督 `pihole` 与 `unbound` 两个 longrun 服务。
- Unbound 监听 `127.0.0.1:5335`，避免与 Pi-hole 的 `53` 端口冲突。
- 每次容器启动都会运行 `unbound-anchor` 更新 DNSSEC 根信任锚。
- 显式安装 Alpine 的 `dns-root-hints` 与 `dnssec-root`，提升受限网络启动场景下的 DNSSEC 稳定性。
- 默认启用 DNSSEC、缓存预取、QNAME minimisation，并将 EDNS UDP 报文限制为 `1232` 字节。
- 提供 Docker Compose、冒烟测试脚本、GitHub Actions 多架构 GHCR 发布、Cosign 签名和 GitHub Release 自动化。

## 架构

容器使用 s6-overlay 的 `cont-init.d` 和 `services.d`：

```text
/init
  -> /etc/cont-init.d/10-unbound-anchor
       -> bootstrap /var/lib/unbound/root.key
       -> unbound-anchor -a /var/lib/unbound/root.key
  -> /etc/services.d/unbound/run
       -> unbound-checkconf /etc/unbound/unbound.conf
       -> exec unbound -d -c /etc/unbound/unbound.conf
  -> /etc/services.d/pihole/run
       -> exec start.sh
```

s6-overlay 作为 PID 1 负责信号处理、子进程回收和 longrun 服务监督。如果 `unbound` 或 `pihole` 进程异常退出，s6 会自动重新拉起对应服务。这个方案比后台 shell loop 更标准，也比 systemd/supervisord 更轻。

## 快速开始

把示例镜像名替换成你的 GHCR 仓库：

```yaml
services:
  pihole:
    image: ghcr.io/username/my-pihole-unbound:latest
    container_name: pihole-unbound
    hostname: pihole
    restart: unless-stopped
    ports:
      - "53:53/tcp"
      - "53:53/udp"
      - "80:80/tcp"
      - "443:443/tcp"
    environment:
      TZ: "America/New_York"
      FTLCONF_dns_upstreams: "127.0.0.1#5335"
      FTLCONF_webserver_api_password: "change-this-password"
      FTLCONF_dns_dnssec: "true"
      FTLCONF_dns_listeningMode: "all"
    volumes:
      - ./data/etc-pihole:/etc/pihole
      - ./data/unbound:/etc/unbound/unbound.conf.d:ro
    cap_add:
      - NET_ADMIN
```

启动：

```bash
docker compose up -d
docker compose logs -f pihole
```

管理界面：

```text
http://<host-ip>/admin/
```

本项目面向 Pi-hole v6+，请使用 `FTLCONF_` 前缀配置。不要使用 v5 时代的 `WEBPASSWORD`、`PIHOLE_DNS_` 等变量。

## DNS 配置

Pi-hole 通过下面的 v6 配置把上游 DNS 指向本机 Unbound：

```yaml
FTLCONF_dns_upstreams: "127.0.0.1#5335"
FTLCONF_dns_dnssec: "true"
```

Unbound 默认配置位于 [docker/unbound/unbound.conf](./docker/unbound/unbound.conf)，核心参数包括：

```text
interface: 127.0.0.1
port: 5335
do-ip4: yes
do-ip6: no
root-hints: "/usr/share/dns-root-hints/named.root"
harden-dnssec-stripped: yes
prefetch: yes
prefetch-key: yes
use-caps-for-id: no
edns-buffer-size: 1232
max-udp-size: 1232
```

Dnsmasq/FTL 侧的 EDNS 限制位于 [docker/dnsmasq.d/99-edns.conf](./docker/dnsmasq.d/99-edns.conf)：

```text
edns-packet-max=1232
```

`1232` 字节通常可减少 UDP DNS 响应在 IPv6/现代网络路径中的分片概率，从而降低解析失败风险。

默认配置将 `do-ip6` 设为 `no`，这是为了兼容 CI、NAS、家庭路由器等常见 Docker 环境中没有原生 IPv6 出口的情况。如果宿主机具备稳定原生 IPv6，可以通过挂载自定义 Unbound 配置开启 IPv6。

默认 Compose 示例不挂载 `/etc/dnsmasq.d`，这样镜像内置的 `99-edns.conf` 不会被空目录遮盖。如果确实需要挂载该目录，请确保宿主机目录里也包含同等配置。

## 自定义 Unbound

推荐只挂载追加配置到 `/etc/unbound/unbound.conf.d`：

```yaml
volumes:
  - ./data/unbound:/etc/unbound/unbound.conf.d:ro
```

例如创建 `./data/unbound/10-local-zone.conf`：

```text
server:
  local-zone: "lan." static
```

如果要完全替换主配置，可以挂载到 `/etc/unbound/unbound.conf`，但需要保留 `127.0.0.1:5335`、`auto-trust-anchor-file` 和 EDNS 限制等关键项。

## 本地构建

```bash
docker build -f docker/Dockerfile -t my-pihole-unbound:local .
```

基础 Pi-hole 版本来自 [docker/Dockerfile](./docker/Dockerfile)：

```dockerfile
ARG PIHOLE_VERSION=2026.05.0
```

s6-overlay 版本同样在 Dockerfile 中固定：

```dockerfile
ARG S6_OVERLAY_VERSION=3.2.3.0
```

## 冒烟测试

脚本位于 [tests/smoke-test.sh](./tests/smoke-test.sh)，支持传入任意镜像 tag：

```bash
bash tests/smoke-test.sh my-pihole-unbound:local
```

测试会执行：

- 启动临时测试容器。
- 等待 DNS 和 Web 管理界面就绪。
- 使用 `pgrep` 验证 `unbound` 与 `pihole-FTL` 同时运行。
- 使用 `dig +dnssec +adflag @127.0.0.1 dnssec.works A` 验证递归 DNSSEC。
- 验证响应为 `NOERROR`，包含 DNSSEC `ad` 标志和 `RRSIG` 记录。
- 退出时自动清理容器。

可通过环境变量调整本地端口：

```bash
SMOKE_DNS_PORT=1054 SMOKE_WEB_PORT=8081 bash tests/smoke-test.sh my-pihole-unbound:local
```

## 发布流程

[.github/workflows/release.yml](./.github/workflows/release.yml) 只发布到 GHCR，并且自动发布只会在 CI 成功后运行：

- `CI` 成功后通过 `workflow_run` 触发 Release。
- 也可以手动 `workflow_dispatch` 发布。
- 自动读取 `ARG PIHOLE_VERSION` 作为发布 tag。
- 使用 Buildx 构建 `linux/amd64`、`linux/arm64`、`linux/arm/v7`。
- 推送到 `ghcr.io/<owner>/<repo>:<PIHOLE_VERSION>` 和 `:latest`。
- 使用 Sigstore Cosign keyless 模式递归签名镜像。
- 自动创建 GitHub Release，并写入 GHCR 拉取命令。

## 文件结构

```text
.
├── .github/workflows/
│   ├── ci.yml
│   └── release.yml
├── docker/
│   ├── Dockerfile
│   ├── dnsmasq.d/99-edns.conf
│   ├── root/
│   │   └── etc/
│   │       ├── cont-init.d/10-unbound-anchor
│   │       └── services.d/
│   │           ├── pihole/run
│   │           └── unbound/run
│   └── unbound/unbound.conf
├── tests/smoke-test.sh
├── compose.yaml
├── .dockerignore
├── .gitattributes
├── .gitignore
├── LICENSE
└── README.md
```

## 安全说明

默认配置只允许 Unbound 从 `127.0.0.1` 接收查询，外部客户端只能访问 Pi-hole 的 `53` 端口。Unbound 会过滤 RFC1918、link-local 和 ULA 私有地址段，减少递归解析泄露内网地址的风险。

## 参考

- [Pi-hole Docker releases](https://github.com/pi-hole/docker-pi-hole/releases)
- [Pi-hole Docker v6 configuration](https://docs.pi-hole.net/docker/configuration/)
- [Pi-hole v5 to v6 environment migration](https://docs.pi-hole.net/docker/upgrading/v5-v6/)
- [s6-overlay](https://github.com/just-containers/s6-overlay)
