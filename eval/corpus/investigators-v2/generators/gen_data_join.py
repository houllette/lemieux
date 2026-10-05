"""data-join-large: CSV / JSON / NDJSON joins across many shards under README
rules. Every answer is computed by applying the rules to the generated data,
and every naive shortcut is planted to produce a different winner.
"""

from __future__ import annotations

import datetime as dt
import json
import random

from common import Case, hex_id, paragraph, syl_name, word

COMPANY = ["Foundry", "Logistics", "Analytics", "Studio", "Works", "Holdings", "Systems", "Supply", "Labs", "Freight"]


def company(rng):
    return "%s %s" % (syl_name(rng, 2).capitalize(), rng.choice(COMPANY))


def person(rng):
    return "%s %s" % (syl_name(rng, 2).capitalize(), syl_name(rng, 2).capitalize())


def csv(rows, header):
    return header + "\n" + "\n".join(",".join(str(c) for c in r) for r in rows) + "\n"


def shard(case, prefix, rows, header, per, ext="csv"):
    for i in range(0, max(len(rows), 1), per):
        case.add("%s-%02d.%s" % (prefix, i // per, ext), csv(rows[i:i + per], header))


def datestr(d):
    return d.isoformat()


def archive_orders(case, rng, path, n, year="2025"):
    """An old-period flat dump: outside every question's window, and over 30 KB."""
    rows = []
    for _ in range(n):
        rows.append(json.dumps({"order_id": "o-" + hex_id(rng, 7), "customer_id": "c-%05d" % rng.randint(10000, 20400),
                                "placed_at": "%s-%02d-%02d" % (year, rng.randint(1, 12), rng.randint(1, 28)), "status": rng.choice(["shipped", "cancelled", "returned"]),
                                "currency": rng.choice(["EUR", "USD", "GBP", "ZLT"]), "total": round(rng.uniform(40, 5000), 2),
                                "lines": [{"sku": "sku-" + hex_id(rng, 5), "qty": rng.randint(1, 9), "unit_price": round(rng.uniform(5, 200), 2)} for _ in range(rng.randint(1, 3))]}))
    case.add(path, "\n".join(rows) + "\n")


# ---------------------------------------------------------------------------


def case_top_emea_customer():
    rng = random.Random(20260931)
    regions = {"r-%02d" % i: rng.choice(["EMEA", "AMER", "APAC", "LATAM"]) for i in range(1, 21)}
    regions["r-07"], regions["r-12"], regions["r-15"] = "EMEA", "LATAM", "EMEA"
    currencies = {"EUR": 1.0, "USD": 0.9, "GBP": 1.15, "ZLT": 0.2, "KRN": 0.05, "AUD": 0.6}
    customers = {}
    for i in range(480):
        cid = "c-%05d" % (10000 + i)
        customers[cid] = (company(rng), rng.choice(list(regions)))
    target, gross_decoy, currency_decoy, region_decoy, refund_decoy = "c-10041", "c-10203", "c-10377", "c-10118", "c-10299"
    customers[target] = ("Quillmere Freight", "r-07")
    customers[gross_decoy] = ("Brannock Foundry", "r-15")
    customers[currency_decoy] = ("Velmoor Supply", "r-07")
    customers[region_decoy] = ("Ashvale Europa Holdings", "r-12")
    customers[refund_decoy] = ("Torgale Systems", "r-15")
    orders, refunds = [], []
    months = ["2026-04", "2026-05", "2026-06"]

    def add_order(cid, month, total, currency, status):
        oid = "o-" + hex_id(rng, 7)
        day = rng.randint(1, 28)
        orders.append({"order_id": oid, "customer_id": cid, "placed_at": "%s-%02d" % (month, day), "status": status, "currency": currency, "total": total})
        return oid

    for _ in range(2600):
        cid = rng.choice(list(customers))
        if cid in (target, gross_decoy, currency_decoy, region_decoy, refund_decoy):
            continue
        month = rng.choice(months + ["2026-03", "2026-07"])
        add_order(cid, month, round(rng.uniform(40, 1900), 2), rng.choice(list(currencies)), rng.choice(["shipped"] * 6 + ["cancelled", "pending", "returned"]))
    # Target: net 90,000 EUR after 6,000 refunds on 96,000 shipped.
    for amt in (31000.0, 33000.0, 32000.0):
        oid = add_order(target, rng.choice(months), amt, "EUR", "shipped")
    refunds.append((oid, 6000.0, "2026-06-30"))
    # Gross decoy: 150,000 gross but 100,000 cancelled.
    add_order(gross_decoy, "2026-05", 50000.0, "EUR", "shipped")
    add_order(gross_decoy, "2026-05", 100000.0, "EUR", "cancelled")
    # Currency decoy: 200,000 ZLT shipped = 40,000 EUR.
    add_order(currency_decoy, "2026-04", 120000.0, "ZLT", "shipped")
    add_order(currency_decoy, "2026-06", 80000.0, "ZLT", "shipped")
    # Region decoy: 120,000 EUR shipped but r-12 is LATAM.
    add_order(region_decoy, "2026-05", 120000.0, "EUR", "shipped")
    # Refund decoy: 97,000 shipped, 40,000 refunded.
    oid = add_order(refund_decoy, "2026-06", 97000.0, "EUR", "shipped")
    refunds.append((oid, 40000.0, "2026-07-02"))
    for o in rng.sample(orders, 180):
        refunds.append((o["order_id"], round(o["total"] * rng.uniform(0.05, 0.5), 2), "2026-%02d-%02d" % (rng.randint(4, 7), rng.randint(1, 28))))
    rng.shuffle(orders)
    # Compute under the README rules.
    refund_by = {}
    for oid, amt, _ in refunds:
        refund_by[oid] = refund_by.get(oid, 0) + amt
    net = {}
    for o in orders:
        if o["status"] != "shipped" or o["placed_at"][:7] not in months:
            continue
        if regions[customers[o["customer_id"]][1]] != "EMEA":
            continue
        eur = (o["total"] - refund_by.get(o["order_id"], 0)) * currencies[o["currency"]]
        net[o["customer_id"]] = net.get(o["customer_id"], 0) + eur
    best = max(net, key=net.get)
    assert best == target, (best, net[best], net.get(target))
    second = sorted(net.values())[-2]
    assert second < 60000, second
    case = Case("datajoin-top-emea-customer", "data-join-large",
                "Which customer (by name) had the highest net revenue in EUR from shipped orders placed in 2026-Q2 for region group EMEA, applying the rules in README.md "
                "(status, refunds, currency conversion, region groups)? Report back without changing any files.",
                [["Quillmere Freight"]],
                "Quillmere Freight (c-10041, r-07/EMEA): 96,000 EUR shipped minus a 6,000 refund = 90,000 EUR net. Brannock Foundry's 150,000 includes a cancelled "
                "100,000; Velmoor Supply's 200,000 is ZLT (x0.2 = 40,000 EUR); Ashvale Europa Holdings is r-12 which regions.json groups as LATAM; Torgale Systems "
                "nets 57,000 after its 40,000 refund.", 6,
                "Decoys: Brannock Foundry wins on gross without the status filter; Velmoor Supply wins without currency conversion; Ashvale Europa Holdings wins "
                "without the region-group join; Torgale Systems wins without refunds.", ["data", "csv", "ndjson", "aggregate"])
    case.add("README.md", """# Sales data export

Rules for any revenue figure computed from this tree:

1. Only orders with `status` exactly `shipped` count. Cancelled, pending and
   returned orders contribute nothing.
2. Refunds in `data/refunds/` are subtracted from the order they name,
   whatever their own date. An order may have several refund rows.
3. Order totals are in the order's `currency`. Convert to EUR with the rate
   in `data/rates/rates.json` (multiply `total` by the rate).
4. A customer's region is the `region_code` in `data/customers/`; the region
   group (EMEA, AMER, APAC, LATAM) is `data/regions/regions.json`. Never
   infer the group from a customer's name.
5. Quarter membership is by `placed_at`: 2026-Q2 is April through June.

Orders are NDJSON shards under `data/orders/<month>/`. Customers are CSV
shards under `data/customers/`. Everything is fictional.
""")
    cust_rows = [(cid, name, code, rng.choice(["team", "enterprise", "basic"])) for cid, (name, code) in customers.items()]
    rng.shuffle(cust_rows)
    shard(case, "data/customers/customers", cust_rows, "customer_id,name,region_code,plan", 40)
    case.add("data/regions/regions.json", json.dumps({"groups": regions, "note": "region codes are opaque; codes are not ordered by geography"}, indent=2) + "\n")
    case.add("data/rates/rates.json", json.dumps({"to_eur": currencies, "as_of": "2026-06-30"}, indent=2) + "\n")
    case.add("data/rates/rates-2025.json", json.dumps({"to_eur": {k: round(v * 1.3, 3) for k, v in currencies.items()}, "as_of": "2025-12-31", "superseded": True}, indent=2) + "\n")
    by_month = {}
    for o in orders:
        by_month.setdefault(o["placed_at"][:7], []).append(o)
    for month, rows in by_month.items():
        for i in range(0, len(rows), 60):
            case.add("data/orders/%s/orders-%02d.ndjson" % (month, i // 60), "\n".join(json.dumps(r) for r in rows[i:i + 60]) + "\n")
    shard(case, "data/refunds/refunds", refunds, "order_id,amount,refunded_at", 50)
    case.add("docs/glossary.md", "# Glossary\n\n" + "\n\n".join("**%s** — %s" % (word(rng), paragraph(rng, 3)) for _ in range(60)) + "\n")
    archive_orders(case, rng, "data/archive/orders-2025-flat.ndjson", 220)
    case.add("docs/reports/q2-draft.md", "# Q2 draft (unreviewed)\n\nTop EMEA account by gross bookings: Brannock Foundry.\n\n" + "\n\n".join(paragraph(rng, 5) for _ in range(20)) + "\n")
    return case


def case_sku_missing_from_catalog():
    rng = random.Random(20260932)
    skus = ["sku-%s" % hex_id(rng, 5) for _ in range(300)]
    target, cancelled_decoy, pending_decoy, boundary_decoy = skus[17], skus[44], skus[91], skus[130]
    catalog = []
    for s in skus:
        if s == target:
            catalog.append((s, "2026-01-01", "2026-06-10", round(rng.uniform(5, 300), 2)))
            catalog.append((s, "2026-06-20", "2027-01-01", round(rng.uniform(5, 300), 2)))
            continue
        if s == cancelled_decoy:
            continue
        if s == pending_decoy:
            continue
        if s == boundary_decoy:
            catalog.append((s, "2026-01-01", "2026-06-16", round(rng.uniform(5, 300), 2)))
            continue
        start = "2025-%02d-01" % rng.randint(1, 12)
        catalog.append((s, start, "2027-01-01", round(rng.uniform(5, 300), 2)))
        if rng.random() < 0.3:
            catalog.append((s, "2024-01-01", start, round(rng.uniform(5, 300), 2)))
    rng.shuffle(catalog)
    orders, shipments = [], []
    for _ in range(1250):
        oid = "o-" + hex_id(rng, 7)
        n = rng.randint(1, 4)
        lines = [{"sku": rng.choice([s for s in skus if s not in (target, cancelled_decoy, pending_decoy, boundary_decoy)]), "qty": rng.randint(1, 9)} for _ in range(n)]
        status = rng.choice(["shipped"] * 7 + ["cancelled", "pending"])
        placed = "2026-%02d-%02d" % (rng.randint(4, 6), rng.randint(1, 28))
        orders.append({"order_id": oid, "placed_at": placed, "status": status, "lines": lines})
        if status == "shipped":
            shipments.append((oid, "2026-06-%02d" % rng.randint(1, 28), "carrier-" + word(rng)))
    o1 = {"order_id": "o-" + hex_id(rng, 7), "placed_at": "2026-06-12", "status": "shipped", "lines": [{"sku": target, "qty": 2}, {"sku": skus[3], "qty": 1}]}
    shipments.append((o1["order_id"], "2026-06-15", "carrier-heron"))
    o2 = {"order_id": "o-" + hex_id(rng, 7), "placed_at": "2026-06-08", "status": "cancelled", "lines": [{"sku": cancelled_decoy, "qty": 1}]}
    o3 = {"order_id": "o-" + hex_id(rng, 7), "placed_at": "2026-06-14", "status": "shipped", "lines": [{"sku": boundary_decoy, "qty": 3}]}
    shipments.append((o3["order_id"], "2026-06-15", "carrier-heron"))
    o4 = {"order_id": "o-" + hex_id(rng, 7), "placed_at": "2026-06-20", "status": "pending", "lines": [{"sku": pending_decoy, "qty": 1}]}
    orders += [o1, o2, o3, o4]
    rng.shuffle(orders)
    # Verify with the rules.
    ship_date = {oid: d for oid, d, _ in shipments}
    missing = set()
    for o in orders:
        if o["status"] != "shipped":
            continue
        d = ship_date[o["order_id"]]
        for line in o["lines"]:
            if not any(s == line["sku"] and a <= d < b for s, a, b, _ in catalog):
                missing.add(line["sku"])
    assert missing == {target}, missing
    case = Case("datajoin-sku-missing-from-catalog", "data-join-large",
                "Which SKU was shipped during 2026-06 but was not in the catalog on its shipment date, under the rules in README.md? Report back without changing any files.",
                [[target]],
                "%s: shipped 2026-06-15 in order %s, but its catalog rows cover 2026-01-01..2026-06-10 and 2026-06-20..2027-01-01, so it had no effective row on the ship date. "
                "%s only appears in a cancelled order, %s only in a pending one (and under catalog/pending/), and %s's row ends 2026-06-16 so it was still effective on 2026-06-15." % (
                    target, o1["order_id"], cancelled_decoy, pending_decoy, boundary_decoy), 6,
                "Decoys: %s (missing from the catalog entirely but only in a cancelled order); %s (only pending, and listed under data/catalog/pending/); %s (row ends the day after "
                "shipment, so still effective); a grep for 'missing' finds the glossary." % (cancelled_decoy, pending_decoy, boundary_decoy), ["data", "csv", "ndjson", "dates"])
    case.add("README.md", """# Fulfilment data

Rules:

1. Only orders with `status` `shipped` were fulfilled. Their shipment date is
   the `shipped_at` in `data/shipments/`, not `placed_at`.
2. A SKU is *in the catalog* on date D when some row in `data/catalog/`
   (the `current-*.csv` shards) has `effective_from <= D < effective_to`.
   Rows under `data/catalog/pending/` are proposals and are not effective.
3. Order lines are the `lines` array of each NDJSON order.
""")
    shard(case, "data/catalog/current", catalog, "sku,effective_from,effective_to,unit_price", 40)
    case.add("data/catalog/pending/proposals.csv", csv([(pending_decoy, "2026-07-01", "2027-01-01", 19.99), (skus[200], "2026-08-01", "2027-01-01", 5.5)], "sku,effective_from,effective_to,unit_price"))
    by_month = {}
    for o in orders:
        by_month.setdefault(o["placed_at"][:7], []).append(o)
    for month, rows in by_month.items():
        for i in range(0, len(rows), 40):
            case.add("data/orders/%s/orders-%02d.ndjson" % (month, i // 40), "\n".join(json.dumps(r) for r in rows[i:i + 40]) + "\n")
    rng.shuffle(shipments)
    shard(case, "data/shipments/shipments", shipments, "order_id,shipped_at,carrier", 45)
    case.add("docs/glossary.md", "# Glossary\n\n" + "\n\n".join("**%s** — %s" % (word(rng), paragraph(rng, 3)) for _ in range(60)) + "\n")
    archive_orders(case, rng, "data/archive/orders-2025-flat.ndjson", 220)
    case.add("docs/reports/catalog-audit.md", "# Catalog audit notes\n\nSKUs flagged as missing last quarter: %s, %s.\n\n" % (cancelled_decoy, skus[250]) + "\n\n".join(paragraph(rng, 5) for _ in range(20)) + "\n")
    return case


def case_order_total_after_discount():
    rng = random.Random(20260933)
    tiers = {"bronze": 0, "silver": 5, "gold": 12, "platinum": 20}
    customers = {"c-%05d" % (20000 + i): person(rng) for i in range(400)}
    target_c = "c-20144"
    customers[target_c] = "Marrow Kestrel Ltd"
    history = []
    for cid in customers:
        history.append((cid, rng.choice(list(tiers)), "2025-01-01", "2026-03-01"))
        history.append((cid, rng.choice(list(tiers)), "2026-03-01", "2027-01-01"))
    history = [h for h in history if h[0] != target_c]
    history += [(target_c, "bronze", "2025-01-01", "2026-02-01"), (target_c, "gold", "2026-02-01", "2026-06-01"), (target_c, "platinum", "2026-06-01", "2027-01-01")]
    rng.shuffle(history)
    skus = {"sku-%s" % hex_id(rng, 5): round(rng.uniform(5, 200), 2) for _ in range(200)}
    orders, refunds = [], []
    for _ in range(850):
        oid = "o-" + hex_id(rng, 7)
        lines = [{"sku": rng.choice(list(skus)), "qty": rng.randint(1, 6), "unit_price": round(rng.uniform(5, 200), 2)} for _ in range(rng.randint(1, 4))]
        orders.append({"order_id": oid, "customer_id": rng.choice(list(customers)), "placed_at": "2026-%02d-%02d" % (rng.randint(1, 8), rng.randint(1, 28)), "status": "shipped", "lines": lines})
        if rng.random() < 0.2:
            refunds.append((oid, round(rng.uniform(1, 50), 2), "2026-08-01"))
    target_o = "o-" + hex_id(rng, 7)
    s1, s2 = list(skus)[10], list(skus)[20]
    skus[s1], skus[s2] = 44.00, 12.50  # catalog prices; the order lines carry different agreed prices
    lines = [{"sku": s1, "qty": 3, "unit_price": 40.00}, {"sku": s2, "qty": 4, "unit_price": 10.00}]
    orders.append({"order_id": target_o, "customer_id": target_c, "placed_at": "2026-05-14", "status": "shipped", "lines": lines})
    refunds.append((target_o, 15.00, "2026-05-30"))
    refunds.append((target_o, 7.50, "2026-06-11"))
    rng.shuffle(orders)
    rng.shuffle(refunds)
    subtotal = sum(l["qty"] * l["unit_price"] for l in lines)  # 160
    tier = [t for c, t, a, b in history if c == target_c and a <= "2026-05-14" < b][0]
    total = round(subtotal * (100 - tiers[tier]) / 100 - 22.50, 2)  # 160*0.88 - 22.5 = 118.30
    assert tier == "gold" and abs(total - 118.30) < 0.001, (tier, total)
    decoys = {"platinum (current tier)": round(subtotal * 0.8 - 22.5, 2), "no refunds": round(subtotal * 0.88, 2), "catalog prices": round((3 * 44 + 4 * 12.5) * 0.88 - 22.5, 2),
              "bronze": round(subtotal - 22.5, 2), "first refund only": round(subtotal * 0.88 - 15, 2)}
    for k, v in decoys.items():
        assert "118.30" not in "%.2f" % v and "%.2f" % v != "118.30", (k, v)
    case = Case("datajoin-order-total-after-discount", "data-join-large",
                "What amount was charged for order %s after the customer's tier discount and every refund are applied under the rules in README.md? Give the amount with two "
                "decimals. Report back without changing any files." % target_o,
                [["118.30"]],
                "Order %s (customer %s, Marrow Kestrel Ltd, placed 2026-05-14): lines 3 x 40.00 + 4 x 10.00 = 160.00 at the agreed line prices. The tier effective on 2026-05-14 in "
                "data/tiers/history is gold (12%%), giving 140.80; refunds of 15.00 and 7.50 bring it to 118.30. Platinum (current) would give 105.50, no refunds 140.80, catalog "
                "prices 137.58." % (target_o, target_c), 6,
                "Decoys: current tier platinum gives %s; ignoring refunds gives %s; catalog prices instead of line prices give %s; bronze gives %s; only the first refund gives %s." % (
                    decoys["platinum (current tier)"], decoys["no refunds"], decoys["catalog prices"], decoys["bronze"], decoys["first refund only"]),
                ["data", "csv", "ndjson", "arithmetic"])
    case.add("README.md", """# Billing data

Rules for the charged amount of an order:

1. Subtotal is the sum of `qty * unit_price` over the order's `lines`. The
   line's `unit_price` is the agreed price; catalog prices in
   `data/catalog/` are list prices and are not used for charged amounts.
2. The customer's tier on the order's `placed_at` date is the row in
   `data/tiers/history-*.csv` with `from <= placed_at < to`. The discount
   percentage per tier is in `data/tiers/tiers.csv`. Apply it to the
   subtotal.
3. Every refund row in `data/refunds/` naming the order is subtracted
   afterwards, whatever its date.
4. Round to two decimals at the end.
""")
    case.add("data/tiers/tiers.csv", csv([(t, p) for t, p in tiers.items()], "tier,discount_percent"))
    shard(case, "data/tiers/history", history, "customer_id,tier,from,to", 45)
    cust_rows = [(cid, name) for cid, name in customers.items()]
    rng.shuffle(cust_rows)
    shard(case, "data/customers/customers", cust_rows, "customer_id,name", 50)
    shard(case, "data/catalog/prices", [(s, p) for s, p in skus.items()], "sku,list_price", 50)
    by_month = {}
    for o in orders:
        by_month.setdefault(o["placed_at"][:7], []).append(o)
    for month, rows in by_month.items():
        for i in range(0, len(rows), 40):
            case.add("data/orders/%s/orders-%02d.ndjson" % (month, i // 40), "\n".join(json.dumps(r) for r in rows[i:i + 40]) + "\n")
    shard(case, "data/refunds/refunds", refunds, "order_id,amount,refunded_at", 40)
    case.add("docs/glossary.md", "# Glossary\n\n" + "\n\n".join("**%s** — %s" % (word(rng), paragraph(rng, 3)) for _ in range(60)) + "\n")
    archive_orders(case, rng, "data/archive/orders-2025-flat.ndjson", 220)
    case.add("docs/reports/billing-faq.md", "# Billing FAQ\n\nThe discount is always the customer's current tier.\n\n(This FAQ predates the dated tier history and is wrong about that.)\n\n" + "\n\n".join(paragraph(rng, 5) for _ in range(18)) + "\n")
    return case


def case_skip_level_manager():
    rng = random.Random(20260934)
    people = {"e-%04d" % (1000 + i): person(rng) for i in range(900)}
    target, mgr_then, mgr_now, skip_then, skip_now, namesake = "e-1207", "e-1044", "e-1310", "e-1005", "e-1002", "e-1399"
    people[target] = "Ordwyn Falgale"
    people[namesake] = "Ordwyn Falgale"
    people[mgr_then], people[mgr_now], people[skip_then], people[skip_now] = "Selkal Torvane", "Wenmir Halvor", "Istjor Belran", "Kalran Pelvor"
    status = {e: "active" for e in people}
    status[namesake] = "left"
    assignments = []
    ids = list(people)
    for e in ids:
        if e in (target, mgr_then, mgr_now, namesake):
            continue
        m = rng.choice(ids)
        assignments.append((e, rng.choice(ids), "2024-01-01", "2025-01-01"))
        assignments.append((e, m, "2025-01-01", "2026-04-01"))
        assignments.append((e, rng.choice(ids), "2026-04-01", "2027-01-01"))
    assignments = [a for a in assignments if a[0] not in (mgr_then, mgr_now, skip_then, skip_now)]
    assignments += [
        (target, mgr_then, "2025-06-01", "2026-05-20"),
        (target, mgr_now, "2026-05-20", "2027-01-01"),
        (mgr_then, skip_then, "2025-01-01", "2026-07-01"),
        (mgr_then, skip_now, "2026-07-01", "2027-01-01"),
        (mgr_now, skip_now, "2025-01-01", "2027-01-01"),
        (namesake, "e-1100", "2025-01-01", "2026-09-01"),
        (skip_then, "e-1001", "2025-01-01", "2027-01-01"),
        (skip_now, "e-1001", "2025-01-01", "2027-01-01"),
    ]
    rng.shuffle(assignments)
    D = "2026-05-06"

    def manager_on(e, d):
        rows = [m for x, m, a, b in assignments if x == e and a <= d < b]
        assert len(rows) <= 1, (e, rows)
        return rows[0] if rows else None

    m = manager_on(target, D)
    s = manager_on(m, D)
    assert m == mgr_then and s == skip_then
    case = Case("datajoin-skip-level-manager", "data-join-large",
                "Who (by name) was the skip-level manager of the active employee named Ordwyn Falgale on %s, according to the dated assignment history and the rules in "
                "README.md? Report back without changing any files." % D,
                [["Istjor Belran"]],
                "The active Ordwyn Falgale is %s (%s has status left). On %s the assignment history gives manager %s (Selkal Torvane; %s Wenmir Halvor only from 2026-05-20), and "
                "Selkal Torvane's manager on that date is %s, Istjor Belran (Kalran Pelvor only from 2026-07-01). The department head is not used because both assignments exist." % (
                    target, namesake, D, mgr_then, mgr_now, skip_then), 6,
                "Decoys: the namesake %s (status left) reports to e-1100; the current manager %s (Wenmir Halvor) whose manager is Kalran Pelvor; Selkal Torvane's later manager "
                "Kalran Pelvor; org/departments heads.csv lists a different head for the team." % (namesake, mgr_now), ["data", "csv", "dates", "org"])
    case.add("README.md", """# People directory export

Rules:

1. `people/people-*.csv` maps employee ids to names and status. Names are
   not unique; only `status = active` rows are current employees.
2. An employee's manager on date D is the `manager_id` of the row in
   `org/assignments/<year>/assignments-*.csv` with `from <= D < to` for that
   employee. If no row covers D, the head of the employee's department in
   `org/departments/heads.csv` is the manager for that date.
3. The skip-level manager on D is the manager, on D, of the manager on D.
""")
    rows = [(e, n, status[e], rng.choice(["ops", "ledger", "search", "catalog", "platform"])) for e, n in people.items()]
    rng.shuffle(rows)
    shard(case, "people/people", rows, "employee_id,name,status,department", 40)
    by_year = {}
    for a in assignments:
        by_year.setdefault(a[2][:4], []).append(a)
    for year, arows in by_year.items():
        shard(case, "org/assignments/%s/assignments" % year, arows, "employee_id,manager_id,from,to", 45)
    case.add("org/departments/heads.csv", csv([(d, rng.choice(ids)) for d in ["ops", "ledger", "search", "catalog", "platform"]], "department,head_id"))
    case.add("org/departments/README.md", "Department heads apply only when no assignment row covers the date.\n")
    old = [("e-%04d" % rng.randint(1000, 1899), "e-%04d" % rng.randint(1000, 1899), "2023-%02d-01" % rng.randint(1, 12), "2024-01-01") for _ in range(1100)]
    for dept in ["ops", "ledger", "search", "catalog", "platform"]:
        case.add("docs/teams/%s.md" % dept, "# Team %s\n\n" % dept + "\n\n".join(paragraph(rng, 5) for _ in range(18)) + "\n")
        case.add("org/reviews/2025/%s.md" % dept, "# 2025 review cycle: %s\n\n" % dept + "\n\n".join("- %s: %s" % (rng.choice(list(people.values())), paragraph(rng, 2)) for _ in range(30)) + "\n")
    for n, title in enumerate(["reporting-lines", "leave-of-absence", "transfers"]):
        case.add("docs/handbook/%s.md" % title, "# %s\n\n" % title + "\n\n".join(paragraph(rng, 6) for _ in range(9)) + "\n")
    older = [("e-%04d" % rng.randint(1000, 1899), "e-%04d" % rng.randint(1000, 1899), "2022-%02d-01" % rng.randint(1, 12), "2023-01-01") for _ in range(1100)]
    case.add("org/archive/assignments-2022-flat.csv", csv(older, "employee_id,manager_id,from,to"))
    case.add("org/archive/assignments-2023-flat.csv", csv(old, "employee_id,manager_id,from,to"))
    case.add("docs/orgchart-2025.md", "# Org chart (2025 snapshot)\n\nOrdwyn Falgale -> Selkal Torvane -> Kalran Pelvor\n\n" + "\n\n".join(paragraph(rng, 5) for _ in range(22)) + "\n")
    case.add("docs/glossary.md", "# Glossary\n\n" + "\n\n".join("**%s** — %s" % (word(rng), paragraph(rng, 3)) for _ in range(60)) + "\n")
    return case


def case_sensor_breach_count():
    rng = random.Random(20260935)
    sites = {"site-%s" % word(rng): ["sn-" + hex_id(rng, 5) for _ in range(4)] for _ in range(6)}
    site = list(sites)[2]
    sensors = sites[site]
    week_start = dt.date(2026, 6, 8)  # ISO week 24
    thresholds = {s: (rng.randint(60, 80)) for s in sites}
    thresholds[site] = 70
    threshold_changes = [(site, 75, "2026-06-11")]  # threshold rises to 75.0 from Thursday
    calibration = {s: 0 for site_sensors in sites.values() for s in site_sensors}
    calibration[sensors[0]] = 8   # +0.8 units from 2026-06-01
    calibration[sensors[1]] = -12  # -1.2 units from 2026-06-01
    readings = []
    for st, sns in sites.items():
        for s in sns:
            for day in range(-3, 10):
                d = week_start + dt.timedelta(days=day)
                for hour in range(0, 24):
                    raw = rng.randint(400, 820)
                    readings.append((s, "%sT%02d:00:00Z" % (d.isoformat(), hour), raw))
    rng.shuffle(readings)

    def count(apply_cal=True, dynamic_threshold=True, only_site=site):
        n = 0
        for s, t, raw in readings:
            if s not in sites[only_site]:
                continue
            d = dt.date.fromisoformat(t[:10])
            if not (week_start <= d < week_start + dt.timedelta(days=7)):
                continue
            value = raw + (calibration[s] if apply_cal else 0)
            thr = thresholds[only_site] * 10
            if dynamic_threshold:
                for st, v, eff in threshold_changes:
                    if st == only_site and t[:10] >= eff:
                        thr = v * 10
            if value > thr:
                n += 1
        return n

    answer = count()
    decoys = {"no calibration": count(apply_cal=False), "old threshold all week": count(dynamic_threshold=False), "no calibration and old threshold": count(False, False)}
    for k, v in decoys.items():
        assert v != answer and str(answer) not in str(v) and str(v) not in str(answer), (k, v, answer)
    case = Case("datajoin-sensor-breach-count", "data-join-large",
                "How many readings from the sensors of %s breached the site's threshold during ISO week 2026-W24 (Monday 2026-06-08 to Sunday 2026-06-14) once the calibration offsets "
                "and the threshold change in effect are applied per README.md? Report back without changing any files." % site,
                [[str(answer)]],
                "%d readings. %s has sensors %s; readings are in tenths, %s carries +8 and %s -12 calibration from 2026-06-01, and the threshold is 70.0 until 2026-06-11 and 75.0 from "
                "then (thresholds/changes.csv). Without calibration the count is %d, with 70.0 all week %d, with neither %d." % (
                    answer, site, ", ".join(sensors), sensors[0], sensors[1], decoys["no calibration"], decoys["old threshold all week"], decoys["no calibration and old threshold"]), 6,
                "Decoys: %d without calibration; %d ignoring the mid-week threshold change; %d with neither; readings from the days outside the week and from other sites' sensors." % (
                    decoys["no calibration"], decoys["old threshold all week"], decoys["no calibration and old threshold"]), ["data", "csv", "sensors", "count"])
    case.add("README.md", """# Telemetry export

Rules:

1. `readings/<sensor>/<day>.csv` holds `value_tenths`, the reading in tenths
   of a unit. A reading breaches when its calibrated value is strictly
   greater than the site threshold in effect at the reading's timestamp.
2. Calibration: add `offset_tenths` from `calibration/offsets.csv` to the
   raw value for readings on or after the offset's `effective_from`.
3. Thresholds: `thresholds/sites.csv` gives each site's threshold in whole
   units; `thresholds/changes.csv` lists changes, effective from the date
   given (inclusive). The site's sensors are listed in `sites/<site>.json`.
""")
    for st, sns in sites.items():
        case.add("sites/%s.json" % st, json.dumps({"site": st, "sensors": sns, "location": word(rng)}, indent=2) + "\n")
    case.add("thresholds/sites.csv", csv([(st, v) for st, v in thresholds.items()], "site,threshold_units"))
    case.add("thresholds/changes.csv", csv(threshold_changes + [(list(sites)[4], 66, "2026-06-20")], "site,threshold_units,effective_from"))
    case.add("calibration/offsets.csv", csv([(s, o, "2026-06-01") for s, o in calibration.items() if o], "sensor,offset_tenths,effective_from"))
    case.add("calibration/README.md", "Offsets are in tenths. Sensors not listed have offset 0.\n")
    by_sensor_day = {}
    for s, t, raw in readings:
        by_sensor_day.setdefault((s, t[:10]), []).append((t, raw))
    for (s, d), rows in by_sensor_day.items():
        rows.sort()
        if s in sensors or rng.random() < 0.25:
            case.add("readings/%s/%s.csv" % (s, d), csv(rows, "ts,value_tenths"))
    others = [(s, t, raw) for s, t, raw in readings if s not in sensors]
    case.add("readings/all-sites-flat.csv", csv(sorted(others), "sensor,ts,value_tenths"))
    case.add("docs/glossary.md", "# Glossary\n\n" + "\n\n".join("**%s** — %s" % (word(rng), paragraph(rng, 3)) for _ in range(60)) + "\n")
    return case


def cases():
    return [case_top_emea_customer(), case_sku_missing_from_catalog(), case_order_total_after_discount(), case_skip_level_manager(), case_sensor_breach_count()]
