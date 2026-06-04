# Pi-hole Unbound Sentinel

一款面向 Pi-hole v6 的单容器 DNS 镜像：在官方 `pihole/pihole` 镜像基础上加入 Unbound 递归解析器，并用轻量级 Sentinel Loop 负责进程守护。它适合希望保留官方 Pi-hole 容器启动逻辑，又想内置本地递归 DNS、DNSSEC 强校验和自动化发布链的家庭实验室与小型网络。

当前基础镜像固定为：

```text
pihole/pihole:2026.05.0
```

## 特性

- 基于官方 Pi-hole v6 Docker 镜像构建。
- 内置 Unbound，监听 `127.0.0.1:5335`，避免与 Pi-hole 的 `53` 端口冲突。
- 每次容器启动都会运行 `unbound-anchor` 更新 DNSSEC 根信任锚。
- 自定义入口脚本启动 Unbound 后运行后台 Sentinel Loop，每 5 秒检测一次，异常退出会自动拉起。
- 入口脚本最后使用 `exec start.sh` 将 PID 1 交给官方 Pi-hole 启动脚本，保留官方信号处理、日志与停机行为。
- 默认启用 DNSSEC、缓存预取、QNAME minimisation，并将 EDNS UDP 报文限制为 `1232` 字节。
- 显式安装 Alpine 的 `dns-root-hints` 与 `dnssec-root`，确保递归根提示和 DNSSEC 初始信任锚在离线/受限启动场景下也可用。
- 提供 Docker Compose、冒烟测试脚本、GitHub Actions 多架构 GHCR 发布、Cosign 签名和 GitHub Release 自动化。

## 架构

容器启动流程很短：

```text
pihole-unbound-entrypoint.sh
  -> unbound-anchor -a /var/lib/unbound/root.key
  -> unbound-checkconf /etc/unbound/unbound.conf
  -> unbound -d -c /etc/unbound/unbound.conf &
  -> sentinel_loop &
  -> exec start.sh
```

Sentinel Loop 是一个简单的后台循环，默认每 `5` 秒执行一次 `pgrep -x unbound`。如果 Unbound 进程不存在，它会重新校验配置并启动 Unbound。这个设计避免引入 systemd、supervisord 之类的重量级进程管理器。

优雅停机由官方 Pi-hole v6 容器入口 `start.sh` 负责。我们的脚本在完成 Unbound 初始化后执行 `exec start.sh "$@"`，所以 PID 1 会被替换为官方启动进程，Docker 发送的 `SIGTERM` 能按 Pi-hole 官方路径处理。

## 快速开始

先把示例镜像名替换成你的 GHCR 仓库，例如：

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

打开管理界面：

```text
http://<host-ip>/admin/
```

注意：本项目面向 Pi-hole v6+，请使用 `FTLCONF_` 前缀配置。不要再使用 v5 时代的 `WEBPASSWORD`、`PIHOLE_DNS_` 等变量。

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

默认配置将 `do-ip6` 设为 `no`，这是为了兼容 CI、NAS、家庭路由器等常见 Docker 环境中没有原生 IPv6 出口的情况。如果你的宿主机具备稳定原生 IPv6，可以通过挂载自定义配置开启 IPv6。

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

如果你要完全替换主配置，可以挂载到 `/etc/unbound/unbound.conf`，但需要保留 `127.0.0.1:5335`、`auto-trust-anchor-file` 和 EDNS 限制等关键项。

## 本地构建

```bash
docker build -f docker/Dockerfile -t my-pihole-unbound:local .
```

基础 Pi-hole 版本来自 [docker/Dockerfile](./docker/Dockerfile)：

```dockerfile
ARG PIHOLE_VERSION=2026.05.0
```

发布工作流会自动读取这个值并生成同名镜像 tag。

## 冒烟测试

脚本位于 [tests/smoke-test.sh](./tests/smoke-test.sh)，支持传入任意镜像 tag：

```bash
bash tests/smoke-test.sh my-pihole-unbound:local
```

测试会执行以下步骤：

- 启动临时测试容器。
- 循环等待 DNS 和 Web 管理界面就绪。
- 使用 `pgrep` 验证 `unbound` 与 `pihole-FTL` 同时运行。
- 在容器内使用 `dig +dnssec @127.0.0.1 cloudflare.com A` 发起递归解析。
- 严格验证响应状态为 `NOERROR`，包含 DNSSEC `ad` 标志和 `RRSIG` 记录。
- 退出时自动清理容器。

可通过环境变量调整本地端口：

```bash
SMOKE_DNS_PORT=1054 SMOKE_WEB_PORT=8081 bash tests/smoke-test.sh my-pihole-unbound:local
```

## 发布流程

[.github/workflows/release.yml](./.github/workflows/release.yml) 只发布到 GHCR：

- 触发条件：合并到 `main` 且 `docker/**` 变化，或手动 `workflow_dispatch`。
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
│   ├── entrypoint.sh
│   └── unbound/unbound.conf
├── tests/smoke-test.sh
├── compose.yaml
├── .dockerignore
├── .gitignore
├── LICENSE
└── README.md
```

## 安全说明

默认配置只允许 Unbound 从 `127.0.0.1` 与 `::1` 接收查询，外部客户端只能访问 Pi-hole 的 `53` 端口。Unbound 会过滤 RFC1918、link-local 和 ULA 私有地址段，减少递归解析泄露内网地址的风险。

## 参考

- [Pi-hole Docker releases](https://github.com/pi-hole/docker-pi-hole/releases)
- [Pi-hole Docker v6 configuration](https://docs.pi-hole.net/docker/configuration/)
- [Pi-hole v5 to v6 environment migration](https://docs.pi-hole.net/docker/upgrading/v5-v6/)
