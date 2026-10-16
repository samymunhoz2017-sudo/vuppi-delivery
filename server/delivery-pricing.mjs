// Espelho puro do cálculo executado no banco. Valores monetários em centavos.
export function quoteDelivery({distanceM,cityId,establishmentId,returnRequired=false},tariff){
 if(!Number.isSafeInteger(distanceM)||distanceM<=0)throw Error('Distância da rota inválida.');
 if(!tariff||tariff.cityId!==cityId||!cityId||!tariff.enabled)throw Error('Tarifa indisponível para esta cidade.');
 if(tariff.establishmentId&&tariff.establishmentId!==establishmentId)throw Error('Tarifa não pertence ao estabelecimento.');
 if(typeof returnRequired!=='boolean')throw Error('Opção de retorno inválida.');
 const integer=(v,label,{min=0,max=1000000}={})=>{if(!Number.isSafeInteger(v)||v<min||v>max)throw Error(label+' inválido.');return v};
 const baseDistanceM=integer(tariff.baseDistanceM,'Distância base',{max:30000}),baseCents=integer(tariff.baseCents,'Preço base'),stepM=integer(tariff.additionalStepM,'Intervalo adicional',{min:100,max:5000}),stepCents=integer(tariff.additionalStepCents,'Preço adicional'),minimumCents=integer(tariff.minimumCents,'Preço mínimo'),maximumDistanceM=integer(tariff.maximumDistanceM,'Distância máxima',{min:1000,max:100000}),returnCents=integer(tariff.returnCents??0,'Taxa de retorno');
 if(maximumDistanceM<=baseDistanceM)throw Error('A distância máxima deve superar a distância base.');
 if(distanceM>maximumDistanceM)throw Error('Rota fora do limite de atendimento da tarifa.');
 const calculatedSteps=Math.ceil(Math.max(0,distanceM-baseDistanceM)/stepM),subtotalCents=Math.max(minimumCents,baseCents+calculatedSteps*stepCents),totalCents=subtotalCents+(returnRequired?returnCents:0);
 integer(totalCents,'Valor calculado');
 return {cityId,distanceM,totalCents,subtotalCents,returnRequired,returnCents:returnRequired?returnCents:0,snapshot:{version:integer(tariff.version,'Versão',{min:1,max:1000000}),method:'base_plus_steps',baseDistanceM,baseCents,stepM,stepCents,minimumCents,maximumDistanceM,calculatedSteps,returnCents:returnRequired?returnCents:0,totalCents}};
}
