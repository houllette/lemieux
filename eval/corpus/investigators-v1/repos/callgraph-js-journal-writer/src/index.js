const { bus } = require('./bus');
const handlers = require('./handlers');

bus.on('order.paid', handlers.onOrderPaid);
bus.on('order.cancelled', handlers.onOrderCancelled);

module.exports = { bus };
