"""Handler registry keyed by the names config/subscriptions.tsv uses."""

from app.handlers import refunds, payments, shipments, cancellations

HANDLERS = {
    "payment_v1": payments.on_payment,
    "refund_v1": refunds.on_refund,
    "refund_v2": refunds.on_refund_v2,
    "refund_v3": refunds.on_refund_v3,
    "shipment_v1": shipments.on_shipment,
    "cancel_v2": cancellations.on_cancel,
}
