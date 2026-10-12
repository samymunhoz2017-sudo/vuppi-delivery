# Auditoria Machine × Vuppi — cadastro e gestão de entregadores

Data da auditoria: 08/10/2026

## Escopo e método

A referência visual enviada foi tratada como requisito de produto, não como instrução técnica. A inspeção foi feita sobre as rotas, telas, APIs, migrações e testes existentes no projeto Vuppi. Nesta etapa não foi criada uma segunda versão do painel, nenhuma tabela foi duplicada e nenhuma migração de banco foi adicionada.

O objetivo aplicado foi evoluir o cadastro de entregadores dentro da tela administrativa já existente, preservando contratos, sessão, RLS, despacho, carteira e aplicativo Android.

## Inventário do sistema atual

| Área | Implementação existente | Fonte principal |
|---|---|---|
| Portal e autenticação única | Login com identificação de perfil e restauração de sessão | `dist/index.html`, `dist/portal.js`, `dist/auth-client.js` |
| Centro administrativo | SPA administrativa com navegação por cadastros, logística, finanças e operação | `dist/admin.html`, `dist/admin.js`, `dist/admin.css` |
| Estabelecimento e entregador | Mesma base de estado operacional, com experiências por perfil | `dist/delivery.html`, `dist/delivery.js` |
| Operação ao vivo | Pedidos, entregadores, estados logísticos e mapa | `/api/delivery/state`, `server/delivery.mjs` |
| Ações administrativas | Status de membro, conclusão remota, retorno e configurações operacionais | `/api/delivery/action`, `server/delivery.mjs` |
| Finanças | Carteiras, lançamentos, reservas e extratos | `/api/finance`, `server/financial.mjs` |
| Google Maps | Configuração protegida no servidor e carregamento nos painéis | `/api/maps/config`, `dist/admin.js`, `dist/delivery.js` |
| Android | Aplicativo do entregador preparado para distribuição direta e Play Store | `mobile/vuppi-entregador-android` |

### Modelo de dados relevante

- `vuppi_members`: perfil, tipo, aprovação, situação cadastral, disponibilidade, última atividade, foto, veículo, placa, CPF, CNH e permissões individuais.
- `vuppi_deliveries`: OS, estabelecimento, entregador, estados do fluxo, endereços, retorno e datas.
- `vuppi_quotes`: estimativa e cálculo de preço.
- Tabelas e funções de operação, finanças, eventos e auditoria são incrementadas pelas migrações em `supabase/migrations`.
- A situação cadastral aceita hoje `pending`, `active`, `suspended` e `inactive`. Categorias como “rejeitado”, “fila de espera” e “excluído” da referência não foram simuladas porque ainda não existem como estados reais no contrato.

## Matriz Machine × Vuppi

| Capacidade observada | Estado anterior na Vuppi | Classificação | Aplicação nesta etapa |
|---|---|---|---|
| Abas de situação com contadores | Lista única com busca simples | IMPROVE_UX | Abas reais: todos, ativos, em análise, suspensos e inativos |
| Filtros laterais | Busca textual | IMPROVE_UX | Busca, cidade e disponibilidade, com limpeza e contagem |
| Tabela densa no desktop | Cartões genéricos | IMPROVE_UX | Tabela com identidade, contato, veículo, status, disponibilidade e última atividade |
| Visualização em celular | Cartões pouco especializados | IMPROVE_UX | Cartões compactos e ficha em tela cheia |
| Perfil do entregador sem sair da lista | Ausente | MINIMAL_SAFE_EXTENSION | Drawer único sobre a rota existente, com URL profunda `perfil` e `aba` |
| Dados pessoais e veículo | Presentes no estado, sem ficha organizada | IMPROVE_UX | Exibição consolidada e CPF mascarado |
| Documentos completos da referência | CPF e CNH básicos | PARTIAL | Somente indicadores reais; upload administrativo depende de armazenamento privado e contrato próprio |
| Status cadastral separado de livre/ocupado | Existente no banco e na operação | STABLE_EXISTING | Mantido e apresentado separadamente |
| Ativar, suspender e inativar | Existente | STABLE_EXISTING | Reutilizado dentro da ficha |
| Conclusão antecipada por entregador | Existente | STABLE_EXISTING | Reutilizada como permissão individual |
| Finalização de retorno pelo entregador | Existente | STABLE_EXISTING | Reutilizada como permissão individual |
| Histórico e total de entregas | Dados existentes, pouco visíveis no cadastro | IMPROVE_UX | KPIs e últimas OS atribuídas dentro da ficha |
| Taxa de aceitação | Sem métrica auditável das últimas ofertas | NOT_IMPLEMENTED | Exibida como não mensurada; não foi inventado percentual |
| Exportação | Ausente na tela de entregadores | MINIMAL_SAFE_EXTENSION | CSV dos resultados filtrados, gerado localmente sem novo endpoint |
| Despacho e aceite idempotente | Implementado nas funções operacionais | STABLE_EXISTING | Sem alteração nesta etapa |
| Pedidos do estabelecimento | Implementado e já redesenhado | IMPROVE_UX | Fora do escopo de alteração deste ciclo |
| Mapas e rastreamento | Integração Google Maps implementada | STABLE_EXISTING | Sem alteração nesta etapa |
| Carteiras e reservas | Implementadas com ledger | STABLE_EXISTING | Sem alteração nesta etapa |
| Provedor financeiro externo | Preparação parcial; depende de credenciais e validação em ambiente | PREPARED_INACTIVE | Não ativado nesta etapa |
| Agrupamento e otimização de rotas | Parcial | PARTIAL | Requer rodada separada de regra operacional e simulação |
| RBAC/RLS | Implementado no servidor e banco | STABLE_EXISTING | Sem relaxamento; testes integrados de isolamento continuam necessários |

## Alterações aplicadas

- Evolução da função existente `memberView` em `dist/admin.js`.
- Reaproveitamento de `state.members`, `state.orders` e das ações reais do servidor.
- Inclusão de abas, filtros, exportação CSV, tabela desktop e cartões mobile.
- Inclusão de uma ficha lateral única com resumo, dados pessoais, veículo, permissões e entregas.
- Links profundos para abrir entregador e seção sem criar nova rota ou duplicar estado.
- CSS responsivo específico em `dist/admin.css`.
- Nenhuma alteração de banco, autenticação, RLS, tarifa, carteira ou regra de despacho.

## Lacunas e backlog priorizado

### P0

- Validar em produção que a lista carrega apenas membros autorizados para o usuário administrativo autenticado.
- Testar as três ações mutáveis da ficha com uma conta administrativa real e confirmar seus registros de auditoria.

### P1

- Criar contrato administrativo seguro para edição cadastral, com lista explícita de campos, validação, auditoria e RLS.
- Criar armazenamento privado e URLs temporárias para documentos de CNH, CRLV, comprovante e certidões.
- Persistir eventos de oferta para calcular taxa de aceitação das últimas 100 ofertas.

### P2

- Adicionar paginação no servidor para bases grandes e filtros com consulta indexada.
- Implementar exportação assíncrona para grandes volumes.
- Completar agrupamento, multi-coleta e otimização com simulação e trilha de auditoria.

### P3

- Avaliar novos estados cadastrais como rejeitado, fila de espera e arquivado após definir transições, efeitos operacionais e política de retenção.
- Adicionar documentos bancários e campos internos somente após política de acesso e necessidade operacional aprovadas.

## Riscos e rollback

A mudança é de apresentação e orquestra ações já existentes. O principal risco é regressão de layout em resoluções específicas; a mitigação é CSS responsivo e testes estruturais. O rollback consiste em restaurar `memberView` e remover o bloco CSS identificado pelo comentário “Entregadores: evolução incremental”. Não há rollback de banco porque nenhuma migração foi criada.

## Critérios de aceite desta etapa

- Uma única tela de entregadores, dentro do painel existente.
- Abas e contagens derivadas de dados reais.
- Filtros combináveis e exportação dos resultados visíveis.
- Ficha aberta por clique ou menu, com retorno à lista e URL compartilhável.
- Ações de status e permissões chamam endpoints existentes.
- Layout se adapta a desktop e celular.
- Sem alteração em autenticação, RLS, finanças, tarifa ou despacho.