#!/bin/bash

# ===== Pretty Output (Colors + Helpers) =====
if command -v tput >/dev/null 2>&1 && [[ -t 1 ]]; then
  C_RESET="$(tput sgr0)"
  C_RED="$(tput setaf 1)"
  C_GREEN="$(tput setaf 2)"
  C_YELLOW="$(tput setaf 3)"
  C_BLUE="$(tput setaf 4)"
  C_MAGENTA="$(tput setaf 5)"
  C_CYAN="$(tput setaf 6)"
  C_BOLD="$(tput bold)"
else
  C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_MAGENTA=""; C_CYAN=""; C_BOLD=""
fi

msg()   { echo -e "${C_CYAN}${C_BOLD}[*]${C_RESET} $*"; }
ok()    { echo -e "${C_GREEN}${C_BOLD}[✓]${C_RESET} $*"; }
warn()  { echo -e "${C_YELLOW}${C_BOLD}[!]${C_RESET} $*"; }
err()   { echo -e "${C_RED}${C_BOLD}[✗]${C_RESET} $*"; }
step()  { echo -e "\n${C_BLUE}${C_BOLD}==> $*${C_RESET}"; }
title() { echo -e "${C_MAGENTA}${C_BOLD}$*${C_RESET}"; }
line()  { echo -e "${C_BLUE}--------------------------------------------------${C_RESET}"; }

SYS_PATH="/etc/sysctl.conf"
PROF_PATH="/etc/profile"
SSH_PATH="/etc/ssh/sshd_config"
SWAP_PATH="/swapfile"
SWAP_SIZE=4G

CHECK_MODE=false
for arg in "$@"; do
  case "$arg" in
    --check|--analyze)
      CHECK_MODE=true
      CHECK_ARG="$arg"
      ;;
  esac
done

ensure_root() {
  if [[ "$EUID" -ne '0' ]]; then
    echo
    err 'Error: You must run this script as root!'
    echo
    return 1
  fi
  return 0
}

run_preflight() {
  local errors=0 warnings=0 iface os_name kernel_version mtu default_route qdisc_info

  step "Root verification"
  if ensure_root; then
    ok 'Running as root'
  else
    ((errors++))
  fi

  step "System information"
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    os_name=$(source /etc/os-release && echo "${PRETTY_NAME:-$NAME}")
  else
    os_name="Unknown"
  fi
  kernel_version=$(uname -r 2>/dev/null || true)
  msg "OS: ${os_name:-Unavailable}"
  msg "Kernel: ${kernel_version:-Unavailable}"

  step "Command availability"
  for cmd in ip tc sysctl; do
    if command -v "$cmd" >/dev/null 2>&1; then
      ok "Found required command: $cmd"
    else
      err "Missing required command: $cmd"
      ((errors++))
    fi
  done
  if command -v ethtool >/dev/null 2>&1; then
    ok 'Found optional command: ethtool'
  else
    warn 'Optional command missing: ethtool'
    ((warnings++))
  fi

  step "Default network interface"
  if ! command -v ip >/dev/null 2>&1; then
    err 'Could not determine default network interface (missing ip command)'
  else
    default_route=$(ip route show default 0.0.0.0/0 2>/dev/null | head -n1)
    iface=$(echo "$default_route" | awk '/default/ {for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n1)
    if [[ -z "$iface" ]]; then
      iface=$(ip -6 route show default 2>/dev/null | awk '/default/ {for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n1)
    fi
    if [[ -z "$iface" ]]; then
      err 'Could not determine default network interface'
      ((errors++))
    else
      ok "Default interface: $iface"
      if command -v tc >/dev/null 2>&1; then
        qdisc_info=$(tc qdisc show dev "$iface" 2>/dev/null | head -n1)
        msg "Qdisc: ${qdisc_info:-Unavailable}"
      else
        msg 'Qdisc: Unavailable (tc missing)'
      fi
      if command -v ethtool >/dev/null 2>&1; then
        msg "Driver info:"
        ethtool -i "$iface" 2>/dev/null || warn "Unable to read driver info for $iface"
        msg "Ring parameters:"
        ethtool -g "$iface" 2>/dev/null || warn "Unable to read ring parameters for $iface"
        msg "Offload features:"
        ethtool -k "$iface" 2>/dev/null || warn "Unable to read features for $iface"
      fi
      mtu=$(ip -o link show dev "$iface" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="mtu") print $(i+1)}')
      msg "MTU: ${mtu:-Unavailable}"
    fi
  fi

  step "Configuration file readability"
  for path in "$SYS_PATH" "$PROF_PATH" "$SSH_PATH"; do
    if [[ -r "$path" ]]; then
      ok "Readable: $path"
    else
      err "Unreadable or missing: $path"
      ((errors++))
    fi
  done

  if ((errors > 0)); then
    err "Preflight summary: ERROR (errors: $errors, warnings: $warnings)"
    return 1
  elif ((warnings > 0)); then
    warn "Preflight summary: WARN (warnings: $warnings)"
    return 0
  else
    ok 'Preflight summary: OK'
    return 0
  fi
}

if $CHECK_MODE; then
  run_preflight
  exit $?
fi

ensure_root || exit 1

clear 2>/dev/null || true
line
title "XRAY / VPN Optimizer"
msg "Amirjon"
line

step "System update"
apt -q update
apt -y upgrade
apt -y full-upgrade
apt -y autoremove
apt -y -q autoclean
apt -y clean
apt -q update
apt -y upgrade
apt -y full-upgrade
apt -y autoremove --purge
ok 'System updated successfully'

step "Disable terminal ads"
sed -i 's/ENABLED=1/ENABLED=0/g' /etc/default/motd-news
if command -v pro >/dev/null 2>&1; then
  pro config set apt_news=false
fi
ok 'Terminal ads disabled'

step "Install essential packages"
apt -y install apt-transport-https apt-utils bash-completion busybox ca-certificates cron curl gnupg2 locales lsb-release nano preload screen software-properties-common unzip vim wget xxd zip autoconf automake bash-completion build-essential git libtool make pkg-config python3 python3-pip bc binutils binutils-common binutils-x86-64-linux-gnu ubuntu-keyring haveged jq libsodium-dev libsqlite3-dev libssl-dev packagekit qrencode socat dialog htop net-tools mtr nload iftop
ok 'Essential packages installed successfully'

step "Enable services at boot"
systemctl enable cron haveged preload
ok 'Services enabled successfully'

step "Create optimized SWAP"
fallocate -l $SWAP_SIZE $SWAP_PATH
chmod 600 $SWAP_PATH
mkswap $SWAP_PATH
swapon $SWAP_PATH
echo "$SWAP_PATH none swap sw 0 0" >> /etc/fstab
ok 'SWAP created successfully'

step "Apply sysctl tuning"
cp $SYS_PATH /etc/sysctl.conf.bak
msg 'Backup saved to /etc/sysctl.conf.bak'

sed -i -e '/fs.file-max/d' \
  -e '/fs.nr_open/d' \
  -e '/fs.inotify.max_user_watches/d' \
  -e '/fs.inotify.max_user_instances/d' \
  -e '/net.core.default_qdisc/d' \
  -e '/net.core.netdev_max_backlog/d' \
  -e '/net.core.optmem_max/d' \
  -e '/net.core.somaxconn/d' \
  -e '/net.core.rmem_max/d' \
  -e '/net.core.wmem_max/d' \
  -e '/net.core.rmem_default/d' \
  -e '/net.core.wmem_default/d' \
  -e '/net.ipv4.tcp_rmem/d' \
  -e '/net.ipv4.tcp_wmem/d' \
  -e '/net.ipv4.tcp_congestion_control/d' \
  -e '/net.ipv4.tcp_fastopen/d' \
  -e '/net.ipv4.tcp_fin_timeout/d' \
  -e '/net.ipv4.tcp_keepalive_time/d' \
  -e '/net.ipv4.tcp_keepalive_probes/d' \
  -e '/net.ipv4.tcp_keepalive_intvl/d' \
  -e '/net.ipv4.tcp_max_orphans/d' \
  -e '/net.ipv4.tcp_max_syn_backlog/d' \
  -e '/net.ipv4.tcp_max_tw_buckets/d' \
  -e '/net.ipv4.tcp_mem/d' \
  -e '/net.ipv4.tcp_mtu_probing/d' \
  -e '/net.ipv4.tcp_notsent_lowat/d' \
  -e '/net.ipv4.tcp_retries2/d' \
  -e '/net.ipv4.tcp_sack/d' \
  -e '/net.ipv4.tcp_dsack/d' \
  -e '/net.ipv4.tcp_slow_start_after_idle/d' \
  -e '/net.ipv4.tcp_window_scaling/d' \
  -e '/net.ipv4.tcp_adv_win_scale/d' \
  -e '/net.ipv4.tcp_ecn/d' \
  -e '/net.ipv4.tcp_ecn_fallback/d' \
  -e '/net.ipv4.tcp_syncookies/d' \
  -e '/net.ipv4.udp_mem/d' \
  -e '/net.ipv6.conf.all.disable_ipv6/d' \
  -e '/net.ipv6.conf.default.disable_ipv6/d' \
  -e '/net.ipv6.conf.lo.disable_ipv6/d' \
  -e '/net.unix.max_dgram_qlen/d' \
  -e '/vm.min_free_kbytes/d' \
  -e '/vm.swappiness/d' \
  -e '/vm.vfs_cache_pressure/d' \
  -e '/net.ipv4.conf.default.rp_filter/d' \
  -e '/net.ipv4.conf.all.rp_filter/d' \
  -e '/net.ipv4.conf.all.accept_source_route/d' \
  -e '/net.ipv4.conf.default.accept_source_route/d' \
  -e '/net.ipv4.neigh.default.gc_thresh1/d' \
  -e '/net.ipv4.neigh.default.gc_thresh2/d' \
  -e '/net.ipv4.neigh.default.gc_thresh3/d' \
  -e '/net.ipv4.neigh.default.gc_stale_time/d' \
  -e '/net.ipv4.conf.default.arp_announce/d' \
  -e '/net.ipv4.conf.lo.arp_announce/d' \
  -e '/net.ipv4.conf.all.arp_announce/d' \
  -e '/kernel.panic/d' \
  -e '/vm.dirty_ratio/d' \
  -e '/vm.overcommit_memory/d' \
  -e '/vm.overcommit_ratio/d' \
  -e '/net.ipv4.tcp_autocorking/d' \
  -e '/net.ipv4.tcp_defer_accept/d' \
  -e '/net.ipv4.tcp_timestamps/d' \
  -e '/net.ipv4.tcp_notsent_lowat/d' \
  -e '/net.ipv4.tcp_frto/d' \
  -e '/net.ipv4.ip_local_port_range/d' \
  -e '/net.ipv4.tcp_rfc1337/d' \
  -e '/net.ipv4.tcp_tw_reuse/d' \
  -e '/net.ipv4.tcp_low_latency/d' \
  -e '/net.ipv4.tcp_delack_min/d' \
  -e '/net.ipv4.tcp_thin_linear_timeouts/d' \
  -e '/net.ipv4.ip_forward/d' \
  -e '/net.ipv4.udp_l3mdev_accept/d' \
  -e '/net.ipv4.tcp_l3mdev_accept/d' \
  -e '/kernel.shmmax/d' \
  -e '/kernel.shmall/d' \
  -e '/kernel.shmmni/d' \
  -e '/kernel.sem/d' \
  -e '/kernel.msgmni/d' \
  -e '/kernel.msgmax/d' \
  -e '/kernel.msgmnb/d' \
  -e '/net.ipv4.tcp_mtu_probing/d' \
  -e '/net.ipv4.tcp_base_mss/d' \
  -e '/net.ipv4.tcp_probe_interval/d' \
  -e '/net.ipv4.tcp_probe_threshold/d' \
  -e '/net.ipv4.tcp_synack_retries/d' \
  -e '/net.ipv4.tcp_syn_retries/d' \
  -e '/vm.dirty_background_ratio/d' \
  -e '/vm.dirty_expire_centisecs/d' \
  -e '/vm.dirty_writeback_centisecs/d' \
  -e '/kernel.numa_balancing/d' \
  -e '/kernel.sched_min_granularity_ns/d' \
  -e '/kernel.sched_wakeup_granularity_ns/d' \
  -e '/kernel.sched_migration_cost_ns/d' \
  -e '/kernel.sched_autogroup_enabled/d' \
  -e '/^#/d' \
  -e '/^$/d' \
  "$SYS_PATH"
  
cat << 'EOF' > "$SYS_PATH"
################################################################
#          Advanced Network Optimization for Xray-Core          #
#               Visit @NotePadVPN for more tools                #
################################################################

# File system limits - Critical for high concurrent connections
fs.file-max = 268435456
fs.nr_open = 134217728
fs.inotify.max_user_watches = 1048576
fs.inotify.max_user_instances = 16384

# Network core optimization (stable defaults)
net.core.default_qdisc = codel
net.core.netdev_max_backlog = 262144
net.core.optmem_max = 4194304
net.core.somaxconn = 131072
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.core.rmem_default = 4194304
net.core.wmem_default = 4194304

# TCP optimization for Xray-Core and VPN services (lossy/stable profile)
net.ipv4.tcp_rmem = 32768 4194304 134217728
net.ipv4.tcp_wmem = 32768 4194304 134217728
net.ipv4.tcp_congestion_control = cubic
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_keepalive_time = 120
net.ipv4.tcp_keepalive_probes = 15
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_max_orphans = 4194304
net.ipv4.tcp_max_syn_backlog = 65536
net.ipv4.tcp_max_tw_buckets = 16777216
net.ipv4.tcp_mem = 786432 4194304 33554432
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_notsent_lowat = 4096
net.ipv4.tcp_retries2 = 5
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_adv_win_scale = -2
net.ipv4.tcp_ecn = 0
net.ipv4.tcp_ecn_fallback = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_low_latency = 1
net.ipv4.tcp_delack_min = 5
net.ipv4.tcp_thin_linear_timeouts = 1
net.ipv4.tcp_defer_accept = 5
net.ipv4.tcp_timestamps = 0
net.ipv4.tcp_autocorking = 0
net.ipv4.tcp_frto = 1
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_base_mss = 1024

# UDP optimization - essential for QUIC and UDP-based protocols in Xray
net.ipv4.udp_mem = 786432 4194304 33554432

# IPv6 settings
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
net.ipv6.conf.lo.disable_ipv6 = 0
net.ipv6.conf.all.forwarding = 1

# Unix socket optimization
net.unix.max_dgram_qlen = 1024

# Virtual memory optimization
vm.min_free_kbytes = 524288
vm.swappiness = 5
vm.vfs_cache_pressure = 150
vm.dirty_ratio = 10
vm.dirty_background_ratio = 3
vm.dirty_expire_centisecs = 1000
vm.dirty_writeback_centisecs = 300
vm.overcommit_memory = 0
vm.overcommit_ratio = 50

# Network security and routing settings
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.neigh.default.gc_thresh1 = 8192
net.ipv4.neigh.default.gc_thresh2 = 16384
net.ipv4.neigh.default.gc_thresh3 = 32768
net.ipv4.neigh.default.gc_stale_time = 60
net.ipv4.conf.default.arp_announce = 2
net.ipv4.conf.lo.arp_announce = 2
net.ipv4.conf.all.arp_announce = 2
net.ipv4.ip_forward = 1
net.ipv4.udp_l3mdev_accept = 1
net.ipv4.tcp_l3mdev_accept = 1

# Kernel optimization
kernel.panic = 5
kernel.sched_min_granularity_ns = 10000000
kernel.sched_wakeup_granularity_ns = 15000000
kernel.sched_migration_cost_ns = 5000000
kernel.sched_autogroup_enabled = 0
kernel.numa_balancing = 0
kernel.shmmax = 137438953472
kernel.shmall = 8589934592
kernel.shmmni = 32768
kernel.sem = 500 64000 200 2048
kernel.msgmni = 65536
kernel.msgmax = 131072
kernel.msgmnb = 131072
EOF

sysctl -p
ok 'Network optimization complete - Xray-Core ready for high performance'

# --- Extra sysctl tweaks for throughput + stability (Xray/VPN) ---
# Append only (do not replace existing sysctl.conf content)
cat <<'EOF' >> /etc/sysctl.conf

################################################################
# Extra Network / TCP tuning for speed + stability (add-on)
################################################################

# Core buffers / queueing
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.core.rmem_default = 16777216
net.core.wmem_default = 16777216
net.core.netdev_max_backlog = 30000
net.core.netdev_budget = 600
net.core.netdev_budget_usecs = 8000
net.core.somaxconn = 32768
net.unix.max_dgram_qlen = 512

# TCP buffers (balanced)
net.ipv4.tcp_rmem = 8192 131072 134217728
net.ipv4.tcp_wmem = 8192 131072 134217728

# Congestion + qdisc (latency control)
net.core.default_qdisc = codel
net.ipv4.tcp_congestion_control = cubic

# TCP behavior
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_max_tw_buckets = 2000000
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_fack = 1
net.ipv4.tcp_ecn = 0
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_synack_retries = 3
net.ipv4.tcp_retries1 = 3
net.ipv4.tcp_retries2 = 8
net.ipv4.tcp_orphan_retries = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_mtu_probing = 2

# Routing / forwarding (needed for VPN)
net.ipv4.ip_forward = 1

# Conntrack (helps stability on many connections)
net.netfilter.nf_conntrack_max = 1048576
net.netfilter.nf_conntrack_buckets = 262144
net.netfilter.nf_conntrack_tcp_timeout_established = 432000
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 60
net.netfilter.nf_conntrack_udp_timeout = 30
net.netfilter.nf_conntrack_udp_timeout_stream = 120
net.netfilter.nf_conntrack_tcp_be_liberal = 1
net.netfilter.nf_conntrack_tcp_loose = 1

# VM baseline
vm.swappiness = 10
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
vm.dirty_expire_centisecs = 1500
vm.dirty_writeback_centisecs = 500
vm.vfs_cache_pressure = 50
vm.min_free_kbytes = 131072

# File descriptors / watchers
fs.file-max = 2097152
fs.nr_open = 2097152
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 256
fs.inotify.max_queued_events = 32768
fs.aio-max-nr = 1048576
fs.pipe-max-size = 4194304

EOF

# Apply sysctl (do not fail the whole script if some keys are unsupported)
sysctl -p /etc/sysctl.conf >/dev/null 2>&1 || true

# Optional speed-oriented TCP profile for clean links (BBR + FQ_CoDel)
echo
warn "Do you want to enable optional BBR speed profile? (y/n)"
read -r speed_profile_choice

if [[ "$speed_profile_choice" =~ ^[Yy]$ ]]; then
  sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 || true
  sysctl -w net.core.default_qdisc=fq_codel >/dev/null 2>&1 || true
  ok "Speed profile applied (BBR + FQ_CoDel)."
else
  msg "Stable profile retained (Cubic + CoDel)."
fi

step 'Optimize SSH'
cp $SSH_PATH /etc/ssh/sshd_config.bak
msg 'SSH config backup saved to /etc/ssh/sshd_config.bak'

sed -i -e 's/#UseDNS yes/UseDNS no/' \
  -e 's/#Compression no/Compression yes/' \
  -e 's/Ciphers .*/Ciphers aes256-ctr,chacha20-poly1305@openssh.com/' \
  -e '/MaxAuthTries/d' \
  -e '/MaxSessions/d' \
  -e '/TCPKeepAlive/d' \
  -e '/ClientAliveInterval/d' \
  -e '/ClientAliveCountMax/d' \
  -e '/AllowAgentForwarding/d' \
  -e '/AllowTcpForwarding/d' \
  -e '/GatewayPorts/d' \
  -e '/PermitTunnel/d' \
  -e '/X11Forwarding/d' "$SSH_PATH"

echo "MaxAuthTries 10" | tee -a "$SSH_PATH"
echo "MaxSessions 100" | tee -a "$SSH_PATH"
echo "TCPKeepAlive yes" | tee -a "$SSH_PATH"
echo "ClientAliveInterval 3000" | tee -a "$SSH_PATH"
echo "ClientAliveCountMax 100" | tee -a "$SSH_PATH"
echo "AllowAgentForwarding yes" | tee -a "$SSH_PATH"
echo "AllowTcpForwarding yes" | tee -a "$SSH_PATH"
echo "GatewayPorts yes" | tee -a "$SSH_PATH"
echo "PermitTunnel yes" | tee -a "$SSH_PATH"
echo "X11Forwarding yes" | tee -a "$SSH_PATH"

systemctl restart ssh
ok 'SSH optimized for better connections'

step 'Optimize system limits for Xray-Core high concurrent connections'
sed -i '/ulimit -c/d' $PROF_PATH
sed -i '/ulimit -d/d' $PROF_PATH
sed -i '/ulimit -f/d' $PROF_PATH
sed -i '/ulimit -i/d' $PROF_PATH
sed -i '/ulimit -l/d' $PROF_PATH
sed -i '/ulimit -m/d' $PROF_PATH
sed -i '/ulimit -n/d' $PROF_PATH
sed -i '/ulimit -q/d' $PROF_PATH
sed -i '/ulimit -s/d' $PROF_PATH
sed -i '/ulimit -t/d' $PROF_PATH
sed -i '/ulimit -u/d' $PROF_PATH
sed -i '/ulimit -v/d' $PROF_PATH
sed -i '/ulimit -x/d' $PROF_PATH

echo "ulimit -c unlimited" | tee -a $PROF_PATH
echo "ulimit -d unlimited" | tee -a $PROF_PATH
echo "ulimit -f unlimited" | tee -a $PROF_PATH
echo "ulimit -i unlimited" | tee -a $PROF_PATH
echo "ulimit -l unlimited" | tee -a $PROF_PATH
echo "ulimit -m unlimited" | tee -a $PROF_PATH
echo "ulimit -n 1048576" | tee -a $PROF_PATH
echo "ulimit -q unlimited" | tee -a $PROF_PATH
echo "ulimit -s -H 65536" | tee -a $PROF_PATH
echo "ulimit -s 32768" | tee -a $PROF_PATH
echo "ulimit -t unlimited" | tee -a $PROF_PATH
echo "ulimit -u unlimited" | tee -a $PROF_PATH
echo "ulimit -v unlimited" | tee -a $PROF_PATH
echo "ulimit -x unlimited" | tee -a $PROF_PATH
ok 'System limits optimized for maximum connections'

# --- Safe NIC tuning for stability (no logs) ---
apt -y install ethtool >/dev/null 2>&1 || true

IFACE=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
if [[ -n "$IFACE" ]]; then

  # Increase ring buffers to NIC maximum (if supported)
  RING="$(ethtool -g "$IFACE" 2>/dev/null || true)"
  MAX_RX="$(echo "$RING" | awk '/Pre-set maximums:/,0' | awk '/RX:/ {print $2; exit}')"
  MAX_TX="$(echo "$RING" | awk '/Pre-set maximums:/,0' | awk '/TX:/ {print $2; exit}')"

  args=()
  [[ -n "$MAX_RX" ]] && args+=(rx "$MAX_RX")
  [[ -n "$MAX_TX" ]] && args+=(tx "$MAX_TX")
  [[ ${#args[@]} -gt 0 ]] && ethtool -G "$IFACE" "${args[@]}" 2>/dev/null || true

  # Enable safe, low-risk NIC features
  ethtool -K "$IFACE" rx-checksumming on 2>/dev/null || true
  ethtool -K "$IFACE" tx-checksumming on 2>/dev/null || true
  ethtool -K "$IFACE" scatter-gather on 2>/dev/null || true
  ethtool -K "$IFACE" receive-hashing on 2>/dev/null || true

fi

# Ensure tc is available
if ! command -v tc >/dev/null 2>&1; then
  step "Install iproute2 (tc command)"
  apt -y install iproute2
fi

step "Applying traffic control (TC) to reduce packet loss/jitter"

apply_tc_smart() {
  # Detect main interface
  local IFACE
  IFACE=$(ip route get 8.8.8.8 2>/dev/null | awk '/dev/ {print $5; exit}')

  if [ -z "$IFACE" ]; then
    err "Could not detect default network interface. Skipping TC."
    return 1
  fi

  # Cleanup old qdisc
  tc qdisc del dev "$IFACE" root 2>/dev/null
  tc qdisc del dev "$IFACE" ingress 2>/dev/null

  # Adjust txqueuelen (safe default)
  echo 1000 > "/sys/class/net/$IFACE/tx_queue_len" 2>/dev/null

  # Try CAKE -> FQ_CoDel -> PFIFO
  if tc qdisc add dev "$IFACE" root handle 1: cake bandwidth 1000mbit rtt 20ms 2>/dev/null; then
    ok "CAKE queue discipline applied on $IFACE"
    return 0

  elif tc qdisc add dev "$IFACE" root handle 1: fq_codel limit 10240 flows 1024 target 5ms interval 100ms 2>/dev/null; then
    ok "FQ_CoDel queue discipline applied on $IFACE"
    return 0

  elif tc qdisc add dev "$IFACE" root handle 1: pfifo_fast 2>/dev/null; then
    warn "Fallback pfifo_fast applied on $IFACE"
    return 0
  fi

  err "Failed to apply TC optimization on $IFACE"
  return 1
}

# Run once now (always)
apply_tc_smart

echo
warn "Apply Netem impairments (adds artificial loss/jitter)? (y/n) [default: n]"
read -r netem_choice

if [[ "$netem_choice" =~ ^[Yy]$ ]]; then
  IFACE=$(ip route get 8.8.8.8 2>/dev/null | awk '/dev/ {print $5; exit}')
  if [[ -n "$IFACE" ]]; then
    tc qdisc add dev "$IFACE" parent 1: handle 10: netem delay 1ms loss 0.005% duplicate 0.05% reorder 0.5% 2>/dev/null && \
      ok "Netem impairments enabled on $IFACE" || \
      warn "Could not enable Netem on $IFACE"
  else
    warn "No interface detected for Netem application."
  fi
else
  msg "Netem skipped; clean CAKE/FQ_CoDel path in use."
fi

line
ok 'Optimization complete'
msg 'Recommended: test stability and reboot only if needed'
line
