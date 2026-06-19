# 💱 Comparador de Cotizaciones — Argentina

Comparador en tiempo real de cotizaciones del dólar y criptomonedas en Argentina.  
Fuente: [comparadolar.ar](https://comparadolar.ar) · Sin backend · Archivo HTML estático.

## Características

- Selector multinivel: activo (USD/USDC/USDT/BTC/ETH) → proveedor → dirección (bid/ask)
- Precios en tiempo real con frecuencia configurable (15s – 5min)
- Gráfico histórico con forward-fill y rangos 7d / 30d / 60d / todo
- Alerta configurable con aviso en pantalla, sonido y **mensaje a Telegram**
- Funciona sin internet si se sirve localmente (excepto las llamadas a la API)

## Instalación en Raspberry Pi

```bash
sudo bash <(curl -sL https://raw.githubusercontent.com/TU_USUARIO/dolar-comparador/main/install.sh)
```

El instalador:
1. Instala **nginx** y sirve el archivo en el puerto 80
2. Pregunta si querés **Cloudflare Tunnel** para acceso remoto sin abrir puertos

Accedé desde cualquier dispositivo en tu red:
```
http://<ip-de-la-rpi>
```

## Telegram

1. Creá un bot con `@BotFather` → `/newbot`
2. Copiá el token en el campo **Bot Token** del comparador
3. Mandá cualquier mensaje a tu bot y presioná **↻ Detectar** para obtener el Chat ID
4. Usá **Enviar mensaje de prueba** para verificar

## Actualizar

```bash
sudo bash <(curl -sL https://raw.githubusercontent.com/TU_USUARIO/dolar-comparador/main/install.sh)
```

## Uso sin RPi

Abrí `index.html` directamente en cualquier navegador — no requiere servidor.
