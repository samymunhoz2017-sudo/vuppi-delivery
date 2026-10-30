// Modelo local para avaliar transições. A aplicação definitiva deve executar
// estas regras no Postgres, dentro da mesma transação da liquidação.
const VALID=new Set(['pending','active','arrived','confirmed','failed','cancelled']);
export function routeProgress(stops,requiresReturn) {
 if(!Array.isArray(stops)||!stops.length||stops.length>24||typeof requiresReturn!=='boolean')throw Error('Rota inválida.');
 const ids=new Set(),sequences=new Set();
 const sorted=stops.map(stop=>{
  if(!stop||typeof stop.id!=='string'||!stop.id.trim()||ids.has(stop.id))throw Error('Parada inválida ou duplicada.');
  if(!Number.isSafeInteger(stop.sequence)||stop.sequence<1||sequences.has(stop.sequence))throw Error('Sequência de paradas inválida ou duplicada.');
  if(!VALID.has(stop.status))throw Error('Estado de parada inválido.');
  ids.add(stop.id);sequences.add(stop.sequence);return {...stop};
 }).sort((a,b)=>a.sequence-b.sequence);
 let unfinished=false,confirmed=0,active=0;
 for(const stop of sorted){
  if(stop.status==='confirmed'){
   if(unfinished)throw Error('Existe uma parada confirmada fora da ordem.');
   confirmed++;
  }else if(stop.status!=='cancelled')unfinished=true;
  if(stop.status==='active'||stop.status==='arrived')active++;
 }
 const next=sorted.find(stop=>!['confirmed','cancelled'].includes(stop.status))||null;
 if(active>1||sorted.some(stop=>['active','arrived'].includes(stop.status)&&stop.id!==next?.id))throw Error('Parada ativa fora da ordem.');
 const phase=next?(next.status==='failed'?'attention':'delivering'):confirmed===0?'cancelled':requiresReturn?'returning':'ready_to_settle';
 return {next_stop_id:next?.id??null,phase,confirmed_count:confirmed,return_available:phase==='returning'};
}
export function confirmRouteStop(stops,requiresReturn,stopId){
 const progress=routeProgress(stops,requiresReturn),stop=stops.find(item=>item.id===stopId);
 if(!stop)throw Error('Parada não encontrada.');
 if(stop.status==='confirmed')return {already_confirmed:true,stops:stops.map(x=>({...x})),...progress};
 if(progress.next_stop_id!==stopId||stop.status==='failed'||stop.status==='cancelled')throw Error('A parada não está disponível ou está fora da ordem.');
 const nextStops=stops.map(x=>({...x,status:x.id===stopId?'confirmed':x.status}));
 return {already_confirmed:false,stops:nextStops,...routeProgress(nextStops,requiresReturn)};
}
