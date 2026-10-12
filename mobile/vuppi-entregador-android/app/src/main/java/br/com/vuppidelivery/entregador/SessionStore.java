package br.com.vuppidelivery.entregador;

import android.content.Context;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.util.Base64;
import java.nio.charset.StandardCharsets;
import java.security.KeyStore;
import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;

final class SessionStore {
  private static final String ALIAS="vuppi-session-v1", PREF="vuppi.secure", KEY="session";
  private final Context context;
  SessionStore(Context context){this.context=context.getApplicationContext();}
  private SecretKey key() throws Exception {
    KeyStore ks=KeyStore.getInstance("AndroidKeyStore"); ks.load(null);
    if(!ks.containsAlias(ALIAS)){ KeyGenerator kg=KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES,"AndroidKeyStore"); kg.init(new KeyGenParameterSpec.Builder(ALIAS,KeyProperties.PURPOSE_ENCRYPT|KeyProperties.PURPOSE_DECRYPT).setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build()); kg.generateKey(); }
    return ((KeyStore.SecretKeyEntry)ks.getEntry(ALIAS,null)).getSecretKey();
  }
  void save(String value) throws Exception { Cipher c=Cipher.getInstance("AES/GCM/NoPadding"); c.init(Cipher.ENCRYPT_MODE,key()); byte[] enc=c.doFinal(value.getBytes(StandardCharsets.UTF_8)); String all=Base64.encodeToString(c.getIV(),Base64.NO_WRAP)+"."+Base64.encodeToString(enc,Base64.NO_WRAP); context.getSharedPreferences(PREF,0).edit().putString(KEY,all).apply(); }
  String get(){ try { String all=context.getSharedPreferences(PREF,0).getString(KEY,""); if(all.isEmpty())return ""; String[] p=all.split("\\.",2); Cipher c=Cipher.getInstance("AES/GCM/NoPadding"); c.init(Cipher.DECRYPT_MODE,key(),new GCMParameterSpec(128,Base64.decode(p[0],Base64.NO_WRAP))); return new String(c.doFinal(Base64.decode(p[1],Base64.NO_WRAP)),StandardCharsets.UTF_8); } catch(Exception e){clear();return "";} }
  void clear(){context.getSharedPreferences(PREF,0).edit().remove(KEY).apply();}
}
