-- Diagnóstico somente de leitura. Execute primeiro em desenvolvimento/homologação.
-- Valores sinalizados são riscos para revisão, não comprovam cobrança indevida.
with deliveries as (
 select d.route_group_id,d.id,d.merchant,d.city,d.status,d.return_required,
        d.return_started_at,d.return_completed_at,d.price_cents,d.quote_id,
        case when q.pricing_snapshot->>'return_cents' ~ '^[0-9]+$'
             then (q.pricing_snapshot->>'return_cents')::bigint end as frozen_return_cents
 from public.vuppi_deliveries d
 left join public.vuppi_quotes q on q.id=d.quote_id
 where d.route_group_id is not null
), group_summary as (
 select route_group_id,min(city) as city,
        array_agg(id order by id) as delivery_ids,
        count(*) as delivery_count,count(distinct merchant) as merchant_count,
        count(*) filter(where return_required) as return_requested_count,
        count(*) filter(where return_started_at is not null) as return_started_count,
        count(*) filter(where return_completed_at is not null) as return_confirmed_count,
        count(*) filter(where status not in ('delivered','cancelled')) as open_delivery_count,
        count(*) filter(where return_required and frozen_return_cents is null) as missing_return_snapshots,
        sum(price_cents)::bigint as recorded_delivery_total_cents,
        sum(frozen_return_cents) filter(where return_required) as quoted_return_total_cents,
        max(frozen_return_cents) filter(where return_required) as largest_quoted_return_cents
 from deliveries group by route_group_id
), transactions as (
 select d.route_group_id,count(t.id) as transaction_count,
        count(t.id) filter(where t.type='delivery_courier_credit') as courier_credit_count,
        count(t.id) filter(where t.type='delivery_platform_revenue') as platform_revenue_count
 from deliveries d join public.vuppi_financial_transactions t on t.delivery_id=d.id
 group by d.route_group_id
)
select g.*,coalesce(t.transaction_count,0) as transaction_count,
       coalesce(t.courier_credit_count,0) as courier_credit_count,
       coalesce(t.platform_revenue_count,0) as platform_revenue_count,
       case when g.open_delivery_count>0 then 'operacao_aberta' else 'revisao_historica' end as review_category
from group_summary g left join transactions t using(route_group_id)
where g.return_requested_count>1 or g.return_started_count>1 or g.return_confirmed_count>1
   or (g.return_requested_count>0 and g.missing_return_snapshots>0)
order by g.open_delivery_count desc,g.route_group_id;
