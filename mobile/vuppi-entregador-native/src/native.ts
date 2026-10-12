import { Platform } from 'react-native';
import * as Location from 'expo-location';
import * as Notifications from 'expo-notifications';
import * as TaskManager from 'expo-task-manager';
import AsyncStorage from '@react-native-async-storage/async-storage';
import { deliveryAction, deliveryState } from './api';

export const LOCATION_TASK = 'vuppi-active-delivery-location';
const LOCATION_QUEUE = 'vuppi.location.pending';
const OFFER_SEEN_KEY = 'vuppi.offer.notified';

Notifications.setNotificationHandler({
  handleNotification: async () => ({
    shouldShowBanner: true,
    shouldShowList: true,
    shouldPlaySound: true,
    shouldSetBadge: true
  })
});

async function publishLocation(latitude: number, longitude: number) {
  try {
    await deliveryAction('location', { lat: latitude, lng: longitude });
    await AsyncStorage.removeItem(LOCATION_QUEUE);
  } catch {
    await AsyncStorage.setItem(LOCATION_QUEUE, JSON.stringify({ lat: latitude, lng: longitude, at: Date.now() }));
  }
}

TaskManager.defineTask(LOCATION_TASK, async ({ data, error }) => {
  if (error || !data) return;
  const locations = (data as { locations?: Location.LocationObject[] }).locations || [];
  const latest = locations.at(-1);
  if (latest) await publishLocation(latest.coords.latitude, latest.coords.longitude);
  try {
    const state = await deliveryState();
    const offer = state.offers?.[0];
    if (offer) await notifyOffer(`${offer.merchant_name || 'Estabelecimento'} · nova entrega disponível`, offer.id);
  } catch { /* A próxima atualização tenta novamente sem encerrar o serviço. */ }
});

export async function configureNotifications() {
  if (Platform.OS === 'android') {
    await Notifications.setNotificationChannelAsync('offers', {
      name: 'Novas entregas', importance: Notifications.AndroidImportance.MAX,
      vibrationPattern: [0, 300, 120, 300], sound: 'default', lockscreenVisibility: Notifications.AndroidNotificationVisibility.PUBLIC
    });
    await Notifications.setNotificationChannelAsync('active-delivery', {
      name: 'Entrega em andamento', importance: Notifications.AndroidImportance.HIGH,
      vibrationPattern: [0, 180], sound: 'default'
    });
  }
  const current = await Notifications.getPermissionsAsync();
  if (!current.granted) await Notifications.requestPermissionsAsync();
}

export async function notifyOffer(title: string, id: string) {
  if (await AsyncStorage.getItem(OFFER_SEEN_KEY) === id) return;
  await AsyncStorage.setItem(OFFER_SEEN_KEY, id);
  await Notifications.scheduleNotificationAsync({
    content: { title: 'Nova entrega disponível', body: title, sound: 'default', data: { type: 'delivery', id } },
    trigger: null
  });
}

export async function notifyCompleted(value: string) {
  await Notifications.scheduleNotificationAsync({
    content: { title: 'Entrega concluída', body: `${value} foi registrado na sua carteira.`, sound: 'delivery_complete.mp3', data: { type: 'wallet' } },
    trigger: null
  });
}

export async function requestForegroundLocation() {
  const services = await Location.hasServicesEnabledAsync();
  if (!services) throw new Error('Ative o GPS para ficar disponível e acompanhar entregas.');
  let permission = await Location.getForegroundPermissionsAsync();
  if (!permission.granted) permission = await Location.requestForegroundPermissionsAsync();
  if (!permission.granted) throw new Error('Permita a localização durante o uso do aplicativo.');
  return Location.getCurrentPositionAsync({ accuracy: Location.Accuracy.High });
}

export async function startCourierTracking(activeDelivery = true) {
  await requestForegroundLocation();
  let background = await Location.getBackgroundPermissionsAsync();
  if (!background.granted) background = await Location.requestBackgroundPermissionsAsync();
  if (!background.granted) return false;
  if (await Location.hasStartedLocationUpdatesAsync(LOCATION_TASK)) return true;
  await Location.startLocationUpdatesAsync(LOCATION_TASK, {
    accuracy: Location.Accuracy.Balanced,
    distanceInterval: 35,
    timeInterval: 15000,
    pausesUpdatesAutomatically: false,
    showsBackgroundLocationIndicator: true,
    foregroundService: {
      notificationTitle: activeDelivery ? 'Entrega VUPPI em andamento' : 'VUPPI: você está livre',
      notificationBody: activeDelivery ? 'Sua localização está sendo atualizada durante a rota.' : 'Buscando novas entregas próximas, inclusive em segundo plano.',
      notificationColor: '#6F20D9',
      killServiceOnDestroy: false
    }
  });
  return true;
}

export async function stopActiveDeliveryTracking() {
  if (await Location.hasStartedLocationUpdatesAsync(LOCATION_TASK)) await Location.stopLocationUpdatesAsync(LOCATION_TASK);
}

export async function flushPendingLocation() {
  const value = await AsyncStorage.getItem(LOCATION_QUEUE);
  if (!value) return;
  const row = JSON.parse(value);
  if (Date.now() - Number(row.at) < 15 * 60 * 1000) await publishLocation(Number(row.lat), Number(row.lng));
  else await AsyncStorage.removeItem(LOCATION_QUEUE);
}

