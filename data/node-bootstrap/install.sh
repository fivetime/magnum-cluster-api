#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Install the Kubernetes node stack on an image that does not already carry it.
#
# The node images built by openstack-magnum-images ship kubeadm, kubelet,
# containerd and the CNI plugins already, and for those this script must never
# run - see the nodeBootstrap feature, which only enables the patch for an
# image whose Glance record has no k8s_version. This exists for the other case:
# a plain distribution image, which is the only kind that exists for bare metal
# (a cloud image has no firmware and no console, so bare metal is installed from
# the vendor's own installer instead, and that installer knows nothing about
# Kubernetes).
#
# Run from preKubeadmCommands, inserted at index 0 so that it precedes every
# other pre-kubeadm command. That position is not cosmetic: the containerdConfig
# patch appends "systemctl restart containerd" unconditionally, which on an
# image without containerd fails and takes the whole bootstrap with it.
#
# Everything is pinned and checksum-verified, and every URL has an override, so
# a deployment that mirrors these artifacts inside its own network sets
# NODE_BOOTSTRAP_MIRROR and never reaches the internet. The checksum check is
# not skipped when mirrored - a mirror is a convenience, not a trust boundary.
#
# The same script also bakes the stack into an image. openstack-ironic-images
# runs it inside a chroot of a freshly installed bare-metal disk, with
# NODE_BOOTSTRAP_MODE=image: the files it writes are the same, but nothing
# that would act on the *builder's* running kernel is done - no modprobe, no
# sysctl, no /dev/shm remount, no service start, no CRI probe. Those are left
# to the image's own first boot, which the persisted files already cover. In
# that mode the mirror is usually file:// (curl reads it like any other URL),
# the distribution packages come pre-fetched from NODE_BOOTSTRAP_PKG_DIR, and
# the control-plane images from NODE_BOOTSTRAP_IMAGES_DIR, so the build needs
# no network at all and every byte has a recorded checksum.

set -Eeuo pipefail

log() { printf '[node-bootstrap] %s\n' "$*"; }
die() { printf '[node-bootstrap] %s\n' "$*" >&2; exit 1; }

CONF=${NODE_BOOTSTRAP_CONF:-/run/kubeadm/node-bootstrap.env}
if [ -r "$CONF" ]; then
    # shellcheck disable=SC1090
    . "$CONF"
fi

: "${K8S_VERSION:?K8S_VERSION is required (written by the nodeBootstrap patch)}"

# live:  this is the node, act on the running kernel and start services (default)
# image: this is a mounted image in a chroot, write files only
MODE=${NODE_BOOTSTRAP_MODE:-live}
case "$MODE" in live|image) ;; *) die "NODE_BOOTSTRAP_MODE must be live or image, not '${MODE}'" ;; esac
live() { [ "$MODE" = live ]; }

# A mirror prefix, e.g. https://artifacts.internal/k8s. Empty means upstream.
# Each component's full URL can also be overridden individually, which is what
# a mirror that does not mimic the upstream layout needs.
MIRROR=${NODE_BOOTSTRAP_MIRROR:-}

DL_K8S=${DL_K8S:-${MIRROR:+${MIRROR}/dl.k8s.io}}
DL_K8S=${DL_K8S:-https://dl.k8s.io}
GH=${GH_RELEASES:-${MIRROR:+${MIRROR}/github.com}}
GH=${GH:-https://github.com}

# Defaults track what openstack-magnum-images resolved for its own builds. They
# are only defaults: hack/versions.sh moves them, and the env file overrides.
CONTAINERD_VERSION=${CONTAINERD_VERSION:-2.3.5}
RUNC_VERSION=${RUNC_VERSION:-1.5.1}
CRUN_VERSION=${CRUN_VERSION:-1.29.1}
CNI_PLUGINS_VERSION=${CNI_PLUGINS_VERSION:-1.9.1}
# crictl tracks the Kubernetes minor; taking the global newest puts a crictl
# from another minor on the node.
CRI_TOOLS_VERSION=${CRI_TOOLS_VERSION:-${K8S_VERSION%.*}.0}

# Runtime handlers beyond runc. The driver creates a RuntimeClass for each of
# these names on every cluster it builds, so a node that does not carry the
# handler admits the pod and fails it at container creation - the failure the
# prebuilt images exist to avoid. Installed by default for that reason; set
# NODE_BOOTSTRAP_RUNTIMES to a subset to leave some out on purpose.
RUNTIMES=${NODE_BOOTSTRAP_RUNTIMES:-"crun gvisor kata"}
# Pinned, not "latest": every node fetches on its own, and a rolling pointer
# would let one cluster's nodes disagree on which runsc they run. The URL path
# takes the tag WITHOUT the "release-" prefix that `runsc --version` prints:
# .../release/20260817.0/x86_64/runsc is a 200, .../release/release-20260817.0/
# is a 404.
GVISOR_RELEASE=${GVISOR_RELEASE:-20260817.0}
GVISOR_PLATFORM=${GVISOR_PLATFORM:-systrap}
KATA_VERSION=${KATA_VERSION:-4.1.0}

case "$(uname -m)" in
    x86_64)  ARCH=amd64 ;;
    aarch64) ARCH=arm64 ;;
    *)       die "unsupported architecture: $(uname -m)" ;;
esac

# ---------------------------------------------------------------- idempotence
#
# preKubeadmCommands re-run when cloud-init re-runs, and a Machine that is
# retried starts from the same user-data. Doing the work twice is slow and, for
# the tarball unpacks, not obviously safe. Having already done it is success.
if [ -x /usr/bin/kubeadm ] &&
   [ "$(/usr/bin/kubeadm version -o short 2>/dev/null || true)" = "v${K8S_VERSION}" ]; then
    log "kubeadm v${K8S_VERSION} is already installed; nothing to do"
    exit 0
fi

log "installing the Kubernetes ${K8S_VERSION} node stack for ${ARCH} (${MODE} mode)"
log "  containerd ${CONTAINERD_VERSION}, runc ${RUNC_VERSION}, crun ${CRUN_VERSION}"
log "  cni-plugins ${CNI_PLUGINS_VERSION}, cri-tools ${CRI_TOOLS_VERSION}"
[ -n "$MIRROR" ] && log "  mirror: ${MIRROR}"

TMPDIR=$(mktemp -d)
# IMPORT_CTRD is the containerd this script may start for the image import;
# it must not outlive the script, least of all when the script dies - in a
# chroot it would keep the image's root filesystem busy.
IMPORT_CTRD=
trap 'rm -rf "$TMPDIR"; [ -n "$IMPORT_CTRD" ] && kill "$IMPORT_CTRD" 2>/dev/null; :' EXIT
cd "$TMPDIR"

fetch() { curl -fsSL --retry 5 --retry-delay 2 -o "$2" "$1" || die "could not fetch $1"; }

# ------------------------------------------------------------ distro packages
#
# kubeadm's preflight refuses to run without conntrack and socat, and the
# kubelet needs ethtool and the bridge tooling. A cloud image has none of them.
#
# NODE_BOOTSTRAP_PKG_DIR holds pre-fetched .deb/.rpm files instead: an image
# build that must not reach a package archive puts the packages it needs there,
# with their checksums recorded by whoever fetched them. Every dependency has
# to be in the directory too; the package manager only resolves within it.
PKG_DIR=${NODE_BOOTSTRAP_PKG_DIR:-}
if [ -n "$PKG_DIR" ]; then
    if command -v dpkg >/dev/null; then
        export DEBIAN_FRONTEND=noninteractive
        set -- "$PKG_DIR"/*.deb
        [ -e "$1" ] && dpkg -i "$@"
    elif command -v rpm >/dev/null; then
        set -- "$PKG_DIR"/*.rpm
        [ -e "$1" ] && rpm -Uvh --replacepkgs "$@"
    else
        die "no supported package manager found"
    fi
    log "distribution packages from ${PKG_DIR}"
elif command -v apt-get >/dev/null; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends \
        conntrack socat ebtables ethtool iptables iproute2 kmod lvm2 \
        logrotate libseccomp2 curl ca-certificates zstd
elif command -v dnf >/dev/null; then
    dnf install -y -q \
        conntrack-tools socat ebtables ethtool iptables-nft iproute kmod lvm2 \
        logrotate libseccomp curl ca-certificates zstd
else
    die "no supported package manager found"
fi

# ------------------------------------------------------------------ containerd
CONTAINERD_TGZ="containerd-${CONTAINERD_VERSION}-linux-${ARCH}.tar.gz"
CONTAINERD_URL=${CONTAINERD_URL:-"${GH}/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/${CONTAINERD_TGZ}"}
fetch "$CONTAINERD_URL" "$CONTAINERD_TGZ"
fetch "${CONTAINERD_SHA256SUM_URL:-${CONTAINERD_URL}.sha256sum}" "${CONTAINERD_TGZ}.sha256sum"
sha256sum -c "${CONTAINERD_TGZ}.sha256sum"
tar --strip-components=1 -C /usr/bin -xzf "$CONTAINERD_TGZ"

install -d -o root -g root -m 711 /etc/containerd
install -d -o root -g root -m 700 /var/lib/containerd
install -d -o root -g root -m 711 /run/containerd
install -d -o root -g root -m 700 /run/containerd/io.containerd.grpc.v1.cri
install -d -o root -g root -m 700 /run/containerd/io.containerd.sandbox.controller.v1.shim
install -d -o root -g root -m 755 /etc/containerd/conf.d

# The containerdConfig patch writes /etc/containerd/config.toml as a `files`
# entry, and files are written before preKubeadmCommands run. So a config that
# is already here is the cluster's, and generating a default over the top of it
# would silently drop the sandbox image and the registry mirrors with it.
if [ ! -s /etc/containerd/config.toml ]; then
    log "no config.toml from the cluster; generating a default"
    containerd config default > /etc/containerd/config.toml
    sed -i 's|^disabled_plugins.*|disabled_plugins = ["io.containerd.snapshotter.v1.btrfs","io.containerd.snapshotter.v1.zfs","io.containerd.snapshotter.v1.devmapper","io.containerd.snapshotter.v1.erofs"]|' /etc/containerd/config.toml
    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
else
    log "keeping the config.toml the cluster supplied"
fi
# The runtime handlers below are drop-ins under conf.d. The cluster's
# config.toml imports that directory; `containerd config default` writes
# `imports = []`, and containerd ignores an unimported drop-in without a word.
# (On a Magnum cluster the containerdConfig patch always supplies the file, so
# the generated branch is a fallback; its version-3 document with version-2
# drop-ins is untested here.)
if ! grep -q 'conf\.d/\*\.toml' /etc/containerd/config.toml; then
    if grep -q '^imports' /etc/containerd/config.toml; then
        sed -i 's|^imports.*|imports = ["/etc/containerd/conf.d/*.toml"]|' /etc/containerd/config.toml
    else
        sed -i '1a imports = ["/etc/containerd/conf.d/*.toml"]' /etc/containerd/config.toml
    fi
fi

cat > /etc/systemd/system/containerd.service <<'UNIT'
[Unit]
Description=containerd container runtime
Documentation=https://containerd.io
After=network.target dbus.service

[Service]
ExecStartPre=-/sbin/modprobe overlay
ExecStart=/usr/bin/containerd
Type=notify
Delegate=yes
KillMode=process
Restart=always
RestartSec=5
LimitNPROC=infinity
LimitCORE=infinity
LimitNOFILE=1024:524288
LimitMEMLOCK=infinity
TasksMax=infinity
OOMScoreAdjust=-999

[Install]
WantedBy=multi-user.target
UNIT

# ------------------------------------------------------------------------ runc
RUNC_BASE=${RUNC_BASE_URL:-"${GH}/opencontainers/runc/releases/download/v${RUNC_VERSION}/runc"}
fetch "${RUNC_BASE}.${ARCH}" "runc.${ARCH}"
fetch "${RUNC_SHA256SUM_URL:-${RUNC_BASE}.sha256sum}" runc.sha256sum
grep "runc.${ARCH}\$" runc.sha256sum | sha256sum -c -
install -m 755 "runc.${ARCH}" /usr/bin/runc

# ------------------------------------------------------------------------ crun
#
# Upstream publishes no checksum file for crun, which is why the DIB element
# does not verify it either. Keeping the same behaviour rather than inventing a
# digest that nobody can check against.
CRUN_URL=${CRUN_URL:-"${GH}/containers/crun/releases/download/${CRUN_VERSION}/crun-${CRUN_VERSION}-linux-${ARCH}"}
fetch "$CRUN_URL" "crun-${CRUN_VERSION}-linux-${ARCH}"
install -m 755 "crun-${CRUN_VERSION}-linux-${ARCH}" /usr/bin/crun
# What the default handler executes. Without this drop-in crun is on disk and
# runc is what runs, which is how the first version of this script shipped.
case " $RUNTIMES " in *" crun "*)
cat > /etc/containerd/conf.d/50-crun.toml <<'CRUN'
version = 2
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
    runtime_type = "io.containerd.runc.v2"
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
    BinaryName = "/usr/bin/crun"
    SystemdCgroup = true
CRUN
;; esac

# ------------------------------------------------------------------- gvisor
#
# A static userspace kernel; the systrap platform needs no /dev/kvm, so this
# handler works on a node where no Kata VM can start. Ported from the gvisor
# element in openstack-magnum-images.
case " $RUNTIMES " in *" gvisor "*)
case "$ARCH" in amd64) GVISOR_ARCH=x86_64 ;; arm64) GVISOR_ARCH=aarch64 ;; esac
GVISOR_URL=${GVISOR_URL:-"${MIRROR:+${MIRROR}/storage.googleapis.com}"}
GVISOR_URL=${GVISOR_URL:-https://storage.googleapis.com}
GVISOR_URL="${GVISOR_URL}/gvisor/releases/release/${GVISOR_RELEASE}/${GVISOR_ARCH}"
for f in runsc containerd-shim-runsc-v1; do
    fetch "${GVISOR_URL}/${f}" "$f"; fetch "${GVISOR_URL}/${f}.sha512" "${f}.sha512"
done
sha512sum -c runsc.sha512 containerd-shim-runsc-v1.sha512
install -m 755 runsc /usr/bin/runsc
install -m 755 containerd-shim-runsc-v1 /usr/bin/containerd-shim-runsc-v1
printf 'platform = "%s"\n' "$GVISOR_PLATFORM" > /etc/containerd/runsc.toml
cat > /etc/containerd/conf.d/99-gvisor.toml <<'GVISOR'
version = 2
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.gvisor]
    runtime_type = "io.containerd.runsc.v1"
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.gvisor.options]
    TypeUrl = "io.containerd.runsc.v1.options"
    ConfigPath = "/etc/containerd/runsc.toml"
GVISOR
log "gvisor ${GVISOR_RELEASE} (${GVISOR_PLATFORM})"
;; esac

# --------------------------------------------------------------------- kata
#
# Two tarballs since 4.1.0 - runtime-rs and the Go runtime - both installed,
# because runtime-rs cannot start a QEMU sandbox here and the Go runtime's
# kata-qemu is the name everything asks for. kata-static first so the Go
# tarball wins where the 87 shared paths overlap. Ported from the kata element;
# the /dev/shm handling is the part that differs at first boot (see below).
case " $RUNTIMES " in *" kata "*)
KATA_BASE=${KATA_BASE_URL:-"${GH}/kata-containers/kata-containers/releases/download/${KATA_VERSION}"}
: > /etc/kata-static.sha256
for t in "kata-static-${KATA_VERSION}-${ARCH}.tar.zst" "kata-go-static-${KATA_VERSION}-${ARCH}.tar.zst"; do
    fetch "${KATA_BASE}/${t}" "$t"
    # The release publishes no checksum asset; record what was installed.
    sha256sum "$t" >> /etc/kata-static.sha256
    tar --zstd -xf "$t" -C /
    rm -f "$t"
done
SHIM_GO=/opt/kata/bin/containerd-shim-kata-v2
SHIM_RS=/opt/kata/runtime-rs/bin/containerd-shim-kata-v2
for shim in "$SHIM_GO" "$SHIM_RS"; do
    [ -x "$shim" ] || die "kata: ${shim} is missing; the tarball layout has changed"
done
for b in cloud-hypervisor firecracker jailer kata-runtime kata-monitor kata-collect-data.sh \
         containerd-shim-kata-v2 qemu-system-x86_64 qemu-system-aarch64; do
    [ -e "/opt/kata/bin/$b" ] && ln -sfn "/opt/kata/bin/$b" "/usr/local/bin/$b"
done
# vhost_vsock/vhost_net carry shim<->agent traffic. Loaded now as well as
# listed when this is the running kernel; in a chroot only the list is ours.
printf 'vhost_vsock\nvhost_net\n' > /etc/modules-load.d/kata.conf
if live; then modprobe vhost_vsock; modprobe vhost_net; fi
DEFAULTS=/opt/kata/share/defaults/kata-containers
install -d -m 755 /etc/kata-containers
for c in configuration-qemu.toml configuration-clh.toml configuration-fc.toml; do
    [ -f "${DEFAULTS}/$c" ] && cp "${DEFAULTS}/$c" "/etc/kata-containers/$c"
done
for c in configuration-qemu-runtime-rs.toml configuration-clh-runtime-rs.toml configuration-dragonball.toml; do
    [ -f "${DEFAULTS}/runtime-rs/$c" ] && cp "${DEFAULTS}/runtime-rs/$c" "/etc/kata-containers/$c"
done
[ -f /etc/kata-containers/configuration-qemu.toml ] &&
    cp /etc/kata-containers/configuration-qemu.toml /etc/kata-containers/configuration.toml
# Handlers under the names kata-deploy uses: bare = Go runtime, -runtime-rs =
# Rust. Derived from the configs present, so each arch registers what it can
# run. privileged_without_host_devices: a privileged Kata pod must not get the
# host's device nodes, they mean nothing in the guest.
{
    echo "version = 2"; echo
    for entry in "kata-qemu:${SHIM_GO}:configuration-qemu.toml" \
                 "kata-clh:${SHIM_GO}:configuration-clh.toml" \
                 "kata-qemu-runtime-rs:${SHIM_RS}:configuration-qemu-runtime-rs.toml" \
                 "kata-clh-runtime-rs:${SHIM_RS}:configuration-clh-runtime-rs.toml" \
                 "kata-dragonball:${SHIM_RS}:configuration-dragonball.toml"; do
        name=${entry%%:*}; rest=${entry#*:}; shim=${rest%%:*}; conf=${rest#*:}
        [ -f "/etc/kata-containers/${conf}" ] || { log "kata: no ${conf} on ${ARCH}; not registering ${name}"; continue; }
        cat <<ENTRY
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.${name}]
  runtime_type = 'io.containerd.kata.v2'
  runtime_path = '${shim}'
  privileged_without_host_devices = true
  pod_annotations = ['io.katacontainers.*']
  container_annotations = ['io.katacontainers.*']
  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.${name}.options]
    ConfigPath = '/etc/kata-containers/${conf}'
ENTRY
    done
} > /etc/containerd/conf.d/50-kata.toml
grep -q 'runtimes\.kata-qemu\]' /etc/containerd/conf.d/50-kata.toml ||
    die "kata: no kata-qemu handler registered; the tarball layout has changed"

# /dev/shm: QEMU backs the guest's RAM with a file there (virtio-fs needs the
# mapping shared), and systemd sizes it at half of RAM - smaller than kata's
# 2048 MB default guest on a small node. Both halves are needed: size it, and
# keep it private so a container's 64 MiB /dev/shm cannot propagate back and
# shadow it. A node with only the size still fails every kata-qemu sandbox.
#
# At first boot /dev/shm is already mounted, so fstab alone would fix the
# *next* boot: remount now as well. No pod has run yet, so private now is
# private before anything could shadow it.
grep -qE '^[^#]*[[:space:]]/dev/shm[[:space:]]' /etc/fstab ||
    printf 'tmpfs /dev/shm tmpfs rw,nosuid,nodev,inode64,size=75%% 0 0\n' >> /etc/fstab
if live; then
    mount -o remount,size=75% /dev/shm
    mount --make-private /dev/shm
fi
cat > /etc/systemd/system/kata-shm-private.service <<'UNIT'
[Unit]
Description=Keep /dev/shm private so container shm cannot shadow it
DefaultDependencies=no
After=local-fs.target
Before=containerd.service kubelet.service sysinit.target
ConditionPathIsMountPoint=/dev/shm

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/mount --make-private /dev/shm

[Install]
WantedBy=sysinit.target
UNIT
install -d -m 755 /etc/systemd/system/sysinit.target.wants
ln -sfn /etc/systemd/system/kata-shm-private.service /etc/systemd/system/sysinit.target.wants/kata-shm-private.service
log "kata ${KATA_VERSION}: $(sed -n 's|.*runtimes\.\(kata-[a-z0-9-]*\)\]$|\1|p' /etc/containerd/conf.d/50-kata.toml | tr '\n' ' ')"
;; esac

# Refuse to hand containerd a config it will reject: a handler drop-in with a
# typo surfaces at first pod start otherwise, well after the node has joined.
containerd --config /etc/containerd/config.toml config dump > /dev/null ||
    die "containerd rejects the assembled config; see the drop-ins in /etc/containerd/conf.d"

# ----------------------------------------------------------------- cni-plugins
CNI_TGZ="cni-plugins-linux-${ARCH}-v${CNI_PLUGINS_VERSION}.tgz"
CNI_URL=${CNI_PLUGINS_URL:-"${GH}/containernetworking/plugins/releases/download/v${CNI_PLUGINS_VERSION}/${CNI_TGZ}"}
fetch "$CNI_URL" "$CNI_TGZ"
fetch "${CNI_PLUGINS_SHA256SUM_URL:-${CNI_URL}.sha256}" "${CNI_TGZ}.sha256"
sha256sum -c "${CNI_TGZ}.sha256"
install -d /opt/cni/bin
tar --no-same-owner -C /opt/cni/bin -xzf "$CNI_TGZ"

# -------------------------------------------------------------------- crictl
CRICTL_TGZ="crictl-v${CRI_TOOLS_VERSION}-linux-${ARCH}.tar.gz"
CRICTL_URL=${CRICTL_URL:-"${GH}/kubernetes-sigs/cri-tools/releases/download/v${CRI_TOOLS_VERSION}/${CRICTL_TGZ}"}
fetch "$CRICTL_URL" "$CRICTL_TGZ"
echo "$(curl -fsSL "${CRICTL_SHA256SUM_URL:-${CRICTL_URL}.sha256}")  ${CRICTL_TGZ}" | sha256sum -c -
tar -C /usr/bin -xzf "$CRICTL_TGZ"

# ------------------------------------------------- kubeadm, kubelet, kubectl
for bin in kubeadm kubelet kubectl; do
    url_var="$(echo "$bin" | tr '[:lower:]' '[:upper:]')_URL"
    url=${!url_var:-"${DL_K8S}/release/v${K8S_VERSION}/bin/linux/${ARCH}/${bin}"}
    fetch "$url" "$bin"
    echo "$(curl -fsSL "${url}.sha256")  ${bin}" | sha256sum -c -
    install -m 755 "$bin" "/usr/bin/${bin}"
done

cat > /etc/systemd/system/kubelet.service <<'UNIT'
[Unit]
Description=kubelet: The Kubernetes Node Agent
Documentation=https://kubernetes.io/docs/home/
Wants=network-online.target
After=network-online.target

[Service]
ExecStart=/usr/bin/kubelet
Restart=always
StartLimitInterval=0
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT

install -d -m 755 /etc/systemd/system/kubelet.service.d
cat > /etc/systemd/system/kubelet.service.d/10-kubeadm.conf <<'DROPIN'
# Note: This dropin only works with kubeadm and kubelet v1.11+
[Service]
Environment="KUBELET_KUBECONFIG_ARGS=--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --kubeconfig=/etc/kubernetes/kubelet.conf"
Environment="KUBELET_CONFIG_ARGS=--config=/var/lib/kubelet/config.yaml"
EnvironmentFile=-/var/lib/kubelet/kubeadm-flags.env
EnvironmentFile=-/etc/default/kubelet
ExecStart=
ExecStart=/usr/bin/kubelet $KUBELET_KUBECONFIG_ARGS $KUBELET_CONFIG_ARGS $KUBELET_KUBEADM_ARGS $KUBELET_EXTRA_ARGS
DROPIN

# ------------------------------------------------------------ kernel and sysctl
cat > /etc/modules-load.d/99-kubernetes.conf <<'MODULES'
overlay
br_netfilter
MODULES
if live; then modprobe overlay; modprobe br_netfilter; fi

cat > /etc/sysctl.d/99-kubelet.conf <<'SYSCTL'
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = 524288
kernel.panic = 10
kernel.panic_on_oops = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
net.ipv4.tcp_congestion_control = bbr
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.all.forwarding = 1
vm.overcommit_memory = 1
SYSCTL
if live; then sysctl --system >/dev/null; fi

# ------------------------------------------------------------ preloaded images
#
# NODE_BOOTSTRAP_IMAGES_DIR holds OCI archives (one tar per image, as skopeo or
# ctr export write them) to put into containerd's k8s.io namespace ahead of
# time, so that kubeadm on this node pulls nothing. containerd is started as a
# plain process for the import when it is not running yet - in a chroot there
# is no systemd to start it - and stopped again afterwards.
IMAGES_DIR=${NODE_BOOTSTRAP_IMAGES_DIR:-}
if [ -n "$IMAGES_DIR" ]; then
    set -- "$IMAGES_DIR"/*.tar
    [ -e "$1" ] || die "NODE_BOOTSTRAP_IMAGES_DIR=${IMAGES_DIR} holds no .tar archive"
    SOCK=/run/containerd/containerd.sock
    if [ ! -S "$SOCK" ]; then
        containerd --config /etc/containerd/config.toml >/tmp/containerd-import.log 2>&1 &
        IMPORT_CTRD=$!
        for _ in $(seq 30); do [ -S "$SOCK" ] && break; sleep 1; done
        [ -S "$SOCK" ] || die "containerd did not come up for the image import; see /tmp/containerd-import.log"
    fi
    n=0
    for t in "$@"; do
        ctr -n k8s.io images import "$t" >/dev/null || die "could not import ${t}"
        n=$((n + 1))
    done
    if [ -n "$IMPORT_CTRD" ]; then
        kill "$IMPORT_CTRD"; wait "$IMPORT_CTRD" 2>/dev/null || true
        IMPORT_CTRD=
        for _ in $(seq 30); do [ -S "$SOCK" ] || break; sleep 1; done
        rm -f "$SOCK"
    fi
    log "preloaded ${n} image archive(s) from ${IMAGES_DIR}"
fi

# ------------------------------------------------------------------- services
#
# containerd has to be up before kubeadm runs; the kubelet is enabled but left
# stopped, because kubeadm is what starts it once it has written a config. In
# a chroot `systemctl enable` still works - it only writes the symlinks - and
# starting anything is the image's first boot's job.
if live; then
    systemctl daemon-reload
    systemctl enable --now containerd
    systemctl enable kubelet

    # Assert rather than assume: a node that reaches kubeadm without a working
    # CRI fails much later and much less legibly.
    for _ in $(seq 30); do
        crictl --runtime-endpoint unix:///run/containerd/containerd.sock version >/dev/null 2>&1 && break
        sleep 1
    done
    crictl --runtime-endpoint unix:///run/containerd/containerd.sock version >/dev/null ||
        die "containerd is installed but its CRI endpoint never answered"
else
    systemctl enable containerd kubelet
fi

log "done: $(kubeadm version -o short), $(containerd --version | awk '{print $1, $3}'); handlers: $(containerd --config /etc/containerd/config.toml config dump 2>/dev/null | sed -n 's|.*containerd\.runtimes\.\([a-z0-9-]*\)\]$|\1|p' | sort -u | tr '\n' ' ')"
