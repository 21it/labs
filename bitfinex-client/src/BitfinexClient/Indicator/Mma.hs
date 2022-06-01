{-# OPTIONS_HADDOCK show-extensions #-}

module BitfinexClient.Indicator.Mma
  ( RewardToRisk (..),
    TradeEntry (..),
    TradeExit (..),
    StopLoss (..),
    TakeProfit (..),
    Mma (..),
    mma,
  )
where

import BitfinexClient.Import
import BitfinexClient.Indicator.Atr (Atr)
import qualified BitfinexClient.Indicator.Atr as Atr
import BitfinexClient.Indicator.Ma
import qualified Data.Map as Map
import qualified Data.Ord as Ord
import qualified Data.Vector as V
import qualified Math.Combinat.Sets as Math

newtype RewardToRisk = RewardToRisk
  { unRewardToRisk :: Rational
  }
  deriving newtype
    ( Eq,
      Ord,
      NFData
    )
  deriving stock
    ( Generic,
      Show
    )

newtype CrvQty = CrvQty
  { unCrvQty :: Int
  }
  deriving newtype
    ( Eq,
      Ord,
      Num,
      Real,
      Enum,
      Integral
    )
  deriving stock
    ( Generic,
      Show
    )

data TradeEntry = TradeEntry
  { tradeEntryCandle :: Candle,
    tradeEntryAtr :: Atr,
    tradeEntryPrevSwingLow :: PrevSwingLow,
    tradeEntryStopLoss :: StopLoss,
    tradeEntryTakeProfit :: TakeProfit
  }
  deriving stock
    ( Eq,
      Ord,
      Generic
    )

instance NFData TradeEntry

newtype TradeExit = TradeExit
  { unTradeExit :: Candle
  }
  deriving newtype
    ( Eq,
      Ord,
      NFData
    )
  deriving stock
    ( Generic,
      Show
    )

newtype PrevSwingLow = PrevSwingLow
  { unPrevSwingLow :: Candle
  }
  deriving newtype
    ( Eq,
      Ord,
      NFData
    )
  deriving stock
    ( Generic,
      Show
    )

newtype TakeProfit = TakeProfit
  { unTakeProfit :: QuotePerBase'
  }
  deriving newtype
    ( Eq,
      Ord,
      NFData
    )
  deriving stock
    ( Generic
    )

newtype StopLoss = StopLoss
  { unStopLoss :: QuotePerBase'
  }
  deriving newtype
    ( Eq,
      Ord,
      NFData
    )
  deriving stock
    ( Generic
    )

data Mma = Mma
  { mmaSymbol :: CurrencyPair,
    mmaCandles :: NonEmpty Candle,
    mmaCurves :: Map MaPeriod (Map UTCTime Ma),
    mmaTrades :: [(TradeEntry, TradeExit)],
    mmaRewardToRisk :: RewardToRisk,
    mmaEntry :: TradeEntry
  }
  deriving stock
    ( Eq,
      Generic
    )

instance NFData Mma

--
-- TODO : use r2r!!!
--
instance Ord Mma where
  compare lhs rhs =
    compare
      (length $ mmaTrades lhs, mmaRewardToRisk lhs)
      (length $ mmaTrades rhs, mmaRewardToRisk rhs)

mma :: CurrencyPair -> NonEmpty Candle -> Maybe Mma
mma sym cs =
  (maximum <$>) . nonEmpty $
    [1 .. 8]
      >>= combineMaPeriods sym cs atr
  where
    atr =
      Atr.atr cs

combineMaPeriods ::
  CurrencyPair ->
  NonEmpty Candle ->
  Map UTCTime Atr ->
  CrvQty ->
  [Mma]
combineMaPeriods sym cs atrs qty =
  mapMaybe
    ( newMma sym cs atrs
        . V.indexed
        . V.fromList
        $ toList cs
    )
    . catMaybes
    . (nonEmpty <$>)
    . Math.choose (unCrvQty qty)
    . ((\p -> (p, ma p cs)) <$>)
    $ [2, 3, 4]
      <> [5, 10, 15, 20]
      <> [30, 50, 60]
      <> [90, 180, 270, 360]

newMma ::
  CurrencyPair ->
  NonEmpty Candle ->
  Map UTCTime Atr ->
  Vector (Int, Candle) ->
  NonEmpty (MaPeriod, Map UTCTime Ma) ->
  Maybe Mma
newMma sym cs0 atrs cs curves = do
  (csPrev, cLast) <- V.unsnoc cs
  (_, cPrev) <- V.unsnoc csPrev
  let newEntry r2r =
        tryFindEntries
          r2r
          cs
          [cPrev, cLast]
          atrs
          curves
          V.!? 0
  dummyEntry <-
    newEntry $ RewardToRisk 1
  maxMma <-
    (maximum <$>)
      . nonEmpty
      . catMaybes
      $ ( \rate -> do
            let r2r = RewardToRisk $ rate % 5
            trades <-
              V.mapM (tryFindExit csPrev) $
                tryFindEntries r2r cs csPrev atrs curves
            pure
              Mma
                { mmaSymbol = sym,
                  mmaCandles = cs0,
                  mmaCurves = Map.fromList $ from curves,
                  mmaTrades = V.toList trades,
                  mmaRewardToRisk = r2r,
                  mmaEntry = snd dummyEntry
                }
        )
        <$> [10, 9 .. 5]
  if length (mmaTrades maxMma) < 4
    then Nothing
    else do
      entry <-
        newEntry $ mmaRewardToRisk maxMma
      pure
        maxMma
          { mmaEntry = snd entry
          }

tryFindEntries ::
  RewardToRisk ->
  Vector (Int, Candle) ->
  Vector (Int, Candle) ->
  Map UTCTime Atr ->
  NonEmpty (MaPeriod, Map UTCTime Ma) ->
  Vector (Int, TradeEntry)
tryFindEntries r2r csHist cs atrs curves =
  ( \((_, c0), (idx1, c1)) ->
      let at0 = candleAt c0
          mas0 = newMas at0
          at1 = candleAt c1
          mas1 = newMas at1
       in if (length curves == length mas0)
            && (length curves == length mas1)
            && goodCandle c0 c1 mas1
            && not (goodCandle c0 c1 mas0)
            then fromMaybe mempty $ do
              atr <- Map.lookup at1 atrs
              prv <- tryFindPrevSwingLow (V.take idx1 csHist) c1
              stopLoss <- tryFindStopLoss prv atr
              takeProfit <- tryFindTakeProfit r2r c1 stopLoss
              pure . V.singleton $
                ( idx1,
                  TradeEntry
                    { tradeEntryCandle = c1,
                      tradeEntryAtr = atr,
                      tradeEntryPrevSwingLow = prv,
                      tradeEntryStopLoss = stopLoss,
                      tradeEntryTakeProfit = takeProfit
                    }
                )
            else mempty
  )
    <=< V.zip cs
    $ V.tail cs
  where
    newMas :: UTCTime -> [(MaPeriod, Ma)]
    newMas t =
      mapMaybe
        (\(p, curve) -> (p,) <$> Map.lookup t curve)
        $ toList curves

goodCandle ::
  Candle ->
  Candle ->
  [(MaPeriod, Ma)] ->
  Bool
goodCandle x0 x1 xs =
  (c1 > c0)
    && all ((unQuotePerBase c1 >) . unMa . snd) xs
    && (xs == sortOn (Ord.Down . snd) xs)
  where
    c0 = candleClose x0
    c1 = candleClose x1

tryFindPrevSwingLow ::
  Vector (Int, Candle) ->
  Candle ->
  Maybe PrevSwingLow
tryFindPrevSwingLow cs cur = do
  (hist, (_, prev)) <- V.unsnoc cs
  if candleLow prev <= candleLow cur
    then tryFindPrevSwingLow hist prev
    else pure $ PrevSwingLow cur

tryFindStopLoss :: PrevSwingLow -> Atr -> Maybe StopLoss
tryFindStopLoss prevLow0 atr0 =
  if prevLow <= volatility
    then Nothing
    else
      Just . StopLoss $
        prevLow |-| volatility
  where
    volatility =
      Atr.unAtr atr0
    prevLow =
      unQuotePerBase . candleLow $
        unPrevSwingLow prevLow0

tryFindTakeProfit ::
  RewardToRisk ->
  Candle ->
  StopLoss ->
  Maybe TakeProfit
tryFindTakeProfit r2r entryCandle stopLoss =
  if current <= stop
    then Nothing
    else
      Just . TakeProfit $
        current |+| ((current |-| stop) |* unRewardToRisk r2r)
  where
    stop =
      unStopLoss stopLoss
    current =
      unQuotePerBase $ candleClose entryCandle

tryFindExit ::
  Vector (Int, Candle) ->
  (Int, TradeEntry) ->
  Maybe (TradeEntry, TradeExit)
tryFindExit cs (idx, entry) =
  tryFindExit' entry
    . toList
    . (snd <$>)
    $ V.drop idx cs

tryFindExit' ::
  TradeEntry ->
  [Candle] ->
  Maybe (TradeEntry, TradeExit)
tryFindExit' _ [] = Nothing
tryFindExit' entr (x : xs)
  | unQuotePerBase (candleLow x)
      < unStopLoss (tradeEntryStopLoss entr) =
    Nothing
  | unQuotePerBase (candleHigh x)
      > unTakeProfit (tradeEntryTakeProfit entr) =
    pure (entr, TradeExit x)
  | otherwise =
    tryFindExit' entr xs
