# conduktor-debug

Public debug sidecar image for Conduktor Console and Gateway. Deploy
alongside a running JVM pod (same PID / network namespace) to inspect
network, TLS, LDAP, Kafka and JVM state without shelling into the
production container or installing tooling on the host.

- **Image:** `conduktor/conduktor-debug` (Docker Hub) — also
  `ghcr.io/conduktor/conduktor-debug`, same digest
- **Source:** [`apko.yaml`](apko.yaml)
- **Architectures:** `linux/amd64`, `linux/arm64` (single OCI index per tag)
- **Default user:** `root`, so `tcpdump` and `strace` work ad-hoc without extra
  capabilities. **Run it as `runAsUser: 10001` (or `1001` for legacy Gateway
  pods) in production** — that is all the JVM tools need, and it needs no
  capabilities at all. See [Privileges](#privileges) below.
- **Size:** ~330 MB compressed (full JDK, not JRE — see below)

## What's in the box

Grouped as in the [`apko.yaml`](apko.yaml):

| Category | Tools |
|----------|-------|
| **JVM diagnostics** | `openjdk-25` (full JDK — `jstack`, `jmap`, `jcmd`, `jhsdb`, `jfr`), `async-profiler` |
| **Network debugging** | `iproute2` (`ip`, `ss`, `tc`), `iputils`, `bind-tools` (`dig`, `nslookup`), `tcpdump`, `nmap`, `netcat-openbsd` (`nc`), `socat`, `mtr`, `iftop`, `lsof` |
| **TLS / PKI** | `openssl`, `libnss-tools` (`certutil`, `pk12util`) |
| **LDAP** | `openldap-2.6-clients` (`ldapsearch`, `ldapwhoami`) |
| **Kafka** | `kafkacat` (formerly `kcat`) |
| **Perf / observability** | `htop`, `sysstat` (`iostat`, `pidstat`, `mpstat`), `strace` |
| **HTTP + JSON/YAML** | `curl`, `wget`, `jq`, `yq` |
| **Comfort** | `bash`, `coreutils`, `sed`, `gawk`, `vim` |

### Why the full JDK, not the JRE + jattach?

The original design shipped `openjdk-25-jre` + `jattach`, but jattach is
**not packaged in Wolfi** ([verified via `apk search`](../../AGENTS.md#1-use-apko-in-priority-verify-wolfi-packages-before-adding)).
The full JDK provides `jstack`, `jmap`, `jcmd`, `jhsdb`, and `jfr` natively
and is the pragmatic path today. If jattach lands in Wolfi later, we can
revisit and drop ~150 MB.

## Deploy as a sidecar

The debug image is meant to run **next to** a live Conduktor JVM pod,
sharing its PID namespace so the JDK tools can attach to the target
process.

### Helm values override

```yaml
podSpec:
  shareProcessNamespace: true
  containers:
    - name: debug
      image: conduktor/conduktor-debug:latest
      command: ["sleep", "infinity"]
      securityContext:
        runAsUser: 10001    # match the target JVM's UID — see Privileges
        runAsGroup: 10001
```

### Raw `kubectl debug` (ephemeral, no manifest edits)

```sh
kubectl debug -n conduktor pod/console-0 \
  --image=conduktor/conduktor-debug:latest \
  --target=console \
  --profile=general \
  -it -- bash
```

`--target` shares the PID namespace with the specified container. Attaching
works here either way: the ephemeral container inherits a pod-level
`runAsUser: 10001` if one is set, and otherwise runs as the image default
`root` — both satisfy HotSpot's check. `--profile=general` additionally grants
`SYS_PTRACE`, which you only need for `strace` / `jhsdb` / the `-F` variants.
Use `--profile=netadmin` (grants `NET_ADMIN` + `NET_RAW`) for `tcpdump`.

### Docker Compose

A Kubernetes pod shares the network namespace by default and the PID namespace
only with `shareProcessNamespace`. Compose shares *neither* by default, so the
sidecar needs both directives to behave like a pod:

```yaml
services:
  console:
    image: conduktor/conduktor-console:latest
    user: "10001:10001"

  debug:
    image: conduktor/conduktor-debug:latest
    user: "10001:10001"        # must match console's UID/GID
    pid: "service:console"     # == shareProcessNamespace: true
    network_mode: "service:console"
    command: ["sleep", "infinity"]
    # cap_add: ["NET_RAW"]     # tcpdump
    # cap_add: ["SYS_PTRACE"]  # strace / jhsdb / jstack -F
```

```sh
docker compose exec debug bash
pgrep -f java          # the console JVM is visible in this namespace
jcmd <pid> GC.heap_info
```

`network_mode: "service:console"` means the `debug` service may not declare
`networks` or `ports` of its own — Compose rejects the file if it does. It also
makes `debug` depend on `console` being up, so a `console` restart takes the
sidecar with it.

### Ad-hoc against an already-running container

The closest equivalent of `kubectl debug --target`, with no compose file edit:

```sh
docker run --rm -it \
  --pid "container:conduktor-console" \
  --network "container:conduktor-console" \
  --user 10001:10001 \
  conduktor/conduktor-debug:latest bash
```

## Privileges

`jcmd`, `jstack`, `jmap`, `jinfo` and `jfr` use the HotSpot *attach* mechanism:
a unix socket whose peer credentials the target JVM validates as
`is_root(uid) || (geteuid() == uid && getegid() == gid)`. Since every Conduktor
image runs as `conduktor` 10001, matching that UID/GID is sufficient — **root
is not required, and neither is `SYS_PTRACE`, which this path never uses.**

| Tool | Needs |
|------|-------|
| `jcmd`, `jstack`, `jmap`, `jinfo`, `jfr` | matching UID+GID (or root) — no capability |
| `strace`, `jstack -F`, `jmap -F`, `jhsdb` | `SYS_PTRACE` (these really call `ptrace(2)`) |
| `tcpdump` | `NET_RAW` |

`async-profiler` uses the same attach mechanism as `jcmd`, but its wall-clock
and allocation modes read perf events — those need
`kernel.perf_event_paranoid` relaxed on the node, not a pod capability.

The UID rule is enforced by the kernel one level below the attach socket:
reaching the target's `/tmp` goes through `/proc/<pid>/root`, which only the
process owner (or root) may traverse. A mismatched UID fails with
`Permission denied` there, before HotSpot's own check is reached.

## Typical debugging recipes

```sh
# JVM
pgrep -f java                          # find the target PID
jcmd <pid> GC.heap_info                # heap summary without a heap dump
jstack <pid>                           # thread dump
jmap -dump:live,format=b,file=/tmp/heap.hprof <pid>
jfr start <pid> duration=60s filename=/tmp/rec.jfr

# Network
tcpdump -i any -n port 9092            # sniff Kafka traffic
ss -tunp                               # sockets + owning process
mtr --report --report-cycles=20 kafka  # path + loss to a hop

# TLS
openssl s_client -connect kafka:9093 -servername kafka -showcerts
openssl x509 -in cert.pem -noout -text

# LDAP
ldapsearch -H ldaps://ldap:636 -x -b "dc=conduktor,dc=io" -D "cn=admin,..." -W

# Kafka
kafkacat -b kafka:9092 -L                          # metadata
kafkacat -b kafka:9092 -t my-topic -C -o beginning # consume from earliest
```

## Pull

```sh
docker pull conduktor/conduktor-debug:latest
# Pin to an immutable tag when embedding in a Helm chart:
docker pull conduktor/conduktor-debug:2026.07.31
# Same image on GHCR, identical digest:
docker pull ghcr.io/conduktor/conduktor-debug:latest
```

## Verify signature + SBOM + provenance

Same recipe as the other images — see
[Verify signature + SBOM + provenance](../../README.md#verify-signature--sbom--provenance).

## Non-obvious notes

- The image also carries the legacy `gateway` user at UID/GID 1001 in
  addition to the standard `conduktor` at 10001, for compatibility with
  existing Gateway deployments. Don't remove without cross-checking Helm
  charts.
- `openssl s_client` inside a sidecar sees only what the target
  container's TLS peer sees when `shareProcessNamespace: true` is set —
  network namespaces are still separate. For same-namespace network
  inspection use `kubectl debug --profile=netadmin`.
- `tcpdump` needs `NET_RAW`, not `SYS_PTRACE`. Granting `SYS_PTRACE` to make
  `jcmd` work is a common mistake — match the UID instead.

## Contributing

Package changes go in [`apko.yaml`](apko.yaml) with a trailing `# why`
comment. Verify Wolfi names first (see the [agent
guide](../../AGENTS.md#1-use-apko-in-priority-verify-wolfi-packages-before-adding)),
then `make build IMAGE=debug && make scan IMAGE=debug` before opening a PR.
