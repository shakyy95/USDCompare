#!/bin/bash
set -e

REPO="https://github.com/ezequiel-creditrust/dolar-comparador"
INSTALL_DIR="/var/www/html"
SERVICE_NAME="dolar-comparador"

echo ""
echo "╔══════════════════════════════════════╗"
echo "║   💱 Instalador — Comparador Dólar   ║"
echo "╚══════════════════════════════════════╝"
echo ""

# ── Detectar arquitectura ──────────────────────────────────────────────────
ARCH=$(uname -m)
case $ARCH in
  aarch64|arm64) CF_ARCH="arm64" ;;
  armv7l|armv6l) CF_ARCH="arm"   ;;
  x86_64)        CF_ARCH="amd64" ;;
  *)             CF_ARCH="arm64" ;;
esac

# ── Verificar root ─────────────────────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
  echo "❌  Ejecutá como root: sudo bash install.sh"
  exit 1
fi

# ── Paso 1: nginx ──────────────────────────────────────────────────────────
echo "▸ [1/4] Instalando nginx..."
apt-get update -qq
apt-get install -y -qq nginx curl git

# ── Paso 2: clonar / actualizar repo ──────────────────────────────────────
echo "▸ [2/4] Descargando comparador..."
TMPDIR=$(mktemp -d)
git clone --depth 1 "$REPO" "$TMPDIR/repo" 2>/dev/null || {
  echo "    ⚠ No se pudo clonar el repo. Verificá la URL en install.sh"
  exit 1
}
cp "$TMPDIR/repo/index.html" "$INSTALL_DIR/index.html"
rm -rf "$TMPDIR"
echo "    ✓ Archivo copiado a $INSTALL_DIR/index.html"

# ── Paso 3: configurar nginx ───────────────────────────────────────────────
echo "▸ [3/4] Configurando nginx..."
cat > /etc/nginx/sites-available/$SERVICE_NAME <<'EOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    root /var/www/html;
    index index.html;
    server_name _;

    location / {
        try_files $uri $uri/ =404;
    }

    # Caché agresivo para assets estáticos
    location ~* \.(js|css|png|jpg|svg|woff2)$ {
        expires 7d;
        add_header Cache-Control "public";
    }
}
EOF

ln -sf /etc/nginx/sites-available/$SERVICE_NAME /etc/nginx/sites-enabled/$SERVICE_NAME
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl restart nginx
systemctl enable nginx
echo "    ✓ nginx corriendo en puerto 80"

# ── Paso 4: cloudflared (opcional) ────────────────────────────────────────
echo ""
read -p "▸ [4/4] ¿Querés acceso remoto con Cloudflare Tunnel? (s/n): " INSTALL_CF

if [[ "$INSTALL_CF" =~ ^[sS]$ ]]; then
  echo "    Descargando cloudflared ($CF_ARCH)..."
  CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$CF_ARCH"
  curl -sL "$CF_URL" -o /usr/local/bin/cloudflared
  chmod +x /usr/local/bin/cloudflared

  # Crear servicio systemd para tunnel temporal
  cat > /etc/systemd/system/cloudflared-tunnel.service <<EOF
[Unit]
Description=Cloudflare Tunnel — Comparador Dólar
After=network.target

[Service]
ExecStart=/usr/local/bin/cloudflared tunnel --url http://localhost:80 --no-autoupdate
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable cloudflared-tunnel
  systemctl start cloudflared-tunnel

  echo "    ✓ Cloudflare Tunnel iniciado"
  echo "    Esperando URL pública..."
  sleep 5
  URL=$(journalctl -u cloudflared-tunnel -n 50 --no-pager 2>/dev/null | grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' | tail -1)
  if [ -n "$URL" ]; then
    echo ""
    echo "    🌐 URL pública: $URL"
  else
    echo "    Revisá la URL con: sudo journalctl -u cloudflared-tunnel -f"
  fi
fi

# ── Resumen ────────────────────────────────────────────────────────────────
IP=$(hostname -I | awk '{print $1}')
echo ""
echo "╔══════════════════════════════════════╗"
echo "║         ✅ Instalación completa       ║"
echo "╠══════════════════════════════════════╣"
echo "║  Red local:  http://$IP"
echo "╚══════════════════════════════════════╝"
echo ""
echo "Para actualizar en el futuro:"
echo "  sudo bash <(curl -sL $REPO/raw/main/install.sh)"
echo ""
