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
| **Kafka** | `kafkacat` (formerly `kcat`), the Apache Kafka [shell tools](https://docs.confluent.io/kafka/operations-tools/kafka-tools.html) — `kafka-topics.sh`, `kafka-consumer-groups.sh`, `kafka-configs.sh`, `kafka-acls.sh`, `kafka-reassign-partitions.sh`, `kafka-console-{consumer,producer}.sh`, … |
| **PostgreSQL** | `postgresql-17-client` (`psql`, `pg_dump`, `pg_isready`), `pgcli` |
| **Conduktor** | `conduktor` CLI ([conduktor/ctl](https://github.com/conduktor/ctl)), `cdk-*` helpers |
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

The UID rule is enforced by the kernel one level below the attach socket:
reaching the target's `/tmp` goes through `/proc/<pid>/root`, which only the
process owner (or root) may traverse. A mismatched UID fails with
`Permission denied` there, before HotSpot's own check is reached.

### async-profiler across containers

`asprof` does not read the profiled JVM's memory itself — it asks the *target*
JVM to `dlopen` the agent library. The target resolves that path in **its own**
mount namespace, and a shared PID namespace does not share mounts, so the
library this image carries at `/usr/lib/libasyncProfiler.so` is invisible to the
Console container:

```
/usr/bin/../lib/libasyncProfiler.so was not loaded.
/usr/bin/../lib/libasyncProfiler.so: cannot open shared object file: No such file or directory
```

Copy the library into a directory the target *can* see, then point `asprof` at
the path **as the target sees it** with `--libpath`. `-f` is written by the
target too, so it also needs a target-side path:

```sh
PID=$(pgrep -f 'java.*conduktor' | head -1)
cp /usr/lib/libasyncProfiler.so "/proc/${PID}/root/tmp/"

asprof --libpath /tmp/libasyncProfiler.so \
       -d 30 -e wall -o collapsed -f /tmp/profile.txt "${PID}"

cp "/proc/${PID}/root/tmp/profile.txt" .   # read the result back
```

Writing into `/proc/<pid>/root/tmp` needs the same UID as the target, so this is
another reason to run the sidecar as `runAsUser: 10001`.

**Pick the event deliberately.** `-e cpu` (and the hardware events) call
`perf_event_open`, which an unprivileged container is not allowed to do against
another process — you get `No samples were collected` rather than an error.
`-e wall` and `-e alloc` use in-JVM sampling and work with no extra privilege;
prefer `wall` for "why is this slow". To get real `cpu` profiles you need
`SYS_ADMIN`/`PERFMON` on the sidecar *and* `kernel.perf_event_paranoid` lowered
on the node — usually not worth it when `wall` answers the question.

## The `cdk-*` support scripts

The image ships Conduktor support helpers on `PATH` — type `cdk-` and tab to
list them. Every one takes `-h`. They are redacted by default, so their output
can be pasted into a ticket as-is.

| Command | What it does |
|---------|--------------|
| `cdk-doctor` | One-shot triage: namespace, UID match, JVM attach, heap, rendered config, HTTP, DNS, Kafka reachability. Exit code = number of failures. |
| `cdk-target` | Lists visible JVMs with their UID and the config paths derived from each one's environment. Run this first. |
| `cdk-env [-a] [PATTERN]` | The target's environment, sorted and masked. |
| `cdk-config [-l\|-i] [NAME]` | The *rendered* per-app configs (`-i` for the input platform config). |
| `cdk-jvm [threads\|heap\|gc\|flags\|props\|dump F]` | JVM state over the attach mechanism. |
| `cdk-tls HOST:PORT` | Chain, expiry, SANs, and validation against the target JVM's own truststore. |
| `cdk-pg [check\|url\|psql\|pgcli\|sizes\|activity]` | Console's Postgres: discovers the connection from the rendered config, checks it, or opens a session. |

Two things make these more than wrappers:

- **Nothing is hardcoded.** Paths come from the target process's own
  environment (`/proc/<pid>/environ`) — `CDK_IN_CONF_FILE`, `CDK_APPS_CONF_DIR`,
  `CDK_VOLUME_DIR`, `CDK_LISTENING_PORT` — with the Console image's defaults as
  fallback only. A chart that overrides `CDK_VOLUME_DIR` is followed correctly.
- **Redaction is on by default.** Values of `*PASSWORD*`, `*SECRET*`, `*TOKEN*`,
  `*JAAS*`, `*LICENSE*` … and the password field of any `scheme://user:pass@host`
  URL are masked, while `*_FILE` / `*_PATH` / `*_LOCATION` keys are kept because
  a keystore's location is usually the answer. `CDK_NO_REDACT=1` disables it.

### Adding a script

The scripts are packaged into the image by [`melange.yaml`](melange.yaml) from
[`tools/`](tools/) — melange rather than apko because these are our own files
and no Wolfi package can provide them.

1. Drop an executable `tools/cdk-<name>` in place, starting from an existing one.
   Keep the two lines every tool has: a `#!/usr/bin/env bash` shebang and
   `. /usr/local/lib/conduktor/cdk-common.sh`. Shared helpers go in
   `tools/cdk-common.sh`.
2. Test it without a full image build:
   ```sh
   make test                       # shellcheck + structural + redaction tests
   ```
3. Then in the image, against a real target container:
   ```sh
   make debug-shell TARGET=<running-container-name>
   ```
   which builds the APK, builds the image, and drops you into it sharing the
   target's PID and network namespaces as UID 10001.
4. Open a PR. `melange.yaml` globs `tools/cdk-*`, so there is no list to update
   — the PR workflow packages and installs it, and the next nightly ships it.

`make debug-scripts` builds just the APKs if you want to iterate on packaging.

Local builds are **host-arch only** (~30s). The foreign arch would run melange
under qemu emulation, which costs minutes for `kafka-tools` and produces an APK
that the host-arch image never installs. Add `ARCHES=x86_64,aarch64` to any of
these targets to reproduce the nightly's multi-arch build.

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

# Kafka — quick metadata / consume with kcat
kafkacat -b kafka:9092 -L                          # metadata
kafkacat -b kafka:9092 -t my-topic -C -o beginning # consume from earliest

# Kafka — admin operations with the Apache shell tools (already on PATH)
kafka-topics.sh --bootstrap-server kafka:9092 --list
kafka-topics.sh --bootstrap-server kafka:9092 --describe --topic my-topic
kafka-consumer-groups.sh --bootstrap-server kafka:9092 --describe --group my-group
kafka-configs.sh --bootstrap-server kafka:9092 --describe --entity-type brokers --entity-name 1
kafka-broker-api-versions.sh --bootstrap-server kafka:9092   # protocol compatibility

# Against a secured cluster, pass a properties file:
kafka-topics.sh --bootstrap-server kafka:9093 \
  --command-config /tmp/client.properties --list

# Console's PostgreSQL
cdk-pg check                           # reachable? version? connection headroom?
cdk-pg sizes                           # what is actually consuming disk
cdk-pg activity                        # non-idle backends, longest query first
cdk-pg psql                            # interactive session on that database

# Console API via the Conduktor CLI
conduktor version
conduktor get application              # needs CDK_BASE_URL + CDK_API_KEY
```

### The `conduktor` CLI

The image bundles [conduktor/ctl](https://github.com/conduktor/ctl) so you can
drive Console's API from inside the cluster — useful when Console is reachable
on the pod network but not from your laptop. It reads `CDK_BASE_URL` and
`CDK_API_KEY` from the environment, so with a shared network namespace:

```sh
export CDK_BASE_URL="http://127.0.0.1:$(cdk-target | awk '/http port/{print $3}')"
export CDK_API_KEY="<admin or application token>"
conduktor get application
```

It is packaged from the upstream release tarball, pinned by SHA-256 — see
[`melange-conduktor-ctl.yaml`](melange-conduktor-ctl.yaml) for the bump recipe.

### Kafka shell tools and the JVM

The Apache tools live in `/usr/lib/kafka/bin`, which is on `PATH` — they are not
symlinked into `/usr/bin` because each script locates `kafka-run-class.sh` and
`libs/` relative to `$0`.

They run on this image's JDK 25 via `JAVA_HOME`, so there is no second JVM.
That is why they are packaged by
[`melange-kafka-tools.yaml`](melange-kafka-tools.yaml) rather than installed from
Wolfi's `kafka-4.3`: that package depends on `openjdk-21-default-jvm` and would
add ~205 MB of JVM that `JAVA_HOME` guarantees is never used (+336 MB vs
+131 MB), while shipping the identical 108 jars, so it gives up no patched
dependencies. Verified against a live Kafka 4.0 broker on JDK 25.

Kafka 4.x clients talk to brokers from 2.1 onward, so these tools work against
older customer clusters; a handful of newer subcommands will report an
unsupported API against much older brokers.

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
