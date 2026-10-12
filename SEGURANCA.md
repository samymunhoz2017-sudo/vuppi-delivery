# Segurança da central UP — v0.4

## Implementado

- Chave real removida do código; valores guardados no ambiente do servidor, marcados como segredos.
- Navegador conectado exclusivamente à API da UP, sem acesso direto ao Supabase.
- Tokens de acesso e renovação fora das respostas JSON e do armazenamento JavaScript.
- Cookie de sessão criptografado com AES-GCM, HttpOnly, Secure e SameSite=Strict.
- Validade absoluta de sessão e revalidação do usuário no Supabase.
- Origem verificada nas requisições que alteram autenticação, para reduzir ataques CSRF.
- Entradas validadas e tamanho máximo de requisição.
- Cabeçalhos de proteção e política que limita conexões da página ao próprio servidor.
- Permissões por usuário e cidade consultadas no banco; metadados de cadastro não concedem acesso.
- Arquivos privados não servidos e arquivos de ambiente ignorados pelo Git.
- Verificação automática de padrões de chaves nos arquivos públicos durante a construção.

## Estado e limites

Os segredos do ambiente foram salvos e o servidor passou em testes com respostas simuladas. A versão não foi publicada, as migrações não foram aplicadas e o login real não foi verificado. As regras de acesso no PostgreSQL só existirão após executar a migração.

A sessão contém tokens criptografados no cookie; eles não são legíveis pelo JavaScript, mas proteção do dispositivo, HTTPS e gestão da chave de criptografia continuam essenciais. Logout remove o cookie e tenta revogar a sessão remota; tokens já copiados podem valer até a expiração. O servidor não guarda senhas nem registra tokens em logs próprios.

As tentativas de login ficam sujeitas aos limites do Supabase. Não há, nesta versão, limitação de tentativas adicional distribuída da UP, nem teste de invasão, monitoramento de incidentes ou garantia contra ataques.

Desativar confirmação de e-mail é uma decisão expressa do projeto e ainda precisa ser aplicada no painel. A exigência de autorização do gestor é mantida.

Corridas e entregas continuam fictícias e locais. A plataforma ainda não deve operar dados ou serviços reais.
