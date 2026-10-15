package br.com.vuppidelivery.entregador;

import java.util.ArrayList;
import java.util.List;

final class PolylineDecoder {
  private PolylineDecoder() {}

  static List<double[]> decode(String encoded) {
    List<double[]> path=new ArrayList<>();
    if(encoded==null)return path;
    int index=0,lat=0,lng=0;
    while(index<encoded.length()){
      int result=0,shift=0,b;
      do{if(index>=encoded.length())return path;b=encoded.charAt(index++)-63;result|=(b&31)<<shift;shift+=5;}while(b>=32);
      lat+=((result&1)!=0?~(result>>1):(result>>1));
      result=0;shift=0;
      do{if(index>=encoded.length())return path;b=encoded.charAt(index++)-63;result|=(b&31)<<shift;shift+=5;}while(b>=32);
      lng+=((result&1)!=0?~(result>>1):(result>>1));
      path.add(new double[]{lat/1E5,lng/1E5});
    }
    return path;
  }
}
