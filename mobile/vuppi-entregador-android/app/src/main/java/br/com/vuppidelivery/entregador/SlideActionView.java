package br.com.vuppidelivery.entregador;

import android.content.Context;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.view.Gravity;
import android.view.MotionEvent;
import android.widget.FrameLayout;
import android.widget.TextView;

/** Fires an action only after a deliberate horizontal drag. */
public final class SlideActionView extends FrameLayout {
  public interface Listener { void onConfirmed(); }
  private final android.view.View thumb;
  private final TextView label;
  private Listener listener;
  private float downX;
  private int travel;
  private boolean dragging;

  public SlideActionView(Context context, String title) {
    super(context);
    setMinimumHeight(dp(58));
    setPadding(dp(5), dp(5), dp(5), dp(5));
    setBackground(round(Color.rgb(111, 32, 217), 18));
    label = new TextView(context);
    label.setText(title + "   ››");
    label.setTextColor(Color.WHITE);
    label.setTextSize(15);
    label.setGravity(Gravity.CENTER);
    label.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
    addView(label, new LayoutParams(-1, -1));
    thumb = new android.view.View(context);
    thumb.setBackground(round(Color.WHITE, 15));
    LayoutParams tp = new LayoutParams(dp(48), dp(48));
    tp.gravity = Gravity.START | Gravity.CENTER_VERTICAL;
    addView(thumb, tp);
    setContentDescription(title + ". Arraste para a direita para confirmar.");
  }

  public void setOnConfirmedListener(Listener value) { listener = value; }
  public void setActionEnabled(boolean enabled) { setEnabled(enabled); setAlpha(enabled ? 1f : .55f); if (!enabled) reset(); }
  @Override protected void onSizeChanged(int w, int h, int oldw, int oldh) { travel = Math.max(0, w - getPaddingLeft() - getPaddingRight() - thumb.getLayoutParams().width); }
  @Override public boolean onTouchEvent(MotionEvent event) {
    if (!isEnabled()) return true;
    switch (event.getActionMasked()) {
      case MotionEvent.ACTION_DOWN: downX = event.getX(); dragging = true; getParent().requestDisallowInterceptTouchEvent(true); return true;
      case MotionEvent.ACTION_MOVE:
        if (!dragging) return true;
        float x = Math.max(0, Math.min(travel, event.getX() - downX));
        thumb.setTranslationX(x); label.setAlpha(1f - .55f * (x / Math.max(1f, travel))); return true;
      case MotionEvent.ACTION_UP:
      case MotionEvent.ACTION_CANCEL:
        getParent().requestDisallowInterceptTouchEvent(false);
        if (dragging && thumb.getTranslationX() >= travel * .78f && event.getActionMasked() == MotionEvent.ACTION_UP) {
          performHapticFeedback(android.view.HapticFeedbackConstants.CONFIRM);
          thumb.animate().translationX(travel).setDuration(100).withEndAction(() -> { if (listener != null) listener.onConfirmed(); reset(); }).start();
        } else reset();
        dragging = false; return true;
      default: return true;
    }
  }
  private void reset() { thumb.animate().translationX(0).setDuration(180).start(); label.animate().alpha(1f).setDuration(180).start(); }
  private GradientDrawable round(int color, int radius) { GradientDrawable d = new GradientDrawable(); d.setColor(color); d.setCornerRadius(dp(radius)); return d; }
  private int dp(int v) { return Math.round(v * getResources().getDisplayMetrics().density); }
}
