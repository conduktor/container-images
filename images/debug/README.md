# conduktor-debug

Public debug sidecar image for Conduktor Console and Gateway. Deploy
alongside a running JVM pod (same PID / network namespace) to inspect
network, TLS, LDAP, Kafka and JVM state without shelling into the
production container or installing tooling on the host.

- **Image:** `ghcr.io/conduktor/conduktor-debug`
- **Source:** [`apko.yaml`](apko.yaml)
- **Architectures:** `linux/amd64`, `linux/arm64` (single OCI index per tag)
- **Default user:** `root` so `jcmd` / `jstack` / `strace` / `tcpdump` work
  without extra runtime privilege beyond `SYS_PTRACE` where required
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
      image: ghcr.io/conduktor/conduktor-debug:latest
      command: ["sleep", "infinity"]
      securityContext:
        capabilities:
          add: ["SYS_PTRACE"]   # required for jcmd / jmap / jstack / strace
```

### Raw `kubectl debug` (ephemeral, no manifest edits)

```sh
kubectl debug -n conduktor pod/console-0 \
  --image=ghcr.io/conduktor/conduktor-debug:latest \
  --target=console \
  --profile=general \
  -it -- bash
```

`--target` shares the PID namespace with the specified container.
`--profile=general` grants `SYS_PTRACE`.

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
docker pull ghcr.io/conduktor/conduktor-debug:latest
# Pin to an immutable tag when embedding in a Helm chart:
docker pull ghcr.io/conduktor/conduktor-debug:2026.07.31
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
- `tcpdump` needs `NET_ADMIN` (or `NET_RAW`), not `SYS_PTRACE`. Add both
  if you plan to sniff and attach.

## Contributing

Package changes go in [`apko.yaml`](apko.yaml) with a trailing `# why`
comment. Verify Wolfi names first (see the [agent
guide](../../AGENTS.md#1-use-apko-in-priority-verify-wolfi-packages-before-adding)),
then `make build IMAGE=debug && make scan IMAGE=debug` before opening a PR.
