{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
module Data.ZRE (
    zreVer
  , newZRE
  , parseZRE
  , encodeZRE
  , zreBeacon
  , parseBeacon
  , Name
  , Headers
  , Content
  , Group
  , Groups
  , Seq
  , GroupSeq
  , ZREMsg(..)
  , ZRECmd(..)) where
import Prelude hiding (putStrLn, take)
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy as BL

import GHC.Word

import Data.Binary.Strict.Get
import Data.Binary.Put

import qualified Data.Map as M
import qualified Data.Set as S
import Data.UUID
import Data.Time.Clock

import System.ZMQ4.Endpoint
import Data.ZMQParse

zreVer :: Int
zreVer = 2
zreSig :: Word16
zreSig = 0xAAA1

type Seq = Int
type GroupSeq = Int
type Group = B.ByteString
type Groups = S.Set Group
type Name = B.ByteString
type Headers = M.Map B.ByteString B.ByteString
type Content = [B.ByteString]

data ZREMsg = ZREMsg {
    msgFrom :: Maybe UUID
  , msgSeq :: Seq
  , msgTime :: Maybe UTCTime
  , msgCmd :: ZRECmd
  } deriving (Show, Eq, Ord)

data ZRECmd =
    Hello Endpoint Groups GroupSeq Name Headers
  | Whisper Content
  | Shout Group Content
  | Join Group GroupSeq
  | Leave Group GroupSeq
  | Ping
  | PingOk
  deriving (Show, Eq, Ord)

zreBeacon :: B.ByteString -> Port -> B.ByteString
zreBeacon uuid port = BL.toStrict $ runPut $ do
  putByteString "ZRE"
  -- XXX: for compatibility with zyre implementation
  -- this should use 0x01 instead, but why when
  -- we can stick zre version there and use it for filtering?
  -- for now leave in compat mode as we don't
  -- assert this but zyre does
  putInt8 $ fromIntegral (0x01 :: Int) -- compat
  --putInt8 $ fromIntegral zreVer -- non-compat
  putByteString uuid
  putInt16be $ fromIntegral port

parseUUID :: Get UUID
parseUUID =  do
  muuid <- fromByteString . BL.fromStrict <$> getByteString 16
  case muuid of
    Just uuid -> return uuid
    Nothing -> fail "Unable to parse UUID"

parseBeacon :: B.ByteString
            -> (Either String (B.ByteString, Integer, UUID, Integer), B.ByteString)
parseBeacon = runGet $ do
  lead <- getByteString 3
  ver <- fromIntegral <$> getWord8
  uuid <- parseUUID
  port <- fromIntegral <$> getWord16be
  return (lead, ver, uuid, port)

cmdCode :: ZRECmd -> Word8
cmdCode (Hello _ _ _ _ _) = 0x01
cmdCode (Whisper _)       = 0x02
cmdCode (Shout _ _)       = 0x03
cmdCode (Join _ _)        = 0x04
cmdCode (Leave _ _)       = 0x05
cmdCode Ping              = 0x06
cmdCode PingOk            = 0x07

getContent :: ZRECmd -> Content
getContent (Whisper c) = c
getContent (Shout _ c) = c
getContent _ = []

newZRE :: Seq -> ZRECmd -> ZREMsg
newZRE seqNum cmd = ZREMsg Nothing seqNum Nothing cmd

encodeZRE :: ZREMsg -> [B.ByteString]
encodeZRE ZREMsg{..} = msg:(getContent msgCmd)
  where
    msg = BL.toStrict $ runPut $ do
      putWord16be zreSig
      putWord8 $ cmdCode msgCmd
      putInt8 $ fromIntegral zreVer
      putInt16be $ fromIntegral msgSeq
      encodeCmd msgCmd

encodeCmd :: ZRECmd -> PutM ()
encodeCmd (Hello endpoint groups statusSeq name headers) = do
  putByteStringLen (pEndpoint endpoint)
  putByteStrings groups
  putInt8 $ fromIntegral statusSeq
  putByteStringLen name
  putMap headers
encodeCmd (Shout group _content) = putByteStringLen group
encodeCmd (Join group statusSeq) = do
  putByteStringLen group
  putInt8 $ fromIntegral statusSeq
encodeCmd (Leave group statusSeq) = do
  putByteStringLen group
  putInt8 $ fromIntegral statusSeq
encodeCmd _ = return ()

parseHello :: Get ZRECmd
parseHello = Hello
  <$> parseEndpoint'
  <*> fmap S.fromList parseStrings
  <*> getInt8
  <*> parseString
  <*> parseMap
  where
    parseEndpoint' = do
      s <- parseString
      case parseAttoEndpoint s of
        (Left err) -> fail $ "Unable to parse endpoint: " ++ err
        (Right endpoint) -> return endpoint

parseShout :: Content -> Get ZRECmd
parseShout frames = Shout <$> parseString <*> pure frames

parseJoin :: Get ZRECmd
parseJoin = Join <$> parseString <*> getInt8

parseLeave :: Get ZRECmd
parseLeave = Leave <$> parseString <*> getInt8

parseCmd :: B.ByteString -> Content -> Get ZREMsg
parseCmd from frames = do
    cmd <- (getInt8 :: Get Int)
    ver <- getInt8
    sqn <- getInt16

    case runGet parseUUID from of
      (Left _err, _) -> fail "No UUID"
      (Right uuid, _)-> do
        if ver /= zreVer
          then fail "Protocol version mismatch"
          else do

            zcmd <- case cmd of
              0x01 -> parseHello
              0x02 -> pure $ Whisper frames -- parseWhisper
              0x03 -> parseShout frames
              0x04 -> parseJoin
              0x05 -> parseLeave
              0x06 -> pure Ping
              0x07 -> pure PingOk
              _    -> fail "Unknown command"

            return $ ZREMsg (Just uuid) sqn Nothing zcmd

parseZRE :: [B.ByteString] -> (Either String ZREMsg, B.ByteString)
parseZRE (from:msg:rest) = parseZre from msg rest
parseZRE _ = (Left "empty message", "")

parseZre :: B.ByteString -> B.ByteString -> Content -> (Either String ZREMsg, B.ByteString)
parseZre from msg frames = flip runGet msg $ do
  sig <- getWord16be
  if sig /= zreSig
    then fail "Signature mismatch"
    else do
      -- we need to drop 1st byte of from string which is '1':UUID (17 bytes)
      res <- parseCmd (B.tail from) frames
      return res
