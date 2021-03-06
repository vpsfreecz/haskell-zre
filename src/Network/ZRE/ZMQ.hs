{-# LANGUAGE OverloadedStrings #-}
module Network.ZRE.ZMQ (zreRouter, zreDealer) where

import Control.Monad
import Control.Concurrent.STM
import Control.Monad.IO.Class
import qualified System.ZMQ4.Monadic as ZMQ
import qualified Data.ByteString.Char8 as B
import qualified Data.List.NonEmpty as NE
import Data.Time.Clock.POSIX

import Data.ZRE
import System.ZMQ4.Endpoint

zreDealer :: Control.Monad.IO.Class.MonadIO m
          => Endpoint
          -> B.ByteString
          -> TBQueue ZRECmd
          -> m a
zreDealer endpoint ourUUID peerQ = ZMQ.runZMQ $ do
  d <- ZMQ.socket ZMQ.Dealer
  ZMQ.setLinger (ZMQ.restrict (1 :: Int)) d
  -- The sender MAY set a high-water mark (HWM) of, for example, 100 messages per second (if the timeout period is 30 second, this means a HWM of 3,000 messages).
  ZMQ.setSendHighWM (ZMQ.restrict $ (30 * 100 :: Int)) d
  ZMQ.setSendTimeout (ZMQ.restrict (0 :: Int)) d
  -- prepend '1' in front of 16bit UUID, ZMQ.restrict would do that for us but protocol requires it
  ZMQ.setIdentity (ZMQ.restrict $ B.cons '1' ourUUID) d
  ZMQ.connect d $ B.unpack $ pEndpoint endpoint
  loop d 1 -- sequence number must start with 1
  where loop d x = do
           cmd <- liftIO $ atomically $ readTBQueue peerQ
           -- liftIO $ print "Sending" >> (print $ newZRE x cmd)
           ZMQ.sendMulti d $ (NE.fromList $ encodeZRE $ newZRE x cmd :: NE.NonEmpty B.ByteString)
           loop d (x+1)

zreRouter :: Control.Monad.IO.Class.MonadIO m
          => Endpoint
          -> (ZREMsg -> IO a1)
          -> m a
zreRouter endpoint handler = ZMQ.runZMQ $ do
  sock <- ZMQ.socket ZMQ.Router
  ZMQ.bind sock $ B.unpack $ pEndpoint endpoint
  forever $ do
     input <- ZMQ.receiveMulti sock
     now <- liftIO $ getCurrentTime
     case parseZRE input of
        (Left err, _) -> liftIO $ print $ "Malformed message received: " ++ err
        (Right msg, _) -> do
          let updateTime = \x -> x { msgTime = Just now }
          void $ liftIO $ handler (updateTime msg)
          return ()
