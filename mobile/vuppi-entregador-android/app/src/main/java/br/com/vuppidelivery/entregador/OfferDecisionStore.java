package br.com.vuppidelivery.entregador;

import android.content.Context;
import android.content.SharedPreferences;
import java.util.ArrayList;
import java.util.List;

/** Temporary device-side suppression. Server-side rejection is intentionally a separate contract. */
final class OfferDecisionStore {
  private static final String PREF = "vuppi.offer.decisions.v1";
  private static final long SUPPRESSION_MS = 24L * 60L * 60L * 1000L;
  private final SharedPreferences preferences;

  OfferDecisionStore(Context context) {
    preferences = context.getApplicationContext().getSharedPreferences(PREF, 0);
  }

  void suppressLocally(String offerId, long now) {
    if (offerId != null && !offerId.isEmpty()) preferences.edit().putLong(key(offerId), now + SUPPRESSION_MS).apply();
  }

  void markPendingReject(String offerId, long now) {
    if (offerId != null && !offerId.isEmpty()) preferences.edit().putLong(pendingKey(offerId), now).apply();
  }

  void markRejectSynced(String offerId) {
    if (offerId != null && !offerId.isEmpty()) preferences.edit().remove(pendingKey(offerId)).apply();
  }

  List<String> pendingRejects() {
    List<String> ids = new ArrayList<>();
    for (String stored : preferences.getAll().keySet()) if (stored.startsWith("pending.reject.")) ids.add(stored.substring("pending.reject.".length()));
    return ids;
  }

  boolean isSuppressed(String offerId, long now) {
    if (offerId == null || offerId.isEmpty()) return false;
    long until = preferences.getLong(key(offerId), 0L);
    if (until <= now) {
      if (until != 0L) preferences.edit().remove(key(offerId)).apply();
      return false;
    }
    return true;
  }

  void clear() { preferences.edit().clear().apply(); }
  private String key(String id) { return "delivery." + id; }
  private String pendingKey(String id) { return "pending.reject." + id; }
}
