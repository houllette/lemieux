const { settle } = require('../ledger/settle');

function onOrderPaid(event) {
  return settle(event.orderId, event.amountCents);
}

module.exports = { onOrderPaid };
