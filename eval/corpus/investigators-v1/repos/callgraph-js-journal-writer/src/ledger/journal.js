const fs = require('fs');
const path = require('path');

const JOURNAL = path.join(__dirname, '..', '..', 'var', 'journal.log');

function buildEntry(type, orderId, amountCents) {
  return { type, orderId, amountCents, at: new Date().toISOString() };
}

function appendEntry(entry) {
  fs.appendFileSync(JOURNAL, JSON.stringify(entry) + '\n');
  return entry;
}

module.exports = { buildEntry, appendEntry };
