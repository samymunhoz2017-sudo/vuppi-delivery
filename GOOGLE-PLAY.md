# VUPPI Entregador — preparação para Google Play

O aplicativo será publicado como Trusted Web Activity (TWA), usando `https://vuppidelivery.com.br/entregador`.

## Identidade sugerida

- Nome: VUPPI Entregador
- Package ID: `br.com.vuppidelivery.entregador`
- URL inicial: `https://vuppidelivery.com.br/entregador`
- Escopo: `https://vuppidelivery.com.br/`
- Manifesto: `https://vuppidelivery.com.br/manifest-courier.webmanifest`

## Etapas restantes

1. Criar a conta de desenvolvedor da Google Play, caso ainda não exista.
2. Criar e guardar a chave de assinatura Android em local seguro.
3. Gerar o Android App Bundle (`.aab`) assinado.
4. Preencher `dist/.well-known/assetlinks.json` com o package ID e o SHA-256 da chave de produção.
5. Publicar a associação e validar a TWA sem barra do navegador.
6. Preparar política de privacidade, segurança de dados, classificação etária, ícone e capturas.
7. Enviar primeiro para teste interno e validar login, localização, notificações, câmera/galeria e conclusão de entrega.

O `assetlinks.json` permanece vazio até a chave de produção existir. Isso evita associar o domínio a uma chave provisória.
