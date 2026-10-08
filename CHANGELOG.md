# Changelog

## 1.01
- Fixed position sizing. Lot size now comes from MetaTrader's `OrderCalcProfit`, which returns the real money lost at the stop for the broker's contract size. Version 1.00 relied on the symbol's tick value, which some servers report in a way that made trades about 8x larger than the intended risk.
- Each trade now logs its risk in account currency and as a % of equity.
- README: corrected the small-account table for current gold prices.

## 1.00
- First release.
