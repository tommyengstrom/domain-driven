module DomainDriven.Internal.Storage.File where

import           Data.Aeson
import qualified RIO.ByteString             as BS
import qualified RIO.ByteString.Lazy        as BL
import           DomainDriven.Internal.Class
import           RIO
import           RIO.Time
import           System.Random


openFileEventStore :: forall e. (FromJSON e, ToJSON e)
                   => FilePath -> IO (EventStore e)
openFileEventStore path = do
    pure EventStore
        { readEvents = do
            file <- BS.readFile path
            let (errors, as) = partitionEithers
                             . fmap eitherDecodeStrict
                             . filter (/= "")
                             $ BS.splitWith (== 10) file

            case errors of
                (err:_) -> throwM . StorageError $ fromString err
                _       -> pure as
        , storeEvent = \e -> do
            s <- toStored e
            withFile path AppendMode $ appendToHandle s
            pure s
        }
    where
        appendToHandle :: Stored e -> Handle -> IO ()
        appendToHandle s h = do
            BL.hPutStr h . (<> "\n") $ encode s
            hFlush h

        toStored :: a -> IO (Stored a)
        toStored a = Stored a <$> getCurrentTime <*> randomIO
