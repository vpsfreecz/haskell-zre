{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE FlexibleContexts #-}
module Main where

import Control.Monad
import Control.Monad.IO.Class
import Control.Concurrent
import Control.Concurrent.Async.Lifted
import Data.Time

import qualified Data.ByteString.Char8 as B

import Network.ZRE

main :: IO ()
main = runZre $ do
  void $ async $ forever $ readZ >>= liftIO . print
  zjoin "time"
  forever $ do
    ct <- liftIO $ getCurrentTime
    zshout "time" (B.pack $ show ct)
    liftIO $ threadDelay 1000000
