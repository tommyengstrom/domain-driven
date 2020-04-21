{-# LANGUAGE TemplateHaskell #-}

-- | This module contains simple example of how to write hierarchical models in
-- domain-driven. Note that in real life you may not want to split these models up. The
-- intent of this example is just to show the technique.
module Main where

import           DomainDriven.Server            ( mkCmdServer
                                                , mkQueryServer
                                                )
import           DomainDriven
import           Prelude
import           Data.Bifunctor                 ( bimap )
import           Servant                        ( serve
                                                , FromHttpApiData
                                                , Proxy(..)
                                                , Server
                                                , (:<|>)(..)
                                                )
import           Data.Typeable                  ( Typeable )
import           Control.Exception              ( Exception )
import           Network.Wai.Handler.Warp       ( run )
import           GHC.Generics                   ( Generic )
import           Data.Aeson                     ( FromJSON
                                                , ToJSON
                                                )
import qualified Data.Map                                     as M
import           Control.Monad
import           Control.Exception              ( throwIO )

------------------------------------------------------------------------------------------
-- Item model ----------------------------------------------------------------------------
------------------------------------------------------------------------------------------
data Item = Item
    { description :: String
    , price :: Price
    } deriving (Show, Eq, Generic, FromJSON, ToJSON)

newtype ItemKey = ItemKey UUID
    deriving newtype (Show, Eq, Ord, FromJSON, ToJSON, FromHttpApiData)

newtype Price = EUR Int
    deriving newtype (Show, Eq, Ord, Num, FromJSON, ToJSON)

data ItemCmd a where
    ChangeDescription ::String -> ItemCmd ()
    ChangePrice ::Price -> ItemCmd ()

data ItemEvent
    = ChangedDescription String
    | ChangedPrice Price
    deriving (Show)

applyItemEvent :: Item -> Stored ItemEvent -> Item
applyItemEvent m (Stored e _ _) = case e of
    ChangedDescription s -> m { description = s }
    ChangedPrice       p -> m { price = p }

data ItemError
    = PriceMustBePositive
    deriving (Show, Eq, Typeable, Exception)

handleItemCmd :: CmdHandler Item ItemEvent ItemCmd ItemError
handleItemCmd = \case
    ChangeDescription s -> pure $ \_ -> Right ((), [ChangedDescription s])
    ChangePrice       p -> do
        when (p < 0) $ throwIO PriceMustBePositive
        -- Throwing the exception while in IO yields the same result as returning
        -- `Left ItemError` in the continuation.
        pure $ \_ -> Right ((), [ChangedPrice p])



------------------------------------------------------------------------------------------
-- Store model ---------------------------------------------------------------------------
------------------------------------------------------------------------------------------
type StoreModel = M.Map ItemKey Item

data StoreCmd a where
   AddItem ::Item -> StoreCmd ()
   RemoveItem ::ItemKey -> StoreCmd ()
   UpdateItem ::ItemKey -> ItemCmd a -> StoreCmd a

data StoreEvent
    = AddedItem ItemKey Item
    | RemovedItem ItemKey
    | UpdatedItem ItemKey ItemEvent
    deriving (Show)

data StoreError
    = NoSuchItem
    | StoreItemError ItemError
    deriving (Show, Eq, Typeable, Exception)

applyStoreEvent :: StoreModel -> Stored StoreEvent -> StoreModel
applyStoreEvent m se@(Stored event _timestamp _uuid) = case event of
    AddedItem iKey i -> M.insert iKey i m
    RemovedItem iKey -> M.delete iKey m
    UpdatedItem iKey iEvent ->
        M.adjust (`applyItemEvent` se { storedEvent = iEvent }) iKey m

handleStoreCmd :: CmdHandler StoreModel StoreEvent StoreCmd StoreError
handleStoreCmd = \case
    AddItem i -> do
        iKey <- ItemKey <$> mkId
        pure $ \_ -> Right ((), [AddedItem iKey i])
    RemoveItem iKey -> pure $ \m -> case M.lookup iKey m of
        Just _  -> Right ((), [RemovedItem iKey])
        Nothing -> Left NoSuchItem
    UpdateItem iKey iCmd -> do
        -- First we have to run the
        itemContinuation <- handleItemCmd iCmd
        pure $ \m -> case M.lookup iKey m of
            Just i ->
                -- We now need to extract the Item data and send it to `itemContinuation`.
                -- After this is done we need to convert `ItemError` to `StoreError` and
                -- `ItemEvent` to `StoreEvent`
                bimap
                        StoreItemError
                        (\(returnValue, listOfEvents) ->
                            (returnValue, fmap (UpdatedItem iKey) listOfEvents)
                        )
                    $ itemContinuation i
            Nothing -> Left NoSuchItem

$(mkCmdServer ''StoreCmd)

------------------------------------------------------------------------------------------
-- Store queries -------------------------------------------------------------------------
------------------------------------------------------------------------------------------

data StoreQuery a where
    ListAllItems ::StoreQuery [(ItemKey, Item)]
    LookupItem ::ItemKey -> StoreQuery Item

runStoreQuery :: StoreQuery a -> StoreModel -> Either StoreError a
runStoreQuery query m = case query of
    ListAllItems    -> Right $ M.toList m
    LookupItem iKey -> maybe (Left NoSuchItem) Right $ M.lookup iKey m

$(mkQueryServer ''StoreQuery)

-- We can assemble the individual APIs as we would with any other Servant APIs.
type Api = StoreCmdApi :<|> StoreQueryApi

-- The complete server require both the a CommandRunner and a QueryRunner
server :: QueryRunner StoreQuery -> CmdRunner StoreCmd -> Server Api
server queryRunner cmdRunner = storeCmdServer cmdRunner :<|> storeQueryServer queryRunner

-- | Start a server running on port 8765
main :: IO ()
main = do
    -- First we need to pick a persistance model.
    persistanceModel <- noPersistance
    -- Then we need to create the model
    model            <- createModel persistanceModel applyStoreEvent mempty
    -- Now we can supply the CmdRunner to the generated server and run it as any other
    -- Servant server.
    run 8765 $ serve
        (Proxy @Api)
        (server (runQuery model runStoreQuery) (runCmd model handleStoreCmd))
