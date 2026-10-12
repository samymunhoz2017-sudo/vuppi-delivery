import * as SecureStore from 'expo-secure-store';
import type { DeliveryState, Tracking, User } from './types';

const SESSION_KEY = 'vuppi.native.session.v1';
export const API_BASE = 'https://vuppidelivery.com.br';

export class ApiError extends Error {
  constructor(message: string, public status = 0) { super(message); }
}

async function readBody(response: Response) {
  try { return await response.json(); } catch { throw new ApiError('A central enviou uma resposta inválida.', response.status); }
}

export async function request<T>(path: string, init: RequestInit = {}): Promise<T> {
  const token = await SecureStore.getItemAsync(SESSION_KEY);
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 20000);
  try {
    const response = await fetch(API_BASE + path, {
      ...init,
      signal: controller.signal,
      headers: {
        Accept: 'application/json',
        'X-Vuppi-Client': 'courier-native',
        'X-Vuppi-App': '0.52.0',
        ...(init.body ? { 'Content-Type': 'application/json' } : {}),
        ...(token ? { Authorization: `Vuppi ${token}` } : {}),
        ...(init.headers || {})
      }
    });
    const renewed = response.headers.get('X-Vuppi-Session');
    if (renewed) await SecureStore.setItemAsync(SESSION_KEY, renewed);
    const data = await readBody(response);
    if (!response.ok) {
      if (response.status === 401) await SecureStore.deleteItemAsync(SESSION_KEY);
      throw new ApiError(data?.message || 'Não foi possível concluir a operação.', response.status);
    }
    return data as T;
  } catch (error) {
    if (error instanceof ApiError) throw error;
    throw new ApiError('Sem conexão com a central. Seus dados locais foram preservados.');
  } finally { clearTimeout(timer); }
}

export async function signIn(email: string, password: string) {
  const result = await request<{ user: User; session: string }>('/api/auth/login', {
    method: 'POST', body: JSON.stringify({ email: email.trim(), password, remember: true })
  });
  await SecureStore.setItemAsync(SESSION_KEY, result.session);
  return result.user;
}

export async function signUp(name: string, email: string, password: string) {
  const result = await request<{ user: User; session: string }>('/api/auth/signup', {
    method: 'POST', body: JSON.stringify({ name: name.trim(), email: email.trim(), password, remember: true })
  });
  await SecureStore.setItemAsync(SESSION_KEY, result.session);
  return result.user;
}

export async function restoreSession() {
  const token = await SecureStore.getItemAsync(SESSION_KEY);
  if (!token) return null;
  return (await request<{ user: User }>('/api/auth/session')).user;
}

export async function signOut() {
  try { await request('/api/auth/logout', { method: 'POST', body: '{}' }); }
  finally { await SecureStore.deleteItemAsync(SESSION_KEY); }
}

export const deliveryState = () => request<DeliveryState>('/api/delivery/state');
export const tracking = (id: string) => request<Tracking>(`/api/delivery/tracking?id=${encodeURIComponent(id)}`);
export const deliveryAction = <T = unknown>(action: string, data: Record<string, unknown> = {}) =>
  request<T>('/api/delivery/action', { method: 'POST', body: JSON.stringify({ action, data }) });

export const hasStoredSession = () => SecureStore.getItemAsync(SESSION_KEY).then(Boolean);
