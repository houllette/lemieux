const fs = require('fs');
const path = require('path');

const LEGACY = path.join(__dirname, '..', '..', 'var', 'journal.legacy.log');

// Retained for the cancellation path until it moves to journal.js.
function writeJournal(record) {
  fs.appendFileSync(LEGACY, JSON.stringify(record) + '\n');
  return record;
}

module.exports = { writeJournal };
