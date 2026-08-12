#!/bin/bash
# ============================================================
#  setup_onion.sh — Host a .onion site on Kali Linux
#  Run as root: sudo bash setup_onion.sh
# ============================================================

set -e  # Exit on any error

# ── Colors ──────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ── Helpers ──────────────────────────────────────────────────
info()    { echo -e "${CYAN}[*]${NC} $1"; }
success() { echo -e "${GREEN}[✔]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
error()   { echo -e "${RED}[✘]${NC} $1"; exit 1; }
header()  { echo -e "\n${BOLD}${CYAN}══════════════════════════════════════${NC}"; \
            echo -e "${BOLD}${CYAN}  $1${NC}"; \
            echo -e "${BOLD}${CYAN}══════════════════════════════════════${NC}\n"; }

# ── Root check ───────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    error "Please run as root: sudo bash setup_onion.sh"
fi

# ── Variables ────────────────────────────────────────────────
WEBROOT="/var/www/html"
NGINX_CONF="/etc/nginx/sites-available/default"
TORRC="/etc/tor/torrc"
HIDDEN_DIR="/var/lib/tor/hidden_service"
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
SOURCE_INDEX="$SCRIPT_DIR/index.html"

# ╔══════════════════════════════════════════════════════════╗
header "STEP 1: System Update & Install Packages"
# ╚══════════════════════════════════════════════════════════╝

info "Updating package lists..."
apt update -y
info "Installing tor, nginx, rsync..."
apt install -y tor nginx rsync

success "Packages installed."

# ╔══════════════════════════════════════════════════════════╗
header "STEP 2: Configure nginx (localhost only)"
# ╚══════════════════════════════════════════════════════════╝

info "Writing nginx config..."
cat > "$NGINX_CONF" <<'EOF'
server {
    listen 127.0.0.1:80;

    root /var/www/html;
    index index.html index.htm;
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65 20;
    server_tokens off;

    server_name localhost;

    # Disable access logs for privacy
    access_log off;
    error_log /dev/null;

    location / {
        try_files $uri $uri/ =404;
    }

    location ~* \.(zip|tar|gz|rar|7z|pdf|exe)$ {
        add_header Content-Disposition "attachment";
        add_header Cache-Control "public, max-age=31536000";
    }
}
EOF

# Remove default symlink if present and recreate
ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default

nginx -t && success "nginx config is valid." || error "nginx config test failed."

systemctl restart nginx
systemctl enable nginx
success "nginx started and enabled on boot."

# ╔══════════════════════════════════════════════════════════╗
header "STEP 3: Create Website Content"
# ╚══════════════════════════════════════════════════════════╝

mkdir -p "$WEBROOT"
info "Copying workspace content to $WEBROOT..."
rsync -a --delete --exclude='setup_onion.sh' --exclude='*.sh' "$SCRIPT_DIR"/ "$WEBROOT"/
success "Workspace content copied to $WEBROOT."

# ╔══════════════════════════════════════════════════════════╗
header "STEP 4: Configure Tor Hidden Service"
# ╚══════════════════════════════════════════════════════════╝

info "Backing up original torrc..."
cp "$TORRC" "${TORRC}.bak" 2>/dev/null || true

# Remove any existing HiddenService lines to avoid duplicates
sed -i '/^HiddenServiceDir/d' "$TORRC"
sed -i '/^HiddenServicePort/d' "$TORRC"

info "Adding Hidden Service config to torrc..."
cat >> "$TORRC" <<EOF

## .onion Hidden Service — added by setup_onion.sh
HiddenServiceDir $HIDDEN_DIR
HiddenServicePort 80 127.0.0.1:80
EOF

success "torrc updated."

# Set correct permissions on hidden service directory (if it exists)
if [[ -d "$HIDDEN_DIR" ]]; then
    chown -R debian-tor:debian-tor "$HIDDEN_DIR"
    chmod 700 "$HIDDEN_DIR"
fi

# ╔══════════════════════════════════════════════════════════╗
header "STEP 5: Start Tor"
# ╚══════════════════════════════════════════════════════════╝

systemctl restart tor
systemctl enable tor --quiet
success "Tor started and enabled on boot."

info "Waiting for Tor to generate .onion keys (up to 60s)..."
for i in $(seq 1 30); do
    if [[ -f "$HIDDEN_DIR/hostname" ]]; then
        break
    fi
    sleep 2
    echo -ne "  Waiting... ${i}/30\r"
done
echo ""

if [[ ! -f "$HIDDEN_DIR/hostname" ]]; then
    error "hostname file not generated. Check: sudo journalctl -u tor"
fi

ONION_ADDR=$(cat "$HIDDEN_DIR/hostname")
success "Hidden service created!"



# ╔══════════════════════════════════════════════════════════╗
header "STEP 7: Verify Setup"
# ╚══════════════════════════════════════════════════════════╝

info "Testing local nginx response..."
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:80)
if [[ "$HTTP_STATUS" == "200" ]]; then
    success "nginx is serving content correctly (HTTP 200)."
else
    warn "nginx returned HTTP $HTTP_STATUS — check your config."
fi

info "Checking Tor service status..."
if systemctl is-active --quiet tor; then
    success "Tor is running."
else
    error "Tor is NOT running. Check: sudo journalctl -u tor"
fi

success "Your .onion site is configured and index.html is hosted."
echo -e "${CYAN}Onion address:${NC} $ONION_ADDR"

# ╔══════════════════════════════════════════════════════════╗
header "✅ SETUP COMPLETE"
# ╚══════════════════════════════════════════════════════════╝

echo -e "${BOLD}${GREEN}"
echo "  ┌─────────────────────────────────────────────┐"
echo "  │   Your .onion address:                      │"
echo "  │                                             │"
echo "  │   ${ONION_ADDR}   │"
echo "  │                                             │"
echo "  │   Open this in Tor Browser to visit         │"
echo "  │   your site from any device.                │"
echo "  └─────────────────────────────────────────────┘"
echo -e "${NC}"

echo -e "${CYAN}Website files:${NC}   $WEBROOT/index.html"
echo -e "${CYAN}Tor keys:${NC}        $HIDDEN_DIR"
echo -e "${CYAN}nginx config:${NC}    $NGINX_CONF"
echo -e "${CYAN}Tor config:${NC}      $TORRC"

echo ""
echo -e "${YELLOW}Useful commands:${NC}"
echo "  sudo systemctl status tor nginx      # Check status"
echo "  sudo systemctl restart tor nginx     # Restart both"
echo "  sudo cat $HIDDEN_DIR/hostname        # Show .onion address"
echo "  sudo journalctl -u tor -f            # Live Tor logs"
echo ""
echo -e "${YELLOW}To change your site:${NC} edit $WEBROOT/index.html"
echo ""
