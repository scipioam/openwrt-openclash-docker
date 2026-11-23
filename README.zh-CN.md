# openwrt-openclash-docker

[English](README.md)

通过 Docker Compose 在现有局域网中运行 OpenWrt + OpenClash，并将其作为一个**可选择使用的 IPv4 网关**。

OpenWrt 容器通过 `macvlan` 直接加入局域网并拥有独立 IP。只有显式将该 IP 设置为 IPv4 网关的客户端才会经过 OpenWrt/OpenClash；其他局域网客户端继续使用原有上游网关。

仓库同时提供基于 OpenWrt 官方 release rootfs 和版本化 OpenClash 软件包的可重复构建、更新与回滚流程。

> [!IMPORTANT]
> 本仓库是独立部署项目，并非 OpenWrt、OpenClash 或 Mihomo 官方项目。

## 主要特性

- 在 Linux 上通过 Docker Compose 运行 OpenWrt
- 单臂 `macvlan` 拓扑，OpenWrt 拥有独立局域网 IP
- 选择性路由，不需要替换现有局域网上游网关
- OpenClash 预装到版本化本地镜像
- Mihomo Core 与镜像生命周期分离并持久化
- 自动校验 OpenWrt 官方 rootfs SHA256
- GitHub 提供 asset digest 时自动校验 OpenClash APK SHA256
- OpenWrt/OpenClash 独立固定版本，便于回滚
- `/etc/config` 与 `/etc/openclash` 使用持久化 volume
- 可选 host-side macvlan shim，解决宿主机无法直接访问 OpenWrt 的问题
- 镜像构建与实际部署有意分离

## 网络架构

```text
                     现有局域网

                     上游网关
                 例如 192.168.0.1
                         |
           +-------------+-------------+
           |                           |
       普通客户端                    Docker 宿主机
       GW = 上游网关                 例如 .0.201
                                       |
                                     物理网卡
                                    例如 enp1s0
                                       |
                                    macvlan
                                       |
                                  OpenWrt .250
                                       |
                                   OpenClash
                                       ^
                                       |
                                    指定客户端
                                   GW = OpenWrt
```

OpenWrt 在这个单臂拓扑中负责同接口转发和 IPv4 masquerade/NAT。

OpenWrt 容器拥有独立 network namespace，因此 OpenClash 的 TUN、策略路由和 nftables 规则与宿主机常规网络配置相互隔离；但与所有 Docker 容器一样，它仍然共享 Linux 宿主机内核。

## 仓库结构

```text
.
├── .env.example              # 提交到仓库的配置模板
├── .env                      # 本地运行配置，由 .env.example 复制生成
├── .dockerignore
├── compose.yml
├── Dockerfile
├── init-openwrt.sh
├── update-openwrt-image.sh
├── install-host-shim.sh
├── backups/
│   └── bootstrap/
│       └── clash_meta          # 可选，本地 Mihomo 初始 Core
├── build/                      # 构建过程生成
└── downloads/                  # 下载缓存
```

| 文件 | 用途 |
|---|---|
| `.env.example` | 提交到仓库的 OpenWrt/OpenClash 版本与局域网参数模板 |
| `.env` | 由 `.env.example` 复制生成的本地运行配置，应保持未跟踪状态 |
| `compose.yml` | 容器、macvlan、volume、TUN 与 sysctl 配置 |
| `Dockerfile` | 构建最终 OpenWrt + OpenClash 镜像 |
| `update-openwrt-image.sh` | 下载、校验、构建并验证版本化镜像 |
| `init-openwrt.sh` | 保证 LAN、DHCP/RA、NAT 配置并初始化可选 Core |
| `install-host-shim.sh` | 通过 systemd 安装持久化 host-side macvlan shim |

## 环境要求

当前实现主要面向：

- Linux 宿主机；主要验证环境为 Ubuntu 24.04
- Docker Engine + Docker Compose v2
- `x86_64` / `amd64`
- 可作为 Docker `macvlan` parent 的有线网卡
- 已存在的 IPv4 局域网和上游网关
- 宿主机内核支持 TUN、nftables、策略路由和 TPROXY

构建脚本还依赖 `curl`、`sha256sum`、`awk`、`sed`、`grep`、`sort`、`python3` 等常见工具。

> [!WARNING]
> OpenWrt 容器使用 `privileged: true` 并访问 `/dev/net/tun`。应将其视为网络基础设施，不要在容器中运行不可信程序。

## 网络配置

仓库提供 `.env.example` 作为配置模板，其中包含类似下面的示例参数：

```dotenv
OPENWRT_VERSION=25.12.6
OPENCLASH_VERSION=0.48.002

OPENWRT_IP=192.168.0.250
OPENWRT_GATEWAY=192.168.0.1
OPENWRT_HOST_SHIM_IP=192.168.0.249
```

`compose.yml` 中还包含局域网参数：

```yaml
parent: enp1s0
subnet: 192.168.0.0/24
ip_range: 192.168.0.248/29
gateway: 192.168.0.1
```

**如果这些值与你的实际局域网不一致，首次部署前必须修改。**

如果物理网卡不是 `enp1s0`，需要同时修改：

- `compose.yml`
- `install-host-shim.sh`

建议将 OpenWrt IP 和 host shim IP 排除在上游 DHCP 动态地址池之外，或者在 DHCP 服务端明确保留。


> [!NOTE]
> `.env.example` 是公开提交到仓库的配置模板；实际运行使用的 `.env` 与具体机器环境相关，应保持未跟踪状态（通常通过 `.gitignore` 排除）。

## 选择性路由方式

本项目**不会**在现有局域网里启动第二套 DHCP 服务。

`init-openwrt.sh` 会保证：

- OpenWrt LAN 使用静态地址
- DHCP Server 关闭
- DHCPv6 关闭
- IPv6 RA 关闭
- LAN 转发开启
- IPv4 masquerade 开启

普通客户端：

```text
Gateway: 上游网关
```

指定客户端：

```text
Gateway: OpenWrt IP
DNS:     OpenWrt IP    # 使用 OpenClash DNS 处理时建议如此设置
```

其他局域网客户端不需要修改路由配置。

## 快速部署

### 1. 克隆仓库

```bash
git clone <repository-url>
cd openwrt-openclash-docker
```

### 2. 创建本地环境配置并设置局域网参数

先从仓库中的模板创建本地运行配置：

```bash
cp .env.example .env
```

然后编辑 `.env` 和 `compose.yml` 中的 `openwrt_lan`。

至少确认：

- 物理网卡
- subnet
- 上游网关
- OpenWrt IP
- host shim IP
- `ip_range`

### 3. 可选：提供 Mihomo Bootstrap Core

如果已经拥有经过验证的 `amd64` Mihomo Core，可放到：

```text
backups/bootstrap/clash_meta
```

并赋予执行权限：

```bash
chmod 0755 backups/bootstrap/clash_meta
```

当 `openclash_data` volume 第一次为空时，它会被复制到：

```text
/etc/openclash/core/clash_meta
```

如果持久化 volume 中已经存在 Core，则 bootstrap 文件不会覆盖它。

该文件并非必须，也可以在 OpenClash 启动后自行安装/更新 Core。

> [!NOTE]
> 对于公开 GitHub 仓库，通常不建议提交 Mihomo 二进制文件本身。建议只在本地保留 `backups/bootstrap/clash_meta`，并从上游渠道获取 Core。

### 4. 检查 TUN

```bash
ls -l /dev/net/tun
```

如果相关能力以可加载模块提供，可视内核情况执行：

```bash
sudo modprobe tun
sudo modprobe nft_tproxy
sudo modprobe nf_tproxy_ipv4
```

不同内核的模块名称以及内建/模块状态可能不同。

### 5. 构建镜像

```bash
chmod +x update-openwrt-image.sh init-openwrt.sh install-host-shim.sh
./update-openwrt-image.sh
```

脚本会：

1. 解析固定的 OpenClash release；
2. 必要时下载并校验 OpenClash APK；
3. 下载 OpenWrt 官方 `sha256sums` 与 x86/64 rootfs；
4. 校验 OpenWrt rootfs SHA256；
5. 导入版本化基础镜像；
6. 构建 OpenWrt + OpenClash 最终镜像；
7. 验证 OpenWrt 和 OpenClash 版本；
8. 只有最终镜像验证成功后才更新 `.env`。

典型镜像名称：

```text
local-openwrt-base:25.12.6
local-openwrt:25.12.6-oc0.48.002
```

构建脚本**不会自动重建正在运行的容器**。

### 6. 检查并启动

```bash
docker compose config
docker compose up -d
```

检查状态：

```bash
docker compose ps
docker logs --tail 100 openwrt
```

基础网络检查：

```bash
docker exec openwrt ip -4 addr show eth0
docker exec openwrt ip route
docker exec openwrt ping -c 3 1.1.1.1
```

### 7. 设置 root 密码

```bash
docker exec -it openwrt passwd
```

建议在配置任何 LuCI 远程访问之前完成。

### 8. 访问 LuCI

从同一局域网其他主机访问：

```text
http://<OPENWRT_IP>/
```

例如：

```text
http://192.168.0.250/
```

LuCI 是 OpenWrt Web 管理界面。最终镜像启动正常后，可以直接在 LuCI 中看到 OpenClash。

## 宿主机访问 OpenWrt

Linux macvlan 默认不允许 Docker 宿主机通过 parent 网卡直接访问自己的 macvlan 子容器。

因此以下情况属于预期：

```text
其他局域网主机 -> OpenWrt       可访问
Docker 宿主机   -> OpenWrt       默认不可访问
```

如果宿主机上的服务需要访问 OpenWrt，可以安装 host shim：

```bash
./install-host-shim.sh
```

脚本会建立由 systemd 管理的 `openwrt-host` macvlan interface，并添加到 OpenWrt IP 的 `/32` 路由。

检查：

```bash
ip route get "$(sed -n 's/^OPENWRT_IP=//p' .env)"
```

它适用于 SSH 转发、`cloudflared`、反向代理以及其他宿主机管理工具。

## 远程访问 LuCI

**不要直接把 LuCI 暴露到公网。**

### SSH 转发

```bash
ssh -N -L 18080:<OPENWRT_IP>:80 user@server
```

然后访问：

```text
http://127.0.0.1:18080/
```

该方案要求 host shim 已启用。

### Cloudflare Tunnel

可以将受保护的 Cloudflare Tunnel hostname 指向：

```text
http://<OPENWRT_IP>:80
```

建议在 LuCI 前增加 Cloudflare Access 或等价身份认证层。由于 `cloudflared` 运行在宿主机 network namespace，同样需要 host shim。

## 持久化数据

Compose 使用两个 named volume：

```text
openwrt_config  -> /etc/config
openclash_data  -> /etc/openclash
```

`openwrt_config` 保存 OpenWrt UCI 配置。

`openclash_data` 保存 OpenClash 数据，例如：

- Mihomo Core
- profiles/configuration
- providers
- GeoIP/GeoSite 数据
- cache/history/runtime 数据

因此正常重建容器不会删除 OpenClash 配置和 Core。

> [!CAUTION]
> `docker compose down -v` 会删除这两个 named volume。正常更新时不要使用 `-v`，除非明确需要完全重置配置。

## 更新

按 `.env` 固定版本构建/选择：

```bash
./update-openwrt-image.sh
```

更新当前 OpenWrt release series 内的最新 patch：

```bash
./update-openwrt-image.sh --latest-openwrt
```

更新到最新 OpenClash：

```bash
./update-openwrt-image.sh --latest-openclash
```

两者同时更新：

```bash
./update-openwrt-image.sh --latest
```

明确指定版本：

```bash
./update-openwrt-image.sh \
  --openwrt 25.12.6 \
  --openclash 0.48.002
```

强制重建已经存在的最终镜像 tag：

```bash
./update-openwrt-image.sh --force
```

`--latest-openwrt` 只会在当前 OpenWrt release series 内更新。需要跨 series 时请显式使用 `--openwrt VERSION`。

构建成功后仍然需要手动部署：

```bash
docker compose config
docker compose up -d
```

## 回滚

普通构建会保留旧的版本化镜像。

查看镜像：

```bash
docker image ls local-openwrt local-openwrt-base
```

将 `.env` 改回需要的版本后：

```bash
docker compose up -d
```

持久化 volume 会继续挂载。

OpenWrt 大版本切换前建议先备份，因为不能假定任意 release 之间的配置完全兼容。

## 备份

```bash
mkdir -p backups/runtime
```

备份 OpenWrt 配置：

```bash
docker exec openwrt tar -C /etc/config -czf - . \
  > "backups/runtime/openwrt-config-$(date +%Y%m%d-%H%M%S).tar.gz"
```

备份 OpenClash 数据：

```bash
docker exec openwrt tar -C /etc/openclash -czf - . \
  > "backups/runtime/openclash-data-$(date +%Y%m%d-%H%M%S).tar.gz"
```

## GitHub API Rate Limit

更新脚本会使用 GitHub API 解析 OpenClash release。

如果匿名 API rate limit 不足，可临时提供 token：

```bash
export GITHUB_TOKEN="..."
./update-openwrt-image.sh --latest-openclash
```

不要把 token 写入仓库。

## IPv6

当前 Compose 有意在 OpenWrt 容器中关闭 IPv6：

```yaml
net.ipv6.conf.all.disable_ipv6: "1"
net.ipv6.conf.default.disable_ipv6: "1"
```

因此当前选择性网关方案以 IPv4 为主。

但这**不会**阻止局域网客户端从上游路由器独立获得 IPv6 默认路由，因此可能出现：

```text
IPv4 -> OpenWrt/OpenClash
IPv6 -> 直接经过上游网关
```

如果要求完整代理所有流量，需要另外处理客户端/上游 IPv6，或者设计支持 IPv6 的路由方案。

## OpenClash 与 Mihomo 生命周期

OpenClash 软件包属于版本化 Docker 镜像。

Mihomo Core 则持久化在：

```text
/etc/openclash/core/clash_meta
```

因此不同组件可以分别更新：

```text
OpenWrt 版本       -> 重建镜像
OpenClash 版本     -> 重建镜像
Mihomo Core        -> 更新持久化 OpenClash 数据
Profiles/providers -> 持久化 OpenClash 数据
```

### OpenClash 自启动

`/etc/rc.d` 位于容器可写层，因此 `init-openwrt.sh` 每次容器启动都会重新启用
OpenClash 自启动；否则容器重启后 Mihomo Core（以及 `9090` 上的面板）不会自动运行。

`/etc/init.d/openclash enable` 依赖 `/var/lock`，而该目录由 `/sbin/init` 创建，
启动钩子执行时尚未存在。因此脚本会先创建该目录，并在必要时直接写入
`/etc/rc.d/S99openclash`。

## 常见问题

### `Pool overlaps with other one on this address space`

说明另一个 Docker network 使用了与 OpenWrt macvlan 重叠的 IPAM subnet。

检查：

```bash
docker network ls -q | xargs -r docker network inspect \
  --format '{{.Name}} | driver={{.Driver}} | {{range .IPAM.Config}}subnet={{.Subnet}} gateway={{.Gateway}} {{end}}'
```

删除无用冲突 network，或者把它迁移到不重叠的地址段。

### Docker 宿主机无法访问 OpenWrt

标准 macvlan 下属于预期行为。安装：

```bash
./install-host-shim.sh
```

### OpenWrt 不断重启并出现 `uci: Entry not found`

官方 release rootfs 在容器初始启动时可能尚未生成 UCI 文件。当前 `init-openwrt.sh` 会在应用设置前显式创建其需要管理的 UCI package 文件。

检查：

```bash
docker logs openwrt
```

### 构建时找不到 OpenWrt rootfs SHA256

OpenWrt `sha256sums` 的文件名可能包含前导 `*`。当前更新脚本会先移除这个字符再匹配文件名；旧版脚本应先更新。

### OpenClash 没有 Mihomo Core

可以在首次初始化 volume 前提供：

```text
backups/bootstrap/clash_meta
```

或者通过 OpenClash 自行安装/更新。

验证：

```bash
docker exec openwrt /etc/openclash/core/clash_meta -v
```

## 常用命令

```bash
# 构建/选择固定版本镜像
./update-openwrt-image.sh

# 启动或重建 OpenWrt
docker compose up -d

# 停止但保留持久化 volume
docker compose down

# 状态
docker compose ps

# 日志
docker logs -f openwrt

# 进入 OpenWrt shell
docker exec -it openwrt /bin/ash

# 查看 OpenWrt 版本
docker exec openwrt cat /etc/openwrt_release

# 查看 Mihomo 版本
docker exec openwrt /etc/openclash/core/clash_meta -v

# 检查 Compose 最终展开配置
docker compose config
```

## 安全建议

- 首次部署后立即设置 OpenWrt root 密码。
- 不要直接将 LuCI 暴露到公网。
- 远程管理建议使用 SSH Tunnel、VPN 或带认证的访问代理。
- 定期维护 OpenWrt、OpenClash 和 Mihomo。
- 实际作为网关使用时，更新前先检查版本变化和构建结果。
- 不要提交 API Token、账号凭证、代理订阅或私有 Profile。
- 除非明确需要完全重置，否则避免 `docker compose down -v`。

## 上游项目

- [OpenWrt](https://openwrt.org/)
- [OpenClash](https://github.com/vernesong/OpenClash)
- [Mihomo](https://github.com/MetaCubeX/mihomo)
- [Docker](https://www.docker.com/)

所有上游组件均遵循各自的许可证和项目政策。
