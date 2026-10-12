# Vuppi Delivery

Plataforma de entregas locais com painel administrativo, área do estabelecimento, backend Node.js e aplicativo Android nativo para entregadores.

## Versão atual

`0.63.1`

Esta versão consolida a estabilização do recebimento de ofertas no Android e atualiza a plataforma web com um novo centro de comando administrativo, Vuppi Wallet baseada no ledger real, entrega rápida sem recarregar a sessão, gestão de consumidores do estabelecimento e Google Maps validado no ambiente publicado.

Produção: [vuppidelivery.com.br](https://vuppidelivery.com.br)

## Estrutura

- `mobile/vuppi-entregador-android`: aplicativo Android nativo.
- `server`: API e regras operacionais.
- `supabase/migrations`: banco de dados e funções transacionais.
- `dist`: aplicação web e artefatos de distribuição.
- `tests`: testes automatizados do backend.
- `docs`: auditorias e documentação técnica.

## Segurança

Chaves de assinatura, credenciais, arquivos `.env` e configurações locais não são versionados. A cópia privada da assinatura Android deve permanecer no backup local protegido.

## Publicação

Consulte `docs/admin-panel-gap-analysis.md` e `HOSPEDAGEM-HOSTINGER.md`.
