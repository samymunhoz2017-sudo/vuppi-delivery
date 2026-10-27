import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
const read=path=>readFileSync(new URL('../'+path,import.meta.url),'utf8');
const activity=read('mobile/vuppi-entregador-android/app/src/main/java/br/com/vuppidelivery/entregador/MainActivity.java');
const delivery=read('dist/delivery.js');
const html=read('dist/delivery.html');
const css=read('dist/delivery.css');
const landing=read('dist/index.html');
const login=read('dist/login.html');
const build=read('scripts/build.mjs');
const worker=read('server/worker.mjs');

assert.match(activity,/Bitmap\.createScaledBitmap\(source,size,size,true\)/);
assert.match(activity,/int size=dp\(36\)/);
assert.doesNotMatch(activity,/fromResource\(R\.drawable\.vuppi_courier_helmet_marker\)/);
assert.match(activity,/courierMarker\.setPosition\(here\)/);
assert.match(activity,/private Button menuTile/);

assert.match(delivery,/merchantHornContext/);
assert.match(delivery,/\['requested','pending','unattended'\]\.includes\(old\)/);
assert.match(delivery,/portal==='merchant'\?4000/);
assert.match(delivery,/merchantPrefs\(\)\.sound/);
assert.match(delivery,/addEventListener\('pointerdown',unlockMerchantAudio/);
assert.match(html,/data-merchant-tab="dashboard"[^>]*>\s*<span/);
assert.match(css,/v83: navegação visual e menus operacionais/);
assert.match(css,/\.courier-menu-list button\[data-tone="green"\]/);

assert.match(landing,/href="\/entrar"/);
assert.match(landing,/vuppi-mascot-3d\.png/);
assert.doesNotMatch(landing,/id="portalLogin"/);
assert.match(login,/id="portalLogin"/);
assert.match(login,/portal\.js\?v=83/);
assert.match(build,/'login\.html'/);
assert.match(worker,/'\/entrar':'\/login\.html'/);
console.log('merchant-experience-v83.test.mjs passed');
