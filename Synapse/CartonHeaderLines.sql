SELECT h.CartOnNumber,h.ToWh,h.OverrideToWh,l.cartonquantity,   *
FROM PacCartonTransferLine AS l
JOIN PacCartonTransferHeader AS h
    ON l.CartonNumber = h.CartonNumber
WHERE l.ItemId = '0850-46158-0050'
  AND (h.ToWh = '0003' OR h.OverrideToWh = '0003');
