package br.com.vuppidelivery.entregador;

import android.content.Context;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.view.Gravity;
import android.view.HapticFeedbackConstants;
import android.view.MotionEvent;
import android.view.View;
import android.widget.FrameLayout;
import android.widget.TextView;

/** Reusable deliberate-drag action; the caller re-enables it after a failed request. */
public final class SlideActionView extends FrameLayout {
  public interface Listener { void onConfirmed(); }
  private final View progress;
  private final TextView thumb;
  private final TextView label;
  private final String title;
  private Listener listener;
  private float downX;
  private int travel;
  private boolean dragging;
  private boolean submitting;

  public SlideActionView(Context context, String title) {
    super(context);
    this.title=title;
    setMinimumHeight(dp(58));
    setPadding(dp(5),dp(5),dp(5),dp(5));
    setBackground(round(Color.rgb(81,31,203),30));
    setClipToOutline(true);
    progress=new View(context);
    progress.setBackground(round(Color.rgb(125,76,242),30));
    LayoutParams fill=new LayoutParams(0, -1, Gravity.START|Gravity.CENTER_VERTICAL);
    addView(progress,fill);
    label=new TextView(context);
    label.setText(title);
    label.setTextColor(Color.WHITE);
    label.setTextSize(14);
    label.setSingleLine(true);
    label.setEllipsize(android.text.TextUtils.TruncateAt.END);
    label.setGravity(Gravity.CENTER);
    label.setTypeface(Typeface.DEFAULT,Typeface.BOLD);
    LayoutParams caption=new LayoutParams(-1,-1);
    caption.setMargins(dp(53),0,dp(12),0);
    addView(label,caption);
    thumb=new TextView(context);
    thumb.setText("➜");
    thumb.setTextColor(Color.rgb(81,31,203));
    thumb.setTextSize(23);
    thumb.setGravity(Gravity.CENTER);
    thumb.setTypeface(Typeface.DEFAULT,Typeface.BOLD);
    thumb.setBackground(round(Color.WHITE,28));
    LayoutParams tp=new LayoutParams(dp(48),dp(48),Gravity.START|Gravity.CENTER_VERTICAL);
    addView(thumb,tp);
    setContentDescription(title+". Arraste para a direita para confirmar.");
  }

  public void setOnConfirmedListener(Listener value){listener=value;}
  public void setActionEnabled(boolean enabled){
    setEnabled(enabled);
    if(enabled)submitting=false;
    setAlpha(enabled?1f:.72f);
    label.setText(!enabled&&submitting?"Aguarde…":title);
    if(enabled)reset();
  }
  @Override protected void onSizeChanged(int w,int h,int oldw,int oldh){
    travel=Math.max(0,w-getPaddingLeft()-getPaddingRight()-thumb.getLayoutParams().width);
  }
  private void updateProgress(float x){
    LayoutParams p=(LayoutParams)progress.getLayoutParams();
    p.width=Math.max(0,Math.round(x)+thumb.getWidth());
    progress.setLayoutParams(p);
    label.setAlpha(1f-.55f*(x/Math.max(1f,travel)));
  }
  @Override public boolean onTouchEvent(MotionEvent event){
    if(!isEnabled()||submitting)return true;
    switch(event.getActionMasked()){
      case MotionEvent.ACTION_DOWN:
        downX=event.getX();dragging=true;thumb.animate().cancel();getParent().requestDisallowInterceptTouchEvent(true);return true;
      case MotionEvent.ACTION_MOVE:
        if(!dragging)return true;
        float x=Math.max(0,Math.min(travel,event.getX()-downX));
        thumb.setTranslationX(x);updateProgress(x);return true;
      case MotionEvent.ACTION_UP:
      case MotionEvent.ACTION_CANCEL:
        getParent().requestDisallowInterceptTouchEvent(false);
        boolean confirmed=dragging&&travel>0&&thumb.getTranslationX()>=travel*.78f&&event.getActionMasked()==MotionEvent.ACTION_UP;
        dragging=false;
        if(confirmed){
          performHapticFeedback(HapticFeedbackConstants.CONFIRM);
          submitting=true;setEnabled(false);label.setText("Aguarde…");label.setAlpha(1f);
          thumb.animate().translationX(travel).setDuration(100).withEndAction(()->{if(listener!=null)listener.onConfirmed();else setActionEnabled(true);}).start();
        }else reset();
        return true;
      default:return true;
    }
  }
  private void reset(){thumb.animate().translationX(0).setDuration(180).withEndAction(()->updateProgress(0)).start();label.animate().alpha(1f).setDuration(180).start();}
  private GradientDrawable round(int color,int radius){GradientDrawable d=new GradientDrawable();d.setColor(color);d.setCornerRadius(dp(radius));return d;}
  private int dp(int v){return Math.round(v*getResources().getDisplayMetrics().density);}
}
