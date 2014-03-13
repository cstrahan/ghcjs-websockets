{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE IncoherentInstances #-}

-- |
-- Module      : JavaScript.WebSockets
-- Copyright   : (c) Justin Le 2014
-- License     : MIT
--
-- Maintainer  : justin@jle.im
-- Stability   : unstable
-- Portability : portable
--
-- 'JavaScript.WebSockets' aims to provide an clean, idiomatic Haskell
-- interface for working abstracting over the Javascript Websockets API,
-- targeting @ghcjs@ for receiving serialized tagged and untagged data.
--
-- This library provides both /tagged/ and /untagged/ communication
-- channels, using @tagged-binary@
-- <http://hackage.haskell.org/package/tagged-binary>.
--
-- * /Untagged/ channels will throw away incoming binary data of unexpected
-- type.
--
-- * /Tagged/ channels will queue up binary data of unexpected type to be
-- accessed later when data of that type is requested.
--
-- /Tagged/ channels mimic the behavior of Cloud Haskell
-- <http://www.haskell.org/haskellwiki/Cloud_Haskell> and
-- @distributed-process@
-- <http://hackage.haskell.org/package/distributed-process>, with their
-- dynamic communication channels.  You can use the same channel to send in
-- polymorphic, typed data and deal with it at the time you wish.
--

module JavaScript.WebSockets (
    -- * Usage
    -- ** Basic usage
    -- $basic
    -- ** Tagged usage
    -- $tagged
    -- * Types and Classes
    Connection          -- abstract
  , ConnectionProcess   -- abstract, instance: Functor, Applicative, Monad, MonadIO
  , Sendable            -- abstract
    -- * Connections
    -- ** Running connection processes
  , withUrl             -- :: Text -> ConnectionProcess a -> IO a
  , withUrlTagged       -- :: Text -> ConnectionProcess a -> IO a
  , withConn            -- :: Connection -> ConnectionProcess a -> IO a
    -- ** Manually opening and closing connections
  , openConnection          -- :: Text -> IO Connection
  , openTaggedConnection    -- :: Text -> IO Connection
  , closeConnection         -- :: Connection -> IO ()
    -- ** Inspecting connections
  , selfConn            -- :: ConnectionProcess Connection
  , connOrigin          -- :: Connection -> Text
  , connTagged          -- :: Connection -> Bool
    -- * Sending messages
  , sendText            -- :: Text -> ConnectionProcess ()
  , sendBinary          -- :: Binary a => a -> ConnectionProcess ()
  , send                -- :: Sendable a => a -> ConnectionProcess ()
  , sendTagged          -- :: (Binary a, Typeable a) => ConnectionProcess ()
    -- * Receiving messages
    -- $ receiving
  , expectBS            -- :: ConnectionProcess ByteString
  , expectText          -- :: ConnectionProcess Text
  , expectEither        -- :: Binary a => ConnectionProcess (Either ByteString a)
  , expectMaybe         -- :: Binary a => ConnectionProcess (Maybe a)
  , expect              -- :: Binary a => ConnectionProcess a
  , expectTagged        -- :: (Binary a, Typeable a) => ConnectionProcess a
  ) where

import Control.Applicative            ((<$>))
import Control.Exception              (bracket)
import Control.Monad                  (when)
import Control.Spoon                  (teaspoon)
import Data.Binary                    (Binary, encode, decode)
import Data.Binary.Tagged
import Data.ByteString.Lazy           (ByteString, fromStrict)
import Data.Foldable                  (mapM_)
import Data.Text                      (Text)
import Data.Text.Encoding             (encodeUtf8, decodeUtf8)
import Data.Typeable                  as DT
import JavaScript.WebSockets.Internal
import Prelude hiding                 (mapM_)

-- $basic
--
-- A simple client that echos what it receives to the console and back to
-- the server:
--
-- > withUrl "ws://server-url.com" . forever $ do
-- >     d <- expectText
-- >     liftIO $ putStrLn d
-- >     sendText d
--
-- 'withUrl' takes a url a 'ConnectionProcess'.  A 'ConnectionProcess'
-- describes a computation/process to be done with a given websocket
-- connection.  'ConnectionProcess' is a 'Monad', so it can be sequenced
-- using @do@ notation.  It is also a 'MonadIO', so you can perform
-- arbitrary 'IO' actions as well using 'liftIO'.
--
-- You can received typed data, too, if it can be serialized/deserialized
-- using the @Binary@ <http://hackage.haskell.org/package/binary> library.
--
-- Here we will continue receiving 'Maybe Int's from a server as long as we
-- receive a 'Just', and stop when we receive our first 'Nothing':
--
-- > whileJust :: ConnectionProcess ()
-- > whileJust = do
-- >     d <- expect
-- >     case d of
-- >       Just d' -> do
-- >           liftIO $ putStrLn d'
-- >           whileJust
-- >       Nothing ->
-- >           return ()
--
--
-- If living inside a monad is a bit too constraining --- if, for example,
-- you want to work with multiple websocket connections at once --- you can
-- always fire off 'ConnectionProcess''s one at a time using 'withConn' and
-- 'openConnection':
--
-- > main :: IO ()
-- > main = do
-- >     c <- openConnection "ws://server-url.com"
-- >     d <- withConn c expectText
-- >     putStrLn d
-- >     withConn c (sendText "goodbye!")
-- >     closeConnection c
--
-- to mimic @io-stream@-like behavior, or for behavior more like the
-- serverside @websockets@ library
-- <http://hackage.haskell.org/package/websockets>.  Just remember to close
-- the connection when you are done!
--
-- Note that with 'expect' and 'expectText', messages that come in that
-- aren't decodable as the desired type are discarded.  You can keep them
-- using 'expectEither', which yields a 'Right' if the data is decodable or
-- 'Left' containing the undecodable 'ByteString'.

-- $tagged
--
-- /ghcjs-websockets/ allows for "tagged" communication channels/sockets,
-- to mimic behavior seen in Cloud Haskell/distributed-process.
--
-- To open a tagged channel, use 'withUrlTagged' or 'openTaggedConnection'
-- instead of their untagged counterparts.
--
-- Use it with 'expectTagged'.  For example, say we have a server that
-- sends (tagged) numbers and strings randomly, and we want to do something
-- with numbers and something with strings in parallel.
--
-- > main :: IO ()
-- > main = do
-- >    c <- openConnection "ws://server-url.com"
-- >    t1 <- forkIO . withConn c . forever $ do
-- >        n <- expectTagged
-- >        replicateM n . liftIO . putStrLn $ "got a number! " ++ show n
-- >    t2 <- forkIO . withConn c . forever $ do
-- >        s <- expectTagged
-- >        liftIO $ putStrN s
-- >    await t1
-- >    await t2
-- >    closeConnection c
--
-- The first 'expectTagged' will only receive 'Int's, and the second will
-- only receive 'String's.  However, the two can safely receive 'Int's and
-- 'String's in parallel without ever worrying about interfering with
-- eachother.
--
-- You can also receive untagged data, like normal, with 'expect' and
-- 'expectText'; any tagged data that they "skip over" will be queued up for
-- 'expectTagged' to access.  In fact, you can use a tagged channel just
-- like a tagged channel!  The only difference is that with an untagged
-- channel, you save the overhead of queueing.

-- | 'Sendable' basically adds a convenient but not exactly necessary layer
-- of abstraction over 'sendText' and 'sendBinary'.  You can send both
-- 'Text' and 'Binary' instances using 'send'.  You really should never
-- have to define your own instances.
class Sendable s where
    encodeSendable :: s -> ByteString

instance Sendable Text where
    encodeSendable = fromStrict . encodeUtf8

instance Binary a => Sendable a where
    encodeSendable = encode

-- | Make a connection to the websocket server given by the url and
-- execute/run a 'ConnectionProcess' process/computation with that
-- connection.  Handles the closing and stuff for you.
--
-- This opens a /non-tagged/ communcation channel.  All uses of 'expect' or
-- attempts to get non-tagged typed data from this channel will throw away
-- non-decodable data.  You can still use 'expectTagged' to get tagged
-- data, and it'll still be queued, but other 'expect' functions won't
-- queue anything.
--
-- If you don't ever expect to receive 'Tagged' data, this is for you.
withUrl :: Text -> ConnectionProcess a -> IO a
withUrl url process = do
    bracket
      (openConnection url)
      (closeConnection)
      (flip withConn process)

-- | Make a connection to the websocket server given by the url and
-- execute/run a 'ConnectionProcess' process/computation with that
-- connection.  Handles the closing and stuff for you.
--
-- This opens a /tagged/ communication channel.  All attempts to get typed
-- data will pass over data of the wrong type and queue it for later
-- access with 'expectTagged'.
--
-- If you expect to use 'Tagged' data, even mixed with untagged data, this
-- is for you.
withUrlTagged :: Text -> ConnectionProcess a -> IO a
withUrlTagged url process = do
    bracket
      (openTaggedConnection url)
      (closeConnection)
      (flip withConn process)

-- | Send strict 'Text' through the connection.
sendText :: Text -> ConnectionProcess ()
sendText = send

-- | Send an instance of 'Binary' through the connection.  It will be
-- serialized using 'encode' before being sent.
sendBinary :: Binary a => a -> ConnectionProcess ()
sendBinary = send

-- | Send a lazy 'ByteString' through the connection.
sendBS :: ByteString -> ConnectionProcess ()
sendBS bs = ProcessSend bs (return ())

-- | Send data tagged with 'Data.Binary.Tagged' --- basically, send the
-- serialized data tagged with information about its type.  See
-- 'Data.Binary.Tagged' in the @tagged-binary@ package
-- <http://hackage.haskell.org/package/tagged-binary> for more
-- information.  Allows you to treat the channel as a dynamic communication
-- channel, and the server can chose to accept, ignore, or queue the
-- message based on its type.
sendTagged :: (Binary a, Typeable a) => a -> ConnectionProcess ()
sendTagged = sendBS . encodeTagged

-- | Send a 'Sendable' instance --- either 'Text' or an instance of
-- 'Binary'.  Mostly a convenience function abstracting over 'sendText' and
-- 'sendBinary'.
send :: Sendable s => s -> ConnectionProcess ()
send = sendBS . encodeSendable

-- $receiving
--
-- All of these receiving commands are expected to block until appropriate
-- data is received.
--
-- Remember that for untagged connections, all data skipped over is thrown
-- away.  For tagged channels, tagged data that is skipped over will be
-- queued up to be accessed by 'expectTagged' when data of that type is
-- requested.

-- | Block and wait for a 'ByteString' to come from the connection.
expectBS :: ConnectionProcess ByteString
expectBS = ProcessExpect return

-- | Block and wait for the next incoming (typed) message.  If the message
-- can be successfully decoded into the desired type, return 'Right x'.
-- Otherwise, return the 'ByteString' in a 'Left'.
--
-- This is polymorphic in its return type, so you should either use the
-- result later somehow or explicitly annotate the type so that GHC knows
-- what you want.
expectEither :: Binary a => ConnectionProcess (Either ByteString a)
expectEither = do
  bs <- expectBS
  return $ maybe (Left bs) Right . teaspoon . decode $ bs

-- | Block and wait for the next incoming (typed) message.  If the message
-- can be successfully decoded into a value of the desired type, return
-- 'Just x'.  Otherwise, return 'Nothing'.
--
-- This is polymorphic in its return type, so you should either use the
-- result later somehow or explicitly annotate the type so that GHC knows
-- what you want.
--
-- If the connection is untagged, it will throw away non-decodable data.
-- If it is tagged, it will queue up tagged data to be retrieved by
-- 'expectTagged', when data of that type is requested.
expectMaybe :: Binary a => ConnectionProcess (Maybe a)
expectMaybe = do
  expected <- expectEither
  case expected of
    Right x -> return (Just x)
    Left bs -> do
      isDyn <- connTagged <$> selfConn
      when isDyn $ mapM_ (flip queueUpFp bs) (bsFingerprint bs)
      return Nothing

-- | Block and wait for the next incoming (typed) message that can be
-- successfully decoded as a value of that type.
--
-- This is polymorphic in its return type, so you should either use the
-- result later somehow or explicitly annotate the type so that GHC knows
-- what you want.
--
-- If the connection is untagged, it will throw away non-decodable data.
-- If it is tagged, it will queue up tagged data to be retrieved by
-- 'expectTagged', when data of that type is requested.
expect :: Binary a => ConnectionProcess a
expect = do
  res <- expectMaybe
  case res of
    Just res' -> return res'
    Nothing   -> expect

-- | Block and wait for the next valid UTF8-encoded Text string.
--
-- If the connection is untagged, it will throw away invalidly encoded
-- data.  If it is tagged, it will queue up tagged data to be retrieved by
-- 'expectTagged', when data of that type is requested.
expectText :: ConnectionProcess Text
expectText = decodeUtf8 <$> expect

-- | A dynamic, polymorphic communication channel.  Can decode and queue
-- 'Tagged' 'ByteString' messages (from @tagged-binary@).
--
-- If there are any messages of the desired type in the queue, returns it
-- immediately.  Otherwise, blocks and waits for the first tagged message
-- of the desired type.  Any incoming messages that are not the proper type
-- are either queued (to be accessed when you want it) or thrown away (if
-- not tagged).
--
-- This is polymorphic in its return type, so you should either use the
-- result later somehow or explicitly annotate the type so that GHC knows
-- what you want.
--
-- Only works if the server sends a tagged message using @tagged-binary@,
-- of course.
expectTagged :: forall a. (Binary a, Typeable a) => ConnectionProcess a
expectTagged = do
  -- check queue first
  let fp = typeFingerprint (undefined :: a)
  queued <- popQueueFp fp
  case queued of
    -- something is there!
    Just q  ->
      case decodeTagged q of
        Just a -> return a
        Nothing -> error "Unable to decode tagged ByteString"
    -- otherwise...
    Nothing -> do
      bs <- expectBS
      case bsFingerprint bs of
        Just fpIn
          | fpIn == fp ->
              case decodeTagged bs of
                Just a  -> return a
                Nothing -> error "Unable to decode tagged ByteString"
          | otherwise -> do
              queueUpFp fpIn bs
              expectTagged
        Nothing   -> expectTagged

