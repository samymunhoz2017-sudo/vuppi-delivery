# Carteira de créditos — Vuppi Delivery

## Estado desta versão

A versão 0.46.0 inclui a arquitetura financeira, o adaptador de pagamentos e as interfaces da carteira. A migration `202610050003_financial_wallet.sql` foi **preparada e não aplicada**, pois não há evidência segura de que o Supabase conectado seja desenvolvimento ou homologação.

O Asaas permanece desativado. O `FakePaymentProvider` é o único provedor utilizável nos testes locais e nunca movimenta dinheiro.

## Modelo

- Uma carteira pertence a estabelecimento, entregador ou plataforma, por cidade e produto `delivery`.
- Cada carteira possui contas `available`, `reserved`, `pending`, `promotional` e `blocked`.
- Toda movimentação cria uma transação e dois lançamentos balanceados no razão.
- Valores usam `bigint` em centavos e moeda BRL.
- Lançamentos e transações efetivadas são imutáveis; correções são compensatórias.
- Chaves de idempotência impedem recarga, reserva e saque duplicados.
- O saldo pode ser reconstruído pelo razão e possui snapshots antes/depois em cada lançamento.

## Fluxos preparados

### Recarga

O estabelecimento informa o valor, recebe o cálculo da taxa configurável e cria uma recarga pendente. O padrão é 2% no modo `add`. O provedor falso devolve apenas uma referência de teste. A confirmação administrativa gera crédito disponível e taxa separada.

### Entrega

Uma OS paga com carteira reserva o valor no banco. Cancelamento libera a reserva. Conclusão transfere a parcela configurada ao entregador e registra a margem da plataforma. O padrão preparado é 85% para o entregador, configurável por cidade.

### Saque

O entregador solicita às segundas-feiras no fuso `America/Sao_Paulo`. O padrão reserva o valor e cobra R$ 1,50 quando o processamento administrativo for confirmado. Solicitações duplicadas e saldos insuficientes são bloqueados no banco.

## Segurança

- Todas as tabelas financeiras usam RLS e não concedem acesso direto a `anon` ou `authenticated`.
- Acesso ocorre pela função `security definer` `vuppi_finance`, que valida usuário, papel e escopo.
- Usuários não confirmam recargas nem concluem saques.
- Secrets não são enviados às interfaces e chaves Pix chegam apenas mascaradas.
- O log de auditoria registra ajustes e ações administrativas.

## Variáveis

```env
ASAAS_ENABLED=false
ASAAS_LIVE_OPERATIONS_ENABLED=false
ASAAS_ENV=sandbox
ASAAS_API_KEY=
ASAAS_WEBHOOK_TOKEN=
ASAAS_BASE_URL=https://api-sandbox.asaas.com/v3
```

Nunca use prefixos públicos (`VITE_`, `NEXT_PUBLIC_`, `EXPO_PUBLIC_`) para credenciais financeiras.

## Testar com o provedor falso

1. Use um Supabase de desenvolvimento ou homologação vazio/descartável.
2. Faça backup e aplique a migration nova pelo processo controlado da equipe.
3. Mantenha `ASAAS_ENABLED=false` e `ASAAS_LIVE_OPERATIONS_ENABLED=false`.
4. Crie uma recarga pela carteira do estabelecimento; ela deve ficar `awaiting_payment` e retornar `simulation: true`.
5. Confirme a recarga somente com uma conta administrativa de teste.
6. Crie uma OS com pagamento `wallet`, verifique a reserva, cancele e verifique a liberação.
7. Repita e conclua a OS; confira crédito do entregador e receita da plataforma em lançamentos separados.
8. Em uma segunda-feira, solicite um saque de teste e confirme que o saldo migra para `reserved`.
9. Execute `npm test`, `npm run check` e `npm run build`.

## Ativação futura do Asaas

1. Obter conta e credenciais oficiais de Sandbox.
2. Implementar as chamadas HTTP finais no `AsaasPaymentProvider` e testes de contrato.
3. Criar endpoint de webhook com validação do token, persistência do evento bruto sanitizado e idempotência por ID do evento.
4. Testar estados pendente, confirmado, expirado, rejeitado, falho e ambíguo.
5. Fazer reconciliação diária no Sandbox.
6. Passar por revisão financeira e de segurança.
7. Cadastrar secrets no cofre do servidor.
8. Ativar primeiro `ASAAS_ENABLED=true` no Sandbox, mantendo operações reais bloqueadas.
9. Liberar produção somente após homologação e aprovação formal.

