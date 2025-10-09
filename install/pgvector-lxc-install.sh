#!/usr/bin/env bash
# Proxmox LXC Helper - PostgreSQL 17 + pgvector (Debian 12)
# Inspired by community-scripts (tteck) installer style (standalone).
set -euo pipefail

# ---------------- User Config (override via env) ----------------
CTID="${CTID:-251}"
HOSTNAME="${HOSTNAME:-pgvector}"
STORAGE="${STORAGE:-local-lvm}"
DISK_GB="${DISK_GB:-16}"
MEM_MB="${MEM_MB:-2048}"
SWAP_MB="${SWAP_MB:-512}"
CORES="${CORES:-2}"
BRIDGE="${BRIDGE:-vmbr0}"
IP_CONFIG="${IP_CONFIG:-dhcp}"      # e.g. "192.168.1.50/24,gw=192.168.1.1"
ONBOOT="${ONBOOT:-1}"

# DB settings (parallels Docker envs)
DB_USER="${DB_USER:-myuser}"
DB_PASS="${DB_PASS:-mypassword}"
DB_NAME="${DB_NAME:-mydatabase}"

# Allow client subnet (CIDR). Use "0.0.0.0/0" to allow all (firewall recommended).
ALLOW_SUBNET="${ALLOW_SUBNET:-0.0.0.0/0}"

# Optional: install Adminer inside LXC
INSTALL_ADMINER="${INSTALL_ADMINER:-false}"

# Template and versions
TEMPLATE="${TEMPLATE:-debian-12-standard_12.7-1_amd64.tar.zst}"
PG_MAJOR="${PG_MAJOR:-17}"

# ---------------- Sanity checks ----------------
if ! command -v pveversion >/dev/null 2>&1; then
  echo "This script must run on a Proxmox host." >&2; exit 1
fi
echo "==> Creating LXC $CTID ($HOSTNAME) with PostgreSQL $PG_MAJOR + pgvector"

# ---------------- Template fetch ----------------
if ! pveam list | grep -q "$TEMPLATE"; then
  echo "Downloading template $TEMPLATE to $STORAGE..."
  pveam update
  pveam download "$STORAGE" "$TEMPLATE"
fi

# ---------------- Create container ----------------
if pct status "$CTID" >/dev/null 2>&1; then
  echo "Container $CTID already exists. Aborting." >&2; exit 1
fi

ROOT_PASS="$(openssl rand -base64 18)"
pct create "$CTID" "$STORAGE:vztmpl/$TEMPLATE" \
  -hostname "$HOSTNAME" \
  -rootfs "$STORAGE:${DISK_GB}" \
  -memory "$MEM_MB" -swap "$SWAP_MB" -cores "$CORES" \
  -net0 "name=eth0,bridge=${BRIDGE},ip=${IP_CONFIG}" \
  -unprivileged 1 \
  -features "keyctl=1,nesting=1" \
  -password "$ROOT_PASS" \
  -tags "pg,pgvector"

pct set "$CTID" -onboot "$ONBOOT" -startup order=3
pct start "$CTID"

# helper to exec inside CT
ct() { pct exec "$CTID" -- bash -lc "$*"; }

echo "Waiting for networking inside the container..."
sleep 5

# ---------------- Install PostgreSQL + pgvector ----------------
echo "Installing PostgreSQL $PG_MAJOR + pgvector…"
ct "set -e
apt-get update -y
apt-get install -y curl ca-certificates gnupg lsb-release software-properties-common
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /etc/apt/keyrings/postgresql.gpg
echo \"deb [signed-by=/etc/apt/keyrings/postgresql.gpg] https://apt.postgresql.org/pub/repos/apt \$(. /etc/os-release && echo \$VERSION_CODENAME)-pgdg main\" > /etc/apt/sources.list.d/pgdg.list
apt-get update -y
apt-get install -y postgresql-$PG_MAJOR postgresql-$PG_MAJOR-pgvector"
echo "PostgreSQL installed."

# ---------------- Configure postgres.conf and pg_hba.conf ----------------
PG_CONF=$(ct "su - postgres -c 'psql -tAc \"SHOW config_file;\"' | tr -d '[:space:]'")
PG_DIR="$(dirname "$PG_CONF")"
PG_HBA="${PG_DIR}/pg_hba.conf"

# listen on all
ct "sed -i \"s/^#\\?listen_addresses.*/listen_addresses = '*'/'\" '$PG_CONF'"

# Hardened yet practical pg_hba (md5 for IPv4, keep local scram/md5)
HBA_BLOCK=$(cat <<EOF
# Added by installer
local   all             postgres                                peer
local   all             all                                     md5
host    all             all             127.0.0.1/32            scram-sha-256
host    all             all             ::1/128                 scram-sha-256
host    all             all             ${ALLOW_SUBNET}         md5
EOF
)
ct "awk 'BEGIN{p=1} /# Added by installer/{p=0} {if(p)print}' '$PG_HBA' > '${PG_HBA}.new'"
ct "printf '%s\n' \"$HBA_BLOCK\" >> '${PG_HBA}.new' && mv '${PG_HBA}.new' '$PG_HBA'"

ct "systemctl restart postgresql@${PG_MAJOR}-main"

# ---------------- Create role/db and enable pgvector ----------------
echo "Creating role '$DB_USER' and database '$DB_NAME'…"
ct "su - postgres -c \"psql -v ON_ERROR_STOP=1 <<'SQL'
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$DB_USER') THEN
    CREATE ROLE \"$DB_USER\" LOGIN PASSWORD '$DB_PASS';
  END IF;
END
\$\$;
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_database WHERE datname = '$DB_NAME') THEN
    CREATE DATABASE \"$DB_NAME\" OWNER \"$DB_USER\";
  END IF;
END
\$\$;
\\c \"$DB_NAME\"
CREATE EXTENSION IF NOT EXISTS vector;
ALTER SCHEMA public OWNER TO \"$DB_USER\";
GRANT ALL PRIVILEGES ON DATABASE \"$DB_NAME\" TO \"$DB_USER\";
SQL
\""

# ---------------- Optional: Adminer ----------------
if [[ "${INSTALL_ADMINER,,}" == "true" ]]; then
  echo "Installing Adminer…"
  ct "apt-get update -y && apt-get install -y adminer apache2 && a2enconf adminer && systemctl reload apache2"
  echo "Adminer available at: http://<CT-IP>/adminer"
fi

# ---------------- Output ----------------
CT_IP=$(pct exec "$CTID" -- bash -lc "ip -4 -o addr show dev eth0 | awk '{print \$4}' | cut -d/ -f1" | tail -n1)
cat <<EOF

✅ Done
Container ID:   $CTID
Hostname:       $HOSTNAME
Container IP:   ${CT_IP:-<dhcp>}
PostgreSQL:     $PG_MAJOR
pgvector:       installed (extension created in $DB_NAME)

Connect:
  psql -h ${CT_IP:-<container-ip>} -U $DB_USER -d $DB_NAME
  (password: $DB_PASS)

To enter the container:
  pct enter $CTID

Tip: Adjust ALLOW_SUBNET (e.g., 192.168.1.0/24) or secure with Proxmox firewall.
EOF
