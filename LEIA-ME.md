# VUPPI MOB — delivery de moto

Atualização v0.6: marca confirmada VUPPI MOB, piloto Pitangueiras/SP e prioridade para delivery. Veja VUPPI-MOB-DELIVERY.md para pesquisa oficial, escopo e pendências. A base anterior de Carros foi preservada como fase futura. Delivery real, portal de estabelecimentos, aplicativo de entregadores e integração de mapas ainda não estão liberados.

---
# Atualização v0.5 — UP Carros

Módulo novo em `/carros`, com servidor, migração incremental e telas próprias. Integrações externas e migração ainda pendentes; consulte [FASE-2-UP-CARROS.md](FASE-2-UP-CARROS.md).

Administração global em `/admin`. Para desenvolvimento local, use `INICIAR-UP.cmd` e abra `http://localhost:8787`; o HTML aberto diretamente não executa o login. Leia [ADMINISTRACAO-E-ACESSO.md](ADMINISTRACAO-E-ACESSO.md) para configuração do Supabase e da conta titular. A publicação na internet ainda não foi concluída.

# UP — Central de operação v0.4

Abra `dist/index.html` no navegador. Mantenha todos os arquivos da pasta `dist` juntos. A versão v0.4 abre pela tela de login e depende da configuração do Supabase descrita em `CONFIGURAR-SUPABASE.md`.

## Login da versão v0.4

Tela de login e cadastro em português, saída da conta, restauração de sessão e consulta de permissões por cidade. A URL e a chave pública do projeto foram configuradas. A confirmação de e-mail e a criação das tabelas de acesso precisam ser ajustadas no Supabase. A autenticação usa agora o servidor da UP e cookies protegidos. Chaves reais foram removidas do código e guardadas no ambiente do servidor. O servidor HTTPS ainda precisa ser publicado; abrir o HTML diretamente permite visualizar a tela, mas não autenticar. Consulte SEGURANCA.md.

## Melhorias disponíveis

- Tarifas de teste por modalidade: bandeirada, quilômetro, minuto e valor mínimo.
- Estimativa baseada em distância e tempo informados manualmente.
- Registro da tarifa aplicada na criação de cada nova solicitação.
- Reatribuição a parceiro disponível e compatível antes do início da corrida ou da coleta, com motivo obrigatório.
- Cancelamento com motivo obrigatório.
- Entrega concluída somente após informar o código fictício exibido nos detalhes para o teste.
- Registro do parceiro, operador e horário da confirmação do recebimento.
- Histórico de ações com data e hora.
- Exportação CSV dos serviços que correspondem aos filtros atuais.
- Atualização entre abas quando o navegador disponibiliza eventos de armazenamento para a mesma origem.

## Como testar

1. Abra Tarifas e configure os valores fictícios.
2. Crie uma entrega e informe distância e tempo estimados.
3. Atribua um entregador disponível e avance o atendimento.
4. Quando estiver Em rota, digite um código errado: a entrega deve continuar em rota.
5. Digite o código fictício mostrado na tela e confirme o recebimento.
6. Consulte o comprovante nos detalhes e a movimentação no histórico.
7. Use Exportar CSV para baixar a lista filtrada.

As solicitações já criadas continuam com o valor anterior quando as tarifas mudam. Serviços da v0.1 mantêm seus valores de exemplo e são identificados como registros sem cálculo de tarifa.

## Limites desta etapa

Os dados operacionais continuam fictícios e locais. A gravação depende das configurações de armazenamento do navegador; a abertura por arquivo pode variar entre navegadores. Login e permissões estão preparados para o Supabase e dependem da configuração remota. Ainda não há sincronização de serviços entre computadores, notificações, GPS, cálculo de rota, pagamento ou despacho real. O histórico pode ser alterado no dispositivo e não constitui auditoria de produção. A confirmação por código demonstra o fluxo; o código de produção deverá ser protegido pelo servidor e disponibilizado ao destinatário.

Os fluxos de tarifas, despacho, reatribuição, conclusão, cancelamento, exportação e persistência foram verificados em ambiente JavaScript simulado. A apresentação visual e o registro WebMCP em um navegador compatível não foram verificados nesta etapa.

## Próxima etapa proposta

Finalizar a configuração do login e das permissões no projeto Supabase e verificar o fluxo real. Depois, mover serviços, despacho, transições de status, validação do código e auditoria para o servidor antes do piloto com usuários reais.

A publicação online permanece pendente porque a política de permissões do ambiente bloqueou a execução necessária. O identificador do Site foi preservado no arquivo `.openai/hosting.json` para retomar a publicação sem criar outro Site.

