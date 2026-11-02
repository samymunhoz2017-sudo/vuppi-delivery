package br.com.vuppidelivery.entregador;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.Rect;
import android.graphics.RectF;
import android.view.View;

/** Displays the actual Vuppi wordmark from the brand guide supplied by the owner. */
public final class VuppiBrandView extends View {
  private final Bitmap guide;
  private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG | Paint.FILTER_BITMAP_FLAG);
  private final Rect source = new Rect(20, 20, 435, 155);
  public VuppiBrandView(Context context) {
    super(context);
    guide = BitmapFactory.decodeResource(getResources(), R.drawable.vuppi_brand_guide);
    setContentDescription("Vuppi Delivery");
  }
  @Override protected void onDraw(Canvas canvas) {
    super.onDraw(canvas);
    if (guide == null) return;
    float scale = Math.min(getWidth() / (float) source.width(), getHeight() / (float) source.height());
    float width = source.width() * scale, height = source.height() * scale;
    float left = (getWidth() - width) / 2, top = (getHeight() - height) / 2;
    canvas.drawBitmap(guide, source, new RectF(left, top, left + width, top + height), paint);
  }
}
