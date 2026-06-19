# 💱 Comparador de Cotizaciones — Argentina

Comparador en tiempo real de cotizaciones del dólar y criptomonedas en Argentina.  
Fuente: [comparadolar.ar](https://comparadolar.ar) · Sin backend · Archivo HTML estático + daemon Node.js.

## Arquitectura

```
RPi
├── nginx          → sirve index.html en :80 (visualización)
└── dolar-monitor  → monitor.js corre en background (alertas Telegram)
```

- La **web** es solo para visualizar. Podés cerrarla y las alertas siguen llegando.
- El **monitor** corre 24/7 como servicio systemd, lee `config.json` y manda Telegram cuando el diferencial supera el umbral.

## Instalación en Raspberry Pi

```bash
sudo bash <(curl -sL https://raw.githubusercontent.com/shakyy95/USDCompare/main/install.sh)
```

El instalador:
1. Instala **nginx** + **Node.js**
2. Copia `index.html` → `/var/www/html/`
3. Copia `monitor.js` → `/opt/dolar-comparador/`
4. Crea `config.json` en `/opt/dolar-comparador/` (solo si no existe)
5. Levanta el servicio `dolar-monitor` como systemd
6. Pregunta si querés **Cloudflare Tunnel** para acceso remoto

## Configurar Telegram y umbral

```bash
nano /opt/dolar-comparador/config.json
```

```json
{
  "telegram": {
    "token": "TU_BOT_TOKEN",
    "chatId": "TU_CHAT_ID"
  },
  "alert": {
    "threshold": 20,
    "enabled": true
  },
  "frequency": 30,
  "sideA": { "asset": "usdc", "slug": "arq",  "dir": "bid" },
  "sideB": { "asset": "usd",  "slug": "uala", "dir": "ask" }
}
```

Luego reiniciar el monitor:
```bash
sudo systemctl restart dolar-monitor
```

## Comandos útiles

```bash
# Ver alertas en tiempo real
sudo journalctl -u dolar-monitor -f

# Estado del monitor
sudo systemctl status dolar-monitor

# Detener / arrancar
sudo systemctl stop dolar-monitor
sudo systemctl start dolar-monitor
```

## Obtener token y chat ID de Telegram

1. Buscá **@BotFather** → `/newbot` → copiá el token
2. Mandá cualquier mensaje a tu bot
3. Abrí `https://api.telegram.org/botTU_TOKEN/getUpdates` en el browser → buscá `chat.id`

También podés detectar el chat ID desde la web (sección Telegram).

## Actualizar

```bash
sudo bash <(curl -sL https://raw.githubusercontent.com/shakyy95/USDCompare/main/install.sh)
```

El instalador preserva tu `config.json` existente al actualizar.
