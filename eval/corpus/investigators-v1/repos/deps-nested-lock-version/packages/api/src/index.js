const leftPad = require('left-pad');

function formatAmount(cents) {
  return leftPad(String(cents), 8, '0');
}

module.exports = { formatAmount };
