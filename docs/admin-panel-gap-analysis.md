# Auditoria do painel administrativo e do estabelecimento — Vuppi 0.63.1

Data: 12/10/2026. Base auditada: versão 0.62 existente, aplicação web estática em JavaScript com servidor Node e funções PostgreSQL/Supabase. A arquitetura real não usa React; portanto, a correção preserva o AppShell atual, o cliente de autenticação e os RPCs existentes.

## Matriz de gaps

| Função | Já existe? | Estado inicial | Arquivos principais | Problema encontrado | Ação desta revisão |
|---|---:|---|---|---|---|
| Sessão administrativa | Sim | Implementada parcialmente | `dist/auth-client.js`, `dist/admin.js` | Ações locais eram confundidas com reinicialização por `location.reload()` e por dois ciclos de atualização concorrentes | Reload mantido somente no logout explícito; atualização global duplicada removida; mutações permanecem no AppShell |
| Entrega rápida administrativa | Sim | Implementada mas quebrada | `dist/admin-quick.js`, `server/delivery.mjs` | Ao criar, executava `location.reload()`, perdia contexto e permitia risco de envio repetido | Fluxo local com progresso, bloqueio de duplo envio, erro inline, evento de sucesso e abertura da OS criada |
| Atualização automática da operação | Sim | Implementada mas concorrente | `dist/admin.js`, `dist/admin-enhancements.js` | O enhancer clicava em atualizar a cada 5 s além do timer da própria tela | Removido o polling global; timer fica restrito ao módulo ativo e preserva filtros |
| Mapa operacional Google | Sim | Implementada e funcionando | `dist/admin.js`, `/api/maps/config` | Era necessário distinguir falha de configuração de falha visual | Endpoint validado com `ready:true`; mapa renderizado no painel publicado; container recebe altura mínima e tratamento de erro permanece |
| Gestão de pedidos | Sim | Implementada e funcionando | `dist/admin.js`, `server/delivery.mjs` | Visual fragmentado; entrega rápida saía da gestão | Shell e componentes unificados; criação rápida volta para Gestão de pedidos e seleciona a OS |
| Criação normal pela loja | Sim | Implementada e funcionando | `dist/delivery.js`, `server/delivery.mjs` | Formulário já cria, calcula rota e permanece no módulo | Preservado; incluído atalho a partir do consumidor conhecido |
| Consumidores da loja | Sim, no backend | Backend sem interface de gestão | `dist/delivery.js`, RPC `customer`/`customer_save` | Autopreenchimento por telefone existia, mas não havia menu/lista | Nova tela Consumidores isolada pelos pedidos da própria loja, busca e reutilização em Nova entrega |
| Carteira da loja | Sim | Implementada e funcionando após hidratação | `dist/delivery.js`, `server/financial.mjs` | HTML inicial ainda contém placeholder antes da hidratação | Integração real preservada; remoção completa do placeholder fica registrada como P1 |
| Vuppi Wallet administrativa | Sim | Implementada parcialmente | `dist/admin.js`, `server/financial.mjs`, migrations Wallet | Dashboard simples e claro, abaixo da referência visual | Novo painel escuro com KPIs, composição, gráfico e transações derivados apenas de dados reais |
| Mensalidades e isenções | Sim | Implementada mas inacessível/quebrada | `dist/admin.js`, migration billing | Views existiam, mas abas não; `billing`, `profiles` e `exemptions` não eram inicializados | Abas expostas e variáveis inicializadas com fallback seguro |
| AppShell / navegação | Sim | Implementada parcialmente | `dist/admin.html`, `dist/admin.css`, `dist/admin.js` | Hierarquia visual inconsistente e busca inexistente | Sidebar reorganizada, topbar estável, busca de comandos, tema SaaS escuro e responsividade |
| Mapa do aplicativo Android | Sim | Requer validação em aparelho | `mobile/`, `dist/delivery.js` | O provider web está configurado; restrições Android e ciclo de vida não podem ser provados no navegador | Mantido como bloqueador de teste físico da próxima rodada Android |
| Alertas críticos para empresas | Não completo | Não implementada | — | Comunicação atual é informativa e não persiste alertas com início/fim | P1 pendente: exige tabela/RPC e isolamento por empresa |
| Multidestinos por parada | Parcial | Implementada parcialmente | migrations de operação, `dist/delivery.js` | Junção/otimização existe, confirmação individual por parada não foi comprovada | P1/P2 pendente após estabilização do fluxo simples |
| Redistribuição preservando OS | Parcial | Não comprovada ponta a ponta | fluxo de atribuição/ocorrências | Atribuição existe; trilha completa A→B e divisão financeira ainda não comprovadas | P2 pendente |
| RBAC granular | Parcial | Implementada parcialmente | RPCs admin, `admin.js` | Superadmin e isolamento por membro existem; papéis financeiro/suporte/leitura ainda não são completos na UI | P1 de segurança pendente |

## Causas raiz P0

1. `admin-quick.js` recarregava toda a página depois de `admin_create`.
2. `admin-enhancements.js` mantinha um `setInterval` global que acionava atualização mesmo fora do controle da tela; `admin.js` já tinha seu próprio timer.
3. As telas de billing estavam presentes, porém fora da lista de abas e dependiam de variáveis inexistentes no escopo.
4. O design era composto por camadas CSS conflitantes (tema claro antigo, refresh azul e componentes financeiros), sem um conjunto final de tokens.

## Evidência do mapa

- `GET https://vuppidelivery.com.br/api/maps/config`: provider `google`, `ready: true`.
- O painel publicado renderizou o mapa Google, termos/cartografia e centro `-21.0106, -48.2217`.
- A ausência de marcadores no instante da inspeção correspondeu a `0 entregadores online`; não foi falha de SDK.

## Bloqueadores restantes para declarar piloto completo

- Executar o checklist físico Android: oferta em segundo plano, overlay, mapa, aceite, coleta e conclusão.
- Validar uma entrega real completa com entregador e loja de teste, inclusive lançamento único no ledger.
- Completar alertas persistentes para empresas e RBAC granular.
- Testar isolamento entre duas contas reais de estabelecimento.
- Validar agendamento em background no horário programado e multidestino com confirmação por parada.

## Publicação e validação da versão 0.63.1

- Pacote publicado: `vuppi-delivery-v63.1-admin-20261012-112357.zip`.
- A Hostinger marcou a implantação como `Concluído` e `Atual` em 12/10/2026 às 11:24:44.
- `GET /api/app/version?platform=web` respondeu `current_web_version: 0.63.1`.
- A sessão administrativa permaneceu autenticada após recarregar `/admin?v=631`.
- O painel financeiro abriu com dados reais do ledger e sem o erro de seletor nulo corrigido no hotfix.
- O mapa operacional carregou o Google Maps sem erros de console; o painel indicou corretamente `0 entregadores online` no momento do teste.
- `npm test`, `npm run check` e `npm run build` foram executados novamente após a publicação e concluíram com sucesso.

O sistema melhorou nos P0 auditados, mas ainda não deve ser classificado como integralmente pronto para piloto até esses testes ponta a ponta serem concluídos.
