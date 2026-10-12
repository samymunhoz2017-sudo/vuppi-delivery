package br.com.vuppidelivery.entregador;

import android.content.Context;
import org.json.JSONObject;
import java.io.*;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;

final class Api {
  static final String BASE="https://vuppidelivery.com.br";
  private final SessionStore store;
  Api(Context c){store=new SessionStore(c);}
  JSONObject get(String path) throws Exception{return call("GET",path,null);}
  JSONObject post(String path,JSONObject body) throws Exception{return call("POST",path,body);}
  JSONObject action(String action,JSONObject data) throws Exception {JSONObject b=new JSONObject();b.put("action",action);b.put("data",data==null?new JSONObject():data);return post("/api/delivery/action",b);}
  JSONObject login(String email,String password) throws Exception {JSONObject b=new JSONObject();b.put("email",email.trim());b.put("password",password);b.put("remember",true);JSONObject r=post("/api/auth/login",b);String session=r.optString("session");if(!session.isEmpty())store.save(session);return r;}
  void logout(){try{post("/api/auth/logout",new JSONObject());}catch(Exception ignored){}store.clear();}
  boolean hasSession(){return !store.get().isEmpty();}
  private JSONObject call(String method,String path,JSONObject body) throws Exception {
    HttpURLConnection c=(HttpURLConnection)new URL(BASE+path).openConnection();c.setRequestMethod(method);c.setConnectTimeout(15000);c.setReadTimeout(20000);c.setRequestProperty("Accept","application/json");c.setRequestProperty("X-Vuppi-Client","courier-native");c.setRequestProperty("X-Vuppi-App","0.62.0");String token=store.get();if(!token.isEmpty())c.setRequestProperty("Authorization","Vuppi "+token);
    if(body!=null){c.setDoOutput(true);c.setRequestProperty("Content-Type","application/json");try(OutputStream o=c.getOutputStream()){o.write(body.toString().getBytes(StandardCharsets.UTF_8));}}
    int status=c.getResponseCode();String renewed=c.getHeaderField("X-Vuppi-Session");if(renewed!=null&&!renewed.isEmpty())store.save(renewed);InputStream in=status>=400?c.getErrorStream():c.getInputStream();String text=read(in);JSONObject out=text.isEmpty()?new JSONObject():new JSONObject(text);if(status==401)store.clear();if(status>=400)throw new IOException(out.optString("message","Falha de comunicação ("+status+")"));return out;
  }
  private static String read(InputStream in)throws Exception{if(in==null)return "";try(BufferedReader r=new BufferedReader(new InputStreamReader(in,StandardCharsets.UTF_8))){StringBuilder b=new StringBuilder();String line;while((line=r.readLine())!=null)b.append(line);return b.toString();}}
}


