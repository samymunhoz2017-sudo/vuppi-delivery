# Publicação da UP na Hostinger

Plano verificado no painel: Unlimited Web Hosting. Domínio autorizado: vuppidelivery.com.br. Localização selecionada: Brasil. Aplicativo Node.js, tipo Other (Outro), com servidor persistente. Não configurar como aplicação estática.

Node.js 24.x, comando de preparação `npm run build`, comando de inicialização `npm start`, entrada `server/hostinger.mjs`, diretório raiz do projeto `.`. Sem dependências externas de execução. O servidor usa a porta definida pela hospedagem na variável PORT, com padrão 3000. Saúde em `/healthz`. O provedor deve terminar HTTPS antes de encaminhar ao processo Node.

Variáveis de ambiente: SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, UP_SESSION_KEY (32 bytes aleatórios em base64), UP_CITY_ID=pitangueiras-sp, UP_PUBLIC_ORIGIN=https://vuppidelivery.com.br. Para mapas, despacho e rotas: SUPABASE_SECRET_KEY, GOOGLE_MAPS_BROWSER_KEY e GOOGLE_MAPS_SERVER_KEY. Guardar segredos no painel de variáveis do servidor; nunca no ZIP ou no HTML. Migrações e configuração de confirmação de e-mail continuam etapas independentes.

Neste adaptador Node, as atualizações usam consultas periódicas autenticadas. O proxy WebSocket existente exige runtime Cloudflare e não é usado na Hostinger. O despacho roda a cada 15 segundos quando os segredos de servidor/mapas estão configurados; o banco coordena as ondas com bloqueios. O agendador depende de o processo permanecer ativo. Nenhuma capacidade de carga foi comprovada.

O pacote de publicação inclui apenas package.json, scripts de build, telas públicas e módulos de servidor necessários. Não inclui arquivos .env, cofres, Git, SQL administrativo, documentos privados, testes ou dados locais. Após implantação verificar status, HTTPS, telas, configuração Auth e cadastro real, separadamente das migrações de banco.

Referência: [publicação Node.js na Hostinger](https://www.hostinger.com/support/how-to-deploy-a-nodejs-website-in-hostinger/).
