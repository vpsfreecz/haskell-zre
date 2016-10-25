{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
module Network.ZRE where

import Prelude hiding (putStrLn, take)
import Control.Exception
import Control.Monad
import Control.Monad.IO.Class
import Control.Applicative
import Control.Concurrent
import Control.Concurrent.Async
import Control.Concurrent.STM
import Control.Concurrent.STM.TBQueue
import Network.BSD (getHostName)
import Network.Info
import Network.Socket hiding (send, sendTo, recv, recvFrom)
import Network.Socket.ByteString
import Network.Multicast
import Network.SockAddr
import qualified System.ZMQ4.Monadic as ZMQ
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy as BL

import qualified Data.List.NonEmpty as NE -- (NonEmpty((:|)))  --as NE

import Data.UUID
import Data.UUID.V1
import Data.Maybe
import Data.Time.Clock
import Data.Time.Clock.POSIX

import qualified Data.Map as M

import Data.Binary.Strict.Get as G

import Data.ZRE
import System.ZMQ4.Endpoint
import System.Process
import System.Exit
import System.Random

import GHC.Conc

mCastPort = 5670
mCastIP = "225.25.25.25"

-- send beacon every 1 second
zreBeaconMs = 1000000

data Peer = Peer {
    peerEndpoint  :: Endpoint
  , peerUUID      :: UUID
  , peerSeq       :: Seq
  , peerGroups    :: Groups
  , peerGroupSeq  :: GroupSeq
  , peerName      :: Name
  , peerAsync     :: Maybe (Async ())
  , peerAsyncPing :: Maybe (Async ())
  , peerQueue     :: TBQueue ZRECmd
  , peerLastHeard :: UTCTime
  }
--  } deriving (Show)
--
newPeer s endpoint uuid groups name t = do
  st <- readTVar s
  peerQ <- newTBQueue 10
  writeTBQueue peerQ $ Hello (zreEndpoint st) (zreGroups st) (zreGroupSeq st) (zreName st) (zreHeaders st)
  writeTBQueue peerQ $ Whisper ["ohai!"]

  let np = Peer endpoint uuid 0 groups 0 name Nothing Nothing peerQ t

  modifyTVar s $ \x -> x { zrePeers = M.insert uuid np (zrePeers x) }

  return $ (np, Just $ dealer endpoint (zreUUID st) peerQ, Just $ pinger peerQ)

newPeerFromBeacon addr port t uuid s = do
  let endpoint = newTCPEndpoint addr port
  newPeer s endpoint uuid ([] :: Groups) "" t
newPeerFromHello (Hello endpoint groups groupSeq name headers) t uuid s =
  newPeer s endpoint uuid groups name t

pinger q = forever $ do
  atomically $ writeTBQueue q $ Ping
  liftIO $ threadDelay 1000000

makePeer s uuid newPeerFn = do
  t <- getCurrentTime
  res <- atomically $ do
    st <- readTVar s
    case M.lookup uuid $ zrePeers st of
      (Just peer) -> return (peer, Nothing, Nothing)
      Nothing -> newPeerFn t uuid s

  case res of
    (peer, Nothing, Nothing) -> return peer
    (peer, Just deal, Just ping) -> do
      a <- async deal
      b <- async ping
      atomically $ updatePeer s (peerUUID peer) $ \x -> x { peerAsync = (Just a) }
      atomically $ updatePeer s (peerUUID peer) $ \x -> x { peerAsyncPing = (Just b) }
      return peer

updatePeer s uuid fn = do
  st <- readTVar s
  case M.lookup uuid $ zrePeers st of
    Nothing -> return ()
    (Just peer) -> modifyTVar s $ \x -> x { zrePeers = M.updateWithKey (wrapfn fn) uuid (zrePeers x) }
  where wrapfn fn k x = Just $ fn x

msgPeer peer msg = writeTBQueue (peerQueue peer) msg

msgPeerUUID s uuid msg = do
  st <- readTVar s
  case M.lookup uuid $ zrePeers st of
    Nothing -> return ()
    (Just peer) -> do
      msgPeer peer msg
      return ()

msgAll s msg = do
  st <- readTVar s
  mapM_ (flip msgPeer msg) (zrePeers st)


-- FIXME: try binding to it up to n times
-- randPort = loop (n) where loop = rport >>= bind ..
randPort :: IO Port
randPort = randomRIO (41000, 65536)

data Event =
  NewPeer B.ByteString UUID Port
  deriving (Show)

type Peers = M.Map UUID Peer

data ZRE = ZRE {
    zreUUID  :: UUID
  , zrePeers :: Peers
  , zreEndpoint :: Endpoint
  , zreGroups :: Groups
  , zreGroupSeq :: GroupSeq
  , zreName :: Name
  , zreHeaders :: Headers
  }

uuidByteString = BL.toStrict . toByteString

exitFail msg = do
  B.putStrLn msg
  exitFailure

bshow :: (Show a) => a -> B.ByteString
bshow = B.pack . show

getDefRoute = do
  ipr <- fmap lines $ readProcess "ip" ["route"] []
  return $ listToMaybe $ catMaybes $ map getDef (map words ipr)
  where
    getDef ("default":"via":gw:"dev":dev:_) = Just (gw, dev)
    getDef _ = Nothing

getIface iname = do
  ns <- getNetworkInterfaces
  return $ listToMaybe $ filter (\x -> name x == iname) ns

main = do
    dr <- getDefRoute
    case dr of
      Nothing -> exitFail "Unable to get default route"
      Just (route, iface) -> do

        ifaceInfo <- getIface iface
        case ifaceInfo of
          Nothing -> exitFail "Unable to get info for interace"
          (Just NetworkInterface{..}) -> do

            u <- nextUUID
            zmqPort <- randPort
            let uuid = uuidByteString $ fromJust u -- BL.toStrict $ toByteString $ fromJust u
            (mCastAddr:_) <- getAddrInfo Nothing (Just mCastIP) (Just $ show mCastPort)

            let mCastEndpoint = newTCPEndpointAddrInfo mCastAddr mCastPort
            let endpoint = newTCPEndpoint (bshow ipv4) zmqPort

            name <- fmap B.pack getHostName

            -- newpeer q
            --q <- atomically $ newTBQueue $ 10
            -- inbox
            --inboxQ <- atomically $ newTBQueue $ 10
            (q, inboxQ) <- atomically $ do
              q <- newTBQueue $ 10
              inboxQ <- newTBQueue $ 10
              return (q, inboxQ)

            -- new ZRE context
            s <- atomically $ newTVar $ ZRE (fromJust u) M.empty endpoint [] 0 name M.empty

            runConcurrently $ Concurrently (beaconRecv q) *>
                              Concurrently (beacon mCastAddr uuid zmqPort) *>
                              Concurrently (router inboxQ zmqPort) *>
                              Concurrently (peerPool q s) *>
                              Concurrently (inbox inboxQ s)
            return ()

inbox inboxQ s = forever $ do
  msg@ZREMsg{..} <- atomically $ readTBQueue inboxQ

  let uuid = fromJust msgFrom

  case msgCmd of
    (Whisper content) -> B.putStrLn $ B.intercalate " " ["whisper", B.concat content]
    (Shout group content) -> B.putStrLn $ B.intercalate " " ["shout", B.concat content]
    (Join group groupSeq) -> B.putStrLn $ B.intercalate " " ["join", group, bshow groupSeq]
    (Leave group groupSeq) -> B.putStrLn $ B.intercalate " " ["leave", group, bshow groupSeq]
    Ping -> atomically $ msgPeerUUID s uuid PingOk
    PingOk -> return ()
    -- if the peer is not known but a message is HELLO we create a new
    -- peer, for other messages we don't know the endpoint to connect to
    --liftIO $ B.putStrLn $ B.concat ["Message from unknown peer ", B.pack $ show uuid]
    h@(Hello endpoint groups groupSeq name headers) -> do
      liftIO $ B.putStrLn $ B.concat ["From hello"]
      peer <- makePeer s uuid $ newPeerFromHello h
      -- if this peer was already registered (e.g. from beacon) update appropriate fields
      atomically $ updatePeer s uuid $
        \x -> x {
            peerGroups = groups
          , peerGroupSeq = groupSeq
          , peerName = name
          }
      atomically $ msgAll s $ Shout "" ["suckers!"]
      return ()

dealer endpoint ourUUID peerQ = ZMQ.runZMQ $ do
  d <- ZMQ.socket ZMQ.Dealer
  ZMQ.setLinger (ZMQ.restrict 1) d
  -- The sender MAY set a high-water mark (HWM) of, for example, 100 messages per second (if the timeout period is 30 second, this means a HWM of 3,000 messages).
  ZMQ.setSendHighWM (ZMQ.restrict $ 30 * 100) d
  ZMQ.setSendTimeout (ZMQ.restrict 0) d
  ZMQ.setIdentity (ZMQ.restrict $ uuidByteString ourUUID) d
  ZMQ.connect d $ B.unpack $ pEndpoint endpoint
  loop d 0
  where loop d x = do
           cmd <- liftIO $ atomically $ readTBQueue peerQ
           ZMQ.sendMulti d $ (NE.fromList $ encodeZRE $ newZRE x cmd :: NE.NonEmpty B.ByteString)
           loop d (x+1)

router inboxQ port = ZMQ.runZMQ $ do
  r <- ZMQ.socket ZMQ.Router
  ZMQ.bind r $ concat ["tcp://", "*:", show port]
  forever $ do
     input <- ZMQ.receiveMulti r
     case parseZRE input of
        (Left err, _) -> liftIO $ print $ "Malformed message received: " ++ err
        (Right msg, _) -> liftIO $ atomically $ writeTBQueue inboxQ msg

peerPool q s = forever $ do
  msg <- atomically $ readTBQueue q
  case msg of
    (NewPeer addr uuid port) -> do
      st <- atomically $ readTVar s

      if uuid == zreUUID st
        then return () -- our own message
        else do
          case M.lookup uuid $ zrePeers st of
            Just _ -> return ()
            Nothing -> do
              B.putStrLn $ B.concat ["New peer from beacon ", B.pack $ show uuid, " (", addr, ":", B.pack $ show port , ")"]
              void $ makePeer s uuid $ newPeerFromBeacon addr port
              return ()


beaconRecv q = do
    sock <- multicastReceiver mCastIP 5670
    forever $ do
        (msg, addr) <- recvFrom sock 22
        case parseBeacon msg of
          (Left err, remainder) -> print err
          (Right (lead, ver, uuid, port), _) -> do
            case addr of
              x@(SockAddrInet _hisport host) -> do
                atomically $ writeTBQueue q $ NewPeer (showSockAddrBS x) uuid (fromIntegral port)
              x@(SockAddrInet6 _hisport _ h _) -> do
                atomically $ writeTBQueue q $ NewPeer (showSockAddrBS x) uuid (fromIntegral port)

--randomPort addr = do
--    withSocketsDo $ do
--      bracket (getSocket addr) close (pure ())
--  where
--    getSocket addr = do
--      s <- socket (addrFamily addr) Datagram defaultProtocol
--      bind s (addrAddress addr)
--      return s

beacon addr uuid port = do
    withSocketsDo $ do
      bracket (getSocket addr) close (talk (addrAddress addr))

  where
    getSocket addr = do
      s <- socket (addrFamily addr) Datagram defaultProtocol
      mapM_ (\x -> setSocketOption s x 1) [Broadcast, ReuseAddr, ReusePort]
      bind s (addrAddress addr)
      return s
    talk addr s = forever $ do
      --putStrLn "send"
      sendTo s (zreBeacon uuid port) addr
      threadDelay zreBeaconMs
