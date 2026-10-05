const { writeJournal } = require('../ledger/legacyJournal');

function onOrderCancelled(event) {
  return writeJournal({ type: 'cancel', orderId: event.orderId });
}

module.exports = { onOrderCancelled };
