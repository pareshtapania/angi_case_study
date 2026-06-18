# Revenue Metrics

## Overview

Revenue metrics track the financial performance of the Angi platform across
three key views: **gross revenue** (what homeowners pay), **platform commission**
(Angi's take), and **pro payout** (what professionals earn). All revenue
metrics are sourced from `fact.fct_revenue`.

## Base Table

`fact.fct_revenue` — one row per payment transaction (`payment_id`).

A single service request (`sr_id`) can have multiple payment rows when
refunds, chargebacks, or adjustments occur. Use `net_platform_revenue` and
`net_pro_payout` (sign-aware) for P&L reporting — never raw `platform_commission`
or `pro_payout_amount`, which ignore reversals.

## Commission Model

Angi operates a **platform commission model** typical of home services
marketplaces:

| Component | Description | Typical range |
|---|---|---|
| **Gross amount** | Total price charged to the homeowner | Set per service request |
| **Commission rate** | Platform take rate (Angi's cut) | 15–25% of gross |
| **Platform commission** | `gross_amount × commission_rate` | Angi revenue |
| **Pro payout** | `gross_amount − commission` | Net to professional |

Commission rates vary by:
- **Category** — higher-complexity trades (HVAC, electrical) carry higher rates
- **Pro tier** — top-rated pros may negotiate lower rates
- **Geography** — competitive markets may have adjusted rates
- **Promotional pricing** — temporary rate reductions for new pros or campaigns

## Key Metrics

### `gross_revenue`

```
gross_revenue = SUM(gross_amount) WHERE payment_status = 'completed'
```

Total money collected from homeowners for completed services. Excludes
pending, failed, refunded, and chargeback transactions.

### `net_platform_revenue`

```
net_platform_revenue = SUM(net_platform_revenue)
```

Angi's net revenue after accounting for refunds and chargebacks. This is the
P&L metric — use this, not `SUM(platform_commission)`.

- Completed payments contribute positive commission
- Refunds and chargebacks contribute negative commission
- Pending and failed payments contribute zero

### `net_pro_payout`

```
net_pro_payout = SUM(net_pro_payout)
```

Net amount paid to professionals after refund/chargeback clawbacks.

### `effective_take_rate`

```
effective_take_rate = SUM(net_platform_revenue) / SUM(gross_amount WHERE payment_status = 'completed')
```

The realized platform take rate after adjustments. Compare against the
stated `commission_rate` to measure rate leakage from refunds, chargebacks,
and promotional overrides.

### `refund_rate`

```
refund_rate = COUNT(payment_id WHERE is_refunded = 1) / COUNT(payment_id WHERE is_settled = 1 OR is_refunded = 1)
```

Share of settled payments that were subsequently refunded. A leading
indicator of service quality issues.

## Grouping Dimensions

### Safe — no fan-out risk

- `category_key` (service category)
- `geography_key` (city-level geography)
- `payment_date_key` and any `dim_date` attribute joined on it
- `payment_method`
- `payment_status`
- `sr_status` (service request status at time of query)

### Unsafe — use with caution

- `pro_key`, `market`, `pro_is_active` — same fan-out risk as
  `fct_booking_funnel` if `dim_pro` join is on `category_key` alone.
  `fct_revenue` joins on `sp_id + category_key` (1:1), but grouping by
  pro attributes can produce misleading aggregations when a pro serves
  multiple categories.
- `sr_id` — safe for detail-level queries, but grouping by it at
  aggregate level is just a no-op (each payment already has an sr_id).

## Structural Guardrails

1. **`revenue_key` must be unique** — one row per payment_id. A duplicate
   means double-counted revenue.

2. **`net_platform_revenue + net_pro_payout = gross_amount` for completed
   payments** — if this invariant breaks, the commission calculation is wrong.

3. **Never mix `fct_revenue` with `fct_booking_funnel` denominators** —
   `fct_booking_funnel` includes bookings that never received payment
   (cancelled, still in-flight). Revenue metrics must use `fct_revenue` only.

4. **Refunds are separate rows, not updates** — do not assume
   `payment_status = 'completed'` is final. A completed payment may later
   have a refund row for the same `sr_id`.
