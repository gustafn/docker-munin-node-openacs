#!/bin/sh
# SPDX-License-Identifier: MPL-2.0

set -eu

CONF=/etc/munin/munin-node.conf
TEMPLATE=/etc/munin/munin-node.conf.template

# Munin node name (as seen by master)
MUNIN_HOSTNAME="${MUNIN_HOSTNAME:-$(hostname)}"

# Which master(s) may connect (CIDR notation)
MUNIN_ALLOW_CIDR="${MUNIN_ALLOW_CIDR:-127.0.0.1/32}"

# NaviServer/OpenACS instance details (for extra plugins)
NS_SERVER_NAME="${NS_SERVER_NAME:-openacs.org}"      # used in plugin names
NS_ADDRESS="${NS_ADDRESS:-openacs-org}"              # Docker service name of OpenACS container
NS_PORT="${NS_PORT:-8080}"                           # HTTP port inside OpenACS container
NS_URL_PATH="${NS_URL_PATH:-/SYSTEM/munin.tcl?t=}"   # path to interface script

export MUNIN_HOSTNAME MUNIN_ALLOW_CIDR NS_SERVER_NAME NS_ADDRESS NS_PORT NS_URL_PATH

# ----------------------------------------------------------------------
# Generate munin-node.conf from template if none is provided by bind-mount
# ----------------------------------------------------------------------
if [ ! -f "$CONF" ]; then
    if [ -f "$TEMPLATE" ]; then
        echo "munin-node: generating $CONF from $TEMPLATE"
        envsubst < "$TEMPLATE" > "$CONF"
        echo "Generated $CONF"
        echo "---"
        sed 's/^/    /' "$CONF"
        echo "---"
    else
        echo "munin-node: $CONF not found and no template $TEMPLATE available, aborting"
        exit 1
    fi
else
    echo "munin-node: using existing $CONF (bind-mounted or image-provided)"
fi

echo "You might check the used munin-node.conf via:"
echo "    docker exec -it munin-node sed 's/^/   /'   /etc/munin/munin-node.conf"
echo " "
echo "To try the interation of the plugin with the server, try"
echo "    munin-run naviserver_openacs.org_views config"
echo "    munin-run naviserver_openacs.org_views"
echo " "

# ----------------------------------------------------------------------
# Plugin configuration for NaviServer/OpenACS
# ----------------------------------------------------------------------
mkdir -p /etc/munin/plugin-conf.d /etc/munin/plugins /usr/local/munin/lib/plugins

cat >/etc/munin/plugin-conf.d/naviserver <<EOF
[naviserver_*]
  env.url ${NS_URL_PATH}

[naviserver_${NS_SERVER_NAME}_*]
  env.address ${NS_ADDRESS}
  env.port ${NS_PORT}
EOF

# Symlink the naviserver_* plugins for this server instance
plugins="locks.busy locks.nr locks.wait logstats lsof memsize \
         responsetime serverstats threadcpu threads users users24 views"

for p in $plugins; do
  src="/usr/local/munin/lib/plugins/naviserver_${p}"
  dst="/etc/munin/plugins/naviserver_${NS_SERVER_NAME}_${p}"
  if [ -x "$src" ]; then
    ln -sf "$src" "$dst"
  else
    echo "Warning: plugin $src not found or not executable"
  fi
done

echo "Starting munin-node for ${MUNIN_HOSTNAME}, allowing ${MUNIN_ALLOW_CIDR}"
echo "Naviserver plugins targeting http://${NS_ADDRESS}:${NS_PORT}${NS_URL_PATH}"

# Optional: Munin master host/port (for info only; master actually connects to us)
MUNIN_MASTER_HOST="${MUNIN_MASTER_HOST:-munin-master}"
MUNIN_MASTER_PORT="${MUNIN_MASTER_PORT:-80}"

echo "munin-node: connectivity checks..."

# Helper: test host:port with nc
check_tcp() {
  host="$1"; port="$2"; label="$3"
  for i in 1 2 3 4 5; do
    if nc -z -w 2 "$host" "$port" >/dev/null 2>&1; then
      echo "  [OK]  $label $host:$port"
      return 0
    fi
    sleep 2
  done
  echo "  [WARN] Cannot reach $host:$port (after retries)"
  return 1
}

# Helper: simple DNS/ICMP check
check_host() {
    host="$1"
    if ping -c1 -W1 "$host" >/dev/null 2>&1; then
        echo "  [OK]  host $host reachable (ping)"
    else
        echo "  [WARN] host $host not reachable (ping failed)"
    fi
}

# Check OpenACS (for naviserver_* plugins)
check_host "$NS_ADDRESS"
check_tcp  "$NS_ADDRESS" "$NS_PORT" "NaviServer"

# Optionally: check that the munin-master name resolves/answers (for human info)
check_host "$MUNIN_MASTER_HOST"
# We are not connecting to the node via port 80, but use just the generated files.
#check_tcp  "$MUNIN_MASTER_HOST" "$MUNIN_MASTER_PORT" "munin master"

echo "munin-node: connectivity checks done."

exec "$@"
