export type User = { id: string; email: string };

export type CourierProfile = {
  user_id?: string;
  kind: 'courier' | 'merchant';
  name: string;
  phone?: string;
  city?: string;
  address?: string;
  approved?: boolean;
  is_available?: boolean;
  avatar_data?: string;
  vehicle_model?: string;
  vehicle_plate?: string;
};

export type Delivery = {
  id: string;
  courier?: string | null;
  merchant?: string;
  merchant_name?: string;
  recipient?: string;
  phone?: string;
  status: 'requested' | 'assigned' | 'collected' | 'delivered' | 'cancelled';
  pickup_address?: string;
  pickup_lat?: number;
  pickup_lng?: number;
  pickup_arrived_at?: string | null;
  destination?: string;
  lat?: number;
  lng?: number;
  distance_m?: number;
  duration_s?: number;
  price_cents?: number;
  payment_method?: string;
  cash_to_collect_cents?: number;
  notes?: string;
  return_required?: boolean;
  return_started_at?: string | null;
  route_polyline?: string;
  external_order_number?: string;
  created_at?: string;
};

export type DeliveryState = {
  admin?: boolean;
  profile?: CourierProfile | null;
  orders?: Delivery[];
  offers?: Delivery[];
};

export type Tracking = {
  status?: Delivery['status'];
  courier_lat?: number;
  courier_lng?: number;
  courier_updated_at?: string;
  pickup_address?: string;
  pickup_city?: string;
  pickup_lat?: number;
  pickup_lng?: number;
  destination?: string;
  destination_lat?: number;
  destination_lng?: number;
  merchant_phone?: string;
  courier_name?: string;
  courier_avatar?: string;
};

export type RootTab = 'map' | 'deliveries' | 'wallet' | 'profile';
