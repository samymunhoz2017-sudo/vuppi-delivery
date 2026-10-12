package br.com.vuppidelivery.entregador;

/** Pure state holder used to deduplicate snapshots and presentation side effects. */
final class OfferStateMachine {
  enum State { IDLE, PRESENTING, ACCEPT_SUBMITTING, ACCEPTED_CONFIRMED, REJECT_SUBMITTING, REJECTED_CONFIRMED, SUPPRESSED_LOCAL, EXPIRED, RECONCILING }
  enum Observation { NEW, CURRENT, SUPPRESSED, CLEARED }

  private String offerId = "";
  private State state = State.IDLE;

  synchronized Observation observe(String candidateId, boolean suppressed) {
    String next = candidateId == null ? "" : candidateId;
    if (next.isEmpty()) {
      boolean hadOffer = !offerId.isEmpty();
      offerId = "";
      state = hadOffer ? State.EXPIRED : State.IDLE;
      return Observation.CLEARED;
    }
    if (suppressed) {
      offerId = next;
      state = State.SUPPRESSED_LOCAL;
      return Observation.SUPPRESSED;
    }
    if (next.equals(offerId) && state != State.EXPIRED && state != State.IDLE && state != State.SUPPRESSED_LOCAL) return Observation.CURRENT;
    offerId = next;
    state = State.PRESENTING;
    return Observation.NEW;
  }

  synchronized boolean beginAccept(String id) {
    if (!offerId.equals(id) || state != State.PRESENTING) return false;
    state = State.ACCEPT_SUBMITTING;
    return true;
  }

  synchronized void acceptingFailed() {
    if (state == State.ACCEPT_SUBMITTING) state = State.RECONCILING;
  }

  synchronized void accepted(String id) {
    if (offerId.equals(id)) state = State.ACCEPTED_CONFIRMED;
  }

  synchronized boolean beginReject(String id) {
    if (!offerId.equals(id) || state != State.PRESENTING) return false;
    state = State.REJECT_SUBMITTING;
    return true;
  }

  synchronized void rejected(String id) {
    if (offerId.equals(id)) state = State.REJECTED_CONFIRMED;
  }

  synchronized void rejectingFailed() {
    if (state == State.REJECT_SUBMITTING) state = State.RECONCILING;
  }

  synchronized void suppress(String id) {
    if (offerId.equals(id)) state = State.SUPPRESSED_LOCAL;
  }

  synchronized String offerId() { return offerId; }
  synchronized State state() { return state; }
  synchronized boolean isPresentable() { return state == State.PRESENTING; }
}
