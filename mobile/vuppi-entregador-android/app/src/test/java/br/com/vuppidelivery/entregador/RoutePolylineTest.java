package br.com.vuppidelivery.entregador;

import static org.junit.Assert.*;
import java.util.List;
import org.junit.Test;

public class RoutePolylineTest {
  @Test public void decodesGoogleEncodedPolylineForInAppNavigation() {
    List<double[]> route=PolylineDecoder.decode("_p~iF~ps|U_ulLnnqC_mqNvxq`@");
    assertEquals(3,route.size());
    assertEquals(38.5,route.get(0)[0],0.00001);
    assertEquals(-120.2,route.get(0)[1],0.00001);
    assertEquals(43.252,route.get(2)[0],0.00001);
    assertEquals(-126.453,route.get(2)[1],0.00001);
  }
}
