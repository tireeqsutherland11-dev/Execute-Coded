//+------------------------------------------------------------------+
//| Execute-Coded CCT EA (MT5)                                       |
//| Description: A labeled, fully-commented implementation of the   |
//| trading system described in the Original document.              |
//|                                                                  |
//| NOTE: This EA is intentionally verbose with comments so every   |
//| aspect is reviewable and understandable.                         |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"
#property description "Execute-Coded CCT EA with HTF bias + LTF ICC entries"

// MQL5 standard trade helper. We use this for order placement and partial closes.
#include <Trade/Trade.mqh>

//+------------------------------------------------------------------+
//| ENUMS AND STRUCTS                                                |
//+------------------------------------------------------------------+

// Directional bias derived from HTF impulse logic.
enum BiasDirection
{
   BIAS_NONE = 0,   // No trade bias detected
   BIAS_BULL = 1,   // Bullish bias
   BIAS_BEAR = -1   // Bearish bias
};

// Management modes as defined in the document.
enum ManagementMode
{
   MODE_IRON_DOME = 0, // Partial close + step trailing based on R
   MODE_SHIELD    = 1  // Breakeven at 80% to TP + structure-activated trail
};

// A simple level record for indication and target levels.
struct Level
{
   double   price;      // The level price
   datetime time;       // The time of the candle that created the level
   int      tf;         // Timeframe of origin (e.g., H4)
};

// Trade state for managing partial closes and trailing rules.
struct TradeState
{
   ulong    ticket;       // Position ticket
   double   entryPrice;   // Entry price
   double   initialSL;    // Initial stop-loss (for R calculation)
   double   initialVol;   // Original volume
   bool     did1R;        // +1R actions completed
   bool     did2R;        // +2R actions completed
   bool     trailActive;  // Trailing enabled (Shield mode)
};

//+------------------------------------------------------------------+
//| INPUTS (USER CONFIGURATION)                                      |
//+------------------------------------------------------------------+

// --- Timeframes ---
input ENUM_TIMEFRAMES TF_Bias  = PERIOD_H4;   // Higher timeframe for bias
input ENUM_TIMEFRAMES TF_Entry = PERIOD_M5;   // Lower timeframe for entries

// --- Bias / Impulse (CIT) settings ---
input int    BiasImpulseBars         = 2;     // Required consecutive impulse candles
input double MomentumBodyRatio       = 0.60;  // Body / Range ratio for momentum
input double MomentumATRMult         = 1.00;  // Range >= ATR * multiplier

// --- Filters / volatility ---
input int    ATRPeriod               = 14;    // ATR period for filters
input double ATRMin                  = 0.0005; // Minimum ATR (symbol points)
input int    RangeLookback           = 20;    // Bars for consolidation check
input double RangeMin                = 0.0020; // Minimum range to avoid consolidation

// --- Indication level rules ---
input int    WickLookback            = 50;    // How many H4 candles to scan
input bool   UseWickHighsForBull     = false; // Default: use wick lows for bull
input double WickMomentumATRMult     = 1.00;  // Momentum candle range >= ATR * this

// --- Entry rules (M5) ---
input double SweepMinPoints          = 20;    // Minimum sweep beyond level (points)
input double GoldenZoneTolerancePts  = 20;    // Tolerance around 50% retrace
input int    GoldenZoneLookbackBars  = 30;    // Bars to detect price touching 50%
input int    PivotLookback           = 2;     // Pivot lookback (fractal-style)
input double DisplacementATRMult     = 1.20;  // Displacement body >= ATR * mult
input double BreakCloseBufferPts     = 10;    // Close beyond level buffer (points)

// --- Session filter ---
input bool   UseSessionFilter        = true;  // Enable NY-London overlap filter
input int    SessionUTCOffsetHours   = -6;    // CST offset from UTC
input int    OverlapStartHour        = 20;    // 8:00 PM CST
input int    OverlapEndHour          = 0;     // 12:00 AM CST (midnight)

// --- News filter ---
input bool   UseNewsFilter           = true;  // Enable news blackout window
input bool   UseCalendarNews         = true;  // Try MT5 calendar first
input int    NewsMinutesBefore       = 60;    // Minutes before news to block
input int    NewsMinutesAfter        = 30;    // Minutes after news to block
input string ManualNewsTimesCSV      = "";    // Comma-separated datetime list

// --- Risk / trade limits ---
input double RiskPercent             = 5.0;   // Risk % per trade
input int    MaxTradesPerDay         = 1;     // Max trades per day
input int    MaxTradesPerWeek        = 5;     // Max trades per week
input double SLBufferPoints          = 30;    // SL buffer beyond indication level
input double TPBufferPoints          = 20;    // TP buffer before target

// --- Trade management ---
input ManagementMode TradeMgmtMode   = MODE_IRON_DOME; // Iron Dome or Shield

// --- Execution / misc ---
input ulong  MagicNumber             = 20250130; // Magic number for EA trades
input bool   AllowLongs              = true;     // Allow buy trades
input bool   AllowShorts             = true;     // Allow sell trades

//+------------------------------------------------------------------+
//| GLOBAL STATE                                                     |
//+------------------------------------------------------------------+

CTrade trade;                           // Trade helper object
BiasDirection g_bias = BIAS_NONE;       // Current HTF bias
Level g_targets[];                      // HTF target levels
Level g_indicationLevels[];             // HTF indication levels
TradeState g_states[];                  // Position management states

// Track last bar times for H4 and M5 to detect new bars.
datetime g_lastH4BarTime = 0;
datetime g_lastM5BarTime = 0;

// Trade counters for daily/weekly limits.
int g_tradesToday = 0;
int g_tradesWeek  = 0;
int g_lastTradeDay = -1;
int g_lastTradeWeek = -1;

//+------------------------------------------------------------------+
//| UTILITY: Array helpers                                           |
//+------------------------------------------------------------------+

// Find index of a trade state by ticket; returns -1 if not found.
int FindTradeStateIndex(const ulong ticket)
{
   for(int i = 0; i < ArraySize(g_states); i++)
   {
      if(g_states[i].ticket == ticket)
         return i;
   }
   return -1;
}

// Add or initialize a trade state when we detect a new position.
void EnsureTradeState(const ulong ticket, const double entry, const double sl, const double vol)
{
   int idx = FindTradeStateIndex(ticket);
   if(idx >= 0)
      return; // Already tracked

   TradeState state;
   state.ticket     = ticket;
   state.entryPrice = entry;
   state.initialSL  = sl;
   state.initialVol = vol;
   state.did1R      = false;
   state.did2R      = false;
   state.trailActive = false;

   int newSize = ArraySize(g_states) + 1;
   ArrayResize(g_states, newSize);
   g_states[newSize - 1] = state;
}

// Remove a trade state by index when position is closed.
void RemoveTradeStateByIndex(const int idx)
{
   if(idx < 0 || idx >= ArraySize(g_states))
      return;

   for(int i = idx; i < ArraySize(g_states) - 1; i++)
      g_states[i] = g_states[i + 1];

   ArrayResize(g_states, ArraySize(g_states) - 1);
}

//+------------------------------------------------------------------+
//| UTILITY: Time / session helpers                                  |
//+------------------------------------------------------------------+

// Convert UTC to local session time using a fixed offset (CST by default).
int GetSessionHour()
{
   datetime utc = TimeGMT();
   datetime sessionTime = utc + (SessionUTCOffsetHours * 3600);
   return TimeHour(sessionTime);
}

// Determine if we are inside the configured overlap window.
bool InSessionWindow()
{
   if(!UseSessionFilter)
      return true; // Filter disabled

   int hour = GetSessionHour();

   // Handle windows that cross midnight (e.g., 20 -> 0).
   if(OverlapStartHour <= OverlapEndHour)
      return (hour >= OverlapStartHour && hour < OverlapEndHour);

   return (hour >= OverlapStartHour || hour < OverlapEndHour);
}

//+------------------------------------------------------------------+
//| UTILITY: News filter helpers                                     |
//+------------------------------------------------------------------+

// Parse manual news times from CSV. Expected format: "YYYY.MM.DD HH:MI".
// Returns true if any event falls inside the blackout window.
bool ManualNewsBlackout()
{
   if(StringLen(ManualNewsTimesCSV) == 0)
      return false;

   datetime now = TimeCurrent();
   string items[];
   int count = StringSplit(ManualNewsTimesCSV, ',', items);
   for(int i = 0; i < count; i++)
   {
      string trimmed = StringTrim(items[i]);
      datetime eventTime = StringToTime(trimmed);
      if(eventTime == 0)
         continue; // Skip invalid entries

      if(now >= eventTime - (NewsMinutesBefore * 60) &&
         now <= eventTime + (NewsMinutesAfter * 60))
      {
         return true;
      }
   }

   return false;
}

// Attempt to use MT5 Economic Calendar if enabled.
bool CalendarNewsBlackout()
{
   if(!UseCalendarNews)
      return false;

   // Request calendar values around now. If broker doesn't support it,
   // CalendarValueHistory may return 0 or fail gracefully.
   datetime now = TimeCurrent();
   datetime from = now - (NewsMinutesBefore * 60);
   datetime to   = now + (NewsMinutesAfter * 60);

   MqlCalendarValue values[];
   int found = CalendarValueHistory(values, from, to);
   if(found <= 0)
      return false; // No events or calendar not available

   for(int i = 0; i < found; i++)
   {
      // Any event inside the blackout window is enough to block trading.
      datetime eventTime = values[i].time;
      if(now >= eventTime - (NewsMinutesBefore * 60) &&
         now <= eventTime + (NewsMinutesAfter * 60))
      {
         return true;
      }
   }

   return false;
}

// Unified news filter check.
bool InNewsBlackout()
{
   if(!UseNewsFilter)
      return false;

   if(CalendarNewsBlackout())
      return true;

   return ManualNewsBlackout();
}

//+------------------------------------------------------------------+
//| UTILITY: New bar detection                                       |
//+------------------------------------------------------------------+

// Returns true if a new bar has formed on the given timeframe.
bool IsNewBar(const ENUM_TIMEFRAMES tf, datetime &lastBarTime)
{
   datetime times[];
   if(CopyTime(_Symbol, tf, 0, 1, times) <= 0)
      return false;

   if(times[0] != lastBarTime)
   {
      lastBarTime = times[0];
      return true;
   }

   return false;
}

//+------------------------------------------------------------------+
//| HTF: Impulse / Bias detection                                    |
//+------------------------------------------------------------------+

// Determine if a candle is momentum-based using body/ATR criteria.
bool IsMomentumCandle(const ENUM_TIMEFRAMES tf, const int index)
{
   double open  = iOpen(_Symbol, tf, index);
   double close = iClose(_Symbol, tf, index);
   double high  = iHigh(_Symbol, tf, index);
   double low   = iLow(_Symbol, tf, index);
   double range = high - low;
   if(range <= 0)
      return false;

   double body  = MathAbs(close - open);
   double ratio = body / range;
   double atr   = iATR(_Symbol, tf, ATRPeriod, index);

   return (ratio >= MomentumBodyRatio && range >= atr * MomentumATRMult);
}

// Determine if a candle breaks the prior candle range in its direction.
bool BrokePriorRange(const ENUM_TIMEFRAMES tf, const int index)
{
   double high  = iHigh(_Symbol, tf, index);
   double low   = iLow(_Symbol, tf, index);
   double highPrev = iHigh(_Symbol, tf, index + 1);
   double lowPrev  = iLow(_Symbol, tf, index + 1);

   bool isBull = (iClose(_Symbol, tf, index) > iOpen(_Symbol, tf, index));
   if(isBull)
      return (high > highPrev);
   else
      return (low < lowPrev);
}

// Determine if a candle qualifies as an impulse candle (CIT).
bool IsImpulseCandle(const ENUM_TIMEFRAMES tf, const int index)
{
   if(!IsMomentumCandle(tf, index))
      return false;

   if(!BrokePriorRange(tf, index))
      return false;

   return true;
}

// Detect bias using consecutive impulse candles in the same direction.
BiasDirection DetectBiasByImpulseCIT(const ENUM_TIMEFRAMES tf)
{
   int bullCount = 0;
   int bearCount = 0;

   for(int i = 1; i <= BiasImpulseBars; i++)
   {
      if(!IsImpulseCandle(tf, i))
         return BIAS_NONE;

      bool isBull = (iClose(_Symbol, tf, i) > iOpen(_Symbol, tf, i));
      if(isBull)
         bullCount++;
      else
         bearCount++;
   }

   if(bullCount == BiasImpulseBars)
      return BIAS_BULL;
   if(bearCount == BiasImpulseBars)
      return BIAS_BEAR;

   return BIAS_NONE;
}

//+------------------------------------------------------------------+
//| HTF: Filters and targets                                         |
//+------------------------------------------------------------------+

// Check HTF filters: consolidation, low volatility, etc.
bool PassesHTFFilters()
{
   double atr = iATR(_Symbol, TF_Bias, ATRPeriod, 1);
   if(atr < ATRMin)
      return false;

   double highest = iHigh(_Symbol, TF_Bias, iHighest(_Symbol, TF_Bias, MODE_HIGH, RangeLookback, 1));
   double lowest  = iLow(_Symbol, TF_Bias, iLowest(_Symbol, TF_Bias, MODE_LOW, RangeLookback, 1));
   if((highest - lowest) < RangeMin)
      return false;

   return true;
}

// Identify swing targets (highs/lows) using a simple fractal-like rule.
void DetectTargets(const ENUM_TIMEFRAMES tf)
{
   ArrayResize(g_targets, 0); // Clear existing targets

   int bars = Bars(_Symbol, tf);
   for(int i = PivotLookback + 1; i < bars - PivotLookback; i++)
   {
      double high = iHigh(_Symbol, tf, i);
      double low  = iLow(_Symbol, tf, i);

      bool isSwingHigh = true;
      bool isSwingLow  = true;

      for(int j = 1; j <= PivotLookback; j++)
      {
         if(iHigh(_Symbol, tf, i - j) >= high || iHigh(_Symbol, tf, i + j) >= high)
            isSwingHigh = false;

         if(iLow(_Symbol, tf, i - j) <= low || iLow(_Symbol, tf, i + j) <= low)
            isSwingLow = false;
      }

      if(isSwingHigh)
      {
         Level lvl;
         lvl.price = high;
         lvl.time  = iTime(_Symbol, tf, i);
         lvl.tf    = tf;
         int size = ArraySize(g_targets) + 1;
         ArrayResize(g_targets, size);
         g_targets[size - 1] = lvl;
      }

      if(isSwingLow)
      {
         Level lvl;
         lvl.price = low;
         lvl.time  = iTime(_Symbol, tf, i);
         lvl.tf    = tf;
         int size = ArraySize(g_targets) + 1;
         ArrayResize(g_targets, size);
         g_targets[size - 1] = lvl;
      }
   }
}

//+------------------------------------------------------------------+
//| HTF: Indication level detection                                  |
//+------------------------------------------------------------------+

// Check if a wick level is untouched since its creation.
bool IsWickUntouched(const ENUM_TIMEFRAMES tf, const int wickIndex, const double level, const BiasDirection bias)
{
   for(int i = wickIndex - 1; i >= 1; i--)
   {
      if(bias == BIAS_BULL)
      {
         // For bullish continuation we want price not to dip to/through the wick level.
         if(iLow(_Symbol, tf, i) <= level)
            return false;
      }
      else if(bias == BIAS_BEAR)
      {
         // For bearish continuation we want price not to rise to/through the wick level.
         if(iHigh(_Symbol, tf, i) >= level)
            return false;
      }
   }

   return true;
}

// Find and store untouched wick levels on HTF.
void DetectIndicationLevels(const ENUM_TIMEFRAMES tf, const BiasDirection bias)
{
   ArrayResize(g_indicationLevels, 0);

   for(int i = 1; i <= WickLookback; i++)
   {
      double open  = iOpen(_Symbol, tf, i);
      double close = iClose(_Symbol, tf, i);
      double high  = iHigh(_Symbol, tf, i);
      double low   = iLow(_Symbol, tf, i);
      double range = high - low;
      if(range <= 0)
         continue;

      double atr = iATR(_Symbol, tf, ATRPeriod, i);
      bool momentumCandle = (range >= atr * WickMomentumATRMult) && (MathAbs(close - open) / range >= MomentumBodyRatio);
      if(!momentumCandle)
         continue;

      double wickLevel = 0.0;
      if(bias == BIAS_BULL)
         wickLevel = (UseWickHighsForBull ? high : low);
      else if(bias == BIAS_BEAR)
         wickLevel = high; // default for bearish = upper wicks
      else
         continue;

      if(IsWickUntouched(tf, i, wickLevel, bias))
      {
         Level lvl;
         lvl.price = wickLevel;
         lvl.time  = iTime(_Symbol, tf, i);
         lvl.tf    = tf;
         int size = ArraySize(g_indicationLevels) + 1;
         ArrayResize(g_indicationLevels, size);
         g_indicationLevels[size - 1] = lvl;
      }
   }
}

// Choose the best indication level: nearest to price in direction of correction.
bool SelectBestIndicationLevel(const BiasDirection bias, Level &outLevel)
{
   if(ArraySize(g_indicationLevels) == 0)
      return false;

   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double bestDist = DBL_MAX;
   bool found = false;

   for(int i = 0; i < ArraySize(g_indicationLevels); i++)
   {
      double lvl = g_indicationLevels[i].price;
      double dist = MathAbs(price - lvl);

      // For bullish bias, we expect levels below price; for bearish, above price.
      if(bias == BIAS_BULL && lvl > price)
         continue;
      if(bias == BIAS_BEAR && lvl < price)
         continue;

      if(dist < bestDist)
      {
         bestDist = dist;
         outLevel = g_indicationLevels[i];
         found = true;
      }
   }

   return found;
}

//+------------------------------------------------------------------+
//| LTF: Entry conditions                                            |
//+------------------------------------------------------------------+

// Check for a sweep below/above indication level and reclaim on the last closed bar.
bool SweptLevelAndReclaimed(const Level &lvl, const BiasDirection bias)
{
   double close = iClose(_Symbol, TF_Entry, 1);
   double low   = iLow(_Symbol, TF_Entry, 1);
   double high  = iHigh(_Symbol, TF_Entry, 1);

   if(bias == BIAS_BULL)
   {
      bool swept = (low <= lvl.price - (SweepMinPoints * _Point));
      bool reclaimed = (close > lvl.price);
      return swept && reclaimed;
   }
   else if(bias == BIAS_BEAR)
   {
      bool swept = (high >= lvl.price + (SweepMinPoints * _Point));
      bool reclaimed = (close < lvl.price);
      return swept && reclaimed;
   }

   return false;
}

// Identify the last impulse leg to compute the 50% retracement.
bool GetLastImpulseLeg(const BiasDirection bias, double &outLow, double &outHigh)
{
   // We use recent swings on H4 to define the leg.
   double lastSwingHigh = 0.0;
   double lastSwingLow  = 0.0;
   bool foundHigh = false;
   bool foundLow  = false;

   int bars = Bars(_Symbol, TF_Bias);
   for(int i = PivotLookback + 1; i < bars - PivotLookback; i++)
   {
      double high = iHigh(_Symbol, TF_Bias, i);
      double low  = iLow(_Symbol, TF_Bias, i);

      bool isSwingHigh = true;
      bool isSwingLow  = true;

      for(int j = 1; j <= PivotLookback; j++)
      {
         if(iHigh(_Symbol, TF_Bias, i - j) >= high || iHigh(_Symbol, TF_Bias, i + j) >= high)
            isSwingHigh = false;

         if(iLow(_Symbol, TF_Bias, i - j) <= low || iLow(_Symbol, TF_Bias, i + j) <= low)
            isSwingLow = false;
      }

      if(isSwingHigh && !foundHigh)
      {
         lastSwingHigh = high;
         foundHigh = true;
      }

      if(isSwingLow && !foundLow)
      {
         lastSwingLow = low;
         foundLow = true;
      }

      if(foundHigh && foundLow)
         break; // Use most recent pair
   }

   if(!foundHigh || !foundLow)
      return false;

   if(bias == BIAS_BULL)
   {
      outLow  = lastSwingLow;
      outHigh = lastSwingHigh;
   }
   else if(bias == BIAS_BEAR)
   {
      outLow  = lastSwingLow;
      outHigh = lastSwingHigh;
   }
   else
      return false;

   return true;
}

// Check if price traded into the 50% golden zone within a lookback window.
bool TradedIntoGoldenZone(const double gold50)
{
   for(int i = 1; i <= GoldenZoneLookbackBars; i++)
   {
      double high = iHigh(_Symbol, TF_Entry, i);
      double low  = iLow(_Symbol, TF_Entry, i);

      if(gold50 >= low - (GoldenZoneTolerancePts * _Point) &&
         gold50 <= high + (GoldenZoneTolerancePts * _Point))
      {
         return true;
      }
   }

   return false;
}

// Determine the last swing high/low on LTF for CHoCH checks.
bool GetLastPivot(const BiasDirection bias, double &outPivot)
{
   int bars = Bars(_Symbol, TF_Entry);
   for(int i = PivotLookback + 1; i < bars - PivotLookback; i++)
   {
      double high = iHigh(_Symbol, TF_Entry, i);
      double low  = iLow(_Symbol, TF_Entry, i);

      bool isSwingHigh = true;
      bool isSwingLow  = true;
      for(int j = 1; j <= PivotLookback; j++)
      {
         if(iHigh(_Symbol, TF_Entry, i - j) >= high || iHigh(_Symbol, TF_Entry, i + j) >= high)
            isSwingHigh = false;
         if(iLow(_Symbol, TF_Entry, i - j) <= low || iLow(_Symbol, TF_Entry, i + j) <= low)
            isSwingLow = false;
      }

      if(bias == BIAS_BULL && isSwingHigh)
      {
         outPivot = high;
         return true;
      }
      if(bias == BIAS_BEAR && isSwingLow)
      {
         outPivot = low;
         return true;
      }
   }

   return false;
}

// CHoCH confirmation: close breaks last pivot in opposite direction.
bool CHoCHConfirmed(const BiasDirection bias, double &outBrokenLevel)
{
   double pivot;
   if(!GetLastPivot(bias, pivot))
      return false;

   double close = iClose(_Symbol, TF_Entry, 1);

   if(bias == BIAS_BULL && close > pivot + (BreakCloseBufferPts * _Point))
   {
      outBrokenLevel = pivot;
      return true;
   }
   if(bias == BIAS_BEAR && close < pivot - (BreakCloseBufferPts * _Point))
   {
      outBrokenLevel = pivot;
      return true;
   }

   return false;
}

// Displacement breakout: last bar has big body and closes beyond pivot.
bool DisplacementBreakout(const BiasDirection bias, const double brokenLevel)
{
   double open  = iOpen(_Symbol, TF_Entry, 1);
   double close = iClose(_Symbol, TF_Entry, 1);
   double high  = iHigh(_Symbol, TF_Entry, 1);
   double low   = iLow(_Symbol, TF_Entry, 1);
   double atr   = iATR(_Symbol, TF_Entry, ATRPeriod, 1);

   double body = MathAbs(close - open);
   if(body < atr * DisplacementATRMult)
      return false;

   if(bias == BIAS_BULL)
      return (close > brokenLevel + (BreakCloseBufferPts * _Point));
   if(bias == BIAS_BEAR)
      return (close < brokenLevel - (BreakCloseBufferPts * _Point));

   return false;
}

//+------------------------------------------------------------------+
//| RISK & POSITION SIZING                                           |
//+------------------------------------------------------------------+

// Calculate lot size based on risk %, SL distance, and symbol properties.
double CalculateLotsByRisk(const double entry, const double sl)
{
   double riskMoney = AccountInfoDouble(ACCOUNT_BALANCE) * (RiskPercent / 100.0);
   double slPoints  = MathAbs(entry - sl) / _Point;
   if(slPoints <= 0)
      return 0.0;

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0)
      return 0.0;

   double valuePerPointPerLot = tickValue / tickSize;
   double lots = riskMoney / (slPoints * valuePerPointPerLot);

   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   lots = MathMax(minLot, MathMin(maxLot, lots));
   lots = MathFloor(lots / stepLot) * stepLot; // Normalize to lot step

   return lots;
}

//+------------------------------------------------------------------+
//| TRADE LIMITS                                                     |
//+------------------------------------------------------------------+

// Update daily/weekly counters using the current time.
void RefreshTradeCounters()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   int day = dt.day;
   int week = dt.week_of_year;

   if(day != g_lastTradeDay)
   {
      g_tradesToday = 0;
      g_lastTradeDay = day;
   }

   if(week != g_lastTradeWeek)
   {
      g_tradesWeek = 0;
      g_lastTradeWeek = week;
   }
}

// Check whether we are allowed to open a new trade.
bool CanTradeNow()
{
   RefreshTradeCounters();

   if(g_tradesToday >= MaxTradesPerDay)
      return false;
   if(g_tradesWeek >= MaxTradesPerWeek)
      return false;

   return true;
}

//+------------------------------------------------------------------+
//| TRADE EXECUTION                                                  |
//+------------------------------------------------------------------+

// Determine nearest target in the trade direction for TP placement.
bool SelectTarget(const BiasDirection bias, double &outTarget)
{
   if(ArraySize(g_targets) == 0)
      return false;

   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double bestDist = DBL_MAX;
   bool found = false;

   for(int i = 0; i < ArraySize(g_targets); i++)
   {
      double lvl = g_targets[i].price;
      if(bias == BIAS_BULL && lvl <= price)
         continue;
      if(bias == BIAS_BEAR && lvl >= price)
         continue;

      double dist = MathAbs(lvl - price);
      if(dist < bestDist)
      {
         bestDist = dist;
         outTarget = lvl;
         found = true;
      }
   }

   return found;
}

// Place the trade with calculated SL/TP and size.
bool PlaceTrade(const BiasDirection bias, const double entry, const double sl, const double tp, const double lots)
{
   trade.SetExpertMagicNumber((int)MagicNumber);
   trade.SetDeviationInPoints(10);

   bool result = false;
   if(bias == BIAS_BULL && AllowLongs)
      result = trade.Buy(lots, _Symbol, entry, sl, tp, "CCT Buy");
   if(bias == BIAS_BEAR && AllowShorts)
      result = trade.Sell(lots, _Symbol, entry, sl, tp, "CCT Sell");

   if(result)
   {
      g_tradesToday++;
      g_tradesWeek++;
   }

   return result;
}

//+------------------------------------------------------------------+
//| TRADE MANAGEMENT (IRON DOME & SHIELD)                            |
//+------------------------------------------------------------------+

// Calculate profit in R terms for a position.
double CurrentProfitR(const BiasDirection bias, const double entry, const double sl)
{
   double r = MathAbs(entry - sl);
   if(r <= 0)
      return 0.0;

   double price = (bias == BIAS_BULL) ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                                     : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(bias == BIAS_BULL)
      return (price - entry) / r;
   else
      return (entry - price) / r;
}

// Update SL for a position using CTrade.
bool ModifyPositionSL(const ulong ticket, const double sl, const double tp)
{
   return trade.PositionModify(ticket, sl, tp);
}

// Perform partial close of a position volume.
bool PartialClose(const ulong ticket, const double volume)
{
   return trade.PositionClosePartial(ticket, volume);
}

// Manage positions according to the selected protocol.
void ManageOpenPositions()
{
   int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      if(!PositionSelectByIndex(i))
         continue;

      string sym = PositionGetString(POSITION_SYMBOL);
      if(sym != _Symbol)
         continue;

      ulong ticket = PositionGetInteger(POSITION_TICKET);
      long magic = PositionGetInteger(POSITION_MAGIC);
      if(magic != (long)MagicNumber)
         continue;

      double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl    = PositionGetDouble(POSITION_SL);
      double tp    = PositionGetDouble(POSITION_TP);
      double vol   = PositionGetDouble(POSITION_VOLUME);
      long type    = PositionGetInteger(POSITION_TYPE);

      BiasDirection bias = (type == POSITION_TYPE_BUY) ? BIAS_BULL : BIAS_BEAR;

      EnsureTradeState(ticket, entry, sl, vol);
      int idx = FindTradeStateIndex(ticket);
      if(idx < 0)
         continue;

      TradeState &state = g_states[idx];
      double profitR = CurrentProfitR(bias, state.entryPrice, state.initialSL);

      if(TradeMgmtMode == MODE_IRON_DOME)
      {
         // +1R: close 25% of original, move SL to BE
         if(profitR >= 1.0 && !state.did1R)
         {
            double closeVol = state.initialVol * 0.25;
            PartialClose(ticket, closeVol);
            ModifyPositionSL(ticket, state.entryPrice, tp);
            state.did1R = true;
         }

         // +2R: close another 25% of original, move SL to +1R
         if(profitR >= 2.0 && !state.did2R)
         {
            double closeVol = state.initialVol * 0.25;
            PartialClose(ticket, closeVol);

            double newSL = (bias == BIAS_BULL)
               ? state.entryPrice + MathAbs(state.entryPrice - state.initialSL)
               : state.entryPrice - MathAbs(state.entryPrice - state.initialSL);

            ModifyPositionSL(ticket, newSL, tp);
            state.did2R = true;
         }

         // +3R+: trail SL by +1R for every additional +1R
         if(profitR >= 3.0)
         {
            double r = MathAbs(state.entryPrice - state.initialSL);
            double targetSL = 0.0;
            int steps = (int)MathFloor(profitR) - 1; // At 3R -> step=2 => SL at +2R

            if(bias == BIAS_BULL)
               targetSL = state.entryPrice + (steps * r);
            else
               targetSL = state.entryPrice - (steps * r);

            // Only move SL forward, never backward.
            if((bias == BIAS_BULL && targetSL > sl) || (bias == BIAS_BEAR && targetSL < sl))
               ModifyPositionSL(ticket, targetSL, tp);
         }
      }
      else if(TradeMgmtMode == MODE_SHIELD)
      {
         // Shield: BE at 80% to TP
         double distToTP = MathAbs(state.entryPrice - tp);
         if(distToTP > 0)
         {
            double price = (bias == BIAS_BULL) ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                                               : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            double progress = MathAbs(price - state.entryPrice);
            if(progress >= distToTP * 0.80)
               ModifyPositionSL(ticket, state.entryPrice, tp);
         }

         // Enable trailing after a structure break with momentum.
         double brokenLevel = 0.0;
         if(!state.trailActive && CHoCHConfirmed(bias, brokenLevel) && DisplacementBreakout(bias, brokenLevel))
            state.trailActive = true;

         if(state.trailActive && profitR >= 1.0)
         {
            double r = MathAbs(state.entryPrice - state.initialSL);
            int steps = (int)MathFloor(profitR);
            double targetSL = 0.0;

            if(bias == BIAS_BULL)
               targetSL = state.entryPrice + (steps * r);
            else
               targetSL = state.entryPrice - (steps * r);

            if((bias == BIAS_BULL && targetSL > sl) || (bias == BIAS_BEAR && targetSL < sl))
               ModifyPositionSL(ticket, targetSL, tp);
         }
      }
   }

   // Clean up trade states for closed positions.
   for(int i = ArraySize(g_states) - 1; i >= 0; i--)
   {
      ulong ticket = g_states[i].ticket;
      if(!PositionSelectByTicket(ticket))
         RemoveTradeStateByIndex(i);
   }
}

//+------------------------------------------------------------------+
//| MAIN ENTRY LOGIC                                                 |
//+------------------------------------------------------------------+

// Check whether LTF execution filters pass (session/news).
bool PassesExecutionFilters()
{
   if(!InSessionWindow())
      return false;
   if(InNewsBlackout())
      return false;
   return true;
}

// Evaluate M5 entry based on ICC + confluences.
void EvaluateEntry()
{
   if(g_bias == BIAS_NONE)
      return;

   if(!PassesExecutionFilters())
      return;

   if(!CanTradeNow())
      return;

   Level level;
   if(!SelectBestIndicationLevel(g_bias, level))
      return;

   double legLow, legHigh;
   if(!GetLastImpulseLeg(g_bias, legLow, legHigh))
      return;

   double gold50 = (legLow + legHigh) / 2.0;

   if(!SweptLevelAndReclaimed(level, g_bias))
      return;
   if(!TradedIntoGoldenZone(gold50))
      return;

   double brokenLevel = 0.0;
   if(!CHoCHConfirmed(g_bias, brokenLevel))
      return;
   if(!DisplacementBreakout(g_bias, brokenLevel))
      return;

   double entry = (g_bias == BIAS_BULL)
      ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
      : SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double sl = (g_bias == BIAS_BULL)
      ? level.price - (SLBufferPoints * _Point)
      : level.price + (SLBufferPoints * _Point);

   double target;
   if(!SelectTarget(g_bias, target))
      return;

   double tp = (g_bias == BIAS_BULL)
      ? target - (TPBufferPoints * _Point)
      : target + (TPBufferPoints * _Point);

   double lots = CalculateLotsByRisk(entry, sl);
   if(lots <= 0)
      return;

   PlaceTrade(g_bias, entry, sl, tp, lots);
}

// Update HTF bias and levels on each new H4 bar.
void UpdateHTFState()
{
   if(!PassesHTFFilters())
   {
      g_bias = BIAS_NONE;
      ArrayResize(g_targets, 0);
      ArrayResize(g_indicationLevels, 0);
      return;
   }

   g_bias = DetectBiasByImpulseCIT(TF_Bias);
   if(g_bias == BIAS_NONE)
      return;

   DetectTargets(TF_Bias);
   DetectIndicationLevels(TF_Bias, g_bias);
}

//+------------------------------------------------------------------+
//| MT5 EVENT HANDLERS                                               |
//+------------------------------------------------------------------+

int OnInit()
{
   trade.SetTypeFilling(ORDER_FILLING_FOK);
   return(INIT_SUCCEEDED);
}

void OnTick()
{
   // Update HTF state on new H4 bar.
   if(IsNewBar(TF_Bias, g_lastH4BarTime))
      UpdateHTFState();

   // Evaluate entry on new M5 bar.
   if(IsNewBar(TF_Entry, g_lastM5BarTime))
      EvaluateEntry();

   // Manage open positions on every tick.
   ManageOpenPositions();
}

