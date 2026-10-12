# UP — Login com autenticação no servidor

## Situação atual

A URL e a chave pública recebidas estão configuradas no ambiente do Site. A chave e a chave de criptografia de sessão foram marcadas como segredos. Nenhum valor real de chave está nos arquivos da plataforma. A configuração de ambiente só passa a valer após publicar uma versão do servidor.

A publicação continua pendente por bloqueio de execução no ambiente. Não houve login real, criação de tabelas nem alteração da confirmação de e-mail no projeto Supabase nesta etapa.

## Arquitetura

O navegador chama apenas `/api/auth` no servidor da UP. O servidor conversa com Supabase usando variáveis de ambiente. Chaves e tokens de acesso/renovação não são retornados nas respostas JSON. Senhas são encaminhadas para autenticação via HTTPS e não são gravadas pelo aplicativo.

A sessão fica em cookie com conteúdo criptografado por AES-GCM, vinculado à origem da plataforma, com as opções HttpOnly, Secure e SameSite=Strict. O JavaScript da página não tem acesso ao cookie. Há validade absoluta de oito horas, validação da conta junto ao Supabase e consulta de permissões no banco. A chave da sessão deve permanecer estável entre publicações; trocá-la encerra as sessões existentes.

Tokens roubados e revogação distribuída exigem controles adicionais: o logout tenta revogar a sessão no Supabase e apaga o cookie da UP, mas um token de acesso copiado pode permanecer válido até expirar. Nenhum sistema é invulnerável. Esta implementação ainda precisa de verificação no ambiente publicado antes do piloto.

## Variáveis de ambiente do servidor

- `SUPABASE_URL`: URL do projeto.
- `SUPABASE_PUBLISHABLE_KEY`: chave pública, guardada como segredo conforme a preferência do projeto.
- `UP_SESSION_KEY`: segredo aleatório de 32 bytes codificado em Base64, para criptografia das sessões.
- `UP_CITY_ID`: identificador da cidade atendida.

Os valores reais foram salvos no armazenamento de ambiente do Site e não em arquivos. `.env.example` contém apenas nomes de variáveis e valores vazios. `.gitignore` impede a inclusão de arquivos locais de ambiente em novos commits. Não há chave service_role ou outra credencial administrativa no aplicativo.

## Cadastro sem confirmação de e-mail

No Supabase, acesse **Authentication → Sign In / Providers → Email**, desative **Confirm email** e salve. Mantenha Email habilitado e permita novos cadastros se quiser usar Criar conta. O servidor consulta essa configuração e interrompe o cadastro quando a confirmação ainda está ativa.

A confirmação de posse de e-mail fica dispensada por escolha do projeto. Isso não concede acesso à central: cada usuário precisa de uma permissão ativa por cidade. Contas antigas não confirmadas precisam ser verificadas separadamente no painel.

Documentação: https://supabase.com/docs/guides/auth/general-configuration

## Configurar acesso à central

1. Execute `supabase/migrations/202610030001_acesso_central.sql` uma única vez no SQL Editor de um projeto de desenvolvimento.
2. Depois de publicar o servidor, cadastre sua conta pelo aplicativo.
3. Substitua `SEU_EMAIL_AQUI` em `supabase/liberar-primeiro-gestor.sql` pelo seu e-mail e execute no SQL Editor.
4. Clique em **Verificar liberação**.

RLS permite que cada usuário leia apenas suas permissões. O navegador não tem permissão para criar, alterar ou apagar os acessos. Metadados enviados no cadastro não concedem papel administrativo.

## Construção e verificação

O projeto não exige dependências externas. Execute `npm run build` para gerar o Worker em `dist/server/index.js`. O build bloqueia padrões de chaves reais nos arquivos públicos. `npm test` executa os testes de segurança com credenciais fictícias e sem conexão externa.

As verificações incluem origem de requisições, HTTPS, cookie adulterado, segregação por usuário e cidade, limite do corpo da requisição, ausência de chaves/tokens nos arquivos públicos e respostas, criptografia de cookie, cabeçalhos de proteção e bloqueio de acesso aos arquivos do servidor. Esses testes não são um teste de invasão nem comprovam a configuração real do PostgreSQL.

O código herda os limites de tentativas do Supabase. Monitoramento, recuperação de conta, testes de carga, limites adicionais distribuídos e auditoria de produção precisam ser concluídos antes do piloto.

## Uso local e dados operacionais

Abrir `dist/index.html` diretamente permite visualizar a tela de login, mas não autenticar. O login depende do servidor HTTPS. A central, depois do login autorizado, continua usando dados fictícios locais por usuário; corridas, entregas e tarifas ainda não foram migradas para o Supabase.

Solicitações fictícias não são proteção nem autorização de dados reais. Na próxima etapa, cada ação operacional precisa ser validada no servidor e protegida no banco.
