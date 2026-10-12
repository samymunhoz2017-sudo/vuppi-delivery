import type { ExpoConfig } from 'expo/config';

const mapsKey = process.env.GOOGLE_MAPS_ANDROID_KEY || '';

const config: ExpoConfig = {
  name: 'VUPPI Entregador',
  slug: 'vuppi-entregador',
  scheme: 'vuppi',
  version: '0.52.0',
  orientation: 'portrait',
  userInterfaceStyle: 'light',
  icon: './assets/icon.png',
  android: {
    package: 'br.com.vuppidelivery.entregador',
    versionCode: 52,
    adaptiveIcon: {
      foregroundImage: './assets/adaptive-icon.png',
      backgroundColor: '#160821'
    },
    googleServicesFile: process.env.GOOGLE_SERVICES_JSON || undefined,
    config: { googleMaps: { apiKey: mapsKey } },
    permissions: [
      'ACCESS_COARSE_LOCATION',
      'ACCESS_FINE_LOCATION',
      'ACCESS_BACKGROUND_LOCATION',
      'FOREGROUND_SERVICE',
      'FOREGROUND_SERVICE_LOCATION',
      'POST_NOTIFICATIONS',
      'CAMERA',
      'READ_MEDIA_IMAGES'
    ],
    intentFilters: [{
      action: 'VIEW',
      autoVerify: true,
      data: [{ scheme: 'https', host: 'vuppidelivery.com.br', pathPrefix: '/entregador' }],
      category: ['BROWSABLE', 'DEFAULT']
    }]
  },
  ios: {
    bundleIdentifier: 'br.com.vuppidelivery.entregador',
    buildNumber: '52',
    supportsTablet: false,
    infoPlist: {
      UIBackgroundModes: ['location', 'remote-notification'],
      NSLocationWhenInUseUsageDescription: 'A VUPPI usa sua localização para exibir sua posição, calcular a rota e acompanhar entregas ativas.',
      NSLocationAlwaysAndWhenInUseUsageDescription: 'Durante uma entrega, a VUPPI mantém o acompanhamento para que o estabelecimento veja o deslocamento.',
      NSCameraUsageDescription: 'A câmera é usada para atualizar sua foto de perfil.',
      NSPhotoLibraryUsageDescription: 'A galeria é usada para escolher sua foto de perfil.'
    }
  },
  plugins: [
    ['expo-splash-screen', { image: './assets/logo.png', imageWidth: 180, resizeMode: 'contain', backgroundColor: '#160821' }],
    ['expo-location', { locationAlwaysAndWhenInUsePermission: 'Permita a localização durante entregas para atualizar sua rota e o acompanhamento em tempo real.', isAndroidBackgroundLocationEnabled: true, isIosBackgroundLocationEnabled: true }],
    ['expo-notifications', { icon: './assets/adaptive-icon.png', color: '#6F20D9', sounds: ['./assets/delivery_complete.mp3'] }],
    ['expo-image-picker', { photosPermission: 'Permita escolher uma foto para o seu perfil de entregador.', cameraPermission: 'Permita tirar uma foto para o seu perfil de entregador.' }],
    ['expo-secure-store', { configureAndroidBackup: true, faceIDPermission: 'Permita que a VUPPI proteja sua sessão.' }]
  ],
  extra: {
    apiBaseUrl: 'https://vuppidelivery.com.br',
    eas: { projectId: process.env.EXPO_PROJECT_ID || undefined }
  }
};

export default config;

