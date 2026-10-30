// Cálculo puro para preparação da liquidação agrupada; não movimenta carteiras.
// O preço congelado de cada cotação já contém sua própria taxa de retorno.
export function calculateGroupedSettlement(deliveries) {
 if (!Array.isArray(deliveries) || deliveries.length<1 || deliveries.length>24)
  throw new Error('A rota deve conter entre 1 e 24 entregas.');
 const ids=new Set(), fees=[]; let subtotal=0;
 for(const delivery of deliveries){
  if(!delivery || typeof delivery.id!=='string' || !delivery.id.trim() || ids.has(delivery.id))
   throw new Error('Identificadores de entrega ausentes ou duplicados.');
  ids.add(delivery.id);
  const price=delivery.frozen_price_cents;
  if(!Number.isSafeInteger(price) || price<0)throw new Error('Preço congelado inválido.');
  if(typeof delivery.return_required!=='boolean')throw new Error('Regra de retorno não informada.');
  let fee=0;
  if(delivery.return_required){
   fee=delivery.frozen_return_cents;
   if(!Number.isSafeInteger(fee)||fee<0||fee>price)throw new Error('Snapshot da taxa de retorno ausente ou inválido.');
   fees.push(fee);
  }
  subtotal+=price-fee;
  if(!Number.isSafeInteger(subtotal))throw new Error('Total fora do limite seguro.');
 }
 if(new Set(fees).size>1)throw new Error('Taxas de retorno diferentes exigem definição administrativa antes da junção.');
 const returnFee=fees[0]??0,total=subtotal+returnFee;
 if(!Number.isSafeInteger(total))throw new Error('Total fora do limite seguro.');
 return {delivery_subtotal_cents:subtotal,requires_return:fees.length>0,return_fee_cents:returnFee,gross_cents:total,delivery_count:deliveries.length};
}
