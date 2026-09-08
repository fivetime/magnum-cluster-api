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

set -Eeuo pipefail

log() { printf '[node-bootstrap] %s\n' "$*"; }
die() { printf '[node-bootstrap] %s\n' "$*" >&2; exit 1; }

CONF=${NODE_BOOTSTRAP_CONF:-/run/kubeadm/node-bootstrap.env}
if [ -r "$CONF" ]; then
    # shellcheck disable=SC1090
    . "$CONF"
fi

: "${K8S_VERSION:?K8S_VERSION is required (written by the nodeBootstrap patch)}"

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

log "installing the Kubernetes ${K8S_VERSION} node stack for ${ARCH}"
log "  containerd ${CONTAINERD_VERSION}, runc ${RUNC_VERSION}, crun ${CRUN_VERSION}"
log "  cni-plugins ${CNI_PLUGINS_VERSION}, cri-tools ${CRI_TOOLS_VERSION}"
[ -n "$MIRROR" ] && log "  mirror: ${MIRROR}"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
cd "$TMPDIR"

fetch() { curl -fsSL --retry 5 --retry-delay 2 -o "$2" "$1" || die "could not fetch $1"; }

# ------------------------------------------------------------ distro packages
#
# kubeadm's preflight refuses to run without conntrack and socat, and the
# kubelet needs ethtool and the bridge tooling. A cloud image has none of them.
if command -v apt-get >/dev/null; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends \
        conntrack socat ebtables ethtool iptables iproute2 kmod lvm2 \
        logrotate libseccomp2 curl ca-certificates
elif command -v dnf >/dev/null; then
    dnf install -y -q \
        conntrack-tools socat ebtables ethtool iptables-nft iproute kmod lvm2 \
        logrotate libseccomp curl ca-certificates
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
modprobe overlay
modprobe br_netfilter

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
sysctl --system >/dev/null

# ------------------------------------------------------------------- services
#
# containerd has to be up before kubeadm runs; the kubelet is enabled but left
# stopped, because kubeadm is what starts it once it has written a config.
systemctl daemon-reload
systemctl enable --now containerd
systemctl enable kubelet

# Assert rather than assume: a node that reaches kubeadm without a working CRI
# fails much later and much less legibly.
for _ in $(seq 30); do
    crictl --runtime-endpoint unix:///run/containerd/containerd.sock version >/dev/null 2>&1 && break
    sleep 1
done
crictl --runtime-endpoint unix:///run/containerd/containerd.sock version >/dev/null ||
    die "containerd is installed but its CRI endpoint never answered"

log "done: $(kubeadm version -o short), $(containerd --version | awk '{print $1, $3}')"
