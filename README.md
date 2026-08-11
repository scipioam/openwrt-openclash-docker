# openwrt-openclash-docker

[简体中文](README.zh-CN.md)

Run OpenWrt with OpenClash in Docker Compose as a **selective IPv4 gateway** on an existing LAN.

The container joins the LAN through `macvlan` and receives its own address. Only clients that explicitly use the OpenWrt address as their IPv4 gateway are routed through OpenWrt/OpenClash; all other LAN clients continue using the existing upstream gateway.

The repository also provides a repeatable build/update workflow based on the official OpenWrt release rootfs and versioned OpenClash packages.

> [!IMPORTANT]
> This is an independent deployment project. It is not an official OpenWrt, OpenClash, or Mihomo project.

## Highlights

- OpenWrt in Docker Compose on Linux
- One-arm `macvlan` topology with a dedicated LAN IP
- Selective routing without replacing the existing LAN gateway
- OpenClash baked into a versioned local image
- Mihomo core and OpenClash runtime data persisted separately from the image
- Official OpenWrt rootfs SHA256 verification
- OpenClash APK digest verification when GitHub exposes an asset digest
- Version-pinned OpenWrt/OpenClash builds with simple rollback
- Persistent `/etc/config` and `/etc/openclash` volumes
- Optional host-side macvlan shim for host-to-OpenWrt access
- Build and deployment are intentionally separate operations

## Architecture

```text
                     Existing LAN

                 Upstream Gateway
                 e.g. 192.168.0.1
                         |
           +-------------+-------------+
           |                           |
     Normal clients                Docker host
     GW = upstream                 e.g. .0.201
                                       |
                                  physical NIC
                                  e.g. enp1s0
                                       |
                                    macvlan
                                       |
                                  OpenWrt .250
                                       |
                                   OpenClash
                                       ^
                                       |
                                Selected clients
                                GW = OpenWrt
```

OpenWrt performs same-interface forwarding and IPv4 masquerading for this one-arm topology.

The container has its own network namespace, so OpenClash TUN, policy routing, and nftables rules are isolated from normal host networking. Like all Docker containers, it still shares the Linux host kernel.

## Repository Layout

```text
.
├── .env.example              # committed configuration template
├── .env                      # local runtime config, created from .env.example
├── .dockerignore
├── compose.yml
├── Dockerfile
├── init-openwrt.sh
├── update-openwrt-image.sh
├── install-host-shim.sh
├── backups/
│   └── bootstrap/
│       └── clash_meta          # optional local Mihomo bootstrap core
├── build/                      # generated build files
└── downloads/                  # download cache
```

| File | Purpose |
|---|---|
| `.env.example` | Committed template for OpenWrt/OpenClash versions and LAN addresses |
| `.env` | Local runtime configuration created from `.env.example`; keep it untracked |
| `compose.yml` | Container, macvlan, volumes, TUN device and sysctls |
| `Dockerfile` | Builds the final OpenWrt + OpenClash image |
| `update-openwrt-image.sh` | Downloads, verifies, builds and validates versioned images |
| `init-openwrt.sh` | Enforces LAN/DHCP/RA/NAT settings and seeds an optional Mihomo core |
| `install-host-shim.sh` | Installs a persistent host-side macvlan shim with systemd |

## Requirements

Current implementation targets:

- Linux host; Ubuntu 24.04 is the primary tested environment
- Docker Engine + Docker Compose v2
- `x86_64` / `amd64`
- A wired interface suitable as a Docker `macvlan` parent
- Existing IPv4 LAN and upstream gateway
- Host kernel support for TUN, nftables, policy routing and TPROXY

The build script also uses common tools such as `curl`, `sha256sum`, `awk`, `sed`, `grep`, `sort`, and `python3`.

> [!WARNING]
> The OpenWrt container uses `privileged: true` and `/dev/net/tun`. Treat it as network infrastructure and do not run untrusted software inside it.

## Network Configuration

The repository ships with `.env.example`, which contains example values similar to:

```dotenv
OPENWRT_VERSION=25.12.5
OPENCLASH_VERSION=0.47.156

OPENWRT_IP=192.168.0.250
OPENWRT_GATEWAY=192.168.0.1
OPENWRT_HOST_SHIM_IP=192.168.0.249
```

`compose.yml` also contains LAN-specific settings:

```yaml
parent: enp1s0
subnet: 192.168.0.0/24
ip_range: 192.168.0.248/29
gateway: 192.168.0.1
```

**Adjust these values before deployment if they do not match your LAN.**

If the physical interface is not `enp1s0`, update it in both:

- `compose.yml`
- `install-host-shim.sh`

Reserve the OpenWrt and host-shim addresses outside the normal DHCP allocation pool, or reserve them explicitly on the upstream DHCP server.


> [!NOTE]
> `.env.example` is the public template. The working `.env` is machine-specific and should remain untracked (normally via `.gitignore`).

## Selective Routing Model

This project does **not** run another DHCP server on the existing LAN.

`init-openwrt.sh` enforces:

- static OpenWrt LAN address
- DHCP server disabled
- DHCPv6 disabled
- IPv6 Router Advertisement disabled
- LAN forwarding enabled
- IPv4 masquerading enabled

Normal client:

```text
Gateway: upstream gateway
```

Selected client:

```text
Gateway: OpenWrt IP
DNS:     OpenWrt IP    # recommended when OpenClash DNS handling is used
```

No routing change is required for unrelated LAN clients.

## Quick Start

### 1. Clone

```bash
git clone <repository-url>
cd openwrt-openclash-docker
```

### 2. Create the local environment file and configure the LAN

Create your local runtime configuration from the committed template:

```bash
cp .env.example .env
```

Then edit `.env` and the `openwrt_lan` section in `compose.yml`.

At minimum verify:

- physical interface
- subnet
- upstream gateway
- OpenWrt IP
- host-shim IP
- `ip_range`

### 3. Optional: provide a bootstrap Mihomo core

If you already have a tested `amd64` Mihomo core, place it at:

```text
backups/bootstrap/clash_meta
```

and make it executable:

```bash
chmod 0755 backups/bootstrap/clash_meta
```

On the first start of an empty `openclash_data` volume, it is copied to:

```text
/etc/openclash/core/clash_meta
```

If a core already exists in the persistent volume, it is never overwritten by the bootstrap file.

The bootstrap core is optional; OpenClash can install/update its core later.

> [!NOTE]
> For a public repository, it is usually better not to commit the Mihomo binary. Keep `backups/bootstrap/clash_meta` local and obtain the core from its upstream distribution channel.

### 4. Check TUN support

```bash
ls -l /dev/net/tun
```

If your kernel exposes the relevant features as loadable modules, commands such as these may be useful:

```bash
sudo modprobe tun
sudo modprobe nft_tproxy
sudo modprobe nf_tproxy_ipv4
```

Module names and built-in/module status can vary by kernel.

### 5. Build the image

```bash
chmod +x update-openwrt-image.sh init-openwrt.sh install-host-shim.sh
./update-openwrt-image.sh
```

The script:

1. resolves the pinned OpenClash release;
2. downloads and verifies the OpenClash APK when needed;
3. downloads the official OpenWrt `sha256sums` and x86/64 rootfs;
4. verifies the OpenWrt rootfs SHA256;
5. imports a versioned base image;
6. builds a final OpenWrt + OpenClash image;
7. validates OpenWrt and OpenClash versions;
8. updates `.env` only after validation succeeds.

Typical image names:

```text
local-openwrt-base:25.12.5
local-openwrt:25.12.5-oc0.47.156
```

The script **does not recreate the running container**.

### 6. Review and start

```bash
docker compose config
docker compose up -d
```

Check status:

```bash
docker compose ps
docker logs --tail 100 openwrt
```

Basic network checks:

```bash
docker exec openwrt ip -4 addr show eth0
docker exec openwrt ip route
docker exec openwrt ping -c 3 1.1.1.1
```

### 7. Set the root password

```bash
docker exec -it openwrt passwd
```

Do this before enabling any remote LuCI access.

### 8. Open LuCI

From another host on the same LAN:

```text
http://<OPENWRT_IP>/
```

Example:

```text
http://192.168.0.250/
```

LuCI is the OpenWrt web administration interface. OpenClash should be available inside LuCI after the image starts successfully.

## Host-to-OpenWrt Access

Linux macvlan normally prevents the Docker host from directly reaching its own macvlan child container through the parent interface.

Therefore this is expected:

```text
Other LAN host -> OpenWrt      works
Docker host    -> OpenWrt      does not work by default
```

Install the optional host shim when host-side services need to access OpenWrt:

```bash
./install-host-shim.sh
```

It creates a systemd-managed `openwrt-host` macvlan interface and a `/32` route to the OpenWrt IP.

Verify it with:

```bash
ip route get "$(sed -n 's/^OPENWRT_IP=//p' .env)"
```

This is useful for SSH forwarding, `cloudflared`, reverse proxies, and other host-side administration tools.

## Remote LuCI Access

Do **not** expose LuCI directly to the public Internet.

### SSH forwarding

```bash
ssh -N -L 18080:<OPENWRT_IP>:80 user@server
```

Then browse locally:

```text
http://127.0.0.1:18080/
```

The host shim must be active.

### Cloudflare Tunnel

A protected Cloudflare Tunnel hostname can target:

```text
http://<OPENWRT_IP>:80
```

Use Cloudflare Access or an equivalent authentication layer in front of LuCI. The host shim is required because `cloudflared` runs in the host network namespace.

## Persistent Data

Two named volumes are used:

```text
openwrt_config  -> /etc/config
openclash_data  -> /etc/openclash
```

`openwrt_config` stores OpenWrt UCI configuration.

`openclash_data` stores OpenClash runtime/user data such as:

- Mihomo core
- profiles/configuration files
- providers
- GeoIP/GeoSite data
- cache/history/runtime state

Container recreation therefore does not normally remove OpenClash configuration or its core.

> [!CAUTION]
> `docker compose down -v` deletes both named volumes. Do not use `-v` during normal updates unless a complete configuration reset is intentional.

## Updating

Use the exact versions pinned in `.env`:

```bash
./update-openwrt-image.sh
```

Latest OpenWrt patch within the current release series:

```bash
./update-openwrt-image.sh --latest-openwrt
```

Latest OpenClash release:

```bash
./update-openwrt-image.sh --latest-openclash
```

Update both:

```bash
./update-openwrt-image.sh --latest
```

Select explicit versions:

```bash
./update-openwrt-image.sh \
  --openwrt 25.12.5 \
  --openclash 0.47.156
```

Force-rebuild an existing final image tag:

```bash
./update-openwrt-image.sh --force
```

`--latest-openwrt` intentionally stays within the current OpenWrt release series. Use an explicit `--openwrt VERSION` when intentionally moving to another series.

After a successful build, deployment is still manual:

```bash
docker compose config
docker compose up -d
```

## Rollback

Normal builds retain old versioned images.

List available images:

```bash
docker image ls local-openwrt local-openwrt-base
```

Set `.env` back to the desired versions and recreate the container:

```bash
docker compose up -d
```

Persistent volumes remain attached.

Back up configuration before major OpenWrt version changes because configuration compatibility is not guaranteed across arbitrary release boundaries.

## Backup

```bash
mkdir -p backups/runtime
```

OpenWrt configuration:

```bash
docker exec openwrt tar -C /etc/config -czf - . \
  > "backups/runtime/openwrt-config-$(date +%Y%m%d-%H%M%S).tar.gz"
```

OpenClash data:

```bash
docker exec openwrt tar -C /etc/openclash -czf - . \
  > "backups/runtime/openclash-data-$(date +%Y%m%d-%H%M%S).tar.gz"
```

## GitHub API Rate Limits

The update script uses the GitHub API to resolve OpenClash releases.

If needed, provide a token through the environment:

```bash
export GITHUB_TOKEN="..."
./update-openwrt-image.sh --latest-openclash
```

Do not store the token in the repository.

## IPv6

The current Compose configuration deliberately disables IPv6 inside the OpenWrt container:

```yaml
net.ipv6.conf.all.disable_ipv6: "1"
net.ipv6.conf.default.disable_ipv6: "1"
```

This keeps the current selective-gateway design IPv4-only.

It does **not** stop a LAN client from independently receiving an IPv6 default route from the upstream router. A selected client may therefore use:

```text
IPv4 -> OpenWrt/OpenClash
IPv6 -> upstream gateway directly
```

If full proxy enforcement is required, handle client/upstream IPv6 separately or implement an IPv6-aware routing design.

## OpenClash and Mihomo Lifecycle

OpenClash itself is part of the versioned Docker image.

The Mihomo core lives in the persistent volume at:

```text
/etc/openclash/core/clash_meta
```

This deliberately separates update lifecycles:

```text
OpenWrt version     -> rebuild image
OpenClash version   -> rebuild image
Mihomo core         -> update persistent OpenClash data
Profiles/providers  -> persistent OpenClash data
```

## Troubleshooting

### `Pool overlaps with other one on this address space`

Another Docker network already uses an overlapping IPAM subnet.

Inspect all Docker networks:

```bash
docker network ls -q | xargs -r docker network inspect \
  --format '{{.Name}} | driver={{.Driver}} | {{range .IPAM.Config}}subnet={{.Subnet}} gateway={{.Gateway}} {{end}}'
```

Remove an unused conflicting network or migrate it to a non-overlapping subnet.

### Docker host cannot reach OpenWrt

Expected with plain macvlan. Install the host shim:

```bash
./install-host-shim.sh
```

### OpenWrt repeatedly restarts with `uci: Entry not found`

The official release rootfs may initially lack generated UCI files in a container. The current `init-openwrt.sh` explicitly creates the UCI package files it manages before applying settings.

Check:

```bash
docker logs openwrt
```

### Build cannot find the OpenWrt rootfs SHA256

OpenWrt `sha256sums` entries may prefix filenames with `*`. The current update script strips that prefix before matching filenames. Update older copies of the script before rebuilding.

### OpenClash has no Mihomo core

Either provide:

```text
backups/bootstrap/clash_meta
```

before the first `openclash_data` volume initialization, or install/update the core through OpenClash.

Validate it with:

```bash
docker exec openwrt /etc/openclash/core/clash_meta -v
```

## Common Commands

```bash
# Build/select pinned image versions
./update-openwrt-image.sh

# Start/recreate OpenWrt
docker compose up -d

# Stop without deleting persistent volumes
docker compose down

# Status
docker compose ps

# Logs
docker logs -f openwrt

# OpenWrt shell
docker exec -it openwrt /bin/ash

# OpenWrt version
docker exec openwrt cat /etc/openwrt_release

# Mihomo version
docker exec openwrt /etc/openclash/core/clash_meta -v

# Expanded Compose configuration
docker compose config
```

## Security Notes

- Set an OpenWrt root password immediately after first deployment.
- Do not expose LuCI directly to the public Internet.
- Prefer SSH forwarding, VPN, or an authenticated access proxy for remote administration.
- Keep OpenWrt, OpenClash, and Mihomo updated.
- Review version changes before recreating a gateway used by active clients.
- Never commit API tokens, credentials, proxy subscriptions, or private profiles.
- Avoid `docker compose down -v` unless a full reset is intentional.

## Upstream Projects

- [OpenWrt](https://openwrt.org/)
- [OpenClash](https://github.com/vernesong/OpenClash)
- [Mihomo](https://github.com/MetaCubeX/mihomo)
- [Docker](https://www.docker.com/)

All upstream components remain subject to their respective licenses and project policies.
