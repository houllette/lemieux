const { EventEmitter } = require('events');

module.exports = { bus: new EventEmitter() };
