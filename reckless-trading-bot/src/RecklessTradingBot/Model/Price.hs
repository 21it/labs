{-# OPTIONS_HADDOCK show-extensions #-}

module RecklessTradingBot.Model.Price
  ( createUpdate,
    getSeq,
    getLatest,
  )
where

import qualified BitfinexClient as Bfx
import RecklessTradingBot.Class.Storage
import RecklessTradingBot.Import
import qualified RecklessTradingBot.Import.Psql as P

createUpdate ::
  ( Storage m
  ) =>
  Bfx.CurrencyPair ->
  Bfx.QuotePerBase 'Bfx.Buy ->
  Bfx.QuotePerBase 'Bfx.Sell ->
  m (Entity Price)
createUpdate sym buy sell = do
  ct <- liftIO getCurrentTime
  let next = newPrice ct
  mPrev <- getLatest sym
  runSql $
    case mPrev of
      Just (Entity id0 prev) | theSamePrice prev next -> do
        P.update $ \row -> do
          P.set row [PriceUpdatedAt P.=. P.val ct]
          P.where_ $ row P.^. PriceId P.==. P.val id0
        pure . Entity id0 $
          prev
            { priceUpdatedAt = ct
            }
      _ -> do
        id0 <- P.insert next
        pure $ Entity id0 next
  where
    newPrice ct =
      Price
        { priceBase = Bfx.currencyPairBase sym,
          priceQuote = Bfx.currencyPairQuote sym,
          priceBuy = buy,
          priceSell = sell,
          priceInsertedAt = ct,
          priceUpdatedAt = ct
        }

theSamePrice :: Price -> Price -> Bool
theSamePrice x y =
  x
    { priceInsertedAt = priceInsertedAt y,
      priceUpdatedAt = priceUpdatedAt y
    }
    == y

getSeq ::
  ( Storage m
  ) =>
  Bfx.CurrencyPair ->
  m [Entity Price]
getSeq =
  getLatestLimit 3

getLatest ::
  ( Storage m
  ) =>
  Bfx.CurrencyPair ->
  m (Maybe (Entity Price))
getLatest =
  (listToMaybe <$>)
    . getLatestLimit 1

getLatestLimit ::
  ( Storage m
  ) =>
  Int64 ->
  Bfx.CurrencyPair ->
  m [Entity Price]
getLatestLimit lim sym =
  runSql $
    P.select $
      P.from $ \row -> do
        P.where_
          ( ( row P.^. PriceBase
                P.==. P.val (Bfx.currencyPairBase sym)
            )
              P.&&. ( row P.^. PriceQuote
                        P.==. P.val (Bfx.currencyPairQuote sym)
                    )
          )
        P.orderBy [P.desc $ row P.^. PriceId]
        P.limit lim
        pure row
