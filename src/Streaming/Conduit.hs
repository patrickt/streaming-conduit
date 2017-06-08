{-# LANGUAGE RankNTypes #-}

{- |
   Module      : Streaming.Conduit
   Description : Bidirectional support for the streaming and conduit libraries
   Copyright   : Ivan Lazar Miljenovic
   License     : MIT
   Maintainer  : Ivan.Miljenovic@gmail.com


  This provides interoperability between the
  <http://hackage.haskell.org/package/streaming streaming> and
  <http://hackage.haskell.org/package/conduit conduit> libraries.

  Not only can you convert between one streaming data representation
  to the other, there is also support to use one in the middle of a
  pipeline.

  No 'B.ByteString'-based analogues of 'asConduit' and 'asStream' are
  provided as it would be of strictly less utility, requiring both the
  input and output of the 'ConduitM' to be 'ByteString'.

 -}
module Streaming.Conduit
  ( -- * Converting from Streams
    fromStream
  , fromStreamSource
  , fromStreamProducer
  , asConduit
    -- ** ByteString support
  , fromBStream
  , fromBStreamProducer
    -- * Converting from Conduits
  , toStream
  , asStream
    -- ** ByteString support
  , toBStream
  ) where

import           Control.Monad             (join, void)
import           Control.Monad.Trans.Class (lift)
import           Data.ByteString           (ByteString)
import qualified Data.ByteString.Streaming as B
import           Data.Conduit              (Conduit, ConduitM, Producer, Source,
                                            await, runConduit, yield, (.|))
import qualified Data.Conduit.List         as CL
import           Streaming                 (Of, Stream, hoist, lazily,
                                            streamFold)
import qualified Streaming.Prelude         as S

--------------------------------------------------------------------------------

-- | The result of this is slightly generic than a 'Source' or a
--   'Producer'.  If it fits in the types you want, you may wish to use
--   'fromStreamProducer' which is subject to fusion.
fromStream :: (Monad m) => Stream (Of o) m r -> ConduitM i o m r
fromStream = streamFold return (join . lift) (uncurry ((>>) . yield) . lazily)

-- | A type-specialised variant of 'fromStream' that ignores the
--   result.
fromStreamSource :: (Monad m) => Stream (Of a) m r -> Source m a
fromStreamSource = void . fromStream

-- | A more specialised variant of 'fromStream' that is subject to
--   fusion.
fromStreamProducer :: (Monad m) => Stream (Of a) m r -> Producer m a
fromStreamProducer = CL.unfoldM S.uncons . void

-- | Convert a streaming 'B.ByteString' into a 'Source'; you probably
--   want to use 'fromBStreamProducer' instead.
fromBStream :: (Monad m) => B.ByteString m r -> Source m ByteString
fromBStream = join . lift . B.foldrChunks ((>>) . yield) (return ())

-- | A more specialised variant of 'fromBStream' that is subject to
--   fusion.
fromBStreamProducer :: (Monad m) => B.ByteString m r -> Producer m ByteString
fromBStreamProducer = CL.unfoldM B.unconsChunk . void

-- | Convert a 'Producer' to a 'Stream'.  Subject to fusion.
--
--   It is not possible to generalise this to be a 'ConduitM' as input
--   values are required.  If you need such functionality, see
--   'asStream'.
toStream :: (Monad m) => Producer m o -> Stream (Of o) m ()
toStream cnd = runConduit (cnd' .| mkStream)
  where
    mkStream = CL.mapM_ S.yield

    cnd' = hoist lift cnd

-- | Convert a 'Producer' to a 'B.ByteString' stream.  Subject to
--   fusion.
toBStream :: (Monad m) => Producer m ByteString -> B.ByteString m ()
toBStream cnd = runConduit (hoist lift cnd .| CL.mapM_ B.chunk)

-- | Treat a 'Conduit' as a function between 'Stream's.  Subject to
--   fusion.
asStream :: (Monad m) => Conduit i m o -> Stream (Of i) m () -> Stream (Of o) m ()
asStream cnd stream = toStream (src .| cnd)
  where
    src = fromStreamProducer stream

-- | Treat a function between 'Stream's as a 'Conduit'.  May be
--   subject to fusion.
asConduit :: (Monad m) => (Stream (Of i) m () -> Stream (Of o) m r) -> Conduit i m o
asConduit f = join . fmap (fromStreamProducer . f) $ go
  where
    -- Probably not the best way to go about it, but it works.
    go = do mo <- await
            case mo of
              Nothing -> return (return ())
              Just o  -> S.cons o <$> go
