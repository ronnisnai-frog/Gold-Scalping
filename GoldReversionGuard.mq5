//+------------------------------------------------------------------+
//|                                          GoldReversionGuard.mq5  |
//|   Mean-reversion Expert Advisor for gold (XAUUSD) on MetaTrader 5 |
//|                                                                  |
//|   Idea: when gold stretches unusually far from its recent        |
//|   average in a quiet, sideways market, bet on a move back toward |
//|   the average. Every decision is made once per closed bar.       |
//|                                                                  |
//|   Educational project. Test on demo before using real money.     |
//+------------------------------------------------------------------+
#property copyright "Ronnis Nai"
#property link      ""
#property version   "1.01"
#property description "Gold mean reversion with cost, trend, volatility, session and news filters."
#property description "Risk-based position sizing, daily loss limit and loss cooldown. No martingale, no grid."

#include <Trade\Trade.mqh>

//--- Strategy
input group "Strategy"
input ENUM_TIMEFRAMES InpTimeframe      = PERIOD_M5;  // Chart timeframe used for signals
input int             InpMeanPeriod     = 50;         // Bars for the average (SMA) and standard deviation
input double          InpEntryZ         = 2.2;        // Enter when price is this many std devs from the average
input double          InpExitZ          = 0.3;        // Backup exit when price is back within this many std devs
input bool            InpRequireTurn    = true;       // Wait for the last closed bar to stop stretching further

//--- Filters
input group "Filters"
input int             InpADXPeriod      = 14;         // ADX period
input double          InpADXMax         = 22.0;       // Only trade when ADX is below this (sideways market)
input int             InpATRPeriod      = 14;         // ATR period
input int             InpATRAvgBars     = 50;         // Bars used to average ATR
input double          InpATRMinRatio    = 0.5;        // Skip when ATR is below this x its average (dead market)
input double          InpATRMaxRatio    = 2.0;        // Skip when ATR is above this x its average (spiky market)
input int             InpMaxSpreadPts   = 50;         // Maximum spread in points
input int             InpExtraCostPts   = 0;          // Round-trip commission in points (0 if none)
input double          InpStdCostMult    = 3.0;        // Std dev must be at least this x trading cost
input double          InpDistCostMult   = 4.0;        // Distance to the average must be at least this x trading cost

//--- Trading hours and news (server time)
input group "Trading hours and news"
input int             InpStartHour      = 10;         // First hour to open trades (server time)
input int             InpEndHour        = 20;         // Stop opening trades from this hour (server time)
input bool            InpUseNewsFilter  = true;       // Block entries around high-impact news
input string          InpNewsCurrency   = "USD";      // News currency to watch
input int             InpNewsMinutes    = 60;         // Minutes before and after news with no new entries
input bool            InpCloseBeforeNews= false;      // Close open trades when news is near

//--- Risk
input group "Risk"
input double          InpRiskPercent    = 1.0;        // Risk per trade, % of equity
input double          InpDailyLossPct   = 3.0;        // Stop for the day after losing this % of day-start equity
input int             InpMaxTradesDay   = 8;          // Maximum new trades per day
input int             InpCooldownBars   = 6;          // Bars to wait after a losing trade
input bool            InpAllowMinLot    = false;      // Allow 0.01 lot even if it risks more than planned
input double          InpMinLotRiskCap  = 3.0;        // If allowed, never risk more than this % with the minimum lot

//--- Exits
input group "Exits"
input double          InpSLATRMult      = 2.5;        // Stop loss = this x ATR ...
input int             InpSLMinPts       = 500;        // ... but never closer than this many points
input double          InpBreakevenATR   = 1.0;        // Move stop to entry after this x ATR in profit (0 = off)
input int             InpBEOffsetPts    = 20;         // Points beyond entry for the breakeven stop
input int             InpMaxHoldBars    = 40;         // Close the trade after this many bars (0 = off)
input bool            InpCloseFriday    = true;       // Close trades and stop on Friday evening
input int             InpFridayHour     = 20;         // Friday hour (server time) to close

//--- General
input group "General"
input long            InpMagic          = 240611;     // Magic number (unique per EA on the account)
input string          InpComment        = "GRG";      // Order comment
input bool            InpShowPanel      = true;       // Show the status panel on the chart

//--- Globals
CTrade   trade;
int      hMA = INVALID_HANDLE, hStd = INVALID_HANDLE, hADX = INVALID_HANDLE, hATR = INVALID_HANDLE;
datetime lastBarTime      = 0;
datetime currentDay       = 0;
double   dayStartEquity   = 0.0;
bool     dailyLocked      = false;
int      tradesToday      = 0;
datetime cooldownUntil    = 0;
datetime newsTimes[];
datetime newsLastRefresh  = 0;
bool     isTester         = false;

// latest closed-bar readings, kept for the panel
double   gZ = 0, gADX = 0, gATRRatio = 0, gMean = 0, gStd = 0, gATR = 0;
string   gStatus = "Starting";

//+------------------------------------------------------------------+
int OnInit()
{
   isTester = (bool)MQLInfoInteger(MQL_TESTER);

   if(InpMeanPeriod < 10 || InpEntryZ <= 0 || InpRiskPercent <= 0 || InpSLATRMult <= 0)
   {
      Print("GoldReversionGuard: check inputs (mean period >= 10, entry Z, risk % and SL multiplier must be positive).");
      return INIT_PARAMETERS_INCORRECT;
   }
   string s = _Symbol;
   StringToUpper(s);
   if(StringFind(s, "XAU") < 0 && StringFind(s, "GOLD") < 0)
      Print("GoldReversionGuard: warning, this EA was designed for gold. Current symbol: ", _Symbol);

   hMA  = iMA(_Symbol, InpTimeframe, InpMeanPeriod, 0, MODE_SMA, PRICE_CLOSE);
   hStd = iStdDev(_Symbol, InpTimeframe, InpMeanPeriod, 0, MODE_SMA, PRICE_CLOSE);
   hADX = iADX(_Symbol, InpTimeframe, InpADXPeriod);
   hATR = iATR(_Symbol, InpTimeframe, InpATRPeriod);
   if(hMA == INVALID_HANDLE || hStd == INVALID_HANDLE || hADX == INVALID_HANDLE || hATR == INVALID_HANDLE)
   {
      Print("GoldReversionGuard: could not create indicators, error ", GetLastError());
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber((ulong)InpMagic);
   trade.SetDeviationInPoints(30);
   trade.SetTypeFillingBySymbol(_Symbol);

   ResetDay();
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(hMA  != INVALID_HANDLE) IndicatorRelease(hMA);
   if(hStd != INVALID_HANDLE) IndicatorRelease(hStd);
   if(hADX != INVALID_HANDLE) IndicatorRelease(hADX);
   if(hATR != INVALID_HANDLE) IndicatorRelease(hATR);
   Comment("");
}

//+------------------------------------------------------------------+
void OnTick()
{
   // New trading day: reset the daily counters
   datetime today = iTime(_Symbol, PERIOD_D1, 0);
   if(today != 0 && today != currentDay)
      ResetDay();

   // Daily loss limit, checked on every tick
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(!dailyLocked && dayStartEquity > 0 &&
      equity - dayStartEquity <= -dayStartEquity * InpDailyLossPct / 100.0)
   {
      dailyLocked = true;
      CloseAllPositions("daily loss limit");
      Print("GoldReversionGuard: daily loss limit reached. No new trades until tomorrow.");
   }

   // Friday close
   if(InpCloseFriday && IsFridayClose() && HasPosition())
      CloseAllPositions("Friday close");

   // Everything else runs once per closed bar
   datetime barTime = iTime(_Symbol, InpTimeframe, 0);
   if(barTime == 0 || barTime == lastBarTime)
   {
      if(InpShowPanel) DrawPanel();
      return;
   }
   lastBarTime = barTime;

   if(!ReadIndicators())
   {
      gStatus = "Waiting for indicator data";
      if(InpShowPanel) DrawPanel();
      return;
   }

   if(InpUseNewsFilter && !isTester)
      RefreshNews();

   if(HasPosition())
      ManagePosition();
   else
      TryEntry();

   if(InpShowPanel) DrawPanel();
}

//+------------------------------------------------------------------+
//| Count new trades and start the cooldown after a loss             |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;
   if(!HistoryDealSelect(trans.deal))
      return;
   if(HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != InpMagic)
      return;
   if(HistoryDealGetString(trans.deal, DEAL_SYMBOL) != _Symbol)
      return;

   long entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(entry == DEAL_ENTRY_IN)
      tradesToday++;
   else if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY)
   {
      double pl = HistoryDealGetDouble(trans.deal, DEAL_PROFIT)
                + HistoryDealGetDouble(trans.deal, DEAL_SWAP)
                + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);
      if(pl < 0 && InpCooldownBars > 0)
         cooldownUntil = TimeCurrent() + InpCooldownBars * PeriodSeconds(InpTimeframe);
   }
}

//+------------------------------------------------------------------+
//| Read closed-bar values (shift 1) for all indicators              |
//+------------------------------------------------------------------+
bool ReadIndicators()
{
   double ma[], sd[], adx[], atr[];
   ArraySetAsSeries(ma, true);
   ArraySetAsSeries(sd, true);
   ArraySetAsSeries(adx, true);
   ArraySetAsSeries(atr, true);

   if(CopyBuffer(hMA, 0, 1, 1, ma) != 1)   return false;
   if(CopyBuffer(hStd, 0, 1, 1, sd) != 1)  return false;
   if(CopyBuffer(hADX, 0, 1, 1, adx) != 1) return false;
   int need = MathMax(InpATRAvgBars, 1);
   if(CopyBuffer(hATR, 0, 1, need, atr) != need) return false;

   double close1 = iClose(_Symbol, InpTimeframe, 1);
   if(close1 <= 0 || sd[0] <= 0) return false;

   double sum = 0;
   for(int i = 0; i < need; i++) sum += atr[i];
   double atrAvg = sum / need;

   gMean = ma[0];
   gStd  = sd[0];
   gADX  = adx[0];
   gATR  = atr[0];
   gZ    = (close1 - gMean) / gStd;
   gATRRatio = atrAvg > 0 ? gATR / atrAvg : 0;
   return true;
}

//+------------------------------------------------------------------+
//| Entry logic                                                      |
//+------------------------------------------------------------------+
void TryEntry()
{
   string why = EntryBlockReason();
   if(why != "")
   {
      gStatus = why;
      return;
   }

   bool wantBuy  = gZ <= -InpEntryZ;
   bool wantSell = gZ >=  InpEntryZ;
   if(!wantBuy && !wantSell)
   {
      gStatus = "Waiting for a stretch (|Z| >= " + DoubleToString(InpEntryZ, 1) + ")";
      return;
   }

   // Turn confirmation: the last closed bar must not stretch further
   if(InpRequireTurn)
   {
      double c1 = iClose(_Symbol, InpTimeframe, 1);
      double c2 = iClose(_Symbol, InpTimeframe, 2);
      if(wantBuy && c1 < c2)  { gStatus = "Stretch found, waiting for price to turn up";   return; }
      if(wantSell && c1 > c2) { gStatus = "Stretch found, waiting for price to turn down"; return; }
   }

   // Cost gate: the expected move must clearly cover spread + commission
   double point  = _Point;
   double spread = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   double cost   = (spread + InpExtraCostPts) * point;
   double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double entry  = wantBuy ? ask : bid;
   double dist   = MathAbs(gMean - entry);
   if(gStd < InpStdCostMult * cost || dist < InpDistCostMult * cost)
   {
      gStatus = "Move too small to cover trading costs";
      return;
   }

   // Stop loss and take profit
   double slDist = MathMax(InpSLMinPts * point, InpSLATRMult * gATR);
   double sl = wantBuy ? entry - slDist : entry + slDist;
   double tp = gMean;
   double minGap = StopsGap();
   if(wantBuy  && (tp <= entry + minGap || sl >= entry - minGap)) { gStatus = "Stops too close for broker rules"; return; }
   if(wantSell && (tp >= entry - minGap || sl <= entry + minGap)) { gStatus = "Stops too close for broker rules"; return; }
   sl = NormalizeDouble(sl, _Digits);
   tp = NormalizeDouble(tp, _Digits);

   // Position size from risk
   string sizeNote = "";
   double riskMoney = 0;
   double lots = LotsForRisk(wantBuy, entry, sl, sizeNote, riskMoney);
   if(lots <= 0)
   {
      gStatus = sizeNote;
      return;
   }

   // Margin check
   double margin = 0;
   ENUM_ORDER_TYPE type = wantBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   if(!OrderCalcMargin(type, _Symbol, lots, entry, margin) ||
      margin > AccountInfoDouble(ACCOUNT_MARGIN_FREE) * 0.9)
   {
      gStatus = "Not enough free margin";
      return;
   }

   bool ok = wantBuy ? trade.Buy(lots, _Symbol, ask, sl, tp, InpComment)
                     : trade.Sell(lots, _Symbol, bid, sl, tp, InpComment);
   if(ok && (trade.ResultRetcode() == TRADE_RETCODE_DONE || trade.ResultRetcode() == TRADE_RETCODE_PLACED))
   {
      gStatus = (wantBuy ? "Bought " : "Sold ") + DoubleToString(lots, 2) + " lots" + sizeNote;
      PrintFormat("GoldReversionGuard: %s %.2f lots at %.2f, SL %.2f, TP %.2f, Z %.2f, ADX %.1f, risk %.2f %s (%.2f%%)",
                  wantBuy ? "BUY" : "SELL", lots, entry, sl, tp, gZ, gADX,
                  riskMoney, AccountInfoString(ACCOUNT_CURRENCY), riskMoney / AccountInfoDouble(ACCOUNT_EQUITY) * 100.0);
   }
   else
   {
      gStatus = "Order failed: " + trade.ResultRetcodeDescription();
      Print("GoldReversionGuard: order failed, ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| Returns why new entries are blocked, or "" if allowed            |
//+------------------------------------------------------------------+
string EntryBlockReason()
{
   if(dailyLocked)                          return "Stopped for today (daily loss limit)";
   if(tradesToday >= InpMaxTradesDay)       return "Daily trade count reached";
   if(TimeCurrent() < cooldownUntil)        return "Cooling down after a loss";
   if(InpCloseFriday && IsFridayClose())    return "Weekend break";
   if(!InSession())                         return "Outside trading hours";
   if(InpUseNewsFilter && NewsNear())       return "High-impact news nearby";
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > InpMaxSpreadPts)             return "Spread too wide (" + IntegerToString(spread) + " pts)";
   if(gADX > InpADXMax)                     return "Market trending (ADX " + DoubleToString(gADX, 1) + ")";
   if(gATRRatio < InpATRMinRatio)           return "Market too quiet";
   if(gATRRatio > InpATRMaxRatio)           return "Market too volatile";
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED))
      return "AutoTrading is off";
   return "";
}

//+------------------------------------------------------------------+
//| Manage an open position once per bar                             |
//+------------------------------------------------------------------+
void ManagePosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;

      bool   isBuy  = PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY;
      double open   = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl     = PositionGetDouble(POSITION_SL);
      double tp     = PositionGetDouble(POSITION_TP);
      datetime opened = (datetime)PositionGetInteger(POSITION_TIME);
      double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double price  = isBuy ? bid : ask;
      double gap    = StopsGap();

      // 1. News close (optional)
      if(InpUseNewsFilter && InpCloseBeforeNews && NewsNear())
      {
         ClosePosition(ticket, "news");
         continue;
      }

      // 2. Back near the average on a closed bar
      if((isBuy && gZ >= -InpExitZ) || (!isBuy && gZ <= InpExitZ))
      {
         ClosePosition(ticket, "back at the average");
         continue;
      }

      // 3. Time exit
      if(InpMaxHoldBars > 0)
      {
         int held = iBarShift(_Symbol, InpTimeframe, opened);
         if(held >= InpMaxHoldBars)
         {
            ClosePosition(ticket, "time exit");
            continue;
         }
      }

      // 4. Breakeven
      double newSL = sl;
      if(InpBreakevenATR > 0)
      {
         double beLevel = InpBreakevenATR * gATR;
         if(isBuy && price - open >= beLevel && (sl == 0 || sl < open))
         {
            double cand = open + InpBEOffsetPts * _Point;
            if(cand < price - gap) newSL = cand;
         }
         if(!isBuy && open - price >= beLevel && (sl == 0 || sl > open))
         {
            double cand = open - InpBEOffsetPts * _Point;
            if(cand > price + gap) newSL = cand;
         }
      }

      // 5. Move the take profit to follow the average
      double newTP = tp;
      double mean  = NormalizeDouble(gMean, _Digits);
      if(isBuy && mean > price + gap)  newTP = mean;
      if(!isBuy && mean < price - gap) newTP = mean;

      newSL = NormalizeDouble(newSL, _Digits);
      newTP = NormalizeDouble(newTP, _Digits);
      if(MathAbs(newSL - sl) >= _Point || MathAbs(newTP - tp) >= 5 * _Point)
      {
         if(!trade.PositionModify(ticket, newSL, newTP))
            Print("GoldReversionGuard: modify failed, ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
      }
      gStatus = (isBuy ? "In a BUY" : "In a SELL") + string(", target ") + DoubleToString(newTP, _Digits);
   }
}

//+------------------------------------------------------------------+
//| Lot size so that hitting the stop loses about InpRiskPercent     |
//| Uses OrderCalcProfit, which asks the terminal for the real money |
//| result of a move, so it works with any contract size or broker.  |
//+------------------------------------------------------------------+
double LotsForRisk(bool isBuy, double entry, double sl, string &note, double &riskOut)
{
   note = "";
   riskOut = 0;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(equity <= 0 || step <= 0 || minLot <= 0)
   {
      note = "Symbol data not ready";
      return 0;
   }

   // Money lost by 1.0 lot if the stop loss is hit
   double pl = 0;
   ENUM_ORDER_TYPE type = isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   if(!OrderCalcProfit(type, _Symbol, 1.0, entry, sl, pl) || pl >= 0)
   {
      note = "Could not calculate trade risk";
      Print("GoldReversionGuard: OrderCalcProfit failed, error ", GetLastError());
      return 0;
   }
   double lossPerLot = -pl;

   double riskMoney = equity * InpRiskPercent / 100.0;
   double lots      = MathFloor(riskMoney / lossPerLot / step + 1e-9) * step;

   if(lots < minLot)
   {
      double minLotRiskPct = minLot * lossPerLot / equity * 100.0;
      if(!InpAllowMinLot || minLotRiskPct > InpMinLotRiskCap)
      {
         note = "Account too small: minimum lot would risk " + DoubleToString(minLotRiskPct, 1) + "%";
         return 0;
      }
      lots = minLot;
      note = " (minimum lot, risking " + DoubleToString(minLotRiskPct, 1) + "%)";
   }
   lots = MathMin(lots, maxLot);

   int volDigits = (int)MathMax(0, MathRound(-MathLog10(step)));
   lots = NormalizeDouble(lots, volDigits);
   riskOut = lots * lossPerLot;
   return lots;
}

//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
void ResetDay()
{
   currentDay     = iTime(_Symbol, PERIOD_D1, 0);
   dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   dailyLocked    = false;
   tradesToday    = 0;
}

double StopsGap()
{
   long stops  = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long freeze = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   return (double)(MathMax(stops, freeze) + 5) * _Point;
}

bool InSession()
{
   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   if(InpStartHour == InpEndHour) return true;
   if(InpStartHour < InpEndHour)  return t.hour >= InpStartHour && t.hour < InpEndHour;
   return t.hour >= InpStartHour || t.hour < InpEndHour;   // session crossing midnight
}

bool IsFridayClose()
{
   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   return t.day_of_week == 5 && t.hour >= InpFridayHour;
}

bool HasPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagic)
         return true;
   }
   return false;
}

void ClosePosition(ulong ticket, string reason)
{
   if(trade.PositionClose(ticket))
      Print("GoldReversionGuard: closed ", ticket, " (", reason, ")");
   else
      Print("GoldReversionGuard: close failed for ", ticket, ", ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
}

void CloseAllPositions(string reason)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagic)
         ClosePosition(ticket, reason);
   }
}

//+------------------------------------------------------------------+
//| News filter using the built-in MQL5 economic calendar            |
//| (the calendar is not available in the Strategy Tester)           |
//+------------------------------------------------------------------+
void RefreshNews()
{
   datetime now = TimeCurrent();
   if(now - newsLastRefresh < 15 * 60 && newsLastRefresh != 0)
      return;
   newsLastRefresh = now;
   ArrayResize(newsTimes, 0);

   MqlCalendarValue values[];
   datetime from = now - InpNewsMinutes * 60;
   datetime to   = now + 24 * 3600;
   ResetLastError();
   CalendarValueHistory(values, from, to, NULL, InpNewsCurrency);
   int n = ArraySize(values);
   for(int i = 0; i < n; i++)
   {
      MqlCalendarEvent ev;
      if(!CalendarEventById(values[i].event_id, ev)) continue;
      if(ev.importance != CALENDAR_IMPORTANCE_HIGH) continue;
      int k = ArraySize(newsTimes);
      ArrayResize(newsTimes, k + 1);
      newsTimes[k] = values[i].time;
   }
}

bool NewsNear()
{
   if(isTester) return false;
   datetime now = TimeCurrent();
   int window = InpNewsMinutes * 60;
   for(int i = 0; i < ArraySize(newsTimes); i++)
      if(MathAbs((long)(newsTimes[i] - now)) <= window)
         return true;
   return false;
}

//+------------------------------------------------------------------+
//| Status panel                                                     |
//+------------------------------------------------------------------+
void DrawPanel()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double dayPL  = dayStartEquity > 0 ? (equity - dayStartEquity) / dayStartEquity * 100.0 : 0;
   long   spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   string news   = !InpUseNewsFilter ? "off" : (isTester ? "off in tester" : (NewsNear() ? "BLOCKING" : "clear"));

   string s = "--- GOLD REVERSION GUARD ---\n";
   s += "Equity: " + DoubleToString(equity, 2) + " " + AccountInfoString(ACCOUNT_CURRENCY) + "\n";
   s += "Risk per trade: " + DoubleToString(InpRiskPercent, 1) + "%   Daily limit: -" + DoubleToString(InpDailyLossPct, 1) + "%\n";
   s += "Today: " + DoubleToString(dayPL, 2) + "%   Trades: " + IntegerToString(tradesToday) + "/" + IntegerToString(InpMaxTradesDay) + "\n";
   s += "Z-score: " + DoubleToString(gZ, 2) + "   ADX: " + DoubleToString(gADX, 1) + "\n";
   s += "ATR ratio: " + DoubleToString(gATRRatio, 2) + "   Spread: " + IntegerToString(spread) + " pts\n";
   s += "News: " + news + "\n";
   s += "Status: " + gStatus;
   Comment(s);
}
//+------------------------------------------------------------------+
