# Gold Reversion Guard

![Platform](https://img.shields.io/badge/platform-MetaTrader%205-1f6feb) ![Language](https://img.shields.io/badge/language-MQL5-orange) ![Symbol](https://img.shields.io/badge/symbol-XAUUSD-d4a017) ![License](https://img.shields.io/badge/license-MIT-green)

A MetaTrader 5 Expert Advisor (trading bot) for **gold (XAUUSD)**. It looks for moments when gold has stretched unusually far from its recent average in a quiet, sideways market, and trades the move back toward the average.

It is built around protecting the account first: risk-based position sizing, a hard daily loss limit, a cooldown after losses, and no martingale or grid.

> **Educational project.** Trading gold with leverage can lose your whole deposit. Run it in the Strategy Tester and on a demo account before using real money.

---

## How it works

Every decision is made **once per closed bar** on the chosen timeframe (default M5).

### 1. Measure the stretch
- **Average:** simple moving average of the last 50 closes.
- **Z-score:** how many standard deviations the last close is from that average.

### 2. Check the market is suitable
A trade is only considered when **all** of these are true:

| Check | Default | Why |
|---|---|---|
| Stretch | Z ≤ −2.2 (buy) or Z ≥ +2.2 (sell) | Price is unusually far from the average |
| Turn | Last bar stopped stretching further | Avoid catching a falling knife |
| Trend | ADX < 22 | Mean reversion works in sideways markets, not strong trends |
| Volatility | ATR between 0.5× and 2.0× its 50-bar average | Skip dead or spiking markets |
| Spread | ≤ 50 points | Avoid expensive entries |
| Cost gate | Std dev ≥ 3× cost and distance to average ≥ 4× cost | The expected move must clearly cover spread and commission |
| Trading hours | 10:00–20:00 server time | Busy London/New York hours |
| News | No high-impact USD news within 60 minutes | Avoid news spikes |
| Daily limits | Under the loss limit and trade count, not in a cooldown | Protect the account |

### 3. Place the trade
- **Direction:** buy when price is stretched low, sell when stretched high.
- **Take profit:** at the average. It is moved each bar as the average moves.
- **Stop loss:** the larger of 2.5 × ATR or 500 points.
- **Size:** calculated so that hitting the stop loses about **1% of equity**, using MetaTrader's own profit calculation so it is correct for any broker's contract size. Each trade's risk in money and % is written to the Experts log.

### 4. Manage and exit
In order of priority:
1. Take profit at the average (handled by the broker's server).
2. Backup exit when a closed bar is back within Z ±0.3 of the average.
3. Stop moves to breakeven after 1 × ATR in profit.
4. Time exit after 40 bars.
5. Stop loss (handled by the broker's server).

Account-level protection:
- **Daily loss limit:** closes trades and stops for the day after losing 3% of the day's starting equity.
- **Cooldown:** waits 6 bars after any losing trade.
- **Max 8 trades per day.**
- **Friday close:** closes trades and stops opening new ones from 20:00 server time on Friday.

---

## Small accounts: read this first

The EA will **refuse to trade** if the smallest possible trade (0.01 lot) would risk more than your chosen risk percentage. The status panel shows *"Account too small"* when that happens.

With gold, a 0.01 lot usually moves about **$1 for every $1 change in the gold price**. At recent gold prices the bot's stop is typically $15–25 away, so one losing trade at 0.01 lot costs roughly $15–25.

| Equity | 0.01-lot loss as % of account |
|---|---|
| $100 | 15–25% |
| $500 | 3–5% |
| $1,000 | 1.5–2.5% |
| $2,000 | about 1% |

To trade a smaller account you can set `InpAllowMinLot = true`. The EA will then use 0.01 lot as long as it risks no more than `InpMinLotRiskCap` (default 3%). Going higher than that makes a few losses in a row very damaging.

Check your broker's contract size for gold. Some "micro" accounts use smaller contracts, and the EA's calculation uses the broker's own tick value, so the sizing stays correct either way.

---

## Installation

1. Open MetaTrader 5 and go to **File → Open Data Folder**.
2. Copy `GoldReversionGuard.mq5` into `MQL5/Experts/`.
3. Open **MetaEditor** (F4), open the file and press **Compile** (F7). It should finish with 0 errors.
4. In MetaTrader 5, open a **XAUUSD** (called **GOLD** on XM) chart. Any chart timeframe works; the EA uses its own timeframe setting.
5. Drag **GoldReversionGuard** from the Navigator onto the chart, review the inputs, and tick **Allow Algo Trading**.
6. Turn on **Algo Trading** in the toolbar. The status panel appears in the top-left corner.

To use the news filter on a live or demo account, the terminal must be able to load the MQL5 economic calendar (it does by default).

The EA only trades while MetaTrader 5 is running. For round-the-clock use, run it on a computer that stays on or a VPS.

---

## Backtesting

1. In MetaTrader 5, open **View → Strategy Tester**.
2. Choose **Expert: GoldReversionGuard**, **Symbol: XAUUSD**, and a period of at least 6–12 months.
3. Set **Modelling: Every tick based on real ticks** for the most realistic results.
4. Set the deposit to the amount you actually plan to trade with.
5. Run it, then look at the **Backtest** tab: net profit, maximum drawdown, profit factor and number of trades.

Notes:
- The news filter is switched off in the Strategy Tester because the economic calendar is not available there. Live results around news will differ.
- If your broker charges commission, set `InpExtraCostPts` to the round-trip commission in points.
- Server time differs between brokers. Adjust `InpStartHour` and `InpEndHour` so the session matches the London/New York overlap on your broker's clock.
- Try a few settings, but be wary of tuning until the past looks perfect. Settings that fit the past too closely usually fail going forward. Check the result holds up on a different date range.

---

## Settings

| Group | Input | Default | Meaning |
|---|---|---|---|
| Strategy | `InpTimeframe` | M5 | Timeframe used for signals |
| | `InpMeanPeriod` | 50 | Bars for the average and standard deviation |
| | `InpEntryZ` | 2.2 | Stretch needed to enter |
| | `InpExitZ` | 0.3 | Backup exit when back near the average |
| | `InpRequireTurn` | true | Wait for price to stop stretching |
| Filters | `InpADXMax` | 22 | Maximum ADX (trend strength) |
| | `InpATRMinRatio` / `InpATRMaxRatio` | 0.5 / 2.0 | Allowed volatility range |
| | `InpMaxSpreadPts` | 50 | Maximum spread in points |
| | `InpExtraCostPts` | 0 | Round-trip commission in points |
| | `InpStdCostMult` / `InpDistCostMult` | 3 / 4 | Cost gate multipliers |
| Hours and news | `InpStartHour` / `InpEndHour` | 10 / 20 | Trading hours, server time |
| | `InpUseNewsFilter` | true | Block entries near high-impact news |
| | `InpNewsCurrency` | USD | Currency to watch |
| | `InpNewsMinutes` | 60 | Minutes before and after news |
| | `InpCloseBeforeNews` | false | Also close open trades near news |
| Risk | `InpRiskPercent` | 1.0 | Risk per trade, % of equity |
| | `InpDailyLossPct` | 3.0 | Daily loss limit, % of day-start equity |
| | `InpMaxTradesDay` | 8 | Maximum new trades per day |
| | `InpCooldownBars` | 6 | Bars to wait after a loss |
| | `InpAllowMinLot` | false | Allow 0.01 lot above the planned risk |
| | `InpMinLotRiskCap` | 3.0 | Maximum % risk when using the minimum lot |
| Exits | `InpSLATRMult` | 2.5 | Stop loss in ATRs |
| | `InpSLMinPts` | 500 | Minimum stop distance in points |
| | `InpBreakevenATR` | 1.0 | Profit (in ATRs) before moving stop to entry; 0 = off |
| | `InpMaxHoldBars` | 40 | Time exit in bars; 0 = off |
| | `InpCloseFriday` / `InpFridayHour` | true / 20 | Friday close |
| General | `InpMagic` | 240611 | Unique ID for this EA's trades |
| | `InpShowPanel` | true | Show the status panel |

---

## Status panel

```
--- GOLD REVERSION GUARD ---
Equity: 1000.00 USD
Risk per trade: 1.0%   Daily limit: -3.0%
Today: 0.42%   Trades: 2/8
Z-score: -1.37   ADX: 18.4
ATR ratio: 1.08   Spread: 22 pts
News: clear
Status: Waiting for a stretch (|Z| >= 2.2)
```

The **Status** line always says what the EA is doing or why it is not trading.

---

## Known limits

- Mean reversion loses when gold breaks into a strong trend. The ADX filter reduces this but cannot remove it.
- Results depend heavily on spread, commission and execution speed at your broker.
- Past backtest results do not predict future results.

## Disclaimer

This software is provided for education and research. It is not financial advice. You are responsible for any trades it places. Only trade money you can afford to lose.

## License

[MIT](LICENSE)

## Author

Ronnis Nai
