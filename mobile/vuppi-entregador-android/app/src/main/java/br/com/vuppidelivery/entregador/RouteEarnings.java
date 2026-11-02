package br.com.vuppidelivery.entregador;
import java.util.HashSet;
import java.util.Set;
/** Presentation only: sums finalized, distinct stops with recorded net amounts. */
public final class RouteEarnings {
  public static final class Stop {
    public final String id, group, courier, status;
    public final Long netCents;
    public Stop(String id,String group,String courier,String status,Long netCents){this.id=id;this.group=group;this.courier=courier;this.status=status;this.netCents=netCents;}
  }
  public static final class Summary {
    public final int count; public final long totalCents; public final boolean complete;
    Summary(int count,long totalCents,boolean complete){this.count=count;this.totalCents=totalCents;this.complete=complete;}
  }
  public static Summary summarize(Stop anchor,Iterable<Stop> stops){
    if(anchor==null||anchor.id==null||anchor.id.isEmpty())return new Summary(0,0,false);
    boolean grouped=anchor.group!=null&&!anchor.group.isEmpty()&&!"null".equalsIgnoreCase(anchor.group);
    if(grouped&&(anchor.courier==null||anchor.courier.isEmpty()||"null".equalsIgnoreCase(anchor.courier)))return new Summary(0,0,false);
    Set<String> seen=new HashSet<>();int count=0;long total=0;boolean complete=true;
    for(Stop row:stops){if(row==null||row.id==null||row.id.isEmpty()||!"delivered".equals(row.status))continue;
      boolean matches=grouped?anchor.group.equals(row.group)&&anchor.courier.equals(row.courier):anchor.id.equals(row.id);
      if(!matches||!seen.add(row.id))continue;count++;
      if(row.netCents==null||row.netCents<0||Long.MAX_VALUE-total<row.netCents)complete=false;else total+=row.netCents;
    }
    return new Summary(count,total,complete&&count>0&&seen.contains(anchor.id));
  }
}
