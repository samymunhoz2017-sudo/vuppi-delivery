package br.com.vuppidelivery.entregador;
import static org.junit.Assert.*;
import java.util.Arrays;
import org.junit.Test;
public class RouteEarningsTest {
  @Test public void groupedDeliveryAddsEachDistinctRecordedNetOnce(){
    RouteEarnings.Stop first=new RouteEarnings.Stop("1","route","rider","delivered",507L),last=new RouteEarnings.Stop("2","route","rider","delivered",543L);
    RouteEarnings.Summary s=RouteEarnings.summarize(last,Arrays.asList(first,last,last,new RouteEarnings.Stop("3","other","rider","delivered",900L),new RouteEarnings.Stop("4","route","other","delivered",900L)));
    assertEquals(2,s.count);assertEquals(1050,s.totalCents);assertTrue(s.complete);
  }
  @Test public void unfinishedOrMissingValuesNeverPresentACompleteTotal(){
    RouteEarnings.Stop first=new RouteEarnings.Stop("1","route","rider","delivered",null),last=new RouteEarnings.Stop("2","route","rider","delivered",543L);
    RouteEarnings.Summary s=RouteEarnings.summarize(last,Arrays.asList(first,last,new RouteEarnings.Stop("3","route","rider","collected",500L)));
    assertEquals(2,s.count);assertFalse(s.complete);
  }
  @Test public void standaloneNeverAddsAnUnrelatedStop(){
    RouteEarnings.Stop a=new RouteEarnings.Stop("1","","rider","delivered",500L);
    RouteEarnings.Summary s=RouteEarnings.summarize(a,Arrays.asList(a,new RouteEarnings.Stop("2","","rider","delivered",500L)));
    assertEquals(1,s.count);assertEquals(500,s.totalCents);assertTrue(s.complete);
  }
}
