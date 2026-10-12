# Vuppi Delivery

Plataforma de entregas locais com painel administrativo, área do estabelecimento, backend Node.js e aplicativo Android nativo para entregadores.

## Versão atual

`0.56.0`

Esta versão estabiliza o recebimento de ofertas no Android, elimina alertas duplicados, adiciona recusa persistida no servidor, protege o aceite contra concorrência e melhora a apresentação da oferta com confirmação por arraste.

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

Consulte `RELEASE-V0.56.md` e `HOSPEDAGEM-HOSTINGER.md`.
