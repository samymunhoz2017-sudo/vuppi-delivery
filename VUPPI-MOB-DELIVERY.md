# VUPPI MOB — primeira versão de delivery

Marca confirmada pelo titular: **VUPPI MOB**. Piloto: **Pitangueiras, SP**. Produto inicial: estabelecimentos conectados a entregadores de moto. Carros ficam para uma fase futura.

## Estado em 03/10/2026

A conta do titular é superadministradora no Supabase. Confirmação de e-mail está desativada. A estrutura de Carros e administração está instalada, mas Delivery ainda usa demonstração local. A versão v0.6 foi publicada e a tela de login da VUPPI MOB foi verificada no endereço HTTPS https://smmidias.site. O botão de entrada está habilitado. Login com a senha do titular ainda não foi executado pelo agente.

Nesta atualização: marca nas telas, prioridade para entregas no formulário e motor de cálculo por faixas de distância com retorno. O motor foi testado, mas não está ligado aos pedidos nem a um provedor de mapas. Não há aplicativo de entregador operacional lançado.

## Referência pesquisada

- [API oficial de entregas da Machine](https://docs.machine.global/pages/v2/entregas/introducao): separação de empresas e central, estimativas, abertura de entregas, acompanhamento e posição do entregador. A API tem ambientes de testes e produção, com credenciais e permissões próprias.
- [Tabela de KM](https://suporte.machine.global/hc/pt-br/articles/360046369273-Tabela-de-KM): em delivery, faixas com preço pré-fixado; distância acima da última faixa bloqueia a solicitação. Esse comportamento inspirou o motor inicial.
- [Tarifas por bairro e retorno](https://suporte.machine.global/hc/pt-br/articles/4414933414555-Tarifas-Por-Bairro): bairros, taxa de retorno e ajustes por empresa. Implementar bairros depois de validar o modelo inicial por distância.
- [Entrega com retorno](https://suporte.machine.global/hc/pt-br/articles/4412342004891-Finaliza%C3%A7%C3%A3o-da-entrega-pelo-estabelecimento): retorno pode exigir conclusão pelo estabelecimento. Deve ser uma configuração explícita por estabelecimento.
- [Multidestinos](https://suporte.machine.global/hc/pt-br/articles/360047270914-Multidestinos-para-Entregas): paradas ordenadas, rota e tarifa. Planejado para depois de validar uma coleta e um destino.

A Machine é referência funcional; nenhuma integração foi ativada e nenhuma credencial da Machine foi solicitada. Desenvolver VUPPI MOB própria não exige contratar ou integrar a Machine.

## Sequência de implantação

1. Resolver domínio e validar entrada HTTPS do titular.
2. Cadastro de estabelecimentos: responsável, contato, endereço de coleta validado no mapa, cidade, situação de análise e aprovação administrativa. Usuário acessa somente os estabelecimentos aos quais pertence.
3. Cadastro e área móvel do entregador: moto e documentação, aprovação, disponibilidade, ofertas, coleta e comprovação da entrega. A autenticação não equivale a aprovação operacional.
4. Pedido real: estabelecimento autorizado, coleta, destinatário, destino validado e preço calculado no servidor. Não confiar em preço, distância ou cidade enviados pelo navegador.
5. Despacho com aceite exclusivo, estados válidos, cancelamento com motivo e acompanhamento autorizado. Uma entrega só pode ser atribuída a um entregador por vez.
6. Operação assistida no piloto e expansão por cidade.

## Expansão e mapas

Cidade em estabelecimentos, entregadores, área de atendimento, tarifas e pedidos. Tarifas versionadas por cidade e, quando necessário, por estabelecimento. Preservar a tarifa da solicitação; alterações futuras não mudam pedidos já precificados. Separar valor cobrado, remuneração e taxa da plataforma.

Mapas precisam de endereços confirmados, coordenadas, rota viária e distância real. Não usar linha reta como preço final. Provedor e credenciais ainda precisam ser definidos; validar cobertura local para motos antes de lançamento. Chaves privadas ficam no servidor. Geolocalização do entregador exige consentimento e rastreamento em segundo plano precisa ser validado no dispositivo; uma página web aberta não comprova essa capacidade.

## Critérios de liberação

Criar conta, cadastrar estabelecimento, aprovar entregador, estimar rota/preço, solicitar entrega, aceitar uma única vez, coletar, confirmar recebimento, registrar histórico e impedir leitura entre empresas/cidades. Testar falha de mapa, perda de conexão, oferta expirada e cancelamento. Não liberar entregas reais antes desses testes.

Valores de teste não definem as tarifas comerciais de Pitangueiras. As faixas, retorno, remuneração e taxa da central serão definidos pelo titular antes da operação.

