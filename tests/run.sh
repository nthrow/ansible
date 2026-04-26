#!/bin/sh
# tests/run.sh — end-to-end validation harness for the alpine-ansible repo.
#
# Spins up a docker network + N alpine containers, applies the relevant
# playbooks against them, verifies expected service state + data flow,
# tears down. Pure POSIX sh; works under bash/dash/fish-with-bash.
#
# Usage:
#   tests/run.sh                  # full suite
#   tests/run.sh cdn              # just the CDN PoC
#   tests/run.sh wg               # just wireguard
#   tests/run.sh obs              # just observability
#   tests/run.sh docker           # just docker_host
#   tests/run.sh --keep           # don't tear down at end (debug)
#
# Requires: docker, ssh, ssh-keygen on the host. The wireguard kernel
# module on the host kernel for the wg test (modprobe wireguard).

set -eu

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NETWORK=cdn-poc-test
SUBNET=172.31.0.0/24
KEEP_RUNNING=
TESTS=

for a in "$@"; do
    case "$a" in
        --keep) KEEP_RUNNING=1 ;;
        --no-idempotency) NO_IDEMP=1 ;;
        static|cdn|wg|obs|docker) TESTS="${TESTS:-} $a" ;;
        *) echo "unknown arg: $a" >&2; exit 2 ;;
    esac
done
TESTS="${TESTS:-static cdn obs docker wg}"

log()     { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
ok()      { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
fail()    { printf '\033[1;31m  ✗\033[0m %s\n' "$*"; FAILED=1; }
warn()    { printf '\033[1;33m  ⚠\033[0m %s\n' "$*"; }
section() { echo; printf '\033[1;36m=== %s ===\033[0m\n' "$*"; }

FAILED=0
START=$(date +%s)

# -----------------------------------------------------------------
# Container provisioning
# -----------------------------------------------------------------

KEYFILE="$HOME/.ssh/alpine-ansible-test"
if [ ! -f "$KEYFILE" ]; then
    ssh-keygen -t ed25519 -N "" -f "$KEYFILE" -q
fi
PUBKEY="$(cat "${KEYFILE}.pub")"

ssh_to() {
    # ssh_to <port> <command...>
    port=$1; shift
    ssh -i "$KEYFILE" -p "$port" \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        admin@localhost "$@"
}

spawn_container() {
    # spawn_container <name> <port> <ip> [extra-docker-flags ...]
    name=$1; port=$2; ip=$3; shift 3
    docker rm -f "$name" >/dev/null 2>&1 || true
    docker run -d --name "$name" \
        --network "$NETWORK" --ip "$ip" \
        --hostname "$name" \
        --tmpfs /run --tmpfs /tmp:exec \
        --cap-add NET_ADMIN --cap-add SYS_ADMIN \
        "$@" \
        -p "${port}:22" \
        alpine:latest sh -c "
            apk add --no-cache openssh openrc doas python3 tar curl &&
            (id admin >/dev/null 2>&1 || adduser -D -G wheel admin) &&
            echo 'permit nopass :wheel' > /etc/doas.d/wheel.conf &&
            chmod 0400 /etc/doas.d/wheel.conf &&
            mkdir -p /home/admin/.ssh &&
            echo '$PUBKEY' > /home/admin/.ssh/authorized_keys &&
            chmod 0700 /home/admin/.ssh &&
            chmod 0600 /home/admin/.ssh/authorized_keys &&
            chown -R admin:admin /home/admin/.ssh &&
            ssh-keygen -A &&
            mkdir -p /run/openrc && touch /run/openrc/softlevel &&
            /usr/sbin/sshd -D -e
        " >/dev/null
}

wait_for_ssh() {
    # wait_for_ssh <port>
    for _ in $(seq 30); do
        if ssh_to "$1" true 2>/dev/null; then return 0; fi
        sleep 1
    done
    fail "ssh on :$1 never came up"
    return 1
}

setup_host_quirks() {
    # remount cgroup rw + tmp exec on each host
    for p in "$@"; do
        ssh_to "$p" 'doas mount -o remount,rw /sys/fs/cgroup 2>/dev/null; doas mount -o remount,exec /tmp 2>/dev/null; true'
    done
}

# Run a play a second time and confirm zero changes. Container quirks
# can make `state: started` flap on rerun even when configs are stable,
# so we tolerate a small known set of cosmetic re-runs (`changed` on
# service tasks only) and only hard-fail when templates/copies report
# drift.
assert_idempotent() {
    # assert_idempotent <play> <inv> <label>
    play=$1; inv=$2; label=$3
    if [ -n "${NO_IDEMP:-}" ]; then return 0; fi
    log "idempotency: rerun $label"
    OUT=$(ssh_to 22210 "cd ansible && ANSIBLE_CONFIG=/home/admin/ansible/ansible.cfg \
        ansible-playbook -i $inv $play 2>&1") || true
    RECAP=$(echo "$OUT" | grep -E '^[a-z][^ ]+ +: ' || true)
    if echo "$OUT" | grep -qE 'failed=[1-9]'; then
        fail "second run failed:"
        echo "$OUT" | tail -15
        return
    fi
    # Sum changed across all hosts in recap.
    CHANGES=$(echo "$RECAP" | awk '{for (i=1; i<=NF; i++) if ($i ~ /^changed=/) {split($i, a, "="); s+=a[2]}} END {print s+0}')
    if [ "$CHANGES" -eq 0 ]; then
        ok "idempotent: changed=0 on rerun"
    else
        # Were the changes all `service` tasks? grep the task list for
        # "changed:" lines and check if all parent tasks are service-related.
        SERVICE_ONLY=$(echo "$OUT" | awk '
            /^TASK \[/ { task=$0 }
            /^changed:/ { if (task ~ /Enable |restart |reload |service|started/) sok++; else nonsok++ }
            END { print (nonsok == 0 && sok > 0) ? "yes" : "no" }')
        if [ "$SERVICE_ONLY" = "yes" ]; then
            warn "idempotent except for service-state tasks (container artifact, $CHANGES changes)"
        else
            fail "non-idempotent: $CHANGES changes on rerun (not just service tasks)"
            echo "$OUT" | grep -B1 "^changed:" | head -30
        fi
    fi
}

teardown() {
    if [ -n "$KEEP_RUNNING" ]; then
        log "containers kept running; cleanup with: docker rm -f \$(docker ps -aq --filter network=$NETWORK)"
        return
    fi
    log "tearing down"
    docker rm -f $(docker ps -aq --filter "network=$NETWORK") >/dev/null 2>&1 || true
    docker network rm "$NETWORK" >/dev/null 2>&1 || true
}
trap teardown EXIT INT

log "creating network $NETWORK"
docker network rm "$NETWORK" >/dev/null 2>&1 || true
docker network create --subnet="$SUBNET" "$NETWORK" >/dev/null

# Always spin up the controller (a host with ansible installed)
log "spawning controller"
spawn_container controller 22210 172.31.0.5
wait_for_ssh 22210
setup_host_quirks 22210
ssh_to 22210 'doas apk add --quiet ansible-core py3-yaml py3-jmespath openssh-client tar 2>&1 >/dev/null
ssh-keygen -t ed25519 -f /home/admin/.ssh/id_ed25519 -N "" -q
cat /home/admin/.ssh/id_ed25519.pub' > /tmp/controller_pubkey
ok "controller ready (ansible installed)"

# Push the repo into the controller
log "pushing repo"
docker cp "$REPO_ROOT/." controller:/home/admin/ansible/
ssh_to 22210 'doas chown -R admin:admin /home/admin/ansible
cd /home/admin/ansible && ansible-galaxy collection install community.general community.crypto community.docker ansible.posix 2>&1 | grep -c installed'
ok "collections installed"

# -----------------------------------------------------------------
# Test: static analysis (ansible-lint + yamllint)
# -----------------------------------------------------------------
case " $TESTS " in (*' static '*)
section "static analysis"

log "installing ansible-lint + yamllint"
ssh_to 22210 'doas apk add --quiet py3-pip 2>/dev/null
pip install --quiet --break-system-packages --disable-pip-version-check \
    ansible-lint yamllint 2>&1 | tail -1' >/dev/null

log "yamllint"
# We use deliberate alignment in inventory (padded braces, columns),
# so disable the whitespace rules and just keep structural checks.
YL_CONFIG='{extends: default, rules: {
  line-length: disable,
  truthy: disable,
  document-start: disable,
  braces: disable,
  colons: disable,
  commas: disable,
  indentation: {spaces: 2, indent-sequences: consistent}
}}'
YL_OUT=$(ssh_to 22210 "cd ansible && yamllint -d '$YL_CONFIG' \
    inventory roles playbooks 2>&1" || true)
YL_ERR=$(echo "$YL_OUT" | grep -cE '\[error\]' || true)
YL_WARN=$(echo "$YL_OUT" | grep -cE '\[warning\]' || true)
if [ "$YL_ERR" -gt 0 ]; then
    fail "yamllint: $YL_ERR error(s)"
    echo "$YL_OUT" | grep -E '\[error\]' | head -10
elif [ "$YL_WARN" -gt 0 ]; then
    warn "yamllint: $YL_WARN warning(s)"
    echo "$YL_OUT" | grep -E '\[warning\]' | head -5
else
    ok "yamllint clean"
fi

log "ansible-lint"
LINT_OUT=$(ssh_to 22210 'cd ansible && ansible-lint --offline --nocolor \
    playbooks/*.yml 2>&1' || true)
LINT_FAIL=$(echo "$LINT_OUT" | grep -cE '^Failed: ' || true)
LINT_ISSUES=$(echo "$LINT_OUT" | grep -cE '^[a-z][a-z0-9_-]+\[' || true)
if [ "$LINT_FAIL" -gt 0 ]; then
    # Failed: <n> failure(s)... line tells us the count
    NUM=$(echo "$LINT_OUT" | grep -oE '^Failed: [0-9]+' | grep -oE '[0-9]+' | head -1)
    fail "ansible-lint: $NUM rule violation(s)"
    echo "$LINT_OUT" | grep -E '^[a-z][a-z0-9_-]+\[' | head -10
elif [ "$LINT_ISSUES" -gt 0 ]; then
    warn "ansible-lint: $LINT_ISSUES advisory issue(s)"
else
    ok "ansible-lint clean"
fi
;;
esac

# -----------------------------------------------------------------
# Test: CDN PoC
# -----------------------------------------------------------------
case " $TESTS " in (*' cdn '*)
section "cdn-poc"

log "spawning edge / varnish / origin"
spawn_container edge    22220 172.31.0.10
spawn_container varnish 22221 172.31.0.20
spawn_container origin  22222 172.31.0.30
wait_for_ssh 22220 && wait_for_ssh 22221 && wait_for_ssh 22222
setup_host_quirks 22220 22221 22222

# Authorize controller's key on each
for p in 22220 22221 22222; do
    cat /tmp/controller_pubkey | ssh_to $p \
        'cat >> ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys'
done

ssh_to 22210 'cat > /home/admin/cdn-inv.yml <<EOF
all:
  vars:
    ansible_user: admin
    ansible_become: true
    ansible_become_method: doas
    ansible_python_interpreter: /usr/bin/python3
    apk_repositories:
      - http://dl-cdn.alpinelinux.org/alpine/edge/main
      - http://dl-cdn.alpinelinux.org/alpine/edge/community
      - http://dl-cdn.alpinelinux.org/alpine/edge/testing
    base_packages: [curl, htop]
    kernel_packages: []
    timezone: UTC
    keymap: us us
    monitoring_bind_iface: eth0
  children:
    cdn_edges:
      hosts: { edge:    { ansible_host: 172.31.0.10 } }
    cdn_varnish:
      hosts: { varnish: { ansible_host: 172.31.0.20 } }
    cdn_origins:
      hosts: { origin:  { ansible_host: 172.31.0.30 } }
EOF
'

log "running cdn-poc.yml"
if ssh_to 22210 'cd ansible && ANSIBLE_CONFIG=/home/admin/ansible/ansible.cfg \
    ansible-playbook -i /home/admin/cdn-inv.yml playbooks/cdn-poc.yml 2>&1 | tail -3 | grep -q failed=0'; then
    ok "play succeeded"
else
    fail "play failed"
fi

assert_idempotent playbooks/cdn-poc.yml /home/admin/cdn-inv.yml cdn-poc

# Smoke test: curl through the chain
log "smoke-testing chain"
RESP=$(ssh_to 22220 'curl -sSI http://localhost/' 2>/dev/null || true)
echo "$RESP" | grep -qi '^HTTP.*200'   && ok "HTTP 200"   || fail "no 200"
echo "$RESP" | grep -qi 'X-CDN: poc'    && ok "varnish X-CDN header" || fail "no X-CDN header"
echo "$RESP" | grep -qi 'X-Tier: varnish' && ok "varnish X-Tier header" || fail "no X-Tier header"

BODY=$(ssh_to 22220 'curl -s http://localhost/' 2>/dev/null || true)
echo "$BODY" | grep -q 'origin' && ok "origin body served" || fail "wrong body"
;;
esac

# -----------------------------------------------------------------
# Test: WireGuard hub
# -----------------------------------------------------------------
case " $TESTS " in (*' wg '*)
section "wireguard"

if ! lsmod | grep -q wireguard; then
    log "skipping wg test — wireguard kernel module not loaded on host"
else
    log "spawning wg-hub / wg-peer"
    spawn_container wg-hub  22230 172.31.0.50 --sysctl net.ipv4.ip_forward=1
    spawn_container wg-peer 22231 172.31.0.60 --sysctl net.ipv4.ip_forward=1
    wait_for_ssh 22230 && wait_for_ssh 22231
    setup_host_quirks 22230 22231

    for p in 22230 22231; do
        cat /tmp/controller_pubkey | ssh_to $p \
            'cat >> ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys'
    done

    # First: hub-only (no peers) so we know it can bootstrap
    ssh_to 22210 'cat > /home/admin/wg-inv.yml <<EOF
all:
  vars:
    ansible_user: admin
    ansible_become: true
    ansible_become_method: doas
    ansible_python_interpreter: /usr/bin/python3
    apk_repositories:
      - http://dl-cdn.alpinelinux.org/alpine/edge/main
      - http://dl-cdn.alpinelinux.org/alpine/edge/community
    base_packages: [curl]
    kernel_packages: []
    timezone: UTC
    keymap: us us
  children:
    wireguard_servers:
      hosts:
        wg-hub: { ansible_host: 172.31.0.50 }
EOF
cat > /home/admin/wg-play.yml <<EOF
- hosts: wireguard_servers
  vars:
    wireguard_advertise_iface: eth0
    wireguard_subnet_v6: ""
    wireguard_server_address_v6: ""
    wireguard_peers: []
  roles:
    - /home/admin/ansible/roles/wireguard_hub
EOF
'
    log "running wireguard_hub role"
    if ssh_to 22210 'cd ansible && ANSIBLE_CONFIG=/home/admin/ansible/ansible.cfg \
        ansible-playbook -i /home/admin/wg-inv.yml /home/admin/wg-play.yml 2>&1 | tail -3 | grep -q failed=0'; then
        ok "play succeeded"
    else
        fail "play failed"
    fi

    assert_idempotent /home/admin/wg-play.yml /home/admin/wg-inv.yml wireguard_hub

    if ssh_to 22230 'doas wg show wg0 2>/dev/null | grep -q "listening port: 51820"'; then
        ok "wg0 up and listening"
    else
        fail "wg0 didn't come up"
    fi

    # Bring up peer manually + handshake test
    HUB_PUBKEY=$(ssh_to 22230 'doas cat /etc/wireguard/wg0.pub')
    ssh_to 22231 "doas mkdir -p /etc/wireguard
doas chmod 700 /etc/wireguard
doas sh -c \"wg genkey | tee /etc/wireguard/peer.key | wg pubkey > /etc/wireguard/peer.pub\""
    PEER_PUBKEY=$(ssh_to 22231 'doas cat /etc/wireguard/peer.pub')

    # Re-apply hub with the peer
    ssh_to 22210 "cat > /home/admin/wg-play.yml <<EOF
- hosts: wireguard_servers
  vars:
    wireguard_advertise_iface: eth0
    wireguard_subnet_v6: ''
    wireguard_server_address_v6: ''
    wireguard_peers:
      - name: peer1
        public_key: \"$PEER_PUBKEY\"
        allowed_ips: [\"10.0.0.2/32\"]
        persistent_keepalive: 25
  roles:
    - /home/admin/ansible/roles/wireguard_hub
EOF
cd ansible && ANSIBLE_CONFIG=/home/admin/ansible/ansible.cfg \
    ansible-playbook -i /home/admin/wg-inv.yml /home/admin/wg-play.yml 2>&1 | tail -1"

    ssh_to 22231 "doas sh -c '
PRIV=\$(cat /etc/wireguard/peer.key)
cat > /etc/wireguard/wg0.conf <<CONF
[Interface]
PrivateKey = \$PRIV
Address    = 10.0.0.2/24
[Peer]
PublicKey  = $HUB_PUBKEY
Endpoint   = 172.31.0.50:51820
AllowedIPs = 10.0.0.0/24
PersistentKeepalive = 25
CONF
chmod 600 /etc/wireguard/wg0.conf
wg-quick up wg0' >/dev/null 2>&1"

    sleep 3
    if ssh_to 22231 'ping -c 2 -W 2 10.0.0.1 >/dev/null 2>&1'; then
        ok "tunnel up: peer can ping hub"
    else
        fail "tunnel didn't establish"
    fi
fi
;;
esac

# -----------------------------------------------------------------
# Test: docker_host (standalone)
# -----------------------------------------------------------------
case " $TESTS " in (*' docker '*)
section "docker_host"

log "spawning dock"
spawn_container dock 22240 172.31.0.70 --privileged
wait_for_ssh 22240

cat /tmp/controller_pubkey | ssh_to 22240 \
    'cat >> ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys'

ssh_to 22210 'cat > /home/admin/dock-inv.yml <<EOF
all:
  vars:
    ansible_user: admin
    ansible_become: true
    ansible_become_method: doas
    ansible_python_interpreter: /usr/bin/python3
    apk_repositories:
      - http://dl-cdn.alpinelinux.org/alpine/edge/main
      - http://dl-cdn.alpinelinux.org/alpine/edge/community
    base_packages: [curl]
    kernel_packages: []
    timezone: UTC
    keymap: us us
    docker_advertise_iface: eth0
    docker_swarm_role: none
  children:
    docker_hosts:
      hosts: { dock: { ansible_host: 172.31.0.70 } }
EOF
cat > /home/admin/dock-play.yml <<EOF
- hosts: docker_hosts
  roles:
    - /home/admin/ansible/roles/common
    - /home/admin/ansible/roles/docker_host
EOF
'

log "running docker_host role"
if ssh_to 22210 'cd ansible && ANSIBLE_CONFIG=/home/admin/ansible/ansible.cfg \
    ansible-playbook -i /home/admin/dock-inv.yml /home/admin/dock-play.yml 2>&1 | tail -3 | grep -q failed=0'; then
    ok "play succeeded"
else
    fail "play failed"
fi

assert_idempotent /home/admin/dock-play.yml /home/admin/dock-inv.yml docker_host

ssh_to 22240 'doas docker info 2>/dev/null | grep -q "Live Restore Enabled: true"' \
    && ok "live-restore enabled" || fail "live-restore not on"

ssh_to 22240 'curl -s -o /dev/null -w "%{http_code}" http://172.31.0.70:9323/metrics 2>/dev/null | grep -q 200' \
    && ok "metrics endpoint serving" || fail "metrics endpoint down"
;;
esac

# -----------------------------------------------------------------
# Test: observability (multi-host scrape)
# -----------------------------------------------------------------
case " $TESTS " in (*' obs '*)
section "observability"

log "spawning obs"
spawn_container obs 22250 172.31.0.40
wait_for_ssh 22250
setup_host_quirks 22250
cat /tmp/controller_pubkey | ssh_to 22250 \
    'cat >> ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys'

# Combined inventory across all groups (only non-empty leaves are scraped)
ssh_to 22210 'cat > /home/admin/obs-inv.yml <<EOF
all:
  vars:
    ansible_user: admin
    ansible_become: true
    ansible_become_method: doas
    ansible_python_interpreter: /usr/bin/python3
    apk_repositories:
      - http://dl-cdn.alpinelinux.org/alpine/edge/main
      - http://dl-cdn.alpinelinux.org/alpine/edge/community
      - http://dl-cdn.alpinelinux.org/alpine/edge/testing
    base_packages: [curl]
    kernel_packages: []
    timezone: UTC
    keymap: us us
    monitoring_bind_iface: eth0
    obs_bind_iface: eth0
    loki_push_url: "http://172.31.0.40:3100/loki/api/v1/push"
  children:
    alpine:
      children:
        observability:
          hosts: { obs: { ansible_host: 172.31.0.40 } }
        cdn_edges:
          hosts: { edge:    { ansible_host: 172.31.0.10 } }
        cdn_varnish:
          hosts: { varnish: { ansible_host: 172.31.0.20 } }
        cdn_origins:
          hosts: { origin:  { ansible_host: 172.31.0.30 } }
        docker_hosts:
          hosts: { dock:    { ansible_host: 172.31.0.70 } }
EOF
cat > /home/admin/obs-play.yml <<EOF
- hosts: alpine
  roles:
    - /home/admin/ansible/roles/common
    - /home/admin/ansible/roles/monitoring_agent
- hosts: observability
  roles:
    - /home/admin/ansible/roles/observability
EOF
'

log "applying monitoring_agent fleet-wide + observability on obs"
if ssh_to 22210 'cd ansible && ANSIBLE_CONFIG=/home/admin/ansible/ansible.cfg \
    ansible-playbook -i /home/admin/obs-inv.yml /home/admin/obs-play.yml 2>&1 | tail -3 | grep -qE "failed=0"'; then
    ok "play succeeded"
else
    fail "play failed"
fi

assert_idempotent /home/admin/obs-play.yml /home/admin/obs-inv.yml observability

sleep 35   # give prometheus 2 scrape intervals
log "checking prometheus targets"
TARGETS=$(ssh_to 22250 'curl -s http://172.31.0.40:9090/api/v1/targets')
echo "$TARGETS" | grep -q '"health":"up"' && ok "at least one target UP" || fail "no UP targets"
echo "$TARGETS" | grep -q 'prometheus' && ok "self-scrape job" || fail "no self-scrape"

log "checking loki"
ssh_to 22250 'curl -sf http://172.31.0.40:3100/ready >/dev/null' && ok "loki ready" || fail "loki not ready"

log "checking grafana"
ssh_to 22250 'curl -sf http://172.31.0.40:3000/login >/dev/null' && ok "grafana up" || fail "grafana down"

DASHBOARDS=$(ssh_to 22250 'curl -s -u admin:admin http://172.31.0.40:3000/api/search?type=dash-db' 2>/dev/null)
for d in "Node Exporter Full" "NGINX exporter" "Varnish" "Wireguard"; do
    echo "$DASHBOARDS" | grep -q "$d" && ok "dashboard: $d" || fail "missing dashboard: $d"
done

# Trigger nginx logs and verify they reach loki via alloy
log "verifying alloy → loki log shipping"
for _ in 1 2 3 4 5; do ssh_to 22220 'curl -s -o /dev/null http://localhost/' 2>/dev/null || true; done
sleep 5
HOSTS=$(ssh_to 22250 'curl -s "http://172.31.0.40:3100/loki/api/v1/label/host/values"' 2>/dev/null)
echo "$HOSTS" | grep -q edge && ok "logs from edge in loki" || fail "no edge logs in loki"
;;
esac

# -----------------------------------------------------------------
END=$(date +%s)
section "summary"
echo "elapsed: $((END - START))s"
if [ "$FAILED" = 0 ]; then
    printf '\033[1;32mall green\033[0m\n'
    exit 0
else
    printf '\033[1;31mfailures: %d\033[0m\n' "$FAILED"
    exit 1
fi
