# Allocation → Carton → Receipt Trace

Follows every allocated unit through the three physical hand-offs and reports the gap at each step.

| Stage | Table | Quantity |
|---|---|---|
| Allocated | `pacallocationdataline` + `pacallocationdataheader` | `allocatedquantity` |
| Cartoned (WM picked & shipped) | `paccartontransferline` | `cartonquantity` |
| Received (store scanned) | `paccartontransferline` | `receivedquantity` |

## The join key

`paccartontransferline.receivernumber` == `pacallocationdataline.receivernumber`
(== `pacwminvoicecartonlinemessage.o4dstr` on the raw WM O4 line).

Validated 2026-08-27: **100%** of August carton lines carrying a receivernumber
(48,306 of 48,306 distinct receiver+SKU combos) matched an allocation line.

## ⚠️ Store must be in the join key

~1% of receivernumbers are **chain-wide** — 1,491 of 151,830 in August fan out to
more than 10 stores, up to all 312. Joining on receiver+SKU alone collapses every
store into one bucket and invents a ~500K-unit phantom "short cartoned" variance.
Both sides use the same 4-char zero-padded warehouse code (`0150`, `1234`, `4905`),
so the store joins directly with no normalisation.

## Files

- `allocation_to_receipt_trace.sql` — funnel summary by destination type + trace status
- `allocation_to_receipt_by_store.sql` — per-store rollup, ranked by aged exceptions
- `allocation_to_receipt_detail.sql` — line-level exceptions aged >14 days

Set `@from` / `@to` at the top of each (allocation created date, UTC).

## Other gotchas baked in

- Allocations to **4901/4902/4905 are DC-to-DC** and never produce a store carton —
  classified `dest_type='DC'` so they don't pollute store exception buckets
  (734,429 of 1,494,777 "no carton" units in August).
- Empty datetimes are the **1900-01-01 sentinel**, never NULL.
- `paccartontransferheader.towh` is blank only for `cartonstatus=0` (CREATED, not yet
  shipped) — 371 of 63,118 in August. Excluded from the carton side by design.
- `receivedquantity` **concentrates on one line** of a duplicated carton pair (the twin
  stays 0) — always roll up per carton+SKU. These queries do.
- Synapse serverless rejects `SELECT ... INTO #temp` over external tables.
- `pacwmstoredistromessage.createddatetime` is the 1900 sentinel on all 3.05M rows —
  useless for windowing; use `SinkCreatedOn` or join to `sunintmessage`.
