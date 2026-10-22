# Auditoria do fluxo de pendências — Vuppi 0.76.0

## FLUXO ENCONTRADO

O banco aceitava apenas `requested`, `assigned`, `collected`, `delivered` e `cancelled`. A interface administrativa calculava uma suposta pendência pela idade de `requested`, enquanto o aplicativo consultava outra função que retornava todas as solicitações `requested`. O contador, a lista, o app e o despacho podiam divergir.

## STATE MACHINE

`requested` (em distribuição) → `pending` (rodadas esgotadas/tempo excedido) → `assigned` (aceite atômico) → `collected` → `delivered`.

Saídas laterais: `requested|pending|assigned|collected` → `cancelled`; `pending` → `unattended` ao expirar. O cancelamento do entregador antes da chegada devolve toda a rota para `requested`. A recusa individual apenas grava a decisão do entregador e não transforma a OS imediatamente em pendência.

## CAUSA RAIZ

Não existia estado persistido `pending`. A regra vivia no JavaScript, dependia do relógio do navegador e não era compartilhada com o Android. Isso explicava entregas que apareciam no contador e sumiam da lista, ou tocavam no app sem aparecer para a central.

## CORREÇÕES IMPLEMENTADAS

- Estado canônico `pending`, com `pending_since`, expiração, motivo, reenvios e origem do aceite.
- Manutenção transacional idempotente para transição, reenvio e expiração.
- Consulta administrativa e consulta do entregador baseadas na mesma fonte.
- Aceite protegido por bloqueio transacional; um único entregador vence a concorrência.
- Aceite de rota agrupada em uma única transação.
- Raios diferentes para listar e aceitar pendências.
- Reenvio automático e manual, com histórico em `vuppi_delivery_events`.
- Painel com tempo pendente, expiração, elegíveis, tentativas e atualização reconciliada.
- Aplicativo Android alerta pendências universais em segundo plano e não soma o histórico ao badge atual.
- Cancelamento seguro antes da chegada devolve a rota à distribuição e registra auditoria.

## ARQUIVOS ALTERADOS

- `supabase/migrations/202610210002_pending_state_machine.sql`
- `server/delivery.mjs`
- `dist/admin.js`, `dist/admin.css`, `dist/delivery.js`
- `mobile/vuppi-entregador-android/.../MainActivity.java`
- `mobile/vuppi-entregador-android/.../CourierService.java`

## TESTES

Os testes de 0.76 validam o estado persistido, fonte canônica, aceite atômico, ações administrativas, alerta Android, badge e botão de cancelamento. O pacote completo também é executado antes da publicação.

## OBSERVAÇÕES FINANCEIRAS

A reserva de saldo do saque e a revisão administrativa são transacionais. O pagamento Pix externo automático depende da habilitação do produto Payouts na conta Mercado Pago; a API pode responder `403 forbidden` quando o token não possui essa permissão. O sistema não marca um saque como pago sem confirmação do provedor.

## PENDÊNCIAS IDENTIFICADAS

- Homologar Payouts/Money Out com o Mercado Pago para efetivar transferências Pix externas.
- Executar teste de campo com dois aparelhos para validar restrições específicas de bateria de cada fabricante.
