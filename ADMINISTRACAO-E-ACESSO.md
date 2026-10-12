# Conta titular e acesso pelo navegador

O e-mail informado para o titular é **samymunhoz2017@gmail.com**. A permissão global depende da identidade da conta no Supabase; não é atribuída a qualquer pessoa que se cadastre primeiro. Com confirmação de e-mail desligada, apenas o e-mail não prova que a conta pertence ao titular.

O painel `/admin` implementa visão geral global com números registrados no banco, contas paginadas e busca, permissões de Carros/central por cidade, permissões de superadministrador, cadastro de cidades, auditoria e situação das integrações. O superadministrador recebe também menus de operação e configuração de Carros em todas as cidades. O servidor e o banco verificam os privilégios; alterar metadados da conta ou esconder/exibir um menu não concede acesso. Todas as alterações globais pedem motivo. O último superadministrador ativo não pode ser removido pelo painel.

## Migrações preparadas

A migração `202610030003_superadministracao.sql` depende das estruturas anteriores. Não foi aplicada. O script `definir-primeiro-superadmin.sql` exige substituição do UUID pela identidade verificada da sua conta, valida o e-mail informado e só define o titular se ainda não existir superadministrador. Execute apenas no ambiente previamente confirmado e pelo administrador confiável do Supabase. A conta não foi criada por esta implementação e sua permissão ainda não foi concedida no projeto remoto.

## Por que o botão não funcionava

O endereço informado era `file:///.../dist/index.html`: a abertura direta do HTML não executa o servidor de login. A mensagem da tela foi corrigida. Não basta ativar visualmente o botão: é necessário servir as APIs e a tela juntos.

## Opção de desenvolvimento no computador

Abra `INICIAR-UP.cmd` na pasta da plataforma. Na primeira execução ele solicita URL e chave publishable do Supabase por entrada oculta e prepara uma chave de sessão aleatória. O cofre `.local/cofre.json` guarda as chaves criptografadas pelo Windows para seu usuário, fora dos arquivos públicos e ignorado pelo Git. Não compartilhe esse cofre nem o computador/sessão com pessoas sem autorização. A proteção local não impede um programa malicioso executado como seu usuário de acessar segredos em memória.

O iniciador prepara os arquivos e inicia o servidor somente em `127.0.0.1:8787`, com Host e origem restritos a `localhost`. Abra **http://localhost:8787** no Chrome ou Edge; administração em **http://localhost:8787/admin**. Mantenha a janela aberta. Esta opção é exclusiva de desenvolvimento e não compartilha o projeto na internet. Cookies mantêm atributos Secure/HttpOnly; localhost usa a exceção dos navegadores compatíveis. [Referência dos cookies](https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Set-Cookie).

O iniciador e o adaptador foram preparados, mas não foi executado teste real de cadastro em navegador. WebSocket não está disponível nesse adaptador local; Carros usa atualização periódica. Migrações, configuração de confirmação de e-mail e permissões do Supabase continuam necessárias. A aplicação publicada mantém exigência de HTTPS.

## Endereço temporário na internet

O projeto da hospedagem Sites já está registrado como `up-central-pitangueiras`, com acesso privado do titular. A nova tentativa de publicação terminou em **“Unable to prepare the Site”** antes de salvar uma versão; o serviço ainda não informou URL publicada. Nenhum domínio temporário ativo foi gerado ou conectado. Não substituir essa etapa por hospedagem somente dos arquivos públicos, pois o login precisa do servidor.

Depois de publicar e validar o cadastro, será possível conectar o domínio comprado na Hostinger por configuração de DNS, conforme os registros exigidos pelo provedor de hospedagem. Não é necessário comprar um domínio agora.

## Testes e pendências

Testes locais verificam cadastro sem elevação automática, recusa de metadados fraudulentos, autorização HTTP, acesso global autorizado, revogação e preservação da central anterior. A proteção do último superadministrador e as transações reais ainda exigem PostgreSQL em homologação. Sem essa validação, não considerar a administração liberada para produção.

Para uma corrida completa: confirmar ambiente, inspecionar e aplicar migrações revisadas, desativar confirmação de e-mail no Supabase, criar a conta titular, conferir seu UUID, atribuir a permissão pelo script, configurar os segredos de Maps/despacho no servidor, ativar área/categoria/tarifas e aprovar um motorista de carro com documentos. Testar com contas separadas de passageiro, motorista e operador.
