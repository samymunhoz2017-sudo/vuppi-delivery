// Rotas públicas de baixo volume. Somente o servidor calcula e grava cotações.
let nextRoute=0,pendingMaintenanceAt=0;const liveRouteWindows=new Map();
export async function handleDelivery(request,c){
 const {s,user}=await c.session(),path=new URL(request.url).pathname;
 const rpc=async(action,data={})=>c.upstream('/rest/v1/rpc/vuppi_delivery',{method:'POST',token:s.access,body:{p_action:action,p_data:data},carErrors:true});
 const reply=async data=>{await c.renewCookie();return c.json(data)};
 const serviceHeaders=()=>({apikey:c.env.SUPABASE_SECRET_KEY,Authorization:'Bearer '+c.env.SUPABASE_SECRET_KEY,'Content-Type':'application/json'});
 const serviceJson=async(url,options={})=>{const response=await c.fetcher(url,{...options,headers:{...serviceHeaders(),...(options.headers||{})},signal:AbortSignal.timeout(10000)}),text=await response.text(),body=text?JSON.parse(text):null;if(!response.ok)throw Error(body?.message||body?.error||'Falha ao consultar a central de mensagens.');return body};
 const maintainPending=async()=>{if(!c.env.SUPABASE_SECRET_KEY||Date.now()<pendingMaintenanceAt)return;pendingMaintenanceAt=Date.now()+5000;try{await serviceJson(c.env.SUPABASE_URL+'/rest/v1/rpc/vuppi_pending_maintenance',{method:'POST',body:'{}'});}catch(error){pendingMaintenanceAt=Date.now()+15000;console.warn('pending_maintenance_unavailable',{message:error.message})}};
 const geocode=async address=>{
  const query=String(address||'').trim();if(query.length<5||!/(?:^|\D)\d{1,6}(?:\D|$)/.test(query))throw Error('Informe um endereço completo, com rua e número.');
  if(!c.env.GOOGLE_MAPS_SERVER_KEY)throw Error('O Google Maps ainda aguarda a chave segura do servidor.');
  const url='https://maps.googleapis.com/maps/api/geocode/json?region=br&language=pt-BR&address='+encodeURIComponent(query+', Pitangueiras, SP, Brasil')+'&key='+encodeURIComponent(c.env.GOOGLE_MAPS_SERVER_KEY);
  const response=await c.fetcher(url,{signal:AbortSignal.timeout(10000)}),body=response.ok?await response.json():{},hit=body.results?.[0],lat=Number(hit?.geometry?.location?.lat),lng=Number(hit?.geometry?.location?.lng);
  if(!Number.isFinite(lat)||!Number.isFinite(lng))throw Error('Não encontramos esse endereço. Confira CEP, rua e número.');
  const types=hit.types||[];if(!types.some(type=>['street_address','premise','subpremise'].includes(type)))throw Error('Selecione um endereço completo do Google, incluindo o número do imóvel.');return {lat,lng,label:hit.formatted_address||query};
 };
 if(path==='/api/delivery/cep'&&request.method==='GET'){
  const cep=new URL(request.url).searchParams.get('cep')?.replace(/\D/g,'');if(!cep||cep.length!==8)return c.json({message:'Informe um CEP válido com 8 números.'},400);
  const response=await c.fetcher('https://viacep.com.br/ws/'+cep+'/json/',{headers:{'User-Agent':'VUPPI-Delivery/0.12'},signal:AbortSignal.timeout(8000)});if(!response.ok)return c.json({message:'Não foi possível consultar o CEP.'},503);const address=await response.json();if(address.erro)return c.json({message:'CEP não encontrado.'},404);return reply({cep:address.cep,street:address.logradouro,neighborhood:address.bairro,city:address.localidade,uf:address.uf,address:[address.logradouro,address.bairro,address.localidade+' - '+address.uf].filter(Boolean).join(', ')})
 }
 if(path==='/api/delivery/address'&&request.method==='GET'){
  const query=String(new URL(request.url).searchParams.get('q')||'').trim();if(query.length<3)return c.json({results:[]});
  if(!c.env.GOOGLE_MAPS_SERVER_KEY)return c.json({message:'A busca Google aguarda a chave segura do servidor.'},503);
  const url='https://maps.googleapis.com/maps/api/geocode/json?region=br&language=pt-BR&address='+encodeURIComponent(query+', Pitangueiras, SP, Brasil')+'&key='+encodeURIComponent(c.env.GOOGLE_MAPS_SERVER_KEY),response=await c.fetcher(url,{signal:AbortSignal.timeout(10000)});
  if(!response.ok)return c.json({message:'A busca de endereços está temporariamente indisponível.'},503);
  const body=await response.json(),rows=body.results||[];return reply({results:rows.slice(0,6).map(x=>({label:x.formatted_address,lat:Number(x.geometry?.location?.lat),lng:Number(x.geometry?.location?.lng)})).filter(x=>x.label&&Number.isFinite(x.lat)&&Number.isFinite(x.lng))});
 }
 if(path==='/api/delivery/messages'&&request.method==='GET'){
  if(!c.env.SUPABASE_SECRET_KEY)return c.json({message:'A central de mensagens ainda não está configurada.'},503);
  const current=await rpc('state'),profile=current?.profile||{},isAdmin=!!current?.admin,now=Date.now();
  if(!isAdmin&&profile.kind!=='courier')return c.json({message:'Mensagens disponíveis somente para entregadores e administração.'},403);
  const base=c.env.SUPABASE_URL+'/rest/v1',rows=await serviceJson(base+'/vuppi_courier_messages?select=*&order=created_at.desc&limit=100'),reads=isAdmin?[]:await serviceJson(base+'/vuppi_courier_message_reads?select=message_id,read_at&courier_id=eq.'+encodeURIComponent(user.id)),readMap=new Map((reads||[]).map(x=>[x.message_id,x.read_at]));
  const eligible=row=>isAdmin||(
   row.active&&new Date(row.starts_at).getTime()<=now&&(!row.ends_at||new Date(row.ends_at).getTime()>now)&&(
    row.target_kind==='all'||
    (row.target_kind==='city'&&String(row.target_value).toLowerCase()===String(profile.city||'').toLowerCase())||
    (row.target_kind==='courier'&&row.target_value===user.id)
   )
  );
  const messages=(rows||[]).filter(eligible).map(row=>({...row,read_at:readMap.get(row.id)||null}));
  return reply({messages,unread:isAdmin?0:messages.filter(x=>!x.read_at).length,admin:isAdmin});
 }
 if(path==='/api/delivery/state'&&request.method==='GET'){
  await maintainPending();
  const state=await c.upstream('/rest/v1/rpc/vuppi_delivery_state',{method:'POST',token:s.access,body:{},carErrors:true});
  if(state?.profile?.kind==='courier'){
   const rules=await c.upstream('/rest/v1/rpc/vuppi_courier_financial_rules',{method:'POST',token:s.access,body:{},carErrors:true}),share=Math.max(0,Math.min(10000,Number(rules?.courier_share_bps??8500)));
   const net=row=>{const copy={...row},gross=Math.max(0,Number(row?.price_cents||0));copy.price_cents=Math.floor(gross*share/10000);copy.courier_price_cents=copy.price_cents;if(Array.isArray(copy.route_stops)){copy.route_stops=copy.route_stops.map(stop=>({...stop,price_cents:Math.floor(Math.max(0,Number(stop?.price_cents||0))*share/10000)}));copy.route_total_cents=copy.route_stops.reduce((sum,stop)=>sum+Number(stop.price_cents||0),0)}else if(copy.route_total_cents!=null)copy.route_total_cents=Math.floor(Math.max(0,Number(copy.route_total_cents))*share/10000);delete copy.merchant_price_cents;delete copy.platform_fee_cents;return copy};
   state.orders=(state.orders||[]).map(net);state.offers=(state.offers||[]).map(net);state.financial_rules={courier_share_bps:share};
  }
  if(state?.admin&&c.env.SUPABASE_SECRET_KEY){
   try{state.pending=await c.upstream('/rest/v1/rpc/vuppi_pending_admin',{method:'POST',token:s.access,body:{p_action:'state',p_data:{}},carErrors:true})}catch(error){console.warn('pending_admin_state_unavailable',{message:error.message})}
   try{
    const response=await c.fetcher(c.env.SUPABASE_URL+'/auth/v1/admin/users?page=1&per_page=100',{headers:{apikey:c.env.SUPABASE_SECRET_KEY,Authorization:'Bearer '+c.env.SUPABASE_SECRET_KEY},signal:AbortSignal.timeout(10000)}),body=response.ok?await response.json():{},existing=new Set((state.members||[]).map(x=>x.user_id));
    for(const account of body.users||[]){const name=String(account.user_metadata?.full_name||'').trim();if(!name||existing.has(account.id))continue;(state.members??=[]).push({user_id:account.id,kind:'courier',name,email:account.email||'',phone:'',city:'',address:'Cadastro operacional ainda não concluído',approved:false,member_status:'pending',registration_incomplete:true,created_at:account.created_at,last_active_at:account.last_sign_in_at||null,is_available:false})}
   }catch(error){console.warn('incomplete_registrations_unavailable',{message:error.message})}
  }
  return reply(state);
 }
 if(path==='/api/delivery/pending'&&request.method==='GET'){
  await maintainPending();
  const pending=await c.upstream('/rest/v1/rpc/vuppi_courier_pending_state',{method:'POST',token:s.access,body:{},carErrors:true}),rules=await c.upstream('/rest/v1/rpc/vuppi_courier_financial_rules',{method:'POST',token:s.access,body:{},carErrors:true}),share=Math.max(0,Math.min(10000,Number(rules?.courier_share_bps??8500))),net=row=>({...row,price_cents:Math.floor(Math.max(0,Number(row?.price_cents||0))*share/10000),courier_price_cents:Math.floor(Math.max(0,Number(row?.price_cents||0))*share/10000)});
  pending.available=(pending.available||[]).map(net);pending.decisions=(pending.decisions||[]).map(net);return reply(pending);
 }
 if(path==='/api/delivery/customer'&&request.method==='GET'){
  const phone=String(new URL(request.url).searchParams.get('phone')||'').replace(/\D/g,'');
  if(phone.length<10)return reply({found:false});
  return reply(await c.upstream('/rest/v1/rpc/vuppi_merchant_customer',{method:'POST',token:s.access,body:{p_action:'find',p_data:{phone}},carErrors:true}));
 }
 if(path==='/api/delivery/tracking'&&request.method==='GET'){
  const id=new URL(request.url).searchParams.get('id');
  if(!/^[0-9a-f-]{36}$/i.test(id||''))return c.json({message:'Entrega inválida.'},400);
  return reply(await c.upstream('/rest/v1/rpc/vuppi_delivery_tracking',{method:'POST',token:s.access,body:{p_delivery:id},carErrors:true}));
 }
 if(path==='/api/delivery/route'&&request.method==='GET'){
  const params=new URL(request.url).searchParams,id=params.get('id'),rawLat=params.get('lat'),rawLng=params.get('lng'),lat=rawLat===null?NaN:Number(rawLat),lng=rawLng===null?NaN:Number(rawLng);
  if(!/^[0-9a-f-]{36}$/i.test(id||''))return c.json({message:'Entrega inválida.'},400);
  const routeWindowKey=String(user.id||'anonymous'),now=Date.now(),allowedAt=liveRouteWindows.get(routeWindowKey)||0;if(now<allowedAt)return c.json({message:'A rota já está atualizada.'},429);liveRouteWindows.set(routeWindowKey,now+2000);if(liveRouteWindows.size>1000)for(const [key,until] of liveRouteWindows)if(until<now)liveRouteWindows.delete(key);
  if(!c.env.GOOGLE_MAPS_SERVER_KEY)return c.json({message:'A navegação aguarda a chave segura do Google Maps.'},503);
  const tracking=await c.upstream('/rest/v1/rpc/vuppi_delivery_tracking',{method:'POST',token:s.access,body:{p_delivery:id},carErrors:true});
  const returning=tracking?.return_required&&tracking?.return_started_at,status=String(tracking?.status||''),originLat=Number.isFinite(lat)?lat:Number(tracking?.courier_lat),originLng=Number.isFinite(lng)?lng:Number(tracking?.courier_lng),targetLat=returning?Number(tracking?.pickup_lat):status==='collected'?Number(tracking?.destination_lat):Number(tracking?.pickup_lat),targetLng=returning?Number(tracking?.pickup_lng):status==='collected'?Number(tracking?.destination_lng):Number(tracking?.pickup_lng);
  if(!Number.isFinite(originLat)||!Number.isFinite(originLng)||Math.abs(originLat)>90||Math.abs(originLng)>180)return c.json({message:'Aguardando a localização atual do entregador.'},409);
  if(!Number.isFinite(targetLat)||!Number.isFinite(targetLng)||Math.abs(targetLat)>90||Math.abs(targetLng)>180)return c.json({message:'O destino desta etapa não possui coordenadas válidas.'},422);
  let targets=[{lat:targetLat,lng:targetLng,id}];
  if(!returning&&tracking?.route_group_id){try{const routeState=await c.upstream('/rest/v1/rpc/vuppi_delivery_state',{method:'POST',token:s.access,body:{},carErrors:true}),sequence=Number(tracking.route_sequence||1),remaining=(routeState.orders||[]).filter(order=>order.route_group_id===tracking.route_group_id&&!['delivered','cancelled'].includes(order.status)&&Number(order.route_sequence||1)>=sequence).sort((a,b)=>Number(a.route_sequence||1)-Number(b.route_sequence||1));targets=[];if(status!=='collected')targets.push({lat:Number(tracking.pickup_lat),lng:Number(tracking.pickup_lng),id:'pickup'});for(const order of remaining)targets.push({lat:Number(order.lat),lng:Number(order.lng),id:order.id});targets=targets.filter(point=>Number.isFinite(point.lat)&&Number.isFinite(point.lng));}catch{targets=[{lat:targetLat,lng:targetLng,id}];}}
  if(!targets.length)targets=[{lat:targetLat,lng:targetLng,id}];const destinationPoint=targets.at(-1),intermediates=targets.slice(0,-1).map(point=>({location:{latLng:{latitude:point.lat,longitude:point.lng}}}));
  const response=await c.fetcher('https://routes.googleapis.com/directions/v2:computeRoutes',{method:'POST',headers:{'Content-Type':'application/json','X-Goog-Api-Key':c.env.GOOGLE_MAPS_SERVER_KEY,'X-Goog-FieldMask':'routes.distanceMeters,routes.duration,routes.polyline.encodedPolyline,routes.legs.steps.navigationInstruction.instructions,routes.legs.steps.distanceMeters'},body:JSON.stringify({origin:{location:{latLng:{latitude:originLat,longitude:originLng}}},destination:{location:{latLng:{latitude:destinationPoint.lat,longitude:destinationPoint.lng}}},...(intermediates.length?{intermediates}:{}),travelMode:'TWO_WHEELER',routingPreference:'TRAFFIC_AWARE',languageCode:'pt-BR',units:'METRIC'}),signal:AbortSignal.timeout(12000)});
  const body=await response.json(),route=body.routes?.[0];
  if(!response.ok||!route?.polyline?.encodedPolyline)return c.json({message:'Não foi possível atualizar a rota agora.'},503);
  const instructions=(route.legs||[]).flatMap(leg=>(leg.steps||[]).map(step=>({text:String(step.navigationInstruction?.instructions||'').trim(),distance_m:Number(step.distanceMeters||0)})).filter(step=>step.text)).slice(0,12);
  return reply({delivery_id:id,status,returning:!!returning,route_group_id:tracking?.route_group_id||null,stop_count:targets.length,origin:{lat:originLat,lng:originLng},target:{lat:targetLat,lng:targetLng},polyline:route.polyline.encodedPolyline,distance_m:Number(route.distanceMeters||0),duration_s:Math.max(0,Math.ceil(Number(String(route.duration||'0s').replace('s','')))),instructions,generated_at:new Date().toISOString()});
 }
 if(path==='/api/delivery/action'&&request.method==='POST'){
  const input=await c.readJson(request,600000),action=input.action;let data=input.data||{};
  if(!['register','admin_register','admin_courier_register','admin_member_update','availability','location','approve','member_status','admin_create','admin_manage','quick_delivery','profile_update','merchant_profile_update','create','accept','reject','courier_release','assign','pending_resend','arrive_pickup','collect','complete','cancel','remote_completion','courier_return_completion','courier_finance_admin','logistics_state','logistics_save','delivery_type_save','pricing_state','pricing_save','pricing_test','pricing_delete_override','merchant_manage','customer_save','return_start','return_finalize','message_create','message_read','message_archive'].includes(action))return c.json({message:'Ação inválida.'},400);
  const courierActions=new Set(['availability','location','accept','reject','courier_release','arrive_pickup','collect','complete','return_start','return_finalize']);
  if(courierActions.has(action)){
   const current=await rpc('state'),profile=current?.profile,status=profile?.member_status||(profile?.approved?'active':'pending');
   if(profile?.kind==='courier'&&(!profile.approved||status!=='active'))return c.json({message:status==='pending'?'Seu cadastro ainda está em análise.':'Seu acesso de entregador está suspenso ou inativo.'},403);
  }
  if(action==='accept')return reply(await c.upstream('/rest/v1/rpc/vuppi_accept_delivery_offer',{method:'POST',token:s.access,body:{p_delivery:data.id},carErrors:true}));
  if(action==='reject')return reply(await c.upstream('/rest/v1/rpc/vuppi_reject_delivery_offer',{method:'POST',token:s.access,body:{p_delivery:data.id},carErrors:true}));
  if(action==='courier_release')return reply(await c.upstream('/rest/v1/rpc/vuppi_courier_release_route',{method:'POST',token:s.access,body:{p_delivery:data.id,p_reason:data.reason||null},carErrors:true}));
  if(action==='assign')return reply(await c.upstream('/rest/v1/rpc/vuppi_assign_delivery',{method:'POST',token:s.access,body:{p_delivery:data.id,p_courier:data.courier},carErrors:true}));
  if(action==='pending_resend')return reply(await c.upstream('/rest/v1/rpc/vuppi_pending_admin',{method:'POST',token:s.access,body:{p_action:'resend',p_data:{id:data.id,reason:data.reason||'Reenvio manual pela central'}},carErrors:true}));
  if(action==='arrive_pickup')return reply(await c.upstream('/rest/v1/rpc/vuppi_delivery_pickup_arrive',{method:'POST',token:s.access,body:{p_delivery:data.id},carErrors:true}));
  if(action==='return_start')return reply(await c.upstream('/rest/v1/rpc/vuppi_start_delivery_return',{method:'POST',token:s.access,body:{p_delivery:data.id},carErrors:true}));
  if(action==='return_finalize')return reply(await c.upstream('/rest/v1/rpc/vuppi_finalize_delivery_return',{method:'POST',token:s.access,body:{p_delivery:data.id},carErrors:true}));
  if(action.startsWith('message_')){
   if(!c.env.SUPABASE_SECRET_KEY)return c.json({message:'A central de mensagens ainda não está configurada.'},503);
   const current=await rpc('state'),profile=current?.profile||{},base=c.env.SUPABASE_URL+'/rest/v1';
   if(action==='message_read'){
    if(profile.kind!=='courier')return c.json({message:'Leitura disponível somente para entregadores.'},403);
    if(!/^[0-9a-f-]{36}$/i.test(data.id||''))return c.json({message:'Mensagem inválida.'},400);
    await serviceJson(base+'/vuppi_courier_message_reads?on_conflict=message_id,courier_id',{method:'POST',headers:{Prefer:'resolution=merge-duplicates,return=minimal'},body:JSON.stringify({message_id:data.id,courier_id:user.id,read_at:new Date().toISOString()})});return reply({ok:true});
   }
   if(!current.admin)return c.json({message:'Acesso exclusivo da administração.'},403);
   if(action==='message_archive'){
    if(!/^[0-9a-f-]{36}$/i.test(data.id||''))return c.json({message:'Mensagem inválida.'},400);
    await serviceJson(base+'/vuppi_courier_messages?id=eq.'+encodeURIComponent(data.id),{method:'PATCH',headers:{Prefer:'return=minimal'},body:JSON.stringify({active:false,updated_at:new Date().toISOString()})});return reply({ok:true});
   }
   const title=String(data.title||'').trim().slice(0,90),body=String(data.body||'').trim().slice(0,1200),priority=['normal','important','urgent'].includes(data.priority)?data.priority:'normal',targetKind=['all','city','courier'].includes(data.target_kind)?data.target_kind:'all',targetValue=targetKind==='all'?null:String(data.target_value||'').trim();
   if(title.length<3||body.length<3)return c.json({message:'Informe título e mensagem completos.'},400);
   if(targetKind!=='all'&&!targetValue)return c.json({message:'Selecione o destino da mensagem.'},400);
   const row={title,body,priority,target_kind:targetKind,target_value:targetValue||null,action_label:String(data.action_label||'').trim().slice(0,40)||null,action_url:String(data.action_url||'').trim().slice(0,500)||null,starts_at:data.starts_at||new Date().toISOString(),ends_at:data.ends_at||null,active:true,created_by:user.id};
   const created=await serviceJson(base+'/vuppi_courier_messages',{method:'POST',headers:{Prefer:'return=representation'},body:JSON.stringify(row)});return reply(created?.[0]||row);
  }
  if(action==='complete'){const progress=await c.upstream('/rest/v1/rpc/vuppi_start_delivery_return',{method:'POST',token:s.access,body:{p_delivery:data.id},carErrors:true});if(progress?.return_required)return reply(progress);}
  if(action==='location')return reply(await c.upstream('/rest/v1/rpc/vuppi_driver_location',{method:'POST',token:s.access,body:{p_lat:Number(data?.lat),p_lng:Number(data?.lng)},carErrors:true}));
  if(action==='logistics_state')return reply(await c.upstream('/rest/v1/rpc/vuppi_logistics_admin',{method:'POST',token:s.access,body:{p_action:'state',p_data:{}},carErrors:true}));
  if(action==='logistics_save')return reply(await c.upstream('/rest/v1/rpc/vuppi_logistics_admin',{method:'POST',token:s.access,body:{p_action:'save_settings',p_data:data},carErrors:true}));
  if(action==='delivery_type_save')return reply(await c.upstream('/rest/v1/rpc/vuppi_logistics_admin',{method:'POST',token:s.access,body:{p_action:'save_type',p_data:data},carErrors:true}));
  if(action.startsWith('pricing_'))return reply(await c.upstream('/rest/v1/rpc/vuppi_pricing_admin',{method:'POST',token:s.access,body:{p_action:action.replace('pricing_',''),p_data:data||{}},carErrors:true}));
  if(action==='quick_delivery')return reply(await c.upstream('/rest/v1/rpc/vuppi_set_quick_delivery',{method:'POST',token:s.access,body:{p_member:data.id,p_enabled:!!data.enabled},carErrors:true}));
  if(action==='remote_completion')return reply(await c.upstream('/rest/v1/rpc/vuppi_set_remote_completion',{method:'POST',token:s.access,body:{p_courier:data.id,p_enabled:!!data.enabled},carErrors:true}));
  if(action==='courier_return_completion')return reply(await c.upstream('/rest/v1/rpc/vuppi_set_courier_return_completion',{method:'POST',token:s.access,body:{p_courier:data.id,p_enabled:!!data.enabled},carErrors:true}));
  if(action==='courier_finance_admin')return reply(await c.upstream('/rest/v1/rpc/vuppi_courier_finance_admin',{method:'POST',token:s.access,body:{p_courier:data.id,p_share_bps:data.use_city_default?null:Number(data.courier_share_bps),p_reason:data.reason},carErrors:true}));
  if(action==='profile_update')return reply(await c.upstream('/rest/v1/rpc/vuppi_update_courier_profile',{method:'POST',token:s.access,body:{p_data:data||{}},carErrors:true}));
  if(action==='merchant_profile_update'){if(data?.address){const place=await geocode(data.address);data={...data,address:place.label,lat:place.lat,lng:place.lng}}return reply(await c.upstream('/rest/v1/rpc/vuppi_update_merchant_profile',{method:'POST',token:s.access,body:{p_data:data||{}},carErrors:true}));}
  if(action==='customer_save')return reply(await c.upstream('/rest/v1/rpc/vuppi_merchant_customer',{method:'POST',token:s.access,body:{p_action:'save',p_data:data||{}},carErrors:true}));
  if(action==='admin_create'){
   const result=await c.upstream('/rest/v1/rpc/vuppi_create_delivery_transaction',{method:'POST',token:s.access,body:{p_data:data},carErrors:true});
   if(data.scheduled_for)await c.upstream('/rest/v1/rpc/vuppi_schedule_delivery',{method:'POST',token:s.access,body:{p_quote:data.quote_id,p_scheduled_for:data.scheduled_for,p_lead_minutes:Number(data.dispatch_lead_minutes||10)},carErrors:true});
   return reply(result);
  }
  if(action==='admin_manage')return reply(await c.upstream('/rest/v1/rpc/vuppi_admin_manage_delivery',{method:'POST',token:s.access,body:{p_action:data.operation,p_delivery:data.id,p_data:data},carErrors:true}));
  if(action==='member_status')return reply(await c.upstream('/rest/v1/rpc/vuppi_delivery_admin',{method:'POST',token:s.access,body:{p_action:action,p_data:data||{}},carErrors:true}));
  if(action==='cancel')return reply(await c.upstream('/rest/v1/rpc/vuppi_cancel_delivery',{method:'POST',token:s.access,body:{p_delivery:data.id,p_reason:data.reason||null},carErrors:true}));
  if(action==='merchant_manage'){
   const operation=String(data.operation||'');if(!['couriers','join','assign','redistribute','favorite','edit','optimize'].includes(operation))return c.json({message:'Operação de pedido inválida.'},400);
   if(operation==='optimize'){
    const current=await rpc('state'),anchor=(current.orders||[]).find(x=>x.id===data.id);
    if(!anchor)return c.json({message:'Entrega não encontrada.'},404);
    const group=anchor.route_group_id?(current.orders||[]).filter(x=>x.route_group_id===anchor.route_group_id):[anchor];
    if(group.length>1){
     if(!c.env.GOOGLE_MAPS_SERVER_KEY)return c.json({message:'A otimização aguarda a chave segura do Google Maps.'},503);
     const stops=group.map(x=>({location:{latLng:{latitude:Number(x.lat),longitude:Number(x.lng)}}}));
     if(stops.some(x=>!Number.isFinite(x.location.latLng.latitude)||!Number.isFinite(x.location.latLng.longitude)))return c.json({message:'Uma das entregas não possui coordenadas válidas.'},422);
     const origin={location:{latLng:{latitude:Number(anchor.pickup_lat),longitude:Number(anchor.pickup_lng)}}};
     const response=await c.fetcher('https://routes.googleapis.com/directions/v2:computeRoutes',{method:'POST',headers:{'Content-Type':'application/json','X-Goog-Api-Key':c.env.GOOGLE_MAPS_SERVER_KEY,'X-Goog-FieldMask':'routes.distanceMeters,routes.duration,routes.polyline.encodedPolyline,routes.optimizedIntermediateWaypointIndex'},body:JSON.stringify({origin,destination:stops.at(-1),intermediates:stops.slice(0,-1),travelMode:'TWO_WHEELER',routingPreference:'TRAFFIC_AWARE',optimizeWaypointOrder:true,languageCode:'pt-BR',units:'METRIC'}),signal:AbortSignal.timeout(15000)});
     const body=await response.json(),route=body.routes?.[0];if(!response.ok||!route)return c.json({message:'Não foi possível otimizar esta rota no Google Maps.'},503);
     const indexes=route.optimizedIntermediateWaypointIndex||stops.slice(0,-1).map((_,i)=>i),ordered=indexes.map(i=>group[i]?.id).filter(Boolean);ordered.push(group.at(-1).id);
     data={...data,ordered_ids:ordered,distance_m:Number(route.distanceMeters||0),duration_s:Math.ceil(Number(String(route.duration||'0s').replace('s',''))),polyline:route.polyline?.encodedPolyline||''};
    }
   }
   return reply(await c.upstream('/rest/v1/rpc/vuppi_merchant_manage_delivery',{method:'POST',token:s.access,body:{p_action:operation,p_delivery:data.id||null,p_data:data},carErrors:true}));
  }
  if(['admin_courier_register','admin_member_update'].includes(action)){
   const state=await rpc('state');if(!state.admin)return c.json({message:'Acesso exclusivo do superadministrador.'},403);
   if(!c.env.SUPABASE_SECRET_KEY)return c.json({message:'A manutenção de cadastros aguarda a chave segura do servidor.'},503);
   const clean=(value,max=250)=>String(value||'').trim().slice(0,max),id=clean(data.id,40),kind=action==='admin_courier_register'?'courier':clean(data.kind,20);
   if(kind!=='courier'&&kind!=='merchant')return c.json({message:'Tipo de cadastro inválido.'},400);
   const name=clean(data.name,100),phone=clean(data.phone,30),city=clean(data.city,60),address=clean(data.address,250);
   if(name.length<2||phone.replace(/\D/g,'').length<10||address.length<5)return c.json({message:'Informe nome, telefone com DDD e endereço completo.'},400);
   if(!(state.cities||[]).some(row=>row.id===city))return c.json({message:'Cidade indisponível.'},400);
   if(action==='admin_member_update'){
    if(!/^[0-9a-f-]{36}$/i.test(id||''))return c.json({message:'Cadastro inválido.'},400);
    const payload={name,phone,city,address};for(const field of ['legal_name','cnpj','contract_number','vehicle_model','vehicle_plate','vehicle_model_2','vehicle_plate_2','document_cpf','document_cnh','state_registration','responsible_name','responsible_document','contact_email','cep','address_number','address_complement','district'])if(data[field]!=null)payload[field]=clean(data[field],140)||null;
    if(kind==='merchant'){
     for(const field of ['payment_wallet_enabled','payment_cash_enabled','payment_pix_enabled','payment_credit_enabled'])if(data[field]!=null)payload[field]=data[field]===true||data[field]==='true'||data[field]==='on';
     for(const field of ['proof_of_delivery_required','pickup_code_required'])if(data[field]!=null)payload[field]=data[field]===true||data[field]==='true'||data[field]==='on';
     if(data.max_delivery_stops!=null)payload.max_delivery_stops=Math.max(1,Math.min(30,Number(data.max_delivery_stops)||10));
     if(data.cash_platform_fee_bps!=null&&data.cash_platform_fee_bps!==''){const fee=Number(data.cash_platform_fee_bps);if(!Number.isInteger(fee)||fee<0||fee>10000)return c.json({message:'Taxa de dinheiro inválida.'},400);payload.cash_platform_fee_bps=fee}else payload.cash_platform_fee_bps=null;
    }
    const updated=await c.fetcher(c.env.SUPABASE_URL+'/rest/v1/vuppi_members?user_id=eq.'+encodeURIComponent(id),{method:'PATCH',headers:{apikey:c.env.SUPABASE_SECRET_KEY,Authorization:'Bearer '+c.env.SUPABASE_SECRET_KEY,'Content-Type':'application/json',Prefer:'return=representation'},body:JSON.stringify(payload),signal:AbortSignal.timeout(10000)});
    if(!updated.ok){let problem={};try{problem=await updated.json()}catch{}return c.json({message:problem.message||'Não foi possível atualizar o cadastro.'},400)}
    return reply({ok:true,user_id:id,profile:(await updated.json().catch(()=>[]))[0]||payload});
   }
   let userId=id;
   if(action==='admin_courier_register'&&!userId){
    const email=clean(data.email,254).toLowerCase(),password=String(data.password||'');
    if(!/^\S+@\S+\.\S+$/.test(email)||password.length<8)return c.json({message:'Informe e-mail válido e senha inicial com pelo menos 8 caracteres.'},400);
    const created=await c.fetcher(c.env.SUPABASE_URL+'/auth/v1/admin/users',{method:'POST',headers:{apikey:c.env.SUPABASE_SECRET_KEY,Authorization:'Bearer '+c.env.SUPABASE_SECRET_KEY,'Content-Type':'application/json'},body:JSON.stringify({email,password,email_confirm:true,user_metadata:{full_name:name,name}}),signal:AbortSignal.timeout(10000)});
    let account={};try{account=await created.json()}catch{}
    if(!created.ok)return c.json({message:account.msg||account.message||'Não foi possível criar a conta do entregador.'},400);
    userId=account.id;
   }
   if(!/^[0-9a-f-]{36}$/i.test(userId||''))return c.json({message:'Conta do entregador inválida.'},400);
   const payload={user_id:userId,kind,name,phone,city,address,approved:false,member_status:'pending',is_available:false};
   const endpoint=c.env.SUPABASE_URL+'/rest/v1/vuppi_members?on_conflict=user_id',saved=await c.fetcher(endpoint,{method:'POST',headers:{apikey:c.env.SUPABASE_SECRET_KEY,Authorization:'Bearer '+c.env.SUPABASE_SECRET_KEY,'Content-Type':'application/json',Prefer:'return=representation,resolution=merge-duplicates'},body:JSON.stringify(payload),signal:AbortSignal.timeout(10000)});
   if(!saved.ok){let problem={};try{problem=await saved.json()}catch{}return c.json({message:problem.message||'Não foi possível salvar o cadastro operacional.'},400)}
   return reply({ok:true,user_id:userId,profile:(await saved.json().catch(()=>[]))[0]||payload});
  }
  if(action==='register'&&data.kind==='courier'){
   const phone=String(data.phone||'').replace(/\D/g,''),address=String(data.address||'').trim(),name=String(data.name||'').trim();if(phone.length<10||phone.length>11||name.length<2||address.length<5||!/(?:^|\D)\d{1,6}(?:\D|$)/.test(address))return c.json({message:'Informe nome, telefone com DDD e endereço com número.'},400);data={...data,name,phone,address};
  }
  if(action==='register'&&data.kind==='courier'&&data.address&&(!Number.isFinite(Number(data.lat))||!Number.isFinite(Number(data.lng)))){
   try{data={...data,...await geocode(data.address)}}catch{data={...data,lat:null,lng:null}}
  }else if(['register','admin_register'].includes(action)&&data.address&&(!Number.isFinite(Number(data.lat))||!Number.isFinite(Number(data.lng)))){
   try{data={...data,...await geocode(data.address)}}catch(error){return c.json({message:error.message},400)}
  }
  if(action==='admin_register'){
   const registerBilling=async()=>c.upstream('/rest/v1/rpc/vuppi_wallet_billing',{method:'POST',token:s.access,body:{p_action:'profile_create',p_data:{email:String(data.email||'').trim().toLowerCase(),free_period_days:Number(data.free_period_days||0),notes:data.billing_notes||''}},carErrors:true});
   try{const result=await rpc(action,data||{});await registerBilling();return reply(result)}catch(error){
    if(!/ainda não existe/i.test(error.message||''))throw error;
    const state=await rpc('state');if(!state.admin)return c.json({message:'Acesso exclusivo do superadministrador.'},403);
    if(!c.env.SUPABASE_SECRET_KEY)return c.json({message:'A criação de contas pelo painel aguarda a chave segura do servidor.'},503);
    if(typeof data?.password!=='string'||data.password.length<8)return c.json({message:'Defina uma senha inicial com pelo menos 8 caracteres.'},400);
    const created=await c.fetcher(c.env.SUPABASE_URL+'/auth/v1/admin/users',{method:'POST',headers:{apikey:c.env.SUPABASE_SECRET_KEY,Authorization:'Bearer '+c.env.SUPABASE_SECRET_KEY,'Content-Type':'application/json'},body:JSON.stringify({email:String(data.email||'').trim().toLowerCase(),password:data.password,email_confirm:true,user_metadata:{name:String(data.name||'').trim()}}),signal:AbortSignal.timeout(10000)});
    if(!created.ok){let problem={};try{problem=await created.json()}catch{}return c.json({message:problem.msg||problem.message||'Não foi possível criar a conta do estabelecimento.'},400)}
    const safe={...data};delete safe.password;const result=await rpc(action,safe);await registerBilling();return reply(result);
   }
  }
  const result=action==='create'
   ?await c.upstream('/rest/v1/rpc/vuppi_create_delivery_transaction',{method:'POST',token:s.access,body:{p_data:data},carErrors:true})
   :await rpc(action,data||{});
  // Scheduling is persisted inside vuppi_create_delivery_transaction. Keeping it in
  // the same database transaction prevents an order from becoming visible between
  // creation and a second scheduling call (or remaining immediate if that call fails).
  if(action==='create'&&data?.quote_id){try{await c.upstream('/rest/v1/rpc/vuppi_merchant_customer',{method:'POST',token:s.access,body:{p_action:'save',p_data:{phone:data.phone,name:data.recipient,address:data.destination,complement:data.complement||'',label:'Principal'}},carErrors:true})}catch(error){console.warn('customer_save_failed',{message:error.message})}}
  return reply(result);
 }
 if(path==='/api/delivery/quote'&&request.method==='POST'){
  if(!c.env.SUPABASE_SECRET_KEY)return c.json({message:'A cotação aguarda a configuração segura do servidor.'},503);
  const data=await c.readJson(request),state=await rpc('state');let profile=state.profile,merchantId=user.id;if(data.merchant&&state.admin){profile=(state.members||[]).find(x=>x.user_id===data.merchant&&x.kind==='merchant');merchantId=data.merchant;if(!profile?.quick_delivery_enabled)return c.json({message:'A solicita\u00e7\u00e3o r\u00e1pida n\u00e3o est\u00e1 habilitada para este estabelecimento.'},403)}
  if(!profile||profile.kind!=='merchant'||!profile.approved)return c.json({message:'O estabelecimento precisa estar aprovado.'},403);
  let destination;if(data.destination){try{destination=await geocode(data.destination)}catch(error){return c.json({message:error.message},400)}}else destination={lat:Number(data.lat),lng:Number(data.lng),label:''};
  const lat=destination.lat,lng=destination.lng;
  if(!Number.isFinite(lat)||!Number.isFinite(lng))return c.json({message:'Informe um endereço de destino válido.'},400);
  if(Math.abs(lat-profile.lat)>.3||Math.abs(lng-profile.lng)>.3)return c.json({message:'O destino precisa estar dentro da área piloto, até aproximadamente 30 km da coleta.'},400);
  if(Date.now()<nextRoute)return c.json({message:'Aguarde alguns segundos e tente novamente.'},429);
  nextRoute=Date.now()+1500;
  if(!c.env.GOOGLE_MAPS_SERVER_KEY)return c.json({message:'O cálculo de rotas Google aguarda a chave segura do servidor.'},503);
  let route;try{const res=await c.fetcher('https://routes.googleapis.com/directions/v2:computeRoutes',{method:'POST',headers:{'Content-Type':'application/json','X-Goog-Api-Key':c.env.GOOGLE_MAPS_SERVER_KEY,'X-Goog-FieldMask':'routes.distanceMeters,routes.duration,routes.polyline.encodedPolyline'},body:JSON.stringify({origin:{location:{latLng:{latitude:Number(profile.lat),longitude:Number(profile.lng)}}},destination:{location:{latLng:{latitude:lat,longitude:lng}}},travelMode:'TWO_WHEELER',routingPreference:'TRAFFIC_AWARE'}),signal:AbortSignal.timeout(10000)});const result=await res.json();route=result.routes?.[0];if(!res.ok||!route||!Number.isFinite(route.distanceMeters)||route.distanceMeters<=0||route.distanceMeters>30000)throw Error()}catch{return c.json({message:'Não foi possível calcular uma rota Google de até 30 km. Ajuste o endereço ou tente mais tarde.'},503)}
  const distance=Math.ceil(route.distanceMeters),durationSeconds=Math.max(1,Math.ceil(Number(String(route.duration||'0s').replace('s',''))));
  const row=await c.upstream('/rest/v1/rpc/vuppi_create_quote',{method:'POST',token:s.access,body:{p_data:{merchant:merchantId,city:profile.city,lat,lng,distance_m:distance,return_required:!!data.return_required}},carErrors:true});
  return reply({...row,destination:destination.label,duration_s:durationSeconds,route_polyline:route.polyline?.encodedPolyline||'',pricing_configured:true});
 }
 return c.json({message:'Recurso não encontrado.'},404);
}
