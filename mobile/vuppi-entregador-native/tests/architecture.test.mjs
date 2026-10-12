import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const app = readFileSync(new URL('../src/App.tsx', import.meta.url), 'utf8');
const api = readFileSync(new URL('../src/api.ts', import.meta.url), 'utf8');
const native = readFileSync(new URL('../src/native.ts', import.meta.url), 'utf8');
const config = readFileSync(new URL('../app.config.ts', import.meta.url), 'utf8');

test('a interface principal usa componentes e mapa nativos', () => {
  assert.match(app, /react-native-maps/);
  assert.match(app, /MapView/);
  assert.doesNotMatch(app, /WebView|iframe|window\.location|document\./);
});

test('sessão é protegida e localização usa APIs nativas', () => {
  assert.match(api, /expo-secure-store/);
  assert.doesNotMatch(api, /localStorage|sessionStorage/);
  assert.match(native, /expo-location/);
  assert.match(native, /startLocationUpdatesAsync/);
});

test('pacote Android e deep link são estáveis', () => {
  assert.match(config, /br\.com\.vuppidelivery\.entregador/);
  assert.match(config, /scheme: 'vuppi'/);
  assert.match(config, /pathPrefix: '\/entregador'/);
});
