# Vuppi Wallet — implementação incremental

Data: 11/10/2026

## Arquitetura preservada

- Uma carteira por titular e operação, com contas `available`, `reserved`, `pending` e `promotional`.
- Razão contábil de partidas vinculadas a `vuppi_financial_transactions` e `vuppi_ledger_entries`.
- Saldos alterados somente por `vuppi_post_transaction`, com bloqueio de linha e chaves idempotentes.
- Fluxos existentes de recarga, saque, entrega, benefícios, estorno, conciliação e auditoria.
- Provedor falso mantido para testes. O adaptador Asaas continua bloqueado para operações reais. Não há integração Mercado Pago neste código.

## Migration nova

Arquivo: `supabase/migrations/202610110001_vuppi_wallet_billing.sql`

Tabelas adicionadas:

- `vuppi_finance_permissions`
- `vuppi_store_billing_profiles`
- `vuppi_billing_exemptions`
- `vuppi_subscription_invoices`
- `vuppi_billing_runs`
- `vuppi_billing_run_items`
- `vuppi_payment_allocations`
- `vuppi_finance_security_events`

Campos incrementais foram adicionados a `vuppi_finance_settings`, `vuppi_topups` e `vuppi_withdrawals`.

## Funções e processos

- `vuppi_billing_profile_ensure`: cria o perfil de cobrança sem duplicar o cadastro do estabelecimento.
- `vuppi_billing_run_execute`: executa prévia ou geração real de mensalidades de forma idempotente.
- `vuppi_wallet_billing`: contrato único para estado, cadastro, configurações, isenções, execução e aprovação de saques.
- Triggers de recarga incluem débitos vencidos no total e criam alocações explícitas.
- Trigger de liquidação baixa faturas após confirmação da recarga.
- Trigger de risco classifica saques e impede processamento sem as aprovações exigidas.
- Agendamento do Worker executa cobrança em `dry-run` por padrão. Lançamentos reais dependem de duas flags independentes.

## Regras implementadas

- Mensalidade padrão de R$ 29,90, configurável por cidade.
- Período gratuito de 0, 30, 60 ou 90 dias no cadastro administrativo.
- Isenção individual e em massa com motivo, validade, idempotência, auditoria e AAL2.
- Prévia do lote antes da cobrança real.
- Débitos de mensalidade adicionados à recarga sem reduzir os créditos solicitados para a carteira.
- Vários débitos vencidos são alocados do mais antigo para o mais recente.
- Revisão por risco e aprovação dupla de saque por faixas configuráveis.
- A segunda aprovação precisa ser feita por outro usuário.

## Interface

Administração:

- Abas “Mensalidades” e “Isenções”.
- Indicadores de ativos, isentos, inadimplentes e receita mensal prevista.
- Prévia de cobrança, isenção individual/em massa e revogação.
- Revisão de saques e indicação da segunda aprovação.
- Configurações de mensalidade, carência, isenção em massa e limites de revisão.

Estabelecimento:

- Valor da mensalidade, situação, próxima cobrança, isenção vigente e débito.
- Composição da recarga: créditos, mensalidades vencidas, taxa estimada e total do pagamento.
- Histórico de faturas permanece disponível pelo estado financeiro usado pela tela.

## Segurança

- RLS habilitado e acesso direto de `anon` e `authenticated` revogado nas tabelas financeiras novas.
- Escritas financeiras passam por funções `security definer` com `search_path` fixo.
- Permissões separadas para visualização, configuração, isenção individual/em massa, revogação e aprovação de saque.
- Ações sensíveis exigem `aal2` ou execução pelo `service_role`.
- Ledger existente continua imutável; não foi criado caminho de escrita direta de saldo pelo navegador.

## Feature flags

- `vuppi_finance_settings.merchant_monthly_billing`: `false` por padrão.
- `vuppi_finance_settings.mass_billing_exemptions`: `false` por padrão.
- `VUPPI_BILLING_SCHEDULE_ACTIVE`: ausente/`false` executa somente prévia.
- Ativação real exige a flag do banco e a flag do Worker.

## Validação executada

- `npm test`: aprovado.
- `npm run check`: aprovado.
- `npm run build`: aprovado.
- Testes adicionados para composição da recarga, feature flags, RLS, idempotência, cobrança, isenção, aprovação de saque e presença das telas.

## Pendências de ativação

1. Fazer backup do banco Supabase.
2. Aplicar a migration em homologação e executar `npm run test:integration` com credenciais de teste.
3. Configurar MFA/AAL2 para os administradores financeiros.
4. Definir os limites de revisão e aprovação dupla de saque.
5. Rodar a prévia e conferir os itens do lote.
6. Homologar um provedor real de pagamentos. Até isso ocorrer, recargas e saques externos permanecem simulados.
7. Ativar as flags somente após a homologação.

Esta entrega altera o código e prepara o build local. A migration ainda não foi aplicada ao banco de produção e nenhuma cobrança real foi ativada.
