module.exports = {
  onOrderPaid: require('./payments').onOrderPaid,
  onOrderCancelled: require('./cancellations').onOrderCancelled,
};
