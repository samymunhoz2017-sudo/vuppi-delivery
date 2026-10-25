package br.com.vuppidelivery.entregador;

import android.app.*;
import android.content.*;
import android.content.pm.PackageManager;
import android.graphics.*;
import android.graphics.drawable.GradientDrawable;
import android.location.Location;
import android.media.*;
import android.os.*;
import android.provider.Settings;
import android.view.*;
import android.widget.*;
import androidx.core.app.ActivityCompat;
import com.google.android.gms.location.*;
import org.json.*;
import java.util.concurrent.atomic.AtomicBoolean;

public class CourierService extends Service {
  static final String ACTION_START="br.com.vuppi.START", ACTION_STOP="br.com.vuppi.STOP", ACTION_APP_FOREGROUND="br.com.vuppi.APP_FOREGROUND", ACTION_APP_BACKGROUND="br.com.vuppi.APP_BACKGROUND", ACTION_STOP_OFFER_ALERT="br.com.vuppi.STOP_OFFER_ALERT", ACTION_REJECT_OFFER="br.com.vuppi.REJECT_OFFER", ACTION_OFFER_CHANGED="br.com.vuppi.OFFER_CHANGED", EXTRA_ACTIVE="active", EXTRA_AVAILABLE="available", EXTRA_OFFER_ID="offerId";
  private static final String CHANNEL_TRACK="vuppi_tracking_v59", CHANNEL_OFFERS="vuppi_offers_v59", CHANNEL_MESSAGES="vuppi_messages_v73", PREF_OVERLAY="vuppi.overlay", PREF_MESSAGES="vuppi.messages";
  private final Handler main=new Handler(Looper.getMainLooper());
  private final AtomicBoolean checking=new AtomicBoolean(false);
  private FusedLocationProviderClient location; private LocationCallback callback; private Api api;
  private static volatile boolean processForeground;
  private static volatile CourierService running;
  private volatile boolean active,available,updatesStarted; private volatile Location lastLocation; private volatile long nextRejectFlushAt,nextMessagePollAt;
  private WindowManager windows; private View floatingIcon,offerOverlay; private TextView badge; private String overlayOfferId="";
  private MediaPlayer offerPlayer; private int offerPlays; private AudioManager audioManager; private AudioFocusRequest audioFocusRequest;
  private OfferStateMachine offerState; private OfferDecisionStore decisions;
  private final Runnable offerPoll=new Runnable(){@Override public void run(){new Thread(()->tick(lastLocation),"vuppi-offers").start();main.postDelayed(this,3000);}};

  @Override public void onCreate(){super.onCreate();running=this;api=new Api(this);location=LocationServices.getFusedLocationProviderClient(this);audioManager=(AudioManager)getSystemService(AUDIO_SERVICE);offerState=new OfferStateMachine();decisions=new OfferDecisionStore(this);channels();}
  @Override public int onStartCommand(Intent intent,int flags,int id){
    String action=intent==null?"":intent.getAction();
    if(ACTION_STOP.equals(action)){clearOfferPresentation();removeFloatingIcon();stopSelf();return START_NOT_STICKY;}
    if(ACTION_APP_FOREGROUND.equals(action)){processForeground=true;removeOfferOverlay();cancelOfferNotification();return START_STICKY;}
    if(ACTION_APP_BACKGROUND.equals(action)){processForeground=false;return START_STICKY;}
    if(ACTION_STOP_OFFER_ALERT.equals(action)){stopOfferAlert();return START_STICKY;}
    if(ACTION_REJECT_OFFER.equals(action)){rejectOffer(intent.getStringExtra(EXTRA_OFFER_ID));return START_STICKY;}
    active=intent!=null&&intent.getBooleanExtra(EXTRA_ACTIVE,false);available=intent!=null&&intent.getBooleanExtra(EXTRA_AVAILABLE,false);
    startForeground(41,trackingNotification());startPolling();if(active||available)startLocationUpdatesIfAllowed();else stopLocationUpdates();showFloatingIcon(false);return START_STICKY;
  }
  private void startPolling(){main.removeCallbacks(offerPoll);main.post(offerPoll);}
  private void startLocationUpdatesIfAllowed(){
    if(updatesStarted||ActivityCompat.checkSelfPermission(this,android.Manifest.permission.ACCESS_FINE_LOCATION)!=PackageManager.PERMISSION_GRANTED)return;
    updatesStarted=true;callback=new LocationCallback(){@Override public void onLocationResult(LocationResult r){Location p=r.getLastLocation();if(p!=null){lastLocation=p;new Thread(()->sendLocation(p),"vuppi-location").start();}}};
    LocationRequest req=new LocationRequest.Builder(Priority.PRIORITY_HIGH_ACCURACY,1500).setMinUpdateIntervalMillis(700).setMinUpdateDistanceMeters(1).setWaitForAccurateLocation(true).build();location.requestLocationUpdates(req,callback,Looper.getMainLooper());
  }
  private void sendLocation(Location p){try{JSONObject d=new JSONObject();d.put("lat",p.getLatitude());d.put("lng",p.getLongitude());api.action("location",d);}catch(Exception ignored){}}
  private void tick(Location p){
    if(!checking.compareAndSet(false,true))return;
    try{
      if((active||available)&&!updatesStarted)main.post(this::startLocationUpdatesIfAllowed);
      JSONObject state=api.get("/api/delivery/state");JSONObject profile=state.optJSONObject("profile");boolean access=profile!=null&&profile.optBoolean("approved")&&"active".equals(profile.optString("member_status","active"));available=access&&profile.optBoolean("is_available");JSONArray orders=state.optJSONArray("orders");active=access&&hasActiveDelivery(orders);if(!access){main.post(()->{clearOfferPresentation();removeFloatingIcon();stopLocationUpdates();});return;}JSONArray offers=state.optJSONArray("offers");JSONObject offer=available&&!active?firstEligibleOffer(offers):null;if(offer==null&&available&&!active){try{JSONObject pending=api.get("/api/delivery/pending");offer=firstEligibleOffer(pending.optJSONArray("available"));if(offer!=null)offer.put("pending_alert",true);}catch(Exception ignored){}}String offerId=offer==null?"":offer.optString("id");boolean suppressed=decisions.isSuppressed(offerId,System.currentTimeMillis());OfferStateMachine.Observation observation=offerState.observe(offerId,suppressed);
      JSONObject finalOffer=offer;main.post(()->presentOffer(finalOffer,observation));flushPendingRejections();pollCentralMessages();
    }catch(Exception ignored){}finally{checking.set(false);}
  }
  private void stopLocationUpdates(){if(callback!=null)try{location.removeLocationUpdates(callback);}catch(Exception ignored){}callback=null;updatesStarted=false;lastLocation=null;}
  private JSONObject firstEligibleOffer(JSONArray offers){
    if(offers==null)return null;
    long now=System.currentTimeMillis();
    for(int i=0;i<offers.length();i++){JSONObject candidate=offers.optJSONObject(i);if(candidate!=null&&!decisions.isSuppressed(candidate.optString("id"),now))return candidate;}
    return null;
  }
  private boolean hasActiveDelivery(JSONArray orders){if(orders==null)return false;for(int i=0;i<orders.length();i++){JSONObject row=orders.optJSONObject(i);String status=row==null?"":row.optString("status");if("assigned".equals(status)||"collected".equals(status))return true;}return false;}
  private void presentOffer(JSONObject offer,OfferStateMachine.Observation observation){
    boolean has=offer!=null&&observation!=OfferStateMachine.Observation.SUPPRESSED&&offerState.isPresentable();
    showFloatingIcon(has);
    if(!has){clearOfferPresentation();announceOfferChange();return;}
    if(processForeground){removeOfferOverlay();cancelOfferNotification();}
    else if(Settings.canDrawOverlays(this)){showOfferOverlay(offer);cancelOfferNotification();}
    else{removeOfferOverlay();if(observation==OfferStateMachine.Observation.NEW)notifyOffer(offer);}
    if(observation==OfferStateMachine.Observation.NEW)playOfferAlert();
    announceOfferChange();
  }
  private void suppressOfferLocally(String offerId){
    if(offerId==null||offerId.isEmpty())offerId=offerState.offerId();
    decisions.suppressLocally(offerId,System.currentTimeMillis());offerState.suppress(offerId);clearOfferPresentation();showFloatingIcon(false);announceOfferChange();
  }
  private void rejectOffer(String offerId){
    if(offerId==null||offerId.isEmpty())offerId=offerState.offerId();final String id=offerId;
    if(id.isEmpty())return;offerState.beginReject(id);decisions.suppressLocally(id,System.currentTimeMillis());decisions.markPendingReject(id,System.currentTimeMillis());clearOfferPresentation();showFloatingIcon(false);announceOfferChange();
    new Thread(()->{try{JSONObject d=new JSONObject();d.put("id",id);api.action("reject",d);decisions.markRejectSynced(id);offerState.rejected(id);}catch(Exception e){if(isTerminalReject(e))decisions.markRejectSynced(id);offerState.rejectingFailed();}},"vuppi-reject").start();
  }
  private void flushPendingRejections(){long now=System.currentTimeMillis();if(now<nextRejectFlushAt)return;nextRejectFlushAt=now+30000;int attempts=0;for(String id:decisions.pendingRejects()){if(attempts++>=3)break;try{JSONObject d=new JSONObject();d.put("id",id);api.action("reject",d);decisions.markRejectSynced(id);offerState.rejected(id);}catch(Exception error){if(isTerminalReject(error))decisions.markRejectSynced(id);}}}
  private boolean isTerminalReject(Exception error){String message=error==null?"":String.valueOf(error.getMessage()).toLowerCase(java.util.Locale.ROOT);return message.contains("não está mais disponível")||message.contains("já foi recusada");}
  private void announceOfferChange(){sendBroadcast(new Intent(ACTION_OFFER_CHANGED).setPackage(getPackageName()));}
  private void cancelOfferNotification(){getSystemService(NotificationManager.class).cancel(99);}
  private void clearOfferPresentation(){removeOfferOverlay();stopOfferAlert();cancelOfferNotification();}
  private void pollCentralMessages(){long now=System.currentTimeMillis();if(now<nextMessagePollAt)return;nextMessagePollAt=now+15000;try{JSONObject result=api.get("/api/delivery/messages");JSONArray rows=result.optJSONArray("messages");if(rows==null)return;for(int i=0;i<rows.length();i++){JSONObject row=rows.optJSONObject(i);if(row==null||!row.isNull("read_at"))continue;String id=row.optString("id");if(id.isEmpty()||getSharedPreferences(PREF_MESSAGES,0).getBoolean("seen_"+id,false))continue;getSharedPreferences(PREF_MESSAGES,0).edit().putBoolean("seen_"+id,true).apply();main.post(()->notifyCentralMessage(row));break;}}catch(Exception ignored){}}
  private void notifyCentralMessage(JSONObject row){Intent open=new Intent(this,MainActivity.class).putExtra("centralMessage",true).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP|Intent.FLAG_ACTIVITY_CLEAR_TOP);PendingIntent pi=PendingIntent.getActivity(this,103,open,PendingIntent.FLAG_IMMUTABLE|PendingIntent.FLAG_UPDATE_CURRENT);String priority=row.optString("priority","normal");Notification n=notificationBuilder(CHANNEL_MESSAGES).setSmallIcon(R.drawable.app_icon).setContentTitle(row.optString("title","Mensagem da central")).setContentText(row.optString("body","Abra a VUPPI para ler.")).setStyle(new Notification.BigTextStyle().bigText(row.optString("body",""))).setPriority("urgent".equals(priority)?Notification.PRIORITY_MAX:Notification.PRIORITY_HIGH).setCategory(Notification.CATEGORY_MESSAGE).setVisibility(Notification.VISIBILITY_PRIVATE).setAutoCancel(true).setContentIntent(pi).build();getSystemService(NotificationManager.class).notify(103,n);}
  private void channels(){
    if(Build.VERSION.SDK_INT<26)return;
    NotificationManager n=getSystemService(NotificationManager.class);NotificationChannel tracking=new NotificationChannel(CHANNEL_TRACK,"VUPPI em segundo plano",NotificationManager.IMPORTANCE_LOW);tracking.setSound(null,null);n.createNotificationChannel(tracking);
    NotificationChannel offers=new NotificationChannel(CHANNEL_OFFERS,"Novas entregas",NotificationManager.IMPORTANCE_HIGH);offers.setDescription("Aviso curto quando uma nova entrega estiver disponível");offers.enableVibration(true);offers.setVibrationPattern(new long[]{0,220,120,320});offers.enableLights(true);offers.setLightColor(Color.rgb(118,33,232));offers.setSound(null,null);n.createNotificationChannel(offers);
    NotificationChannel messages=new NotificationChannel(CHANNEL_MESSAGES,"Mensagens da central",NotificationManager.IMPORTANCE_HIGH);messages.setDescription("Comunicados operacionais enviados pela central VUPPI");messages.enableVibration(true);messages.setVibrationPattern(new long[]{0,180,120,180});n.createNotificationChannel(messages);
  }
  private Notification.Builder notificationBuilder(String channel){return Build.VERSION.SDK_INT>=26?new Notification.Builder(this,channel):new Notification.Builder(this);}
  private Notification trackingNotification(){PendingIntent pi=PendingIntent.getActivity(this,1,new Intent(this,MainActivity.class),PendingIntent.FLAG_IMMUTABLE|PendingIntent.FLAG_UPDATE_CURRENT);String title=active?"Entrega VUPPI em andamento":available?"VUPPI: você está livre":"VUPPI conectada à central",body=active?"Acompanhando sua rota em segundo plano.":available?"Buscando entregas na sua região.":"Você receberá comunicados da matriz neste aparelho.";return notificationBuilder(CHANNEL_TRACK).setSmallIcon(R.drawable.app_icon).setContentTitle(title).setContentText(body).setContentIntent(pi).setOngoing(true).build();}
  private void notifyOffer(JSONObject offer){Intent open=new Intent(this,MainActivity.class).putExtra("offerId",offer.optString("id")).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP|Intent.FLAG_ACTIVITY_CLEAR_TOP);PendingIntent pi=PendingIntent.getActivity(this,2,open,PendingIntent.FLAG_IMMUTABLE|PendingIntent.FLAG_UPDATE_CURRENT);Notification n=notificationBuilder(CHANNEL_OFFERS).setSmallIcon(R.drawable.app_icon).setContentTitle("Nova entrega disponível").setContentText("Abra a VUPPI para consultar e responder à oferta.").setPriority(Notification.PRIORITY_MAX).setCategory(Notification.CATEGORY_EVENT).setVisibility(Notification.VISIBILITY_PRIVATE).setAutoCancel(true).setContentIntent(pi).build();getSystemService(NotificationManager.class).notify(99,n);}
  private void playOfferAlert(){
    stopOfferAlert();offerPlays=0;
    try{
      AudioAttributes attributes=new AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_NOTIFICATION_EVENT).setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build();
      if(Build.VERSION.SDK_INT>=26){audioFocusRequest=new AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK).setAudioAttributes(attributes).setOnAudioFocusChangeListener(change->{if(change==AudioManager.AUDIOFOCUS_LOSS)stopOfferAlert();}).build();if(audioManager.requestAudioFocus(audioFocusRequest)!=AudioManager.AUDIOFOCUS_REQUEST_GRANTED)return;}
      offerPlayer=MediaPlayer.create(this,R.raw.vuppi_delivery,attributes,AudioManager.AUDIO_SESSION_ID_GENERATE);
      if(offerPlayer!=null){
        offerPlayer.setOnCompletionListener(p->{offerPlays++;if(offerPlayer==p&&offerPlays<3){p.seekTo(0);p.start();}else stopOfferAlert();});
        offerPlayer.start();
      }
    }catch(Exception ignored){stopOfferAlert();}
    try{Vibrator v=(Vibrator)getSystemService(VIBRATOR_SERVICE);long[] pattern={0,240,110,350,550,240,110,350};if(Build.VERSION.SDK_INT>=26)v.vibrate(VibrationEffect.createWaveform(pattern,-1));else v.vibrate(pattern,-1);}catch(Exception ignored){}
  }
  private void stopOfferAlert(){MediaPlayer player=offerPlayer;offerPlayer=null;if(player!=null)try{player.stop();player.release();}catch(Exception ignored){}try{((Vibrator)getSystemService(VIBRATOR_SERVICE)).cancel();}catch(Exception ignored){}if(Build.VERSION.SDK_INT>=26&&audioFocusRequest!=null&&audioManager!=null){audioManager.abandonAudioFocusRequest(audioFocusRequest);audioFocusRequest=null;}}
  private void showFloatingIcon(boolean pending){
    if(!getSharedPreferences(PREF_OVERLAY,0).getBoolean("enabled",true)||!Settings.canDrawOverlays(this)){removeFloatingIcon();return;}if(floatingIcon==null){windows=(WindowManager)getSystemService(WINDOW_SERVICE);FrameLayout bubble=new FrameLayout(this);bubble.setPadding(dp(4),dp(4),dp(4),dp(4));bubble.setBackground(round(Color.WHITE,30));bubble.setElevation(dp(14));ImageView logo=new ImageView(this);logo.setImageDrawable(circleLogo());logo.setScaleType(ImageView.ScaleType.CENTER_CROP);bubble.addView(logo,new FrameLayout.LayoutParams(dp(52),dp(52)));badge=new TextView(this);badge.setText("!");badge.setTextColor(Color.WHITE);badge.setTextSize(11);badge.setTypeface(android.graphics.Typeface.DEFAULT,android.graphics.Typeface.BOLD);badge.setGravity(Gravity.CENTER);badge.setBackground(round(Color.rgb(239,55,88),10));bubble.addView(badge,new FrameLayout.LayoutParams(dp(20),dp(20),Gravity.END|Gravity.TOP));WindowManager.LayoutParams p=overlayParams(dp(60),dp(60));p.gravity=Gravity.TOP|Gravity.END;p.x=dp(14);p.y=dp(150);final float[] t=new float[4];bubble.setOnTouchListener((view,e)->{if(e.getAction()==MotionEvent.ACTION_DOWN){t[0]=e.getRawX();t[1]=e.getRawY();t[2]=p.x;t[3]=p.y;return true;}if(e.getAction()==MotionEvent.ACTION_MOVE){p.x=(int)(t[2]-(e.getRawX()-t[0]));p.y=(int)(t[3]+(e.getRawY()-t[1]));windows.updateViewLayout(view,p);return true;}if(e.getAction()==MotionEvent.ACTION_UP){boolean tap=Math.abs(e.getRawX()-t[0])<12&&Math.abs(e.getRawY()-t[1])<12;if(tap)openApp();else if(e.getRawY()>getResources().getDisplayMetrics().heightPixels-dp(140)){getSharedPreferences(PREF_OVERLAY,0).edit().putBoolean("enabled",false).apply();removeFloatingIcon();Toast.makeText(this,"Ícone flutuante desativado. Ative novamente no Perfil.",Toast.LENGTH_LONG).show();}return true;}return false;});try{windows.addView(bubble,p);floatingIcon=bubble;}catch(Exception ignored){}}
    if(badge!=null)badge.setVisibility(pending?View.VISIBLE:View.GONE);
  }
  private void showOfferOverlay(JSONObject offer){
    if(offer==null||!Settings.canDrawOverlays(this))return;String id=offer.optString("id");if(id.equals(overlayOfferId)&&offerOverlay!=null)return;removeOfferOverlay();overlayOfferId=id;if(windows==null)windows=(WindowManager)getSystemService(WINDOW_SERVICE);
    LinearLayout card=new LinearLayout(this);card.setOrientation(LinearLayout.VERTICAL);card.setPadding(dp(20),dp(18),dp(20),dp(18));card.setBackground(round(Color.WHITE,26));card.setElevation(dp(18));LinearLayout head=new LinearLayout(this);head.setGravity(Gravity.CENTER_VERTICAL);ImageView logo=new ImageView(this);logo.setImageDrawable(circleLogo());logo.setScaleType(ImageView.ScaleType.CENTER_CROP);logo.setContentDescription("Vuppi Delivery");head.addView(logo,new LinearLayout.LayoutParams(dp(48),dp(48)));LinearLayout identity=new LinearLayout(this);identity.setOrientation(LinearLayout.VERTICAL);TextView tag=text("OFERTA DISPONÍVEL",11,true);tag.setTextColor(Color.rgb(111,32,217));identity.addView(tag);identity.addView(text(offer.optString("merchant_name","Estabelecimento"),20,true));head.addView(identity,new LinearLayout.LayoutParams(0,dp(54),1));TextView value=text(money(offer.optInt("price_cents")),28,true);value.setTextColor(Color.rgb(111,32,217));head.addView(value);card.addView(head);TextView route=text("Rota da entrega",14,true);route.setTextColor(Color.rgb(66,57,75));card.addView(route,margin(0,14,0,9));card.addView(info("1  COLETA",offer.optString("pickup_address","Endereço da coleta")));card.addView(info("2  DESTINO",offer.optString("destination","Endereço do cliente")));TextView guidance=text("Confira a rota antes de aceitar.",12,false);guidance.setTextColor(Color.GRAY);card.addView(guidance,margin(2,2,0,12));SlideActionView slide=new SlideActionView(this,"Arraste para aceitar");card.addView(slide,new LinearLayout.LayoutParams(-1,dp(60)));slide.setOnConfirmedListener(()->{stopOfferAlert();slide.setActionEnabled(false);new Thread(()->acceptOverlay(id,slide),"vuppi-accept").start();});Button later=new Button(this);later.setText("Recusar oferta");later.setContentDescription("Recusar definitivamente esta oferta");later.setAllCaps(false);later.setTextColor(Color.rgb(174,43,75));later.setBackgroundColor(Color.TRANSPARENT);later.setOnClickListener(v->rejectOffer(id));card.addView(later,new LinearLayout.LayoutParams(-1,dp(48)));WindowManager.LayoutParams p=overlayParams(-1,-2);p.gravity=Gravity.BOTTOM;p.x=dp(12);p.y=dp(18);p.flags=WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN;try{windows.addView(card,p);offerOverlay=card;}catch(Exception ignored){overlayOfferId="";}
  }
  private void acceptOverlay(String id,SlideActionView slide){if(!offerState.beginAccept(id)){main.post(()->slide.setActionEnabled(true));return;}try{JSONObject d=new JSONObject();d.put("id",id);api.action("accept",d);offerState.accepted(id);main.post(()->{clearOfferPresentation();openApp();});}catch(Exception e){offerState.acceptingFailed();main.post(()->{slide.setActionEnabled(true);Toast.makeText(this,e.getMessage()==null?"Não foi possível aceitar.":e.getMessage(),Toast.LENGTH_LONG).show();});}}
  private void openApp(){Intent open=new Intent(this,MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK|Intent.FLAG_ACTIVITY_SINGLE_TOP|Intent.FLAG_ACTIVITY_CLEAR_TOP);startActivity(open);}
  private WindowManager.LayoutParams overlayParams(int w,int h){int type=Build.VERSION.SDK_INT>=26?WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY:WindowManager.LayoutParams.TYPE_PHONE;return new WindowManager.LayoutParams(w,h,type,WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE|WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,PixelFormat.TRANSLUCENT);}
  private LinearLayout info(String cap,String val){LinearLayout box=new LinearLayout(this);box.setOrientation(LinearLayout.VERTICAL);box.setPadding(dp(13),dp(9),dp(13),dp(9));box.setBackground(round(Color.rgb(247,244,251),14));TextView a=text(cap,11,true);a.setTextColor(Color.rgb(111,32,217));box.addView(a);box.addView(text(val,14,false));box.setLayoutParams(margin(0,0,0,8));return box;}
  private TextView text(String s,int size,boolean bold){TextView v=new TextView(this);v.setText(s);v.setTextSize(size);v.setTextColor(Color.rgb(29,23,36));if(bold)v.setTypeface(android.graphics.Typeface.DEFAULT,android.graphics.Typeface.BOLD);return v;}
  private LinearLayout.LayoutParams margin(int l,int t,int r,int b){LinearLayout.LayoutParams p=new LinearLayout.LayoutParams(-1,-2);p.setMargins(dp(l),dp(t),dp(r),dp(b));return p;}
  private static String money(int cents){return String.format(java.util.Locale.forLanguageTag("pt-BR"),"R$ %.2f",cents/100.0).replace('.',',');}
  private void removeOfferOverlay(){if(windows!=null&&offerOverlay!=null)try{windows.removeView(offerOverlay);}catch(Exception ignored){}offerOverlay=null;overlayOfferId="";}
  private void removeFloatingIcon(){if(windows!=null&&floatingIcon!=null)try{windows.removeView(floatingIcon);}catch(Exception ignored){}floatingIcon=null;badge=null;}
  private void removeOverlays(){removeOfferOverlay();removeFloatingIcon();}
  static void setProcessForeground(boolean foreground){processForeground=foreground;}
  static void commandOffer(String action,String offerId){CourierService service=running;if(service==null)return;service.main.post(()->{if(ACTION_STOP_OFFER_ALERT.equals(action))service.stopOfferAlert();else if(ACTION_REJECT_OFFER.equals(action))service.rejectOffer(offerId);});}
  private GradientDrawable round(int color,int radius){GradientDrawable d=new GradientDrawable();d.setColor(color);d.setCornerRadius(dp(radius));return d;}
  private android.graphics.drawable.Drawable circleLogo(){Bitmap src=BitmapFactory.decodeResource(getResources(),R.drawable.app_icon);int size=Math.min(src.getWidth(),src.getHeight());Bitmap out=Bitmap.createBitmap(size,size,Bitmap.Config.ARGB_8888);Canvas canvas=new Canvas(out);Paint paint=new Paint(Paint.ANTI_ALIAS_FLAG);BitmapShader shader=new BitmapShader(src,Shader.TileMode.CLAMP,Shader.TileMode.CLAMP);float scale=(float)size/Math.min(src.getWidth(),src.getHeight());android.graphics.Matrix matrix=new android.graphics.Matrix();matrix.setScale(scale,scale);shader.setLocalMatrix(matrix);paint.setShader(shader);canvas.drawCircle(size/2f,size/2f,size/2f,paint);return new android.graphics.drawable.BitmapDrawable(getResources(),out);}
  private int dp(int v){return Math.round(v*getResources().getDisplayMetrics().density);}
  @Override public void onDestroy(){main.removeCallbacksAndMessages(null);clearOfferPresentation();stopLocationUpdates();removeOverlays();if(running==this)running=null;super.onDestroy();}
  @Override public android.os.IBinder onBind(Intent i){return null;}
}



