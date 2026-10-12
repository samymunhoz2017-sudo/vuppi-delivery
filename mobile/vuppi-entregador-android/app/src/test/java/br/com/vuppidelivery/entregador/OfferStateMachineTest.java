package br.com.vuppidelivery.entregador;

import static org.junit.Assert.*;
import org.junit.Test;

public class OfferStateMachineTest {
  @Test public void duplicateSnapshotDoesNotCreateAnotherPresentation() {
    OfferStateMachine machine = new OfferStateMachine();
    assertEquals(OfferStateMachine.Observation.NEW, machine.observe("delivery-1", false));
    assertEquals(OfferStateMachine.Observation.CURRENT, machine.observe("delivery-1", false));
    assertEquals(OfferStateMachine.State.PRESENTING, machine.state());
  }

  @Test public void suppressionPreventsSameDeliveryFromPresenting() {
    OfferStateMachine machine = new OfferStateMachine();
    machine.observe("delivery-1", false);
    machine.suppress("delivery-1");
    assertEquals(OfferStateMachine.Observation.SUPPRESSED, machine.observe("delivery-1", true));
    assertEquals(OfferStateMachine.State.SUPPRESSED_LOCAL, machine.state());
  }

  @Test public void acceptingIsSingleFlightAndNetworkFailureDoesNotRealert() {
    OfferStateMachine machine = new OfferStateMachine();
    machine.observe("delivery-1", false);
    assertTrue(machine.beginAccept("delivery-1"));
    assertFalse(machine.beginAccept("delivery-1"));
    machine.acceptingFailed();
    assertEquals(OfferStateMachine.Observation.CURRENT, machine.observe("delivery-1", false));
    assertEquals(OfferStateMachine.State.RECONCILING, machine.state());
    assertFalse(machine.isPresentable());
  }

  @Test public void acceptedSnapshotCannotReopenPresentation() {
    OfferStateMachine machine = new OfferStateMachine();
    machine.observe("delivery-1", false);
    assertTrue(machine.beginAccept("delivery-1"));
    machine.accepted("delivery-1");
    assertEquals(OfferStateMachine.Observation.CURRENT, machine.observe("delivery-1", false));
    assertFalse(machine.isPresentable());
  }

  @Test public void rejectIsSingleFlightAndCannotReopenPresentation() {
    OfferStateMachine machine = new OfferStateMachine();
    machine.observe("delivery-1", false);
    assertTrue(machine.beginReject("delivery-1"));
    assertFalse(machine.beginReject("delivery-1"));
    machine.rejected("delivery-1");
    assertEquals(OfferStateMachine.Observation.CURRENT, machine.observe("delivery-1", false));
    assertFalse(machine.isPresentable());
  }

  @Test public void differentDeliveryCreatesNewPresentation() {
    OfferStateMachine machine = new OfferStateMachine();
    machine.observe("delivery-1", false);
    assertEquals(OfferStateMachine.Observation.NEW, machine.observe("delivery-2", false));
    assertEquals("delivery-2", machine.offerId());
  }

  @Test public void emptySnapshotClearsCurrentOffer() {
    OfferStateMachine machine = new OfferStateMachine();
    machine.observe("delivery-1", false);
    assertEquals(OfferStateMachine.Observation.CLEARED, machine.observe("", false));
    assertEquals(OfferStateMachine.State.EXPIRED, machine.state());
  }
}
