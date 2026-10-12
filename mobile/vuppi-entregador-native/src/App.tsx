import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  ActivityIndicator, Alert, AppState, BackHandler, FlatList, Image, KeyboardAvoidingView,
  Linking, Modal, Platform, Pressable, RefreshControl, ScrollView, StyleSheet, Text, TextInput, View
} from 'react-native';
import MapView, { Marker, Polyline, PROVIDER_GOOGLE, type Region } from 'react-native-maps';
import { SafeAreaProvider, SafeAreaView, useSafeAreaInsets } from 'react-native-safe-area-context';
import { StatusBar } from 'expo-status-bar';
import * as SplashScreen from 'expo-splash-screen';
import * as Location from 'expo-location';
import * as Haptics from 'expo-haptics';
import * as ImagePicker from 'expo-image-picker';
import * as Notifications from 'expo-notifications';
import AsyncStorage from '@react-native-async-storage/async-storage';
import { useNetInfo } from '@react-native-community/netinfo';
import {
  ApiError, deliveryAction, deliveryState, restoreSession, signIn, signOut, signUp, tracking
} from './api';
import {
  configureNotifications, flushPendingLocation, notifyCompleted, notifyOffer,
  requestForegroundLocation, startCourierTracking, stopActiveDeliveryTracking
} from './native';
import { decodePolyline, type Point } from './polyline';
import { colors, radius, spacing } from './theme';
import type { CourierProfile, Delivery, DeliveryState, RootTab, Tracking, User } from './types';

SplashScreen.preventAutoHideAsync().catch(() => undefined);

const CACHE_KEY = 'vuppi.native.delivery-state.v1';
const PITANGUEIRAS: Region = { latitude: -21.0106, longitude: -48.2217, latitudeDelta: .055, longitudeDelta: .055 };
const money = (cents = 0) => (Number(cents) / 100).toLocaleString('pt-BR', { style: 'currency', currency: 'BRL' });
const activeStatus = (order?: Delivery) => order && ['assigned', 'collected'].includes(order.status);
const statusLabel = (order: Delivery) => order.status === 'assigned'
  ? (order.pickup_arrived_at ? 'No estabelecimento' : 'A caminho da coleta')
  : order.status === 'collected' ? (order.return_required && order.return_started_at ? 'Retornando ao estabelecimento' : 'A caminho do destino')
    : order.status === 'delivered' ? 'Entregue' : order.status === 'cancelled' ? 'Cancelada' : 'Aguardando';

function Button({ title, onPress, disabled, tone = 'primary', compact = false }: {
  title: string; onPress: () => void; disabled?: boolean; tone?: 'primary' | 'secondary' | 'danger' | 'quiet'; compact?: boolean;
}) {
  return <Pressable accessibilityRole="button" disabled={disabled} onPress={onPress}
    style={({ pressed }) => [styles.button, styles[`button_${tone}`], compact && styles.buttonCompact, disabled && styles.disabled, pressed && !disabled && styles.pressed]}>
    {disabled ? <ActivityIndicator color={tone === 'primary' ? colors.white : colors.purple} /> : <Text style={[styles.buttonText, tone !== 'primary' && styles[`buttonText_${tone}`]]}>{title}</Text>}
  </Pressable>;
}

function OfflineBanner({ reconnecting }: { reconnecting: boolean }) {
  return <View style={styles.offline}><Text>{reconnecting ? 'Reconectando à central…' : 'Sem internet · mostrando os dados salvos'}</Text></View>;
}

function LoginScreen({ onAuthenticated }: { onAuthenticated: (user: User) => void }) {
  const [mode, setMode] = useState<'login' | 'signup'>('login');
  const [name, setName] = useState(''); const [email, setEmail] = useState(''); const [password, setPassword] = useState('');
  const [busy, setBusy] = useState(false); const [error, setError] = useState('');
  const submit = async () => {
    setBusy(true); setError('');
    try { onAuthenticated(mode === 'login' ? await signIn(email, password) : await signUp(name, email, password)); }
    catch (e) { setError(e instanceof Error ? e.message : 'Não foi possível entrar.'); }
    finally { setBusy(false); }
  };
  return <KeyboardAvoidingView style={styles.loginPage} behavior={Platform.OS === 'ios' ? 'padding' : undefined}>
    <StatusBar style="light" />
    <View style={styles.loginGlow} />
    <View style={styles.loginBrand}><Image source={require('../assets/logo.png')} style={styles.loginLogo as any} resizeMode="contain" /><Text style={styles.loginBrandTitle}>VUPPI</Text><Text style={styles.loginBrandSub}>DELIVERY</Text></View>
    <View style={styles.loginCard}>
      <Text style={styles.eyebrow}>{mode === 'login' ? 'APLICATIVO DO ENTREGADOR' : 'NOVO ENTREGADOR'}</Text>
      <Text style={styles.loginTitle}>{mode === 'login' ? 'Bom trabalho.' : 'Comece com a VUPPI.'}</Text>
      <Text style={styles.loginCopy}>{mode === 'login' ? 'Entre para receber e acompanhar suas entregas.' : 'Crie sua conta. O cadastro operacional será concluído no próximo passo.'}</Text>
      {mode === 'signup' && <Field label="Nome completo" value={name} onChangeText={setName} autoCapitalize="words" />}
      <Field label="E-mail" value={email} onChangeText={setEmail} keyboardType="email-address" autoCapitalize="none" autoComplete="email" />
      <Field label="Senha" value={password} onChangeText={setPassword} secureTextEntry autoCapitalize="none" autoComplete={mode === 'login' ? 'current-password' : 'new-password'} />
      {!!error && <Text style={styles.error}>{error}</Text>}
      <Button title={mode === 'login' ? 'Entrar' : 'Criar conta'} onPress={submit} disabled={busy || !email || !password || (mode === 'signup' && !name)} />
      <Pressable onPress={() => { setMode(mode === 'login' ? 'signup' : 'login'); setError(''); }} style={styles.textAction}><Text>{mode === 'login' ? 'Primeiro acesso? Criar conta' : 'Já tenho conta'}</Text></Pressable>
      {mode === 'login' && <Pressable onPress={() => Linking.openURL('mailto:suporte@vuppidelivery.com.br?subject=Recuperar%20acesso')} style={styles.textAction}><Text>Esqueci minha senha</Text></Pressable>}
    </View>
    <Text style={styles.loginFoot}>Sessão protegida no aparelho · v0.52</Text>
  </KeyboardAvoidingView>;
}

function Field(props: React.ComponentProps<typeof TextInput> & { label: string }) {
  const { label, ...input } = props;
  return <View style={styles.field}><Text style={styles.fieldLabel}>{label}</Text><TextInput {...input} placeholderTextColor="#9B92A4" style={styles.input} /></View>;
}

function Registration({ user, onSaved }: { user: User; onSaved: () => Promise<void> }) {
  const [name, setName] = useState(''); const [phone, setPhone] = useState(''); const [address, setAddress] = useState('');
  const [vehicle, setVehicle] = useState(''); const [plate, setPlate] = useState(''); const [busy, setBusy] = useState(false);
  const save = async () => {
    setBusy(true);
    try {
      const pos = await requestForegroundLocation();
      await deliveryAction('register', { kind: 'courier', name, phone, city: 'pitangueiras-sp', address, vehicle_model: vehicle, vehicle_plate: plate, lat: pos.coords.latitude, lng: pos.coords.longitude });
      await onSaved();
    } catch (e) { Alert.alert('Não foi possível concluir', e instanceof Error ? e.message : 'Tente novamente.'); }
    finally { setBusy(false); }
  };
  return <SafeAreaView style={styles.page}><ScrollView contentContainerStyle={styles.formPage} keyboardShouldPersistTaps="handled">
    <Text style={styles.eyebrow}>CADASTRO OPERACIONAL</Text><Text style={styles.pageTitle}>Configure seu perfil</Text><Text style={styles.paragraph}>Precisamos destes dados para identificar você nas entregas. Sua conta: {user.email}</Text>
    <Field label="Nome completo" value={name} onChangeText={setName} />
    <Field label="Telefone" value={phone} onChangeText={setPhone} keyboardType="phone-pad" />
    <Field label="Endereço completo" value={address} onChangeText={setAddress} />
    <Field label="Modelo da moto" value={vehicle} onChangeText={setVehicle} />
    <Field label="Placa" value={plate} onChangeText={setPlate} autoCapitalize="characters" />
    <View style={styles.infoBox}><Text style={styles.infoTitle}>Localização necessária</Text><Text>Usamos sua posição para encontrar entregas próximas e atualizar a rota durante um atendimento.</Text></View>
    <Button title="Enviar cadastro" onPress={save} disabled={busy || !name || !phone || !address || !vehicle || !plate} />
  </ScrollView></SafeAreaView>;
}

function Header({ profile, balance, onMenu, onWallet }: { profile: CourierProfile; balance: number; onMenu: () => void; onWallet: () => void }) {
  return <View style={styles.floatingHeader}>
    <Pressable onPress={onMenu} style={styles.identityButton}>{profile.avatar_data ? <Image source={{ uri: profile.avatar_data }} style={styles.avatarSmall as any} /> : <View style={styles.avatarSmallFallback}><Text>{profile.name?.slice(0, 1) || 'V'}</Text></View>}<Text style={styles.menuGlyph}>☰</Text></Pressable>
    <Pressable onPress={onWallet} style={styles.walletPill}><Text style={styles.walletPillText}>{money(balance)} ›</Text></Pressable>
  </View>;
}

function NativeMap({ location, active, track }: { location?: Point; active?: Delivery; track?: Tracking }) {
  const map = useRef<MapView>(null);
  const activeVisible = Boolean(active);
  const pickup = useMemo(() => active && Number.isFinite(Number(track?.pickup_lat ?? active.pickup_lat)) ? { latitude: Number(track?.pickup_lat ?? active.pickup_lat), longitude: Number(track?.pickup_lng ?? active.pickup_lng) } : undefined, [active, track?.pickup_lat, track?.pickup_lng]);
  const destination = useMemo(() => active && Number.isFinite(Number(track?.destination_lat ?? active.lat)) ? { latitude: Number(track?.destination_lat ?? active.lat), longitude: Number(track?.destination_lng ?? active.lng) } : undefined, [active, track?.destination_lat, track?.destination_lng]);
  const courier = useMemo(() => Number.isFinite(Number(track?.courier_lat)) ? { latitude: Number(track?.courier_lat), longitude: Number(track?.courier_lng) } : location, [location, track?.courier_lat, track?.courier_lng]);
  const route = active?.route_polyline ? decodePolyline(active.route_polyline) : [courier, active?.status === 'collected' ? destination : pickup].filter(Boolean) as Point[];
  useEffect(() => {
    const points = [courier, pickup, destination].filter(Boolean) as Point[];
    if (points.length) setTimeout(() => map.current?.fitToCoordinates(points, { edgePadding: { top: 140, right: 50, bottom: activeVisible ? 390 : 150, left: 50 }, animated: true }), 250);
  }, [active?.id, active?.status, activeVisible, courier, destination, pickup]);
  return <MapView ref={map} style={StyleSheet.absoluteFill} provider={Platform.OS === 'android' ? PROVIDER_GOOGLE : undefined} initialRegion={location ? { ...location, latitudeDelta: .035, longitudeDelta: .035 } : PITANGUEIRAS} showsCompass={false} showsMyLocationButton={false} rotateEnabled={false} toolbarEnabled={false}>
    {courier && <Marker coordinate={courier} title="Sua posição" anchor={{ x: .5, y: .5 }}><View style={[styles.mapMarker, styles.mapMarkerCourier]}><Text>➤</Text></View></Marker>}
    {pickup && <Marker coordinate={pickup} title="Coleta"><View style={[styles.mapMarker, styles.mapMarkerPickup]}><Text>1</Text></View></Marker>}
    {destination && <Marker coordinate={destination} title="Destino"><View style={[styles.mapMarker, styles.mapMarkerDestination]}><Text style={{ color: '#fff' }}>2</Text></View></Marker>}
    {route.length > 1 && <Polyline coordinates={route} strokeColor={active?.status === 'collected' ? colors.green : colors.purple} strokeWidth={6} />}
  </MapView>;
}

function Progress({ order }: { order: Delivery }) {
  const arrived = !!order.pickup_arrived_at, collected = order.status === 'collected';
  const steps = [{ label: 'Aceite', done: true }, { label: 'Chegada', done: arrived || collected }, { label: 'Coleta', done: collected }, { label: order.return_required && order.return_started_at ? 'Retorno' : 'Destino', done: false }];
  return <View style={styles.progress}>{steps.map((step, index) => <React.Fragment key={step.label}><View style={styles.step}><View style={[styles.stepDot, step.done && styles.stepDone, !step.done && ((index === 1 && !arrived) || (index === 2 && arrived && !collected) || (index === 3 && collected)) && styles.stepCurrent]}><Text style={styles.stepNumber}>{step.done ? '✓' : index + 1}</Text></View><Text style={styles.stepLabel}>{step.label}</Text></View>{index < steps.length - 1 && <View style={[styles.stepLine, step.done && steps[index + 1]?.done && styles.stepLineDone]} />}</React.Fragment>)}</View>;
}

function ActiveDeliverySheet({ order, track, busy, onAdvance, onCancel, onClose }: { order: Delivery; track?: Tracking; busy: boolean; onAdvance: () => void; onCancel: () => void; onClose: () => void }) {
  const insets = useSafeAreaInsets(); const collected = order.status === 'collected'; const arrived = !!order.pickup_arrived_at;
  const title = collected ? 'Confirmar entrega concluída' : arrived ? 'Confirmar coleta' : 'Cheguei ao estabelecimento';
  const target = collected ? order.destination : order.pickup_address;
  const openRoute = () => Linking.openURL(`https://www.google.com/maps/dir/?api=1&destination=${encodeURIComponent(target || '')}&travelmode=two-wheeler`);
  return <View style={[styles.activeLayer, { paddingBottom: Math.max(insets.bottom, 10) }]}>
    <View style={styles.activeSheet}>
      <View style={styles.sheetHandle} /><View style={styles.activeHead}><Pressable onPress={onClose} style={styles.circleButton}><Text>↓</Text></Pressable><View><Text style={styles.eyebrow}>ENTREGA EM ANDAMENTO</Text><Text style={styles.activeTitle}>{statusLabel(order)}</Text></View></View>
      <View style={styles.metrics}><View><Text>Distância</Text><Text style={styles.metricValue}>{(Number(order.distance_m || 0) / 1000).toFixed(1)} km</Text></View><View><Text>Previsão</Text><Text style={styles.metricValue}>{Math.max(1, Math.ceil(Number(order.duration_s || 60) / 60))} min</Text></View></View>
      <View style={styles.stop}><View style={[styles.stopNumber, { backgroundColor: colors.purple }]}><Text style={{ color: '#fff' }}>1</Text></View><View style={styles.stopText}><Text style={styles.stopLabel}>COLETA NO ESTABELECIMENTO</Text><Text style={styles.stopAddress}>{track?.pickup_address || order.pickup_address || 'Endereço não informado'}</Text>{track?.merchant_phone && <Pressable onPress={() => Linking.openURL(`tel:${track.merchant_phone?.replace(/\D/g, '')}`)}><Text style={styles.phone}>Ligar para a loja · {track.merchant_phone}</Text></Pressable>}</View></View>
      <View style={styles.stop}><View style={[styles.stopNumber, { backgroundColor: colors.black }]}><Text style={{ color: '#fff' }}>2</Text></View><View style={styles.stopText}><Text style={styles.stopLabel}>DESTINO DO CLIENTE</Text><Text style={styles.stopAddress}>{track?.destination || order.destination || 'Endereço não informado'}</Text><Text style={styles.client}>{order.recipient || 'Cliente'} · {order.phone || 'Telefone não informado'}</Text>{order.phone && <Pressable onPress={() => Linking.openURL(`tel:${order.phone?.replace(/\D/g, '')}`)}><Text style={styles.phone}>Ligar para o cliente</Text></Pressable>}</View></View>
      <View style={styles.paymentRow}><Text>Pagamento</Text><Text style={styles.paymentValue}>{({ pix: 'Pix', cash: 'Dinheiro', credit: 'Cartão', wallet: 'Carteira' } as Record<string, string>)[order.payment_method || ''] || 'Pix'}{order.cash_to_collect_cents ? ` · cobrar ${money(order.cash_to_collect_cents)}` : ''}</Text></View>
      <View style={styles.actionRow}><View style={{ flex: 1 }}><Button title="Abrir rota" tone="secondary" onPress={openRoute} /></View><View style={{ flex: 1.65 }}><Button title={title} onPress={onAdvance} disabled={busy} /></View></View>
      <Pressable onPress={onCancel} disabled={busy} style={styles.cancelLink}><Text>Cancelar corrida</Text></Pressable>
    </View>
  </View>;
}

function OfferModal({ offer, busy, onAccept, onReject }: { offer?: Delivery; busy: boolean; onAccept: () => void; onReject: () => void }) {
  if (!offer) return null;
  return <Modal visible transparent animationType="slide" statusBarTranslucent><View style={styles.modalScrim}><View style={styles.offerSheet}><View style={styles.offerIcon}><Text>⚡</Text></View><Text style={styles.eyebrow}>NOVA ENTREGA</Text><Text style={styles.offerTitle}>{offer.merchant_name || 'Entrega VUPPI'}</Text><View style={styles.offerValue}><Text>{money(offer.price_cents)}</Text><Text>{(Number(offer.distance_m || 0) / 1000).toFixed(1)} km</Text></View><View style={styles.offerStop}><Text style={styles.offerIndex}>1</Text><View><Text style={styles.stopLabel}>COLETA</Text><Text style={styles.offerAddress}>{offer.pickup_address || offer.merchant_name}</Text></View></View><View style={styles.offerStop}><Text style={[styles.offerIndex, { backgroundColor: colors.black }]}>2</Text><View><Text style={styles.stopLabel}>ENTREGA</Text><Text style={styles.offerAddress}>{offer.destination || 'Endereço disponível ao aceitar'}</Text></View></View><View style={styles.actionRow}><View style={{ flex: 1 }}><Button title="Agora não" tone="quiet" onPress={onReject} disabled={busy} /></View><View style={{ flex: 1.5 }}><Button title="Aceitar entrega" onPress={onAccept} disabled={busy} /></View></View></View></View></Modal>;
}

function DeliveryList({ rows, refreshing, onRefresh, onOpen }: { rows: Delivery[]; refreshing: boolean; onRefresh: () => void; onOpen: (row: Delivery) => void }) {
  return <FlatList contentContainerStyle={styles.listContent} data={rows} keyExtractor={item => item.id} refreshControl={<RefreshControl refreshing={refreshing} onRefresh={onRefresh} tintColor={colors.purple} />} ListHeaderComponent={<><Text style={styles.eyebrow}>MINHAS ENTREGAS</Text><Text style={styles.pageTitle}>Acompanhe seu trabalho</Text></>} ListEmptyComponent={<View style={styles.empty}><Text style={styles.emptyIcon}>□</Text><Text style={styles.infoTitle}>Nenhuma entrega por aqui</Text><Text>As novas ofertas aparecem automaticamente quando você está livre.</Text></View>} renderItem={({ item }) => <Pressable onPress={() => onOpen(item)} style={styles.deliveryCard}><View style={styles.deliveryCardTop}><Text style={styles.deliveryId}>#{item.external_order_number || item.id.slice(0, 8).toUpperCase()}</Text><Text style={[styles.statusPill, item.status === 'delivered' && styles.statusDone]}>{statusLabel(item)}</Text></View><Text style={styles.deliveryMerchant}>{item.merchant_name || 'Estabelecimento'}</Text><Text style={styles.deliveryAddress}>{item.destination}</Text><View style={styles.deliveryCardFoot}><Text>{item.created_at ? new Date(item.created_at).toLocaleDateString('pt-BR') : 'Data não informada'}</Text><Text style={styles.deliveryPrice}>{money(item.price_cents)}</Text></View></Pressable>} />;
}

function Wallet({ rows, profile }: { rows: Delivery[]; profile: CourierProfile }) {
  const done = rows.filter(row => row.status === 'delivered'); const balance = done.reduce((sum, row) => sum + Number(row.price_cents || 0), 0);
  return <ScrollView contentContainerStyle={styles.listContent}><Text style={styles.eyebrow}>CARTEIRA VUPPI</Text><Text style={styles.pageTitle}>Seus ganhos</Text><View style={styles.profileRow}>{profile.avatar_data ? <Image source={{ uri: profile.avatar_data }} style={styles.avatarLarge as any} /> : <View style={styles.avatarLargeFallback}><Text>{profile.name?.slice(0, 1)}</Text></View>}<View><Text style={styles.profileName}>{profile.name}</Text><Text>{profile.city || 'Pitangueiras, SP'}</Text></View></View><View style={styles.balanceCard}><Text>Disponível no período</Text><Text style={styles.balanceValue}>{money(balance)}</Text><Text>{done.length} {done.length === 1 ? 'entrega concluída' : 'entregas concluídas'}</Text></View><Text style={styles.sectionTitle}>Movimentações</Text>{done.slice(0, 20).map(row => <View key={row.id} style={styles.statement}><View><Text style={styles.statementTitle}>Entrega #{row.external_order_number || row.id.slice(0, 8)}</Text><Text>{row.created_at ? new Date(row.created_at).toLocaleDateString('pt-BR') : 'Data não informada'}</Text></View><Text style={styles.statementValue}>+ {money(row.price_cents)}</Text></View>)}{!done.length && <View style={styles.empty}><Text>As entregas concluídas aparecerão aqui.</Text></View>}</ScrollView>;
}

function Profile({ profile, busy, onPhoto, onLogout }: { profile: CourierProfile; busy: boolean; onPhoto: (camera: boolean) => void; onLogout: () => void }) {
  return <ScrollView contentContainerStyle={styles.listContent}><Text style={styles.eyebrow}>SEU PERFIL</Text><Text style={styles.pageTitle}>Cadastro do entregador</Text><View style={styles.profileHero}>{profile.avatar_data ? <Image source={{ uri: profile.avatar_data }} style={styles.avatarHero as any} /> : <View style={styles.avatarHeroFallback}><Text>{profile.name?.slice(0, 1)}</Text></View>}<Text style={styles.profileHeroName}>{profile.name}</Text><Text>{profile.vehicle_model || 'Moto'} · {profile.vehicle_plate || 'Placa não informada'}</Text><View style={styles.actionRow}><Button title="Tirar foto" tone="secondary" compact onPress={() => onPhoto(true)} disabled={busy} /><Button title="Escolher foto" tone="secondary" compact onPress={() => onPhoto(false)} disabled={busy} /></View></View><View style={styles.infoGrid}><Info label="Telefone" value={profile.phone} /><Info label="Cidade" value={profile.city} /><Info label="Endereço" value={profile.address} /><Info label="Situação" value={profile.approved ? 'Cadastro aprovado' : 'Em análise'} /></View><Button title="Sair deste aparelho" tone="danger" onPress={onLogout} /></ScrollView>;
}
function Info({ label, value }: { label: string; value?: string | boolean }) { return <View style={styles.infoItem}><Text>{label}</Text><Text style={styles.infoValue}>{String(value || 'Não informado')}</Text></View>; }

function BottomTabs({ value, onChange }: { value: RootTab; onChange: (tab: RootTab) => void }) {
  const tabs: { id: RootTab; icon: string; label: string }[] = [{ id: 'map', icon: '●', label: 'Mapa' }, { id: 'deliveries', icon: '▣', label: 'Entregas' }, { id: 'wallet', icon: '◉', label: 'Carteira' }, { id: 'profile', icon: '☺', label: 'Perfil' }];
  return <View style={styles.tabs}>{tabs.map(tab => <Pressable key={tab.id} onPress={() => onChange(tab.id)} style={styles.tab}><Text style={[styles.tabIcon, value === tab.id && styles.tabActive]}>{tab.icon}</Text><Text style={[styles.tabLabel, value === tab.id && styles.tabActive]}>{tab.label}</Text></Pressable>)}</View>;
}

function CourierApp({ user, onLogout }: { user: User; onLogout: () => void }) {
  const [data, setData] = useState<DeliveryState>({}); const [tab, setTab] = useState<RootTab>('map'); const [activeId, setActiveId] = useState('');
  const [trackingData, setTrackingData] = useState<Tracking>(); const [location, setLocation] = useState<Point>(); const [busy, setBusy] = useState(false); const [refreshing, setRefreshing] = useState(false); const [reconnecting, setReconnecting] = useState(false); const [rejected, setRejected] = useState<Set<string>>(new Set());
  const net = useNetInfo(); const seenOffer = useRef(''); const locationSubscription = useRef<Location.LocationSubscription | null>(null);
  const profile = data.profile; const orders = (data.orders || []).filter(row => row.courier === user.id); const active = orders.find(row => row.id === activeId) || orders.find(activeStatus);
  const offer = (data.offers || []).find(row => !rejected.has(row.id)); const balance = orders.filter(row => row.status === 'delivered').reduce((sum, row) => sum + Number(row.price_cents || 0), 0);
  const sync = useCallback(async (manual = false) => {
    if (manual) setRefreshing(true); setReconnecting(true);
    try { const next = await deliveryState(); setData(next); await AsyncStorage.setItem(CACHE_KEY, JSON.stringify(next)); if (next.profile?.kind && next.profile.kind !== 'courier') throw new ApiError('Esta conta pertence ao painel do estabelecimento.', 403); }
    catch (e) { const cached = await AsyncStorage.getItem(CACHE_KEY); if (cached) setData(current => current.profile ? current : JSON.parse(cached)); if (manual) Alert.alert('Atualização indisponível', e instanceof Error ? e.message : 'Tente novamente.'); }
    finally { setRefreshing(false); setReconnecting(false); }
  }, []);
  useEffect(() => { const start = setTimeout(() => sync(), 0); configureNotifications().catch(() => undefined); flushPendingLocation().catch(() => undefined); const timer = setInterval(() => { if (AppState.currentState === 'active') sync(); }, 6000); return () => { clearTimeout(start); clearInterval(timer); }; }, [sync]);
  useEffect(() => {
    let mounted = true;
    requestForegroundLocation().then(pos => { if (mounted) setLocation({ latitude: pos.coords.latitude, longitude: pos.coords.longitude }); }).catch(() => undefined);
    Location.watchPositionAsync({ accuracy: Location.Accuracy.Balanced, distanceInterval: 25, timeInterval: 15000 }, pos => { setLocation({ latitude: pos.coords.latitude, longitude: pos.coords.longitude }); deliveryAction('location', { lat: pos.coords.latitude, lng: pos.coords.longitude }).catch(() => undefined); }).then(sub => locationSubscription.current = sub).catch(() => undefined);
    return () => { mounted = false; locationSubscription.current?.remove(); };
  }, []);
  useEffect(() => {
    if (active) { const open = setTimeout(() => setActiveId(active.id), 0); startCourierTracking(true).catch(() => undefined); const load = () => tracking(active.id).then(setTrackingData).catch(() => undefined); load(); const timer = setInterval(load, 10000); return () => { clearTimeout(open); clearInterval(timer); }; }
    if (profile?.is_available) startCourierTracking(false).catch(() => undefined);
    else stopActiveDeliveryTracking().catch(() => undefined);
    const clear = setTimeout(() => setTrackingData(undefined), 0); return () => clearTimeout(clear);
  }, [active, profile?.is_available]);
  useEffect(() => { if (offer && offer.id !== seenOffer.current) { seenOffer.current = offer.id; Haptics.notificationAsync(Haptics.NotificationFeedbackType.Warning); notifyOffer(`${offer.merchant_name || 'Estabelecimento'} · ${money(offer.price_cents)}`, offer.id).catch(() => undefined); } }, [offer]);
  useEffect(() => {
    const sub = Notifications.addNotificationResponseReceivedListener(response => { const id = String(response.notification.request.content.data?.id || ''); if (id) { setActiveId(id); setTab('map'); } if (response.notification.request.content.data?.type === 'wallet') setTab('wallet'); }); return () => sub.remove();
  }, []);
  useEffect(() => { const sub = BackHandler.addEventListener('hardwareBackPress', () => { if (activeId) { setActiveId(''); return true; } if (tab !== 'map') { setTab('map'); return true; } return false; }); return () => sub.remove(); }, [activeId, tab]);
  const act = async (action: string, payload: Record<string, unknown>, success?: () => void) => { if (busy) return; setBusy(true); try { await deliveryAction(action, payload); await Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success); await sync(); success?.(); } catch (e) { Alert.alert('Não foi possível concluir', e instanceof Error ? e.message : 'Tente novamente.'); } finally { setBusy(false); } };
  const advance = () => {
    if (!active) return;
    if (active.status === 'collected') act('complete', { id: active.id }, async () => { await stopActiveDeliveryTracking(); await notifyCompleted(money(active.price_cents)); setActiveId(''); setTab('wallet'); });
    else if (!active.pickup_arrived_at) act('arrive_pickup', { id: active.id }); else act('collect', { id: active.id });
  };
  const cancel = () => active && Alert.alert('Cancelar corrida?', 'Informe a central apenas quando realmente não puder continuar.', [{ text: 'Voltar', style: 'cancel' }, { text: 'Cancelar corrida', style: 'destructive', onPress: () => act('cancel', { id: active.id, reason: 'Cancelada pelo entregador no aplicativo' }, () => setActiveId('')) }]);
  const toggle = async () => {
    if (!profile) return;
    try { if (!profile.is_available) { const pos = await requestForegroundLocation(); await deliveryAction('location', { lat: pos.coords.latitude, lng: pos.coords.longitude }); } await act('availability', { available: !profile.is_available }); } catch (e) { Alert.alert('Localização necessária', e instanceof Error ? e.message : 'Verifique o GPS.'); }
  };
  const updatePhoto = async (camera: boolean) => {
    setBusy(true); try {
      if (camera) { const p = await ImagePicker.requestCameraPermissionsAsync(); if (!p.granted) throw Error('Permita o uso da câmera para tirar sua foto.'); }
      else { const p = await ImagePicker.requestMediaLibraryPermissionsAsync(); if (!p.granted) throw Error('Permita o acesso às fotos para escolher uma imagem.'); }
      const result = camera ? await ImagePicker.launchCameraAsync({ mediaTypes: ['images'], allowsEditing: true, aspect: [1, 1], quality: .5, base64: true }) : await ImagePicker.launchImageLibraryAsync({ mediaTypes: ['images'], allowsEditing: true, aspect: [1, 1], quality: .5, base64: true });
      if (result.canceled) return; const base64 = result.assets[0]?.base64; if (!base64) throw Error('Não foi possível preparar a foto.'); const photo = `data:image/jpeg;base64,${base64}`; if (photo.length > 540000) throw Error('A foto ficou muito grande. Escolha outra imagem.');
      await deliveryAction('profile_update', { avatar_data: photo }); await sync();
    } catch (e) { Alert.alert('Foto não atualizada', e instanceof Error ? e.message : 'Tente novamente.'); } finally { setBusy(false); }
  };
  if (!profile) return <Registration user={user} onSaved={() => sync(true)} />;
  if (profile.kind !== 'courier') return <SafeAreaView style={styles.page}><View style={styles.center}><Text style={styles.pageTitle}>Conta de outro painel</Text><Text style={styles.paragraph}>Este aplicativo é exclusivo para entregadores.</Text><Button title="Sair" onPress={onLogout} /></View></SafeAreaView>;
  return <SafeAreaView style={styles.app} edges={['top', 'left', 'right']}>
    <StatusBar style="dark" />
    {net.isConnected === false && <OfflineBanner reconnecting={reconnecting} />}
    <View style={styles.content}>
      {tab === 'map' && <View style={StyleSheet.absoluteFill}><NativeMap location={location} active={active} track={trackingData} /><Header profile={profile} balance={balance} onMenu={() => setTab('profile')} onWallet={() => setTab('wallet')} /><Pressable onPress={toggle} disabled={busy || !!active} style={[styles.availability, profile.is_available && styles.availabilityOn, active && styles.availabilityBusy]}><Text style={styles.availabilityText}>{active ? 'Entrega em andamento' : profile.is_available ? 'Ficar indisponível' : 'Ficar livre'}</Text></Pressable>{active && <Progress order={active} />}{active && activeId && <ActiveDeliverySheet order={active} track={trackingData} busy={busy} onAdvance={advance} onCancel={cancel} onClose={() => setActiveId('')} />}</View>}
      {tab === 'deliveries' && <DeliveryList rows={orders} refreshing={refreshing} onRefresh={() => sync(true)} onOpen={row => { if (activeStatus(row)) { setActiveId(row.id); setTab('map'); } else Alert.alert(`#${row.external_order_number || row.id.slice(0, 8)}`, `${statusLabel(row)}\n\n${row.destination || ''}`); }} />}
      {tab === 'wallet' && <Wallet rows={orders} profile={profile} />}
      {tab === 'profile' && <Profile profile={profile} busy={busy} onPhoto={updatePhoto} onLogout={onLogout} />}
    </View>
    {(!activeId || tab !== 'map') && <BottomTabs value={tab} onChange={setTab} />}
    <OfferModal offer={active ? undefined : offer} busy={busy} onReject={() => offer && setRejected(current => new Set(current).add(offer.id))} onAccept={() => offer && act('accept', { id: offer.id }, () => { setActiveId(offer.id); setTab('map'); })} />
  </SafeAreaView>;
}

function AppRoot() {
  const [phase, setPhase] = useState<'boot' | 'auth' | 'app'>('boot'); const [user, setUser] = useState<User>();
  useEffect(() => { let alive = true; (async () => { try { const restored = await restoreSession(); if (!alive) return; if (restored) { setUser(restored); setPhase('app'); } else setPhase('auth'); } catch { setPhase('auth'); } finally { await SplashScreen.hideAsync(); } })(); return () => { alive = false; }; }, []);
  if (phase === 'boot') return <View style={styles.splash}><Image source={require('../assets/logo.png')} style={styles.splashLogo as any} resizeMode="contain" /><ActivityIndicator color={colors.white} /></View>;
  if (phase === 'auth' || !user) return <LoginScreen onAuthenticated={next => { setUser(next); setPhase('app'); }} />;
  return <CourierApp user={user} onLogout={async () => { await signOut(); await AsyncStorage.removeItem(CACHE_KEY); setUser(undefined); setPhase('auth'); }} />;
}

export default function App() { return <SafeAreaProvider><AppRoot /></SafeAreaProvider>; }

const styles = StyleSheet.create({
  app: { flex: 1, backgroundColor: colors.white }, page: { flex: 1, backgroundColor: colors.surface }, content: { flex: 1 }, center: { flex: 1, justifyContent: 'center', padding: spacing.lg, gap: spacing.md }, paragraph: { color: colors.muted, fontSize: 16, lineHeight: 23 }, eyebrow: { color: colors.purple, fontSize: 11, fontWeight: '900', letterSpacing: 1.8 }, pageTitle: { color: colors.ink, fontSize: 30, lineHeight: 36, fontWeight: '800', letterSpacing: -.8, marginTop: 7, marginBottom: 10 },
  button: { minHeight: 52, borderRadius: radius.md, paddingHorizontal: 18, alignItems: 'center', justifyContent: 'center', backgroundColor: colors.purple }, buttonCompact: { minHeight: 44, paddingHorizontal: 14 }, button_primary: {}, button_secondary: { backgroundColor: colors.purpleSoft, borderWidth: 1, borderColor: '#DEC9F6' }, button_danger: { backgroundColor: '#FCEAEC', borderWidth: 1, borderColor: '#F4C6CD' }, button_quiet: { backgroundColor: colors.surface }, buttonText: { color: colors.white, fontSize: 15, fontWeight: '800' }, buttonText_secondary: { color: colors.purple }, buttonText_danger: { color: colors.red }, buttonText_quiet: { color: colors.ink }, disabled: { opacity: .55 }, pressed: { transform: [{ scale: .98 }], opacity: .9 },
  offline: { backgroundColor: '#FFF1C9', paddingVertical: 7, alignItems: 'center' }, loginPage: { flex: 1, backgroundColor: '#160821', justifyContent: 'center', padding: 22, overflow: 'hidden' }, loginGlow: { position: 'absolute', width: 460, height: 460, borderRadius: 230, backgroundColor: '#6F20D955', top: -210, right: -180 }, loginBrand: { alignItems: 'center', marginBottom: 28 }, loginLogo: { width: 72, height: 72 }, loginBrandTitle: { color: colors.white, fontSize: 19, fontWeight: '900', letterSpacing: 5, marginTop: 5 }, loginBrandSub: { color: '#BE8FFF', fontSize: 9, fontWeight: '900', letterSpacing: 4 }, loginCard: { backgroundColor: colors.white, borderRadius: radius.lg, padding: 24, shadowColor: '#000', shadowOpacity: .25, shadowRadius: 30, elevation: 10 }, loginTitle: { color: colors.ink, fontSize: 29, fontWeight: '800', marginTop: 7 }, loginCopy: { color: colors.muted, fontSize: 15, lineHeight: 22, marginTop: 5, marginBottom: 10 }, loginFoot: { color: '#B5A7C2', textAlign: 'center', fontSize: 11, marginTop: 18 }, field: { marginTop: 13 }, fieldLabel: { color: colors.ink, fontSize: 12, fontWeight: '800', marginBottom: 7 }, input: { borderWidth: 1, borderColor: colors.line, borderRadius: radius.sm, minHeight: 50, paddingHorizontal: 14, color: colors.ink, backgroundColor: '#FCFBFD', fontSize: 16 }, error: { color: colors.red, marginVertical: 10 }, textAction: { padding: 12, alignItems: 'center' },
  formPage: { padding: 24, paddingBottom: 50 }, infoBox: { backgroundColor: '#EEE5FA', padding: 16, borderRadius: radius.md, marginVertical: 18 }, infoTitle: { color: colors.ink, fontWeight: '800', fontSize: 16, marginBottom: 4 }, floatingHeader: { position: 'absolute', top: 16, left: 16, right: 16, flexDirection: 'row', justifyContent: 'space-between' }, identityButton: { flexDirection: 'row', alignItems: 'center', padding: 7, paddingRight: 14, gap: 9, backgroundColor: '#FFFFFFF2', borderRadius: radius.pill, shadowColor: '#2E1F39', shadowOpacity: .14, shadowRadius: 10, elevation: 6 }, avatarSmall: { width: 42, height: 42, borderRadius: 21 }, avatarSmallFallback: { width: 42, height: 42, borderRadius: 21, alignItems: 'center', justifyContent: 'center', backgroundColor: colors.purpleSoft }, menuGlyph: { fontSize: 22 }, walletPill: { backgroundColor: '#FFFFFFF2', paddingHorizontal: 20, minHeight: 56, justifyContent: 'center', borderRadius: radius.pill, shadowColor: '#2E1F39', shadowOpacity: .14, shadowRadius: 10, elevation: 6 }, walletPillText: { fontWeight: '800', fontSize: 17 },
  availability: { position: 'absolute', bottom: 104, alignSelf: 'center', minWidth: 220, minHeight: 58, borderRadius: radius.pill, backgroundColor: colors.white, justifyContent: 'center', alignItems: 'center', shadowColor: '#2E1F39', shadowOpacity: .18, shadowRadius: 16, elevation: 8 }, availabilityOn: { backgroundColor: colors.black }, availabilityBusy: { backgroundColor: colors.purpleDark }, availabilityText: { color: colors.ink, fontSize: 17, fontWeight: '800' }, mapMarker: { width: 38, height: 38, borderRadius: 19, backgroundColor: colors.white, borderWidth: 3, borderColor: colors.white, justifyContent: 'center', alignItems: 'center', shadowColor: '#000', shadowOpacity: .25, shadowRadius: 6, elevation: 5 }, mapMarkerCourier: { backgroundColor: colors.purple }, mapMarkerPickup: { backgroundColor: '#F2D6FF' }, mapMarkerDestination: { backgroundColor: colors.black },
  progress: { position: 'absolute', top: 84, left: 10, right: 10, height: 68, paddingHorizontal: 14, flexDirection: 'row', alignItems: 'center', justifyContent: 'center', backgroundColor: '#FFFFFFF8', borderRadius: radius.md, shadowColor: '#000', shadowOpacity: .12, shadowRadius: 12, elevation: 5 }, step: { alignItems: 'center' }, stepDot: { width: 27, height: 27, borderRadius: 14, backgroundColor: '#E7E2EA', alignItems: 'center', justifyContent: 'center' }, stepDone: { backgroundColor: colors.purple }, stepCurrent: { borderWidth: 3, borderColor: colors.purple, backgroundColor: '#fff' }, stepNumber: { color: colors.white, fontSize: 11, fontWeight: '900' }, stepLabel: { fontSize: 9, fontWeight: '800', marginTop: 4 }, stepLine: { height: 3, width: 28, backgroundColor: '#E7E2EA', marginHorizontal: 3, marginBottom: 15 }, stepLineDone: { backgroundColor: colors.purple },
  activeLayer: { ...{ position: 'absolute', top: 0, right: 0, bottom: 0, left: 0 }, justifyContent: 'flex-end', backgroundColor: 'transparent' }, activeSheet: { maxHeight: '72%', backgroundColor: colors.white, borderTopLeftRadius: 30, borderTopRightRadius: 30, padding: 18, shadowColor: '#000', shadowOpacity: .2, shadowRadius: 20, elevation: 12 }, sheetHandle: { width: 44, height: 5, borderRadius: 3, backgroundColor: '#D5CFDA', alignSelf: 'center', marginBottom: 12 }, activeHead: { flexDirection: 'row', gap: 12, alignItems: 'center', marginBottom: 12 }, circleButton: { width: 38, height: 38, borderRadius: 19, backgroundColor: colors.surface, alignItems: 'center', justifyContent: 'center' }, activeTitle: { fontSize: 21, fontWeight: '800', color: colors.ink, marginTop: 3 }, metrics: { flexDirection: 'row', gap: 10, marginBottom: 12 }, metricValue: { fontWeight: '800', fontSize: 18, marginTop: 2 }, stop: { flexDirection: 'row', gap: 12, paddingVertical: 10, borderBottomWidth: 1, borderBottomColor: colors.line }, stopNumber: { width: 31, height: 31, borderRadius: 16, alignItems: 'center', justifyContent: 'center' }, stopText: { flex: 1 }, stopLabel: { fontSize: 9, letterSpacing: 1, fontWeight: '900', color: colors.muted }, stopAddress: { color: colors.ink, fontSize: 14, lineHeight: 20, fontWeight: '700', marginTop: 3 }, phone: { color: colors.purple, fontWeight: '800', marginTop: 4 }, client: { color: colors.muted, marginTop: 3 }, paymentRow: { flexDirection: 'row', justifyContent: 'space-between', paddingVertical: 12 }, paymentValue: { color: colors.ink, fontWeight: '800', maxWidth: '65%', textAlign: 'right' }, actionRow: { flexDirection: 'row', gap: 9, alignItems: 'center', marginTop: 8 }, cancelLink: { alignItems: 'center', paddingTop: 13 },
  modalScrim: { flex: 1, justifyContent: 'flex-end', backgroundColor: '#100919AA' }, offerSheet: { backgroundColor: colors.white, borderTopLeftRadius: 32, borderTopRightRadius: 32, padding: 24, paddingBottom: 34 }, offerIcon: { width: 52, height: 52, borderRadius: 18, backgroundColor: colors.purpleSoft, alignItems: 'center', justifyContent: 'center', marginBottom: 16 }, offerTitle: { color: colors.ink, fontSize: 27, fontWeight: '800', marginTop: 6 }, offerValue: { flexDirection: 'row', justifyContent: 'space-between', backgroundColor: colors.purpleDark, borderRadius: radius.md, padding: 18, marginVertical: 18 }, offerStop: { flexDirection: 'row', gap: 12, paddingVertical: 10, alignItems: 'flex-start' }, offerIndex: { width: 29, height: 29, lineHeight: 29, textAlign: 'center', borderRadius: 15, overflow: 'hidden', color: colors.white, fontWeight: '900', backgroundColor: colors.purple }, offerAddress: { color: colors.ink, fontSize: 15, lineHeight: 21, fontWeight: '700', maxWidth: 285 },
  listContent: { padding: 22, paddingBottom: 42 }, empty: { alignItems: 'center', backgroundColor: colors.surface, borderRadius: radius.lg, padding: 32, marginTop: 22 }, emptyIcon: { fontSize: 42, color: colors.muted, marginBottom: 10 }, deliveryCard: { backgroundColor: colors.white, borderWidth: 1, borderColor: colors.line, borderRadius: radius.md, padding: 16, marginTop: 12 }, deliveryCardTop: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' }, deliveryId: { color: colors.muted, fontSize: 11, fontWeight: '800' }, statusPill: { color: colors.purple, backgroundColor: colors.purpleSoft, paddingHorizontal: 10, paddingVertical: 5, borderRadius: radius.pill, overflow: 'hidden', fontSize: 11, fontWeight: '800' }, statusDone: { color: colors.green, backgroundColor: '#E4F5EC' }, deliveryMerchant: { fontSize: 17, fontWeight: '800', marginTop: 12 }, deliveryAddress: { color: colors.muted, marginTop: 4 }, deliveryCardFoot: { flexDirection: 'row', justifyContent: 'space-between', marginTop: 15, paddingTop: 12, borderTopWidth: 1, borderTopColor: colors.line }, deliveryPrice: { color: colors.green, fontWeight: '800' },
  profileRow: { flexDirection: 'row', gap: 14, alignItems: 'center', marginVertical: 18 }, avatarLarge: { width: 64, height: 64, borderRadius: 32 }, avatarLargeFallback: { width: 64, height: 64, borderRadius: 32, backgroundColor: colors.purpleSoft, alignItems: 'center', justifyContent: 'center' }, profileName: { fontSize: 18, fontWeight: '800' }, balanceCard: { backgroundColor: colors.purpleDark, borderRadius: radius.lg, padding: 24 }, balanceValue: { color: colors.white, fontSize: 36, fontWeight: '900', marginVertical: 8 }, sectionTitle: { fontSize: 19, fontWeight: '800', marginTop: 26, marginBottom: 8 }, statement: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', paddingVertical: 15, borderBottomWidth: 1, borderBottomColor: colors.line }, statementTitle: { fontWeight: '800', marginBottom: 4 }, statementValue: { color: colors.green, fontWeight: '800' }, profileHero: { alignItems: 'center', backgroundColor: colors.white, borderRadius: radius.lg, padding: 22, borderWidth: 1, borderColor: colors.line, marginTop: 12 }, avatarHero: { width: 112, height: 112, borderRadius: 56 }, avatarHeroFallback: { width: 112, height: 112, borderRadius: 56, alignItems: 'center', justifyContent: 'center', backgroundColor: colors.purpleSoft }, profileHeroName: { fontSize: 22, fontWeight: '800', marginTop: 12 }, infoGrid: { marginVertical: 18 }, infoItem: { paddingVertical: 14, borderBottomWidth: 1, borderBottomColor: colors.line }, infoValue: { color: colors.ink, fontWeight: '800', marginTop: 3 },
  tabs: { flexDirection: 'row', minHeight: 72, borderTopWidth: 1, borderTopColor: colors.line, backgroundColor: colors.white, paddingBottom: Platform.OS === 'android' ? 6 : 0 }, tab: { flex: 1, alignItems: 'center', justifyContent: 'center', gap: 4 }, tabIcon: { fontSize: 21, color: '#9B93A2' }, tabLabel: { fontSize: 11, color: '#7F7786', fontWeight: '700' }, tabActive: { color: colors.purple }, splash: { flex: 1, alignItems: 'center', justifyContent: 'center', gap: 20, backgroundColor: '#160821' }, splashLogo: { width: 150, height: 100 }
});

