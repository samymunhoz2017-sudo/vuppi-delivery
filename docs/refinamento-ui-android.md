# Auditoria visual Android — 30/10/2026

O aplicativo é Android nativo em Java com Views programáticas. A referência fornecida é uma composição estática; o vídeo citado na especificação não acompanha esta mensagem.

Componentes existentes reaproveitados: `SlideActionView` (aceite e etapas), `MainActivity` (cabeçalho, card operacional, oferta, navegação, dialogs e toast), Google Maps `MapView`, recursos de ícones, `EarningsChartView` e temas locais. Cores ainda estão em constantes na activity; não há um design system unificado.

Alterações incrementais: controle de arraste com marcador circular, seta, preenchimento e estado de envio; reabilitação do aceite em erro; tratamento de textos opcionais nulos na oferta; lista de paradas rolável para preservar ações em telas menores. As ações, preços, mapas e regras de despacho não foram alterados.

Pendente: validar em aparelho/emulador as telas e tamanhos, acessibilidade, comparação visual, mapa, fluxo completo e concorrência. Também faltam unificação integral de tokens, barra de progresso, cabeçalho, rota completa e polimento P1/P2 da especificação. Não afirmar que o design de referência foi implementado integralmente.

Versão 0.90: cabeçalho compacto, menor elevação, estado operacional antes do banner, navegação com destaque para o mapa, cartões da rota em sequência e indicação do valor restante. A listagem existente inclui apenas paradas ativas; não se inventa quantidade concluída ou ETA por parada.
