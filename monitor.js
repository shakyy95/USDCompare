#!/usr/bin/env node
'use strict';

const https  = require('https');
const fs     = require('fs');
const path   = require('path');
const { spawn } = require('child_process');

const CONFIG_PATH = path.join(__dirname, 'config.json');

// ── Leer config (se recarga en cada ciclo) ──────────────────────────────────
function loadConfig() {
  try {
    return JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8'));
  } catch (e) {
    console.error('[config] No se pudo leer config.json:', e.message);
    process.exit(1);
  }
}

// ── Fetch con promesa (sin dependencias externas) ───────────────────────────
function get(url) {
  return new Promise((resolve, reject) => {
    const req = https.get(url, { timeout: 10000 }, res => {
      let body = '';
      res.on('data', d => body += d);
      res.on('end', () => {
        try { resolve(JSON.parse(body)); }
        catch (e) { reject(new Error(`JSON inválido en ${url}`)); }
      });
    });
    req.on('error', reject);
    req.on('timeout', () => { req.destroy(); reject(new Error(`Timeout: ${url}`)); });
  });
}

function post(url, data) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify(data);
    const u    = new URL(url);
    const opts = {
      hostname: u.hostname,
      path: u.pathname,
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
      timeout: 10000,
    };
    const req = https.request(opts, res => {
      let b = '';
      res.on('data', d => b += d);
      res.on('end', () => { try { resolve(JSON.parse(b)); } catch { resolve({}); } });
    });
    req.on('error', reject);
    req.on('timeout', () => { req.destroy(); reject(new Error('Timeout Telegram')); });
    req.write(body);
    req.end();
  });
}

// ── Formato ARS ─────────────────────────────────────────────────────────────
function fmt(n) {
  if (n == null) return '—';
  return `$${Number(n).toLocaleString('es-AR', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
}

// ── Beep por ALSA (aplay) ───────────────────────────────────────────────────
function playBeep() {
  // Genera WAV PCM 16-bit mono 44100Hz con dos tonos (880Hz + 440Hz)
  const sampleRate = 44100;
  const duration   = 1.2;        // segundos totales
  const numSamples = Math.floor(sampleRate * duration);
  const dataSize   = numSamples * 2; // 16-bit = 2 bytes por muestra

  const buf = Buffer.alloc(44 + dataSize);

  // Cabecera RIFF/WAV
  buf.write('RIFF', 0);                           buf.writeUInt32LE(36 + dataSize, 4);
  buf.write('WAVE', 8);                           buf.write('fmt ', 12);
  buf.writeUInt32LE(16, 16);                      buf.writeUInt16LE(1, 20);   // PCM
  buf.writeUInt16LE(1, 22);                       buf.writeUInt32LE(sampleRate, 24);
  buf.writeUInt32LE(sampleRate * 2, 28);          buf.writeUInt16LE(2, 32);
  buf.writeUInt16LE(16, 34);                      buf.write('data', 36);
  buf.writeUInt32LE(dataSize, 40);

  // Dos pitidos: 880Hz durante 0.4s, silencio 0.1s, 880Hz durante 0.4s
  const seg1end = Math.floor(sampleRate * 0.4);
  const seg2end = Math.floor(sampleRate * 0.5);
  const seg3end = numSamples;

  for (let i = 0; i < numSamples; i++) {
    let sample = 0;
    if (i < seg1end) {
      sample = Math.sin(2 * Math.PI * 880 * i / sampleRate) * 28000;
    } else if (i >= seg2end && i < seg3end) {
      sample = Math.sin(2 * Math.PI * 1100 * (i - seg2end) / sampleRate) * 28000;
    }
    buf.writeInt16LE(Math.round(sample), 44 + i * 2);
  }

  const proc = spawn('aplay', ['-q', '-'], { stdio: ['pipe', 'ignore', 'ignore'] });
  proc.stdin.write(buf);
  proc.stdin.end();
  proc.on('error', () => {}); // aplay no disponible — ignorar silenciosamente
}

// ── Enviar alerta Telegram ───────────────────────────────────────────────────
async function sendAlert(cfg, pA, pB, diff, metaA, metaB) {
  const { token, chatId } = cfg.telegram;
  if (!token || !chatId) {
    console.warn('[telegram] Sin configurar — editá config.json');
    return;
  }

  const labelA = `${metaA} ${cfg.sideA.asset.toUpperCase()} ${cfg.sideA.dir}`;
  const labelB = `${metaB} ${cfg.sideB.asset.toUpperCase()} ${cfg.sideB.dir}`;
  const pct    = (diff / Math.abs(pB) * 100).toFixed(2);
  const text   =
    `💱 *Alerta Comparador*\n\n` +
    `*${labelA}:* ${fmt(pA)}\n` +
    `*${labelB}:* ${fmt(pB)}\n\n` +
    `*Diferencia: ${fmt(diff)}* (+${pct}%)\n` +
    `_${new Date().toLocaleString('es-AR')}_`;

  try {
    const res = await post(`https://api.telegram.org/bot${token}/sendMessage`, {
      chat_id: chatId, text, parse_mode: 'Markdown',
    });
    if (res.ok) {
      console.log('[telegram] Alerta enviada ✓');
    } else {
      console.error('[telegram] Error:', res.description);
    }
  } catch (e) {
    console.error('[telegram] Error al enviar:', e.message);
  }
}

// ── Ciclo principal ──────────────────────────────────────────────────────────
let alertCoolingDown = false;
const COOLDOWN_MS = 5 * 60 * 1000; // 5 min entre alertas repetidas

async function tick() {
  const cfg = loadConfig();

  if (!cfg.alert.enabled) {
    console.log('[monitor] Alerta desactivada en config.json');
    return;
  }

  const BASE = 'https://api.comparadolar.ar';
  const needA = `${BASE}/${cfg.sideA.asset}`;
  const needB = cfg.sideA.asset === cfg.sideB.asset ? null : `${BASE}/${cfg.sideB.asset}`;

  let listA, listB;
  try {
    [listA, listB] = await Promise.all([
      get(needA),
      needB ? get(needB) : get(needA),
    ]);
    if (!needB) listB = listA;
  } catch (e) {
    console.error('[fetch] Error:', e.message);
    return;
  }

  const entA = (listA || []).find(p => p.slug === cfg.sideA.slug);
  const entB = (listB || []).find(p => p.slug === cfg.sideB.slug);

  const pA = entA?.[cfg.sideA.dir] ?? null;
  const pB = entB?.[cfg.sideB.dir] ?? null;

  if (pA == null || pB == null) {
    console.warn('[monitor] No se encontró precio para el par configurado');
    return;
  }

  const diff = pA - pB;
  const ts   = new Date().toLocaleTimeString('es-AR');

  console.log(`[${ts}] A=${fmt(pA)}  B=${fmt(pB)}  diff=${fmt(diff)}`);

  if (diff >= cfg.alert.threshold && !alertCoolingDown) {
    console.log(`[monitor] ⚡ Umbral superado (${fmt(diff)} >= ${fmt(cfg.alert.threshold)})`);
    alertCoolingDown = true;
    setTimeout(() => { alertCoolingDown = false; }, COOLDOWN_MS);
    playBeep();
    await sendAlert(cfg, pA, pB, diff, entA?.prettyName ?? cfg.sideA.slug, entB?.prettyName ?? cfg.sideB.slug);
  } else if (diff < cfg.alert.threshold && alertCoolingDown) {
    // Resetear cooldown si la diferencia bajó del umbral
    alertCoolingDown = false;
  }
}

// ── Arranque ─────────────────────────────────────────────────────────────────
async function main() {
  const cfg = loadConfig();
  console.log('╔══════════════════════════════════════╗');
  console.log('║     💱 Monitor de Cotizaciones       ║');
  console.log('╚══════════════════════════════════════╝');
  console.log(`Par:       ${cfg.sideA.slug.toUpperCase()} ${cfg.sideA.asset.toUpperCase()} ${cfg.sideA.dir} vs ${cfg.sideB.slug.toUpperCase()} ${cfg.sideB.asset.toUpperCase()} ${cfg.sideB.dir}`);
  console.log(`Umbral:    ${fmt(cfg.alert.threshold)} ARS`);
  console.log(`Frecuencia: cada ${cfg.frequency}s`);
  console.log(`Telegram:  ${cfg.telegram.token ? '✓ configurado' : '✗ sin configurar'}`);
  console.log('');

  await tick();
  setInterval(tick, cfg.frequency * 1000);
}

main().catch(e => { console.error('Fatal:', e); process.exit(1); });
