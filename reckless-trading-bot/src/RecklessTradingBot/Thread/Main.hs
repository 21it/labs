{-# LANGUAGE TemplateHaskell #-}
{-# OPTIONS_HADDOCK show-extensions #-}

module RecklessTradingBot.Thread.Main (apply) where

import RecklessTradingBot.Import
import qualified RecklessTradingBot.Storage.Migration as Migration
import qualified RecklessTradingBot.Thread.Order as ThreadOrder
import qualified RecklessTradingBot.Thread.Price as ThreadPrice

apply :: Env m => m ()
apply = do
  Migration.migrateAll
  xs <-
    mapM
      spawnLink
      [ ThreadPrice.apply,
        ThreadOrder.apply
      ]
  liftIO
    . void
    $ waitAnyCancel xs
  $(logTM) ErrorS "Terminate program"
