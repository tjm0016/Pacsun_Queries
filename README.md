PACSUN queries for various functions related to products, purchase orders, pricing, etc.

Queries are organized by data source. Within a source, related queries are grouped
into subfolders.

## Synapse

D365 F&O Dataverse, Synapse serverless pool.

- Server: `d365-synapse-ps-prod-ondemand.sql.azuresynapse.net`
- Database: `dataverse_psprod_unq1fedfd537528f111a7e5000d3a5cc`
- DBeaver connection: **D365-Production**

Subfolders:

- `ASN_Discrepancy/` — WM (PIX) vs D365 (WMSJournalTrans) receipt reconciliation, in several timezone variants.
- `DC_Sync/` — DC sync gap analysis, leakage matrix, shrink root cause, and WM recon.
