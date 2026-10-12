// Motor de preço para entregas de moto. Valores monetários em centavos.
// Recebe distância de uma rota verificada no servidor, nunca do formulário público.
export function quoteDelivery({distanceM, cityId, establishmentId, returnRequired=false}, tariff) {
  if (!Number.isSafeInteger(distanceM) || distanceM <= 0) throw Error('Distância da rota inválida.');
  if (!tariff || tariff.cityId !== cityId || !cityId || !tariff.enabled) throw Error('Tarifa indisponível para esta cidade.');
  if (tariff.establishmentId && tariff.establishmentId !== establishmentId) throw Error('Tarifa não pertence ao estabelecimento.');
  if (typeof returnRequired !== 'boolean') throw Error('Opção de retorno inválida.');
  const money = value => { if (!Number.isSafeInteger(value) || value < 0 || value > 10000000) throw Error('Valor da tarifa inválido.'); return value; };
  if (!Array.isArray(tariff.bands) || !tariff.bands.length || tariff.bands.length > 100) throw Error('Cadastre as faixas de distância.');
  let previous = 0;
  for (const band of tariff.bands) {
    if (!Number.isSafeInteger(band.upToM) || band.upToM <= previous || band.upToM > 500000) throw Error('As faixas devem ter limites crescentes.');
    previous = band.upToM; money(band.priceCents);
  }
  const band = tariff.bands.find(b => distanceM <= b.upToM);
  if (!band) throw Error('Rota fora do limite de atendimento da tarifa.');
  const returnCents = money(tariff.returnCents ?? 0);
  const totalCents = band.priceCents + (returnRequired ? returnCents : 0);
  money(totalCents);
  if (typeof tariff.version !== 'string' || !tariff.version.trim()) throw Error('Informe a versão da tarifa.');
  return {cityId, distanceM, totalCents, returnRequired,
    snapshot:{version:tariff.version, method:'distance_bands', upToM:band.upToM, priceCents:band.priceCents, returnCents:returnRequired ? returnCents : 0}};
}
