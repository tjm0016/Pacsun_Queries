# PIX Adjustments

Queries behind the **PIX DC Adjustments Daily Report** — a day-by-day breakdown of every
WM PIX inventory adjustment that D365 maps to a journal (`MOV-DCADJ` / "DC Inv Adjustment").

| File | Purpose |
|------|---------|
| `01_Mapped_Adjustments.sql` | The current set of mapped Type/Code/ActionCode combos from `pacwmpixtransactionmappingtable`. |
| `02_Daily_Adjustment_Totals.sql` | Per-day transaction counts + units from `pacwmpixmessage` for those combos. |

Decode Type/Code/AC into English via the **PIX 2014 processing matrix**
(`Documents\Claude\Code\PIX_Reference\PIX_Processing_Matrix_2014.csv`). Codes absent from
that spec (Action Code `99`, Type `901`/`906`) are PacSun/post-2014 custom types.

A packaged version that runs both queries, decodes, and builds the Excel workbook lives as
the Claude Code skill `pix-dc-adjustments-report` (`~/.claude/skills/`).

**Units caveat:** `pxinva` scale is /10000 or /1000 (2014 design docs disagree). Counts are exact.
