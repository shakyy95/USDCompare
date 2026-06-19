#!/bin/bash
set -e

REPO="https://github.com/shakyy95/USDCompare"
INSTALL_DIR="/var/www/html"
APP_DIR="/opt/dolar-comparador"
SERVICE_NAME="dolar-comparador"
MONITOR_SERVICE="dolar-monitor"

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

# ── Elegir puerto web ──────────────────────────────────────────────────────
# Si ya hay un puerto guardado de una instalación previa, usarlo como default
SAVED_PORT=""
if [ -f "$APP_DIR/.web_port" ]; then
  SAVED_PORT=$(cat "$APP_DIR/.web_port")
fi
DEFAULT_PORT="${SAVED_PORT:-8080}"

read -p "▸ Puerto para la web [Enter = $DEFAULT_PORT]: " INPUT_PORT
WEB_PORT="${INPUT_PORT:-$DEFAULT_PORT}"

# Validar que sea un número entre 1024 y 65535
if ! [[ "$WEB_PORT" =~ ^[0-9]+$ ]] || [ "$WEB_PORT" -lt 1024 ] || [ "$WEB_PORT" -gt 65535 ]; then
  echo "❌  Puerto inválido. Debe ser un número entre 1024 y 65535."
  exit 1
fi

# Verificar que el puerto no esté en uso
if ss -tlnH | awk '{print $4}' | grep -q ":${WEB_PORT}$"; then
  echo "⚠  El puerto $WEB_PORT ya está en uso. Elegí otro."
  exit 1
fi

echo "    ✓ Puerto web: $WEB_PORT"

# ── Paso 1: dependencias ───────────────────────────────────────────────────
echo "▸ [1/5] Instalando dependencias..."
apt-get update -qq
apt-get install -y -qq nginx curl git

# Instalar Node.js si no está disponible
if ! command -v node &>/dev/null; then
  echo "    Instalando Node.js..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash - >/dev/null 2>&1
  apt-get install -y -qq nodejs
fi
echo "    ✓ nginx + Node.js $(node -v)"

# ── Paso 2: clonar / actualizar repo ──────────────────────────────────────
echo "▸ [2/5] Descargando comparador..."
TMPDIR=$(mktemp -d)
git clone --depth 1 "$REPO" "$TMPDIR/repo" 2>/dev/null || {
  echo "    ⚠ No se pudo clonar el repo. Verificá la URL en install.sh"
  exit 1
}

# Web estática → nginx
cp "$TMPDIR/repo/index.html" "$INSTALL_DIR/index.html"

# Daemon y config → /opt
mkdir -p "$APP_DIR"
cp "$TMPDIR/repo/monitor.js" "$APP_DIR/monitor.js"

# Solo copiar config.json si no existe (preservar config existente)
if [ ! -f "$APP_DIR/config.json" ]; then
  cp "$TMPDIR/repo/config.json" "$APP_DIR/config.json"
  echo "    ✓ config.json creado en $APP_DIR"
else
  echo "    ✓ config.json existente preservado"
fi

rm -rf "$TMPDIR"

# Guardar puerto elegido para futuras actualizaciones
echo "$WEB_PORT" > "$APP_DIR/.web_port"
echo "    ✓ Archivos instalados"

# ── Paso 3: configurar nginx ───────────────────────────────────────────────
echo "▸ [3/5] Configurando nginx en puerto $WEB_PORT..."

cat > /etc/nginx/sites-available/$SERVICE_NAME <<EOF
server {
    listen $WEB_PORT default_server;
    listen [::]:$WEB_PORT default_server;
    root /var/www/html;
    index index.html;
    server_name _;

    location / {
        try_files \$uri \$uri/ =404;
    }

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
echo "    ✓ nginx corriendo en puerto $WEB_PORT"

# ── Paso 4: servicio monitor (background) ─────────────────────────────────
echo "▸ [4/5] Configurando monitor en background..."

cat > /etc/systemd/system/$MONITOR_SERVICE.service <<EOF
[Unit]
Description=Monitor de Cotizaciones — Comparador Dólar
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/node $APP_DIR/monitor.js
WorkingDirectory=$APP_DIR
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable $MONITOR_SERVICE
systemctl restart $MONITOR_SERVICE
echo "    ✓ Monitor corriendo como servicio systemd"

# ── Paso 5: cloudflared (opcional) ────────────────────────────────────────
echo ""
read -p "▸ [5/5] ¿Querés acceso remoto con Cloudflare Tunnel? (s/n): " INSTALL_CF

if [[ "$INSTALL_CF" =~ ^[sS]$ ]]; then
  echo "    Descargando cloudflared ($CF_ARCH)..."
  CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$CF_ARCH"
  curl -sL "$CF_URL" -o /usr/local/bin/cloudflared
  chmod +x /usr/local/bin/cloudflared

  cat > /etc/systemd/system/cloudflared-tunnel.service <<EOF
[Unit]
Description=Cloudflare Tunnel — Comparador Dólar
After=network.target

[Service]
ExecStart=/usr/local/bin/cloudflared tunnel --url http://localhost:$WEB_PORT --no-autoupdate
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
echo "╔══════════════════════════════════════════════════════╗"
echo "║              ✅ Instalación completa                  ║"
echo "╠══════════════════════════════════════════════════════╣"
echo "║  Web:    http://$IP:$WEB_PORT"
echo "║  Config: $APP_DIR/config.json"
echo "╠══════════════════════════════════════════════════════╣"
echo "║  Configurar Telegram y umbral:"
echo "║    nano $APP_DIR/config.json"
echo "║    sudo systemctl restart $MONITOR_SERVICE"
echo "╠══════════════════════════════════════════════════════╣"
echo "║  Ver logs del monitor:"
echo "║    sudo journalctl -u $MONITOR_SERVICE -f"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "Para actualizar en el futuro:"
echo "  sudo bash <(curl -sL $REPO/raw/main/install.sh)"
echo ""
