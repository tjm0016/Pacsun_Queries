/* =============================================================================
   Variant transaction trace at a store  (D365 Synapse serverless, prod)
   -----------------------------------------------------------------------------
   Question it answers: "did a SALE deduct inventory for variant X at store Y
   on/around date Z?" -- and more generally, every inventory movement for one
   variant at one warehouse, typed by what caused it.

   Written for: retailvariantid 0010034474 (= 0192-61198-0062 / color 459 /
   size 9600) at store 0158 HAYWOOD SC, question date 2026-08-01.
   Answer that run: yes -- SO-0006590513, -1 u / -$28.21, physical+financial
   8/1/2026, posted 09:25:51 PT; the unit had landed 7/27 on carton transfer
   INV-01306449, so the store netted back to zero.

   Set the three variables below and run.  @FromDate/@ToDate are a DISPLAY filter
   only -- the running on-hand is computed over ALL history first, because
   date-bounding the CTE fakes a negative opening balance.

   Gotchas baked in:
     * retailvariantid is 10-digit ZERO-PADDED -> TRY_CAST(... AS BIGINT) so you
       can paste either '0010034474' or 10034474
     * ISNULL(IsDelete,0)=0  -- live rows carry NULL, not 0
     * inventtrans.createddatetime is the ORDER-creation time (returns 1899 for
       retail SOs) -> modifieddatetime is the posting-time proxy
     * all Dataverse datetimes are UTC -> AT TIME ZONE for a real PT clock
     * datephysical = '1900-01-01' means the row is not physically posted yet
     * inventtransorigin.referencecategory is the "why does this row exist"
       decoder: 0 Sales Order, 3 Purchase Order, 4 Movement journal,
       6 Carton transfer, 13 Count / DC-Sync
     * the variant's own inventdimid carries NO warehouse -- match the variant by
       itemid + inventcolorid + inventsizeid, then take the warehouse off the
       TRANSACTION's inventdim
   ============================================================================= */

DECLARE @VariantId BIGINT      = 10034474;      -- retailvariantid, padded or not
DECLARE @Store     VARCHAR(20) = '0158';        -- inventlocationid; '' = all warehouses
DECLARE @FromDate  DATE        = '2000-01-01';  -- display window start
DECLARE @ToDate    DATE        = '2099-12-31';  -- display window end

/* ---------- 1. resolve the variant to itemid + color + size ---------------- */
DECLARE @ItemId VARCHAR(30), @ColorId VARCHAR(30), @SizeId VARCHAR(30);

SELECT
    @ItemId  = idc.itemid,
    @ColorId = id.inventcolorid,
    @SizeId  = id.inventsizeid
FROM dbo.inventdimcombination idc
JOIN dbo.inventdim id
  ON id.inventdimid = idc.inventdimid
 AND id.partition   = idc.partition
WHERE TRY_CAST(idc.retailvariantid AS BIGINT) = @VariantId
  AND ISNULL(idc.IsDelete, 0) = 0;

SELECT @VariantId AS retailvariantid,
       @ItemId    AS itemid,
       @ColorId   AS inventcolorid,
       @SizeId    AS inventsizeid,
       @ItemId + '-' + @ColorId + '-' + @SizeId AS long_sku;

/* ---------- 2. every inventory movement, with running physical on-hand ----- */
WITH ledger AS (
    SELECT
        CAST(t.datephysical  AS DATE) AS datephysical,
        CAST(t.datefinancial AS DATE) AS datefinancial,
        id.inventlocationid,
        id.wmslocationid,
        o.referencecategory,
        CASE o.referencecategory
             WHEN  0 THEN 'Sales Order'
             WHEN  3 THEN 'Purchase Order'
             WHEN  4 THEN 'Movement Journal'
             WHEN  6 THEN 'Carton Transfer'
             WHEN 13 THEN 'Count / DC-Sync'
             ELSE CONCAT('refcat ', o.referencecategory)
        END COLLATE DATABASE_DEFAULT  AS trans_type,
        o.referenceid,
        t.qty,
        t.costamountphysical,
        t.costamountposted,
        t.modifieddatetime,
        /* running physical on-hand: posted-physical rows only, ALL history */
        SUM(CASE WHEN t.datephysical > '1900-01-02' THEN t.qty ELSE 0 END)
            OVER (PARTITION BY id.inventlocationid
                  ORDER BY t.datephysical, t.modifieddatetime, t.recid
                  ROWS UNBOUNDED PRECEDING) AS running_onhand
    FROM dbo.inventtrans t
    JOIN dbo.inventdim id
      ON id.inventdimid = t.inventdimid
     AND id.partition   = t.partition
     AND id.dataareaid  = t.dataareaid
    JOIN dbo.inventtransorigin o
      ON o.recid     = t.inventtransorigin
     AND o.partition = t.partition
    WHERE t.dataareaid = '1001'
      AND ISNULL(t.IsDelete, 0) = 0
      AND t.itemid          COLLATE DATABASE_DEFAULT = @ItemId
      AND id.inventcolorid  COLLATE DATABASE_DEFAULT = @ColorId
      AND id.inventsizeid   COLLATE DATABASE_DEFAULT = @SizeId
      AND (@Store = ''
           OR id.inventlocationid COLLATE DATABASE_DEFAULT IN (@Store, @Store + '-T'))
)
SELECT
    datephysical,
    datefinancial,
    inventlocationid,
    wmslocationid,
    trans_type,
    referenceid,
    qty,
    running_onhand,
    costamountphysical,
    costamountposted,
    CONVERT(varchar(19),
            modifieddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time',
            120) AS posted_pt
FROM ledger
WHERE datephysical BETWEEN @FromDate AND @ToDate
   OR datephysical = '1900-01-01'          -- keep not-yet-physical rows visible
ORDER BY datephysical, posted_pt;

/* ---------- 3. current on-hand snapshot (sanity check on the ledger) ------- */
SELECT
    loc.inventlocationid,
    loc.name                          AS warehouse_name,
    SUM(ISNULL(s.physicalinvent, 0))  AS physical_onhand,
    SUM(ISNULL(s.availphysical,  0))  AS avail_physical,
    SUM(ISNULL(s.availordered,   0))  AS avail_ordered   -- ATP; negative = over-committed
FROM dbo.inventsum s
JOIN dbo.inventdim id
  ON id.inventdimid = s.inventdimid
 AND id.partition   = s.partition
 AND id.dataareaid  = s.dataareaid
JOIN dbo.inventlocation loc
  ON loc.inventlocationid = id.inventlocationid
 AND loc.dataareaid       = id.dataareaid
 AND loc.partition        = id.partition
WHERE s.dataareaid = '1001'
  AND ISNULL(s.IsDelete, 0) = 0
  AND s.itemid         COLLATE DATABASE_DEFAULT = @ItemId
  AND id.inventcolorid COLLATE DATABASE_DEFAULT = @ColorId
  AND id.inventsizeid  COLLATE DATABASE_DEFAULT = @SizeId
  AND (@Store = ''
       OR id.inventlocationid COLLATE DATABASE_DEFAULT IN (@Store, @Store + '-T'))
GROUP BY loc.inventlocationid, loc.name
ORDER BY loc.inventlocationid;
