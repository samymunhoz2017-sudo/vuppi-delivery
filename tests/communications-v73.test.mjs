import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

const migration=readFileSync(new URL('../supabase/migrations/202610200002_courier_communications.sql',import.meta.url),'utf8');
const server=readFileSync(new URL('../server/delivery.mjs',import.meta.url),'utf8');
const admin=readFileSync(new URL('../dist/admin.js',import.meta.url),'utf8');
const courier=readFileSync(new URL('../dist/delivery.js',import.meta.url),'utf8');
const service=readFileSync(new URL('../mobile/vuppi-entregador-android/app/src/main/java/br/com/vuppidelivery/entregador/CourierService.java',import.meta.url),'utf8');
const activity=readFileSync(new URL('../mobile/vuppi-entregador-android/app/src/main/java/br/com/vuppidelivery/entregador/MainActivity.java',import.meta.url),'utf8');

for(const invariant of ['vuppi_courier_messages','vuppi_courier_message_reads','target_kind','priority','enable row level security'])assert.ok(migration.includes(invariant),`Central de mensagens sem ${invariant}`);
for(const action of ['message_create','message_read','message_archive'])assert.ok(server.includes(action),`Contrato ausente: ${action}`);
assert.ok(server.includes("path==='/api/delivery/messages'"));
assert.ok(admin.includes('communicationsView')&&admin.includes('Novo comunicado')&&admin.includes('Todos os entregadores'));
assert.ok(courier.includes('loadCourierMessages')&&courier.includes('central-message-splash'));
assert.ok(service.includes('pollCentralMessages')&&service.includes('CHANNEL_MESSAGES'));
assert.ok(activity.includes('centralMessagesDialog')&&activity.includes('Mensagens da central'));
console.log('V73: central de mensagens, segmentação, leitura e alerta Android verificados.');
