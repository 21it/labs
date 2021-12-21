{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_HADDOCK show-extensions #-}

module RecklessTradingBot.Thread.Price (apply) where

import qualified BitfinexClient as Bfx
import RecklessTradingBot.Import
import qualified RecklessTradingBot.Model.Price as Price

apply :: (Env m) => m ()
apply = do
  $(logTM) InfoS "Spawned"
  xs <- mapM (spawnLink . loop) =<< getPairs
  liftIO . void $ waitAnyCancel xs

loop :: (Env m) => MVar TradeConf -> m ()
loop varCfg = do
  cfg <- liftIO $ readMVar varCfg
  sleepPriceTtl $ tradeConfPair cfg
  createUpdate cfg
  loop varCfg

createUpdate :: (Env m) => TradeConf -> m ()
createUpdate cfg = do
  res <-
    runExceptT . withExceptT ErrorBfx $
      (,) <$> getPrice @'Bfx.Buy <*> getPrice @'Bfx.Sell
  case res of
    Left e -> do
      $(logTM) ErrorS $ logStr (show e :: Text)
      sleep [seconds|60|]
    Right (buy, sell) -> do
      priceEnt@(Entity _ price) <-
        Price.createUpdate sym buy sell
      when (priceUpdatedAt price == priceInsertedAt price) $
        putCurrPrice priceEnt
  where
    sym :: Bfx.CurrencyPair
    sym =
      tradeConfPair cfg
    getPrice ::
      forall (act :: Bfx.ExchangeAction) m.
      ( Env m,
        SingI act,
        Bfx.ToRequestParam (Bfx.MoneyBase act)
      ) =>
      ExceptT Bfx.Error m (Bfx.QuotePerBase act)
    getPrice = do
      Bfx.marketAveragePrice
        ( case sing :: Sing act of
            Bfx.SBuy -> tradeConfMinBuyAmt cfg
            Bfx.SSell -> tradeConfMinSellAmt cfg
        )
        sym
