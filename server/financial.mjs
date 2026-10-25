const CENTS_MAX=9_000_000_000_000;

export function cents(value,{min=0,max=CENTS_MAX}={}){
 const n=typeof value==='number'?value:Number(String(value??'').replace(',','.'));
 if(!Number.isSafeInteger(n)||n<min||n>max)throw Error('Valor financeiro inválido.');
 return n;
}

export function calculateTopup(amountCents,percentBps=200,mode='add'){
 const amount=cents(amountCents,{min:100});
 const fee=Math.ceil(amount*cents(percentBps,{max:10000})/10000);
 if(!['add','deduct'].includes(mode))throw Error('Modelo de taxa de recarga inválido.');
 return mode==='add'
  ?{amount_cents:amount,fee_cents:fee,total_cents:amount+fee,credit_cents:amount}
  :{amount_cents:amount,fee_cents:fee,total_cents:amount,credit_cents:amount-fee};
}

export function calculateWithdrawal(amountCents,feeCents=150){
 const amount=cents(amountCents,{min:1}),fee=cents(feeCents);
 if(amount<=fee)throw Error('O saque precisa ser maior que a taxa.');
 return {amount_cents:amount,fee_cents:fee,net_cents:amount-fee,reserve_cents:amount};
}

export function calculateBillingTopup(amountCents,subscriptionDebtCents=0,feeCents=0){
 const recharge=cents(amountCents,{min:100}),debt=cents(subscriptionDebtCents),fee=cents(feeCents);
 return {recharge_cents:recharge,subscription_debt_cents:debt,fee_cents:fee,total_cents:recharge+debt+fee,wallet_credit_cents:recharge};
}

export function canWithdrawToday(date=new Date(),timeZone='America/Sao_Paulo',allowedWeekday=1){
 const name=new Intl.DateTimeFormat('en-US',{weekday:'short',timeZone}).format(date);
 return ['Sun','Mon','Tue','Wed','Thu','Fri','Sat'].indexOf(name)===allowedWeekday;
}

export class FakePaymentProvider{
 constructor(){this.name='fake';this.calls=[]}
 async createPixCharge(input){this.calls.push({operation:'create_pix_charge',input});return {provider:'fake',reference:`fake_charge_${input.externalReference||this.calls.length}`,status:'pending',qr_code:'FAKE-PIX-NO-REAL-MONEY'}}
 async requestPixTransfer(input){this.calls.push({operation:'request_pix_transfer',input});return {provider:'fake',reference:`fake_transfer_${input.externalReference||this.calls.length}`,status:'pending'}}
}

export class AsaasPaymentProvider{
 constructor(env={},fetcher=fetch){this.enabled=env.ASAAS_ENABLED==='true';this.live=env.ASAAS_LIVE_OPERATIONS_ENABLED==='true';this.baseUrl=env.ASAAS_BASE_URL||'https://api-sandbox.asaas.com/v3';this.apiKey=env.ASAAS_API_KEY||'';this.fetcher=fetcher}
 assertDisabled(){if(!this.enabled||!this.live)throw Error('Operações reais do Asaas estão desativadas.');if(!this.apiKey)throw Error('Credencial Asaas não configurada.')}
 async createPixCharge(){this.assertDisabled();throw Error('Adaptador Asaas preparado; ativação depende de homologação.')}
 async requestPixTransfer(){this.assertDisabled();throw Error('Adaptador Asaas preparado; ativação depende de homologação.')}
}

async function providerJson(fetcher,url,options,message){
 const response=await fetcher(url,{...options,signal:AbortSignal.timeout(20000)}),body=await response.json().catch(()=>({}));
 if(!response.ok)throw Error(body?.message||body?.error||message);return body;
}

export class MercadoPagoPaymentProvider{
 constructor(env={},fetcher=fetch){this.name='mercadopago';this.enabled=env.MERCADOPAGO_ENABLED==='true';this.live=env.MERCADOPAGO_LIVE_MODE==='true';this.accessToken=env.MERCADOPAGO_ACCESS_TOKEN||'';this.payoutAccessToken=env.MERCADOPAGO_PAYOUTS_ACCESS_TOKEN||this.accessToken;this.payoutsEnabled=env.MERCADOPAGO_PAYOUTS_ENABLED==='true';this.payoutPrivateKey=String(env.MERCADOPAGO_PAYOUTS_PRIVATE_KEY||'').replace(/\\n/g,'\n');this.origin=String(env.UP_PUBLIC_ORIGIN||'https://vuppidelivery.com.br').replace(/\/$/,'');this.fetcher=fetcher}
 assertReady(){if(!this.enabled)throw Error('Mercado Pago ainda não foi ativado.');if(!this.accessToken)throw Error('Credencial do Mercado Pago não configurada.')}
 headers(idempotencyKey=''){return {Authorization:'Bearer '+this.accessToken,'Content-Type':'application/json',...(idempotencyKey?{'X-Idempotency-Key':idempotencyKey}:{})}}
 async createPixPayment(input){
  this.assertReady();const reference=String(input.externalReference||'');if(!/^[0-9a-f-]{36}$/i.test(reference))throw Error('Referência da recarga inválida.');
  const body={transaction_amount:Number(input.value),description:'Recarga da carteira Vuppi Delivery',payment_method_id:'pix',external_reference:reference,notification_url:this.origin+'/api/finance/mercadopago/webhook',payer:{email:String(input.email||'')},metadata:{topup_id:reference}};
  const data=await providerJson(this.fetcher,'https://api.mercadopago.com/v1/payments',{method:'POST',headers:this.headers(reference),body:JSON.stringify(body)},'Não foi possível gerar o Pix no Mercado Pago.');
  const pix=data.point_of_interaction?.transaction_data||{};if(!data.id||!pix.qr_code||!pix.qr_code_base64)throw Error('Mercado Pago não devolveu o QR Code Pix.');
  return {provider:this.name,reference:String(data.id),status:String(data.status||'pending'),payment_method:'pix',qr_code:String(pix.qr_code),qr_code_base64:String(pix.qr_code_base64),ticket_url:String(pix.ticket_url||''),expires_at:data.date_of_expiration||null,live_mode:data.live_mode===true};
 }
 async getPayment(id){this.assertReady();if(!/^\d{1,32}$/.test(String(id)))throw Error('Pagamento do Mercado Pago inválido.');return providerJson(this.fetcher,'https://api.mercadopago.com/v1/payments/'+id,{headers:this.headers()},'Não foi possível consultar o pagamento no Mercado Pago.')}
 async payoutSignature(body){if(!this.payoutPrivateKey)throw Error('Chave privada Ed25519 do Mercado Pago Payouts não configurada.');const encoded=this.payoutPrivateKey.replace(/-----BEGIN PRIVATE KEY-----|-----END PRIVATE KEY-----|\s/g,''),bytes=Uint8Array.from(atob(encoded),c=>c.charCodeAt(0)),key=await crypto.subtle.importKey('pkcs8',bytes,{name:'Ed25519'},false,['sign']),signature=await crypto.subtle.sign('Ed25519',key,new TextEncoder().encode(body));return btoa(String.fromCharCode(...new Uint8Array(signature)))}
 async requestPixTransfer(input){this.assertReady();if(!this.payoutsEnabled)throw Error('Mercado Pago Payouts ainda não está habilitado nesta integração.');if(!this.payoutAccessToken)throw Error('Access Token de Payouts não configurado.');const reference=String(input.externalReference||'').replace(/[^a-zA-Z0-9_-]/g,'').slice(0,50);if(!reference)throw Error('Referência de saque inválida.');const body=JSON.stringify({external_reference:reference,config:{notification_url:this.origin+'/api/finance/mercadopago/payout-webhook'},description:'Saque Vuppi Delivery',transactions:[{description:'Repasse entregador Vuppi',type:'pix',pix:{type:input.pixType,chave:input.pixKey},amount:{currency:'BRL',value:Number(input.value)},external_reference:reference}]});const signature=await this.payoutSignature(body),data=await providerJson(this.fetcher,'https://api.mercadopago.com/v1/payouts',{method:'POST',headers:{Authorization:'Bearer '+this.payoutAccessToken,'Content-Type':'application/json','X-Idempotency-Key':reference,'X-enforce-signature':'true','X-test-token':'false','X-signature':signature},body},'Não foi possível enviar o Pix pelo Mercado Pago.');const transaction=data.transactions?.[0];if(!data.id||!transaction?.id)throw Error('Mercado Pago não devolveu os identificadores do saque.');return {provider:this.name,payout_id:String(data.id),transaction_id:String(transaction.id),status:String(data.status||'created'),raw:data}}
 async getPayoutTransaction(payoutId,transactionId){this.assertReady();if(!this.payoutsEnabled)throw Error('Mercado Pago Payouts não está habilitado.');return providerJson(this.fetcher,`https://api.mercadopago.com/v1/payouts/${encodeURIComponent(payoutId)}/transactions/${encodeURIComponent(transactionId)}`,{headers:{Authorization:'Bearer '+this.payoutAccessToken,'Content-Type':'application/json','X-test-token':'false'}},'Não foi possível consultar o saque no Mercado Pago.')}
}

export function paymentProvider(env={},fetcher=fetch){if(env.MERCADOPAGO_ENABLED==='true')return new MercadoPagoPaymentProvider(env,fetcher);return env.ASAAS_ENABLED==='true'?new AsaasPaymentProvider(env,fetcher):new FakePaymentProvider()}

const hexBytes=value=>{if(!/^[0-9a-f]{64}$/i.test(value))return null;return Uint8Array.from(value.match(/../g),x=>parseInt(x,16))};
export async function validateMercadoPagoSignature({signature,requestId,dataId,secret},cryptoApi=crypto){
 const parts=Object.fromEntries(String(signature||'').split(',').map(part=>part.trim().split('=',2))),ts=parts.ts,digest=hexBytes(parts.v1||'');
 if(!ts||!digest||!requestId||!dataId||!secret)return false;
 const key=await cryptoApi.subtle.importKey('raw',new TextEncoder().encode(secret),{name:'HMAC',hash:'SHA-256'},false,['verify']);
 return cryptoApi.subtle.verify('HMAC',key,digest,new TextEncoder().encode(`id:${String(dataId).toLowerCase()};request-id:${requestId};ts:${ts};`));
}

async function serviceRpc(env,fetcher,name,body){
 const base=String(env.SUPABASE_URL||'').replace(/\/$/,''),secret=env.SUPABASE_SERVICE_ROLE_KEY||env.SUPABASE_SECRET_KEY||'';if(!base||!secret)throw Error('Liquidação financeira não configurada.');
 return providerJson(fetcher,base+'/rest/v1/rpc/'+name,{method:'POST',headers:{apikey:secret,Authorization:'Bearer '+secret,'Content-Type':'application/json'},body:JSON.stringify(body)},'Não foi possível liquidar a recarga.');
}

function normalizePixKey(value){const key=String(value||'').trim();if(key.length<5||key.length>140)throw Error('Informe uma chave Pix válida.');const digits=key.replace(/\D/g,'');let type='PIX_CODE';if(/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(key))type='EMAIL';else if(digits.length===11&&/^\+?\d/.test(key)&&/[+() -]/.test(key))type='PHONE';else if(digits.length===11)type='CPF';else if(digits.length===14)type='CNPJ';return {key,type,masked:type==='EMAIL'?key.replace(/^(.{2}).*(@.*)$/,'$1***$2'):type==='PIX_CODE'?key.slice(0,4)+'***'+key.slice(-4):'***'+digits.slice(-4)}}
async function syncMercadoPagoWithdrawal(c,id){const provider=c.paymentProvider();if(provider.name!=='mercadopago')throw Error('Saque Pix exige o Mercado Pago configurado.');const payload=await serviceRpc(c.env,c.fetcher,'vuppi_withdrawal_payout_payload',{p_id:id});let payoutId=payload.provider_reference,transactionId=payload.metadata?.transaction_id;if(!payoutId){const sent=await provider.requestPixTransfer({externalReference:String(id),value:Number(payload.net_cents)/100,pixKey:payload.pix_key,pixType:payload.pix_type});payoutId=sent.payout_id;transactionId=sent.transaction_id;await serviceRpc(c.env,c.fetcher,'vuppi_withdrawal_payout_submitted',{p_id:id,p_payout:payoutId,p_transaction:transactionId,p_status:sent.status,p_details:{submitted:true}})}if(!transactionId)return {ok:true,status:'processing',payout_id:payoutId};const transaction=await provider.getPayoutTransaction(payoutId,transactionId),status=String(transaction.status||''),detail=String(transaction.status_detail||'');if(status==='success'&&detail==='accredited')return serviceRpc(c.env,c.fetcher,'vuppi_withdrawal_payout_finalize',{p_id:id,p_status:'success',p_details:{payout_id:payoutId,transaction_id:transactionId,status,status_detail:detail}});if(['error','rejected','refunded','canceled'].includes(status))return serviceRpc(c.env,c.fetcher,'vuppi_withdrawal_payout_finalize',{p_id:id,p_status:status,p_details:{payout_id:payoutId,transaction_id:transactionId,status,status_detail:detail,message:'Transferência Pix não concluída: '+(detail||status)}});return {ok:true,status:'processing',provider_status:status,status_detail:detail,payout_id:payoutId,transaction_id:transactionId}}

export async function handleMercadoPagoWebhook(request,c){
 const url=new URL(request.url),body=await c.readJson(request),dataId=String(url.searchParams.get('data.id')||body?.data?.id||'');
 if(String(url.searchParams.get('type')||body?.type||'')!=='payment'||!dataId)return c.json({received:true});
 const valid=await validateMercadoPagoSignature({signature:request.headers.get('x-signature'),requestId:request.headers.get('x-request-id'),dataId,secret:c.env.MERCADOPAGO_WEBHOOK_SECRET||''});
 if(!valid)return c.json({message:'Assinatura do Mercado Pago inválida.'},401);
 const provider=new MercadoPagoPaymentProvider(c.env,c.fetcher),payment=await provider.getPayment(dataId),reference=String(payment.external_reference||'');
 if(!/^[0-9a-f-]{36}$/i.test(reference))return c.json({received:true});
 const amountCents=Math.round(Number(payment.transaction_amount)*100);if(!Number.isSafeInteger(amountCents)||amountCents<1)throw Error('Valor do pagamento inválido.');
 await serviceRpc(c.env,c.fetcher,'vuppi_mercadopago_settle',{p_topup:reference,p_payment_id:String(payment.id),p_status:String(payment.status||''),p_amount_cents:amountCents,p_currency:String(payment.currency_id||''),p_live_mode:payment.live_mode===true,p_details:{status_detail:String(payment.status_detail||''),payment_type_id:String(payment.payment_type_id||''),date_approved:payment.date_approved||null}});
 return c.json({received:true});
}

export async function handleMercadoPagoPayoutWebhook(request,c){
 const notice=await c.readJson(request),payoutId=String(notice?.payout?.id||''),transactionId=String(notice?.id||'');if(!payoutId||!transactionId)return c.json({received:true});
 const provider=new MercadoPagoPaymentProvider(c.env,c.fetcher),transaction=await provider.getPayoutTransaction(payoutId,transactionId),reference=String(transaction.external_reference||notice.external_reference||'');if(!/^[0-9a-f-]{36}$/i.test(reference))return c.json({received:true});
 const status=String(transaction.status||''),detail=String(transaction.status_detail||'');if(status==='success'&&detail==='accredited')await serviceRpc(c.env,c.fetcher,'vuppi_withdrawal_payout_finalize',{p_id:reference,p_status:'success',p_details:{payout_id:payoutId,transaction_id:transactionId,status,status_detail:detail}});else if(['error','rejected','refunded','canceled'].includes(status))await serviceRpc(c.env,c.fetcher,'vuppi_withdrawal_payout_finalize',{p_id:reference,p_status:status,p_details:{payout_id:payoutId,transaction_id:transactionId,status,status_detail:detail,message:'Transferência Pix não concluída: '+(detail||status)}});
 return c.json({received:true});
}

export async function runFinanceBilling(env={},fetcher=fetch,{dryRun=true,runKey='scheduled'}={}){
 const base=String(env.SUPABASE_URL||'').replace(/\/$/,''),secret=env.SUPABASE_SERVICE_ROLE_KEY||env.SUPABASE_SECRET_KEY||'';
 if(!base||!secret)return {ok:false,disabled:true,reason:'service_role_not_configured'};
 const response=await fetcher(base+'/rest/v1/rpc/vuppi_billing_run_execute',{method:'POST',headers:{apikey:secret,Authorization:'Bearer '+secret,'Content-Type':'application/json'},body:JSON.stringify({p_city:env.UP_CITY_ID||'pitangueiras-sp',p_dry_run:dryRun,p_run_key:runKey}),signal:AbortSignal.timeout(30000)});
 const body=await response.json().catch(()=>({}));if(!response.ok)throw Error('billing_job_failed');return {ok:true,result:body};
}

export async function handleFinancial(request,c){
 const {s,user}=await c.session(),url=new URL(request.url),path=url.pathname;
 const rpc=(action,data={})=>c.upstream('/rest/v1/rpc/vuppi_finance',{method:'POST',token:s.access,body:{p_action:action,p_data:data},carErrors:true});
 const billingRpc=(action,data={})=>c.upstream('/rest/v1/rpc/vuppi_wallet_billing',{method:'POST',token:s.access,body:{p_action:action,p_data:data},carErrors:true});
 const reply=async data=>{await c.renewCookie();return c.json(data)};
 if(path==='/api/finance/state'&&request.method==='GET'){
  const state=await rpc('state'),provider=c.paymentProvider(),webhookUrl=String(c.env.UP_PUBLIC_ORIGIN||'https://vuppidelivery.com.br').replace(/\/$/,'')+'/api/finance/mercadopago/webhook';
  state.provider=provider.name==='mercadopago'?{name:'mercadopago',label:'Mercado Pago',enabled:provider.enabled===true,live_operations:provider.live===true,mode:provider.live?'production':'test',credential_configured:Boolean(provider.accessToken),webhook_configured:Boolean(c.env.MERCADOPAGO_WEBHOOK_SECRET),webhook_url:webhookUrl,payment_method:'pix',automatic_settlement:true,payouts_enabled:provider.payoutsEnabled===true,payout_signature_configured:Boolean(provider.payoutPrivateKey),automatic_withdrawals:provider.payoutsEnabled===true&&Boolean(provider.payoutPrivateKey)}:{name:provider.name,enabled:false,live_operations:false,payment_method:'pix',payouts_enabled:false,automatic_withdrawals:false};
  try{state.billing=await billingRpc('state',{city:url.searchParams.get('city')||''});state.billing.ready=true}catch(error){state.billing={ready:false,message:error.message}}return reply(state);
 }
 if(path==='/api/finance/statement'&&request.method==='GET')return reply(await rpc('statement',{wallet_id:url.searchParams.get('wallet_id'),limit:Math.min(200,Math.max(1,Number(url.searchParams.get('limit')||50)))}));
 if(path==='/api/finance/summary'&&request.method==='GET'){
  const state=await rpc('state'),wallet=state?.wallet;
  const entries=wallet?.id?await rpc('statement',{wallet_id:wallet.id,limit:Math.min(100,Math.max(1,Number(url.searchParams.get('limit')||50)))}):[];
  return reply({state,entries:Array.isArray(entries)?entries:[]});
 }
 if(path==='/api/finance/action'&&request.method==='POST'){
  const input=await c.readJson(request),action=String(input.action||''),data=input.data||{};
  const billingActions=['billing_profile_create','billing_run_preview','billing_run_execute','billing_exemption_create','billing_exemption_revoke','billing_exemption_mass_preview','billing_exemption_mass_apply','billing_withdrawal_approve','billing_settings_save'];
  if(!['topup_quote','topup_request','withdraw_request','withdrawal_review','withdrawal_reject','admin_adjust','admin_confirm_topup','admin_process_withdrawal','settings_save','benefit_create','reconcile',...billingActions].includes(action))return c.json({message:'Ação financeira inválida.'},400);
  if(action==='admin_adjust')return reply(await c.upstream('/rest/v1/rpc/vuppi_admin_wallet_adjust',{method:'POST',token:s.access,body:{p_wallet:data.wallet_id,p_direction:data.direction,p_amount_cents:Number(data.amount_cents),p_reason:data.reason,p_idempotency_key:data.idempotency_key},carErrors:true}));
  if(action==='settings_save')return reply(await c.upstream('/rest/v1/rpc/vuppi_finance_settings_admin',{method:'POST',token:s.access,body:{p_data:data},carErrors:true}));
  if(action==='withdraw_request')await c.upstream('/rest/v1/rpc/vuppi_withdrawal_clear_stale',{method:'POST',token:s.access,body:{},carErrors:false});
  if(action==='withdrawal_review'){const provider=c.paymentProvider();if(provider.name!=='mercadopago'||!provider.payoutsEnabled||!provider.payoutPrivateKey)throw Error('Ative Mercado Pago Payouts e configure a assinatura Ed25519 antes de liberar o saque.');const reviewed=await c.upstream('/rest/v1/rpc/vuppi_withdrawal_review',{method:'POST',token:s.access,body:{p_id:data.id,p_reason:data.reason},carErrors:true});if(reviewed?.status==='processing')return reply(await syncMercadoPagoWithdrawal(c,data.id));return reply(reviewed)}
  if(action==='withdrawal_reject')return reply(await c.upstream('/rest/v1/rpc/vuppi_withdrawal_reject',{method:'POST',token:s.access,body:{p_id:data.id,p_reason:data.reason},carErrors:true}));
  if(billingActions.includes(action))return reply(await billingRpc(action.replace('billing_',''),data));
  if(action==='topup_request'){
   const created=await rpc(action,data),provider=c.paymentProvider();
   if(provider.name==='mercadopago'){
    const charge=await provider.createPixPayment({externalReference:created.id,value:Number(created.total_cents)/100,email:user.email});
    await serviceRpc(c.env,c.fetcher,'vuppi_mercadopago_link',{p_topup:created.id,p_preference_id:charge.reference,p_checkout_url:charge.ticket_url||'https://www.mercadopago.com.br',p_live_mode:charge.live_mode});
    return reply({...created,provider:charge,qr_code:charge.qr_code,qr_code_base64:charge.qr_code_base64,ticket_url:charge.ticket_url,expires_at:charge.expires_at,simulation:false});
   }
   const charge=await provider.createPixCharge({externalReference:created.id,value:Number(created.total_cents)/100,description:'Créditos Vuppi Delivery'});
   if(provider.name==='fake')return reply({...created,provider:charge,simulation:true});
  }
  if(action==='withdraw_request'){
   const pix=normalizePixKey(data.pix_key||data.pix_key_masked),created=await rpc(action,{...data,pix_key_masked:pix.masked});await serviceRpc(c.env,c.fetcher,'vuppi_withdrawal_store_pix',{p_id:created.id,p_key:pix.key,p_type:pix.type});return reply({...created,pix_key_masked:pix.masked,provider_status:'awaiting_approval',message:'Saque reservado e pronto para aprovação segura.'});
  }
  if(action==='admin_process_withdrawal')return reply(await syncMercadoPagoWithdrawal(c,data.id));
  return reply(await rpc(action,data));
 }
 return c.json({message:'Recurso financeiro não encontrado.'},404);
}
