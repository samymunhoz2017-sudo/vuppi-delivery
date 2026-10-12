# VUPPI Entregador Android

Aplicativo Android nativo do entregador. O build de produção exige `GOOGLE_MAPS_ANDROID_KEY` e as quatro variáveis `VUPPI_KEYSTORE_*`; elas devem permanecer fora do repositório.

O serviço `CourierService` mantém a localização e a consulta de ofertas enquanto o entregador está livre ou possui uma entrega ativa. O canal **Novas entregas** usa som, vibração e prioridade alta no Android.
