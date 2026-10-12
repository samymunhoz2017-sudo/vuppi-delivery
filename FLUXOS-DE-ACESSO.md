# VUPPI DELIVERY · fluxos de acesso

O endereço principal `https://smmidias.site/` é o portal inicial e não redireciona para um tipo de conta. A pessoa escolhe a área antes de entrar.

1. **Administração global:** `/admin` — superadministrador, para contas, permissões, cidades, auditoria e integrações.
2. **Central de operações:** `/operacao` — equipe autorizada, para analisar parceiros, acompanhar entregas e despachar entregadores.
3. **Estabelecimento:** `/estabelecimento` — restaurante/loja, para cadastro, pedidos e acompanhamento. Novo cadastro cria a conta e depois envia o perfil para análise.
4. **Entregador:** `/entregador` — cadastro de entregador de moto, disponibilidade, ofertas, entregas aceitas e links para navegação externa.

Os caminhos de estabelecimento e entregador usam a mesma aplicação técnica, mas a página define o tipo de cadastro e valida o perfil autenticado antes de mostrar a área. O servidor e as permissões do banco continuam responsáveis por autorizar qualquer ação; o caminho visível não concede privilégios.

`/entregas` encaminha instalações antigas do PWA para `/entregador`. Restaurantes devem usar `/estabelecimento`. `/carros` permanece separado como produto da fase futura. A instalação do PWA de entregador inicia em `/entregador`.
