const { buildEntry, appendEntry } = require('./journal');

function settle(orderId, amountCents) {
  const entry = buildEntry('settle', orderId, amountCents);
  return appendEntry(entry);
}

module.exports = { settle };
