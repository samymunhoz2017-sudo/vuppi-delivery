(()=>{
 'use strict';
 const adminHelp={overview:'Resumo da operação, alertas prioritários e atalhos para as tarefas mais usadas.',operation:'Consulte, filtre, edite, redistribua, finalize ou cancele ordens de serviço.',scheduled:'Mostra somente entregas agendadas e o horário planejado de despacho.',occurrences:'Fila viva de entregas que precisam de decisão da central.',tracking:'Acompanhe entregas em andamento e abra os detalhes de cada rota.',driverMap:'Veja entregadores e entregas ativas no mapa operacional.',osChanges:'Localize uma OS para corrigir dados e registrar alterações auditadas.',logistics:'Configure raio, reoferta, agrupamento, prazos e regras de segurança.',deliveryTypes:'Defina os tipos de entrega aceitos e seus limites operacionais.',pricing:'Crie tarifas por cidade ou específicas por estabelecimento e simule o preço.',merchants:'Cadastre, aprove, edite e controle estabelecimentos.',couriers:'Analise cadastros, aprove ou rejeite entregadores e edite veículos e permissões.',cities:'Configure cidades, áreas atendidas e situação operacional.',finance:'Gerencie carteiras, recargas, saques, mensalidades e movimentações.',users:'Controle integrantes da equipe e seus níveis de acesso.',audit:'Consulte quem alterou dados críticos e quando.',health:'Confira integrações, autenticação, mapas e saúde dos serviços.'};
 const merchantHelp={dashboard:'Indicadores da loja no período escolhido e atalhos para tarefas diárias.',orders:'Crie pedidos e acompanhe entregadores e rotas em tempo real.',consumers:'Consulte clientes recorrentes e reutilize seus dados em uma nova entrega.',wallet:'Veja saldo, reservas, mensalidades, recargas e débitos das entregas.',history:'Pesquise entregas antigas combinando período, status, OS e cliente.',reports:'Filtre resultados e exporte ou imprima o relatório da operação.',communication:'Acesse orientações para contato com a central sobre uma OS.',settings:'Defina atualização automática, notificações e alertas sonoros.',help:'Abra o guia resumido do fluxo do estabelecimento.'};
 const actionHelp=[
  [/nova|solicitar|chamar entregador/i,'Inicia uma solicitação. Confira endereço, pagamento, retorno e tarifa antes de confirmar.'],
  [/atualizar/i,'Busca os dados mais recentes no servidor sem perder os filtros atuais.'],
  [/exportar/i,'Baixa os resultados visíveis em arquivo CSV para análise ou conferência.'],
  [/filtrar|filtros/i,'Restringe os resultados usando os critérios informados.'],
  [/salvar/i,'Valida e grava as alterações. Campos inválidos permanecem destacados.'],
  [/aprovar/i,'Libera o cadastro para operar e receber entregas.'],
  [/rejeitar|inativar/i,'Impede o cadastro de operar. A alteração fica registrada.'],
  [/suspender/i,'Pausa temporariamente o acesso operacional deste cadastro.'],
  [/cancelar/i,'Cancela a entrega e registra o motivo para auditoria.'],
  [/redistribuir/i,'Remove a atribuição atual e inicia uma nova oferta aos entregadores elegíveis.'],
  [/finalizar/i,'Encerra a etapa atual depois das validações operacionais e financeiras.'],
  [/otimizar/i,'Recalcula a melhor sequência disponível para a rota.'],
  [/juntar/i,'Agrupa as entregas selecionadas em uma única rota operacional.'],
  [/calcular|simular/i,'Faz uma simulação sem criar ou cobrar uma entrega.'],
  [/recarga|crédito|ajustar saldo/i,'Abre o controle financeiro auditado desta carteira.'],
  [/imprimir/i,'Abre a versão preparada para impressão do relatório atual.'],
  [/sair/i,'Encerra a sessão neste aparelho.']
 ];
 let tooltip,launcher,dialog,tour=[],tourIndex=0,active;
 const clean=value=>String(value||'').replace(/\s+/g,' ').trim();
 const visible=el=>!!(el.offsetWidth||el.offsetHeight||el.getClientRects().length);
 function description(el){
  if(el.dataset.vuppiHelp)return el.dataset.vuppiHelp;
  const admin=el.dataset.adminTab,merchant=el.dataset.merchantTab;
  if(admin)return adminHelp[admin];if(merchant)return merchantHelp[merchant];
  const text=clean(el.getAttribute('aria-label')||el.textContent||el.placeholder);
  for(const [pattern,help] of actionHelp)if(pattern.test(text))return help;
  if(el.matches('label')){const field=clean(el.childNodes[0]?.textContent||text);return `Informe ${field.toLowerCase()}. Este dado será usado nesta operação.`}
  if(el.matches('input,select,textarea'))return `Preencha ${clean(el.closest('label')?.childNodes[0]?.textContent||el.placeholder||'este campo').toLowerCase()}.`;
  return '';
 }
 function annotate(root=document){
  const scope=document.querySelector('#admin-app:not([hidden])')||document.querySelector('#merchantHome:not([hidden])');
  if(!scope){if(launcher)launcher.hidden=true;return}
  launcher.hidden=false;
  scope.querySelectorAll('button,label,input,select,textarea,[data-admin-tab],[data-merchant-tab]').forEach(el=>{const help=description(el);if(!help)return;el.dataset.vuppiHelp=help;if(!el.hasAttribute('aria-label')&&el.matches('button')&&!clean(el.textContent))el.setAttribute('aria-label','Consultar função')});
 }
 function show(el){const text=description(el);if(!text||innerWidth<720)return;active=el;tooltip.textContent=text;tooltip.hidden=false;const r=el.getBoundingClientRect(),w=Math.min(330,innerWidth-24),left=Math.max(12,Math.min(innerWidth-w-12,r.left+r.width/2-w/2)),below=r.bottom+10;tooltip.style.width=w+'px';tooltip.style.left=left+'px';tooltip.style.top=(below+110<innerHeight?below:Math.max(12,r.top-tooltip.offsetHeight-10))+'px'}
 function hide(el){if(active===el){tooltip.hidden=true;active=null}}
 function available(){const scope=document.querySelector('#admin-app:not([hidden])')||document.querySelector('#merchantHome:not([hidden])');if(!scope)return[];return [...scope.querySelectorAll('[data-vuppi-help]')].filter(visible).filter((x,i,a)=>a.findIndex(y=>y.dataset.vuppiHelp===x.dataset.vuppiHelp)===i).slice(0,18)}
 function drawTour(){document.querySelectorAll('.vuppi-tour-target').forEach(x=>x.classList.remove('vuppi-tour-target'));if(!tour.length)return closeTour();const el=tour[tourIndex];el.classList.add('vuppi-tour-target');el.scrollIntoView({behavior:'smooth',block:'center'});dialog.innerHTML=`<div class="vuppi-guide-card"><span>PASSO ${tourIndex+1} DE ${tour.length}</span><h3>${clean(el.textContent||el.closest('label')?.textContent||'Funcionalidade')}</h3><p>${el.dataset.vuppiHelp}</p><div><button data-tour-close>Fechar</button><button data-tour-prev ${tourIndex?'':'disabled'}>Voltar</button><button class="primary" data-tour-next>${tourIndex===tour.length-1?'Concluir':'Próximo'}</button></div></div>`;dialog.hidden=false;dialog.querySelector('[data-tour-close]').onclick=closeTour;dialog.querySelector('[data-tour-prev]').onclick=()=>{tourIndex--;drawTour()};dialog.querySelector('[data-tour-next]').onclick=()=>{if(tourIndex===tour.length-1)closeTour();else{tourIndex++;drawTour()}}}
 function closeTour(){dialog.hidden=true;document.querySelectorAll('.vuppi-tour-target').forEach(x=>x.classList.remove('vuppi-tour-target'))}
 function openGuide(){const items=available(),context=document.querySelector('[data-admin-tab].active,[data-merchant-tab].active')?.textContent||'painel';dialog.innerHTML=`<div class="vuppi-guide-card vuppi-guide-center"><button class="vuppi-guide-x" data-tour-close aria-label="Fechar">×</button><span>CENTRAL DE AJUDA</span><h2>Como usar ${clean(context)}</h2><p>Passe o mouse sobre botões e campos para ver uma explicação. No celular, toque no botão <b>?</b> sempre que precisar.</p><div class="vuppi-guide-list">${items.slice(0,8).map(x=>`<article><b>${clean(x.textContent||x.closest('label')?.textContent||'Função')}</b><small>${x.dataset.vuppiHelp}</small></article>`).join('')}</div><div><button data-tour-close>Agora não</button><button class="primary" data-start-tour>Iniciar tutorial desta tela</button></div></div>`;dialog.hidden=false;dialog.querySelectorAll('[data-tour-close]').forEach(x=>x.onclick=closeTour);dialog.querySelector('[data-start-tour]').onclick=()=>{tour=items;tourIndex=0;drawTour()}}
 function boot(){tooltip=document.createElement('div');tooltip.className='vuppi-tooltip';tooltip.hidden=true;tooltip.setAttribute('role','tooltip');launcher=document.createElement('button');launcher.className='vuppi-help-launcher';launcher.type='button';launcher.textContent='?';launcher.setAttribute('aria-label','Abrir tutorial desta tela');launcher.dataset.vuppiHelp='Abra explicações e um tutorial guiado das funções desta tela.';dialog=document.createElement('div');dialog.className='vuppi-guide-overlay';dialog.hidden=true;document.body.append(tooltip,launcher,dialog);launcher.onclick=openGuide;document.addEventListener('pointerover',e=>{const el=e.target.closest('[data-vuppi-help]');if(el)show(el)});document.addEventListener('pointerout',e=>{const el=e.target.closest('[data-vuppi-help]');if(el)hide(el)});document.addEventListener('focusin',e=>{const el=e.target.closest('[data-vuppi-help]');if(el)show(el)});document.addEventListener('focusout',e=>{const el=e.target.closest('[data-vuppi-help]');if(el)hide(el)});new MutationObserver(()=>requestAnimationFrame(annotate)).observe(document.body,{childList:true,subtree:true,attributes:true,attributeFilter:['hidden','class']});annotate()}
 addEventListener('DOMContentLoaded',boot);
})();
