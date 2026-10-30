# Retorno e liquidação de entregas agrupadas

O projeto atual usa `vuppi_deliveries.route_group_id` para agrupar entregas. Cada linha conserva seu próprio estado, indicação de retorno e valor; as cotações guardam o snapshot tarifário em `vuppi_quotes.pricing_snapshot`. A carteira usa reservas e lançamentos de dupla entrada por entrega. A transição de cada entrega para `delivered` aciona o processamento financeiro individual.

## Risco identificado

O cálculo original de cada cotação inclui a taxa de retorno quando o retorno foi solicitado. Assim, somar os preços congelados de várias entregas com retorno pode incluir essa taxa mais de uma vez. A função `vuppi_start_delivery_return` trabalha na entrega individual e não verifica se existem paradas posteriores na rota. A alteração correta exige coordenar os estados, as reservas já feitas e os lançamentos numa transação; trocar apenas o texto ou o cálculo da interface não resolve a liquidação.

## Ferramentas preparadas

- `scripts/audit-grouped-returns.sql` é uma consulta somente de leitura que lista grupos com múltiplos retornos ou snapshot ausente. As somas de taxas são indicativos para análise e não comprovam cobrança indevida. Não identifica automaticamente estornos nem altera lançamentos.
- `server/grouped-settlement.mjs` calcula o subtotal individual a partir dos preços e taxas congelados e adiciona uma única taxa. Rejeita taxas diferentes, informações ausentes e IDs repetidos para evitar uma escolha financeira silenciosa. Ainda não está ligado ao despacho nem às carteiras.
- `tests/grouped-settlement.test.mjs` cobre três destinos sem retorno, um retorno, três retornos, taxas divergentes, snapshot ausente, duplicidade e limite de 24 destinos.
- `server/grouped-stops.mjs` e `tests/grouped-stops.test.mjs` modelam ordem, repetição e visibilidade do retorno; são funções locais, sem efeito na operação.
- `supabase/migrations/202610300001_grouped_route_foundation.sql` prepara tabelas aditivas de OS, paradas e liquidações. Elas ficam fechadas a `anon` e `authenticated`, têm RLS habilitada e ainda não são utilizadas pelo aplicativo. A migração não foi aplicada ao Supabase. O teste opcional `tests/grouped-route-db-local.cjs` usa PGlite em memória e um esquema mínimo, apenas para verificar restrições; ele não valida os fluxos, políticas e concorrência do projeto real.
- `202610300002_grouped_route_transitions.sql` prepara confirmação das paradas, chegada e autorização do retorno, e cria uma liquidação pendente. Não credita nem debita carteiras.
- `202610300003_prepare_grouped_route.sql` materializa snapshots de um grupo ainda não aceito; atualmente bloqueia grupos com entregas já aceitas, com estabelecimentos, cidades ou modalidades de pagamento diferentes, ou com taxas de retorno divergentes.
- `202610300004_grouped_route_accept_collect.sql` prepara aceite e coleta em transação com chamadas às funções legadas. No teste local essas funções legadas são substituídas por implementações mínimas: isso não demonstra que o fluxo existente, as regras de oferta, o saldo ou os gatilhos reais estão corretos.
- `202610300005_grouped_route_state.sql` prepara uma consulta autorizada que não envia o endereço de retorno até a parada de retorno estar ativa e não envia o valor bruto para o entregador.
- A API preparada depende de `VUPPI_GROUPED_ROUTES_V2=true`; a opção permanece desligada por padrão e nenhum cliente existente usa essas rotas.

Nenhuma dessas cinco migrations foi aplicada ao Supabase. Para repetir os testes locais isolados, instale `@electric-sql/pglite@0.5.13` fora do repositório, defina `VUPPI_PGLITE_MODULE` para a pasta do módulo e execute `node tests/grouped-route-db-local.cjs` na raiz do projeto. Esse ambiente usa um esquema mínimo e não é uma réplica de produção.

## Pendências para homologação

Conectar a criação e o estado da OS às interfaces e ao app; projetar e testar a liquidação atômica com as reservas e as taxas já incluídas nas cotações. Os lançamentos legados são disparados por entrega e não podem ser simplesmente executados junto com uma nova liquidação de OS. Também faltam geofence, eventos, dados de dispositivo, fluxo de exceção, proteção de dados por perfil, concorrência real e integração com cash e créditos. Antes de qualquer alteração histórica, executar o relatório, revisar os grupos sinalizados e conservar os movimentos existentes. Validar RLS, créditos, dinheiro, retorno, retomada e confirmação fora da ordem com dados isolados de homologação.

## Roteiro de teste alvo

Em homologação, criar três entregas da mesma loja com retorno, registrar suas cotações congeladas e agrupá-las. Confirmar cada entrega na sequência e verificar que o retorno só aparece após a terceira. Confirmar o retorno com o perfil autorizado e conferir no extrato um único valor de retorno e uma única liquidação da OS. Repetir a confirmação e verificar que não há novos lançamentos. Este roteiro ainda não é um teste aprovado do sistema atual.
