package br.com.vuppidelivery.entregador;

import android.content.Context;
import android.graphics.*;
import android.view.View;

public final class EarningsChartView extends View {
  private int[] values=new int[]{0};
  private final Paint line=new Paint(1),fill=new Paint(1),grid=new Paint(1),dot=new Paint(1);
  public EarningsChartView(Context context){super(context);line.setColor(Color.rgb(112,33,232));line.setStrokeWidth(7);line.setStyle(Paint.Style.STROKE);line.setStrokeCap(Paint.Cap.ROUND);line.setStrokeJoin(Paint.Join.ROUND);fill.setShader(new LinearGradient(0,0,0,260,Color.argb(120,112,33,232),Color.argb(5,112,33,232),Shader.TileMode.CLAMP));grid.setColor(Color.rgb(229,222,238));grid.setStrokeWidth(2);dot.setColor(Color.WHITE);dot.setStyle(Paint.Style.FILL);}
  public void setValues(int[] next){values=next==null||next.length==0?new int[]{0}:next;invalidate();}
  @Override protected void onDraw(Canvas c){super.onDraw(c);float left=20,top=22,right=getWidth()-20,bottom=getHeight()-24;for(int i=0;i<4;i++){float y=top+(bottom-top)*i/3f;c.drawLine(left,y,right,y,grid);}int max=1;for(int v:values)max=Math.max(max,v);Path path=new Path();for(int i=0;i<values.length;i++){float x=values.length==1?(left+right)/2:left+(right-left)*i/(values.length-1f),y=bottom-(bottom-top)*values[i]/max;if(i==0)path.moveTo(x,y);else path.lineTo(x,y);}Path area=new Path(path);area.lineTo(right,bottom);area.lineTo(left,bottom);area.close();c.drawPath(area,fill);c.drawPath(path,line);for(int i=0;i<values.length;i++){float x=values.length==1?(left+right)/2:left+(right-left)*i/(values.length-1f),y=bottom-(bottom-top)*values[i]/max;c.drawCircle(x,y,8,line);c.drawCircle(x,y,4,dot);}}
}
