{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Instance Blockchain Listener for WalletWebDB.
-- Guaranteed that state of GStateDB and BlockDB isn't changed
-- during @onApplyBlocks@ and @onRollbackBlocks@ callbacks.

module Pos.Wallet.Web.Tracking.BListener
       ( BlocksStorageModifierVar
       , HasBlocksStorageModifier

       , MonadBListener(..)
       , onApplyBlocksWebWallet
       , onRollbackBlocksWebWallet
       ) where

import           Universum

import qualified Control.Concurrent.STM            as STM
import           Control.Lens                      (to)
import qualified Data.List.NonEmpty                as NE
import           Data.Time.Units                   (convertUnit)
import           Formatting                        (build, sformat, (%))
import           System.Wlog                       (HasLoggerName (modifyLoggerName),
                                                    WithLogger)

import           Pos.Block.BListener               (MonadBListener (..))
import           Pos.Block.Core                    (BlockHeader, getBlockHeader,
                                                    mainBlockTxPayload)
import           Pos.Block.Types                   (Blund, undoTx)
import           Pos.Core                          (HasConfiguration, HeaderHash, SlotId,
                                                    Timestamp, difficultyL, headerSlotL)
import           Pos.DB.BatchOp                    (SomeBatchOp)
import           Pos.DB.Class                      (MonadDBRead)
import qualified Pos.GState                        as GS
import           Pos.Reporting                     (MonadReporting, reportOrLogW)
import           Pos.Slotting                      (MonadSlots, MonadSlotsData,
                                                    getCurrentEpochSlotDuration,
                                                    getCurrentSlotInaccurate,
                                                    getSlotStartPure, getSystemStartM)
import           Pos.Txp.Core                      (TxAux (..), TxUndo, flattenTxPayload)
import           Pos.Util.Chrono                   (NE, NewestFirst (..),
                                                    OldestFirst (..))
import           Pos.Util.LogSafe                  (logInfoS, logWarningS)
import           Pos.Util.TimeLimit                (CanLogInParallel, logWarningWaitInf)
import           Pos.Util.Util                     (HasLens', lensOf)

import           Pos.Wallet.Web.Account            (AccountMode, getSKById)
import           Pos.Wallet.Web.ClientTypes        (CId, Wal)
import qualified Pos.Wallet.Web.State              as WS
import           Pos.Wallet.Web.State.Memory.Types (StorageModifier, applyWalModifier)
import           Pos.Wallet.Web.Tracking.Modifier  (WalletModifier (..))
import           Pos.Wallet.Web.Tracking.Sync      (trackingApplyTxs, trackingRollbackTxs)
import           Pos.Wallet.Web.Util               (getWalletAddrMetas)

type BlocksStorageModifierVar = TVar StorageModifier
type HasBlocksStorageModifier ctx = HasLens' ctx BlocksStorageModifierVar

walletGuard
    :: AccountMode ctx m
    => HeaderHash
    -> CId Wal
    -> m ()
    -> m ()
walletGuard curTip wAddr action = WS.getWalletSyncTip wAddr >>= \case
    Nothing -> logWarningS $ sformat ("There is no syncTip corresponding to wallet #"%build) wAddr
    Just WS.NotSynced    -> logInfoS $ sformat ("Wallet #"%build%" hasn't been synced yet") wAddr
    Just (WS.SyncedWith wTip)
        | wTip /= curTip ->
            logWarningS $
                sformat ("Skip wallet #"%build%", because of wallet's tip "%build
                         %" mismatched with current tip") wAddr wTip
        | otherwise -> action

-- Perform this action under block lock.
onApplyBlocksWebWallet
    :: forall ctx m .
    ( AccountMode ctx m
    , HasBlocksStorageModifier ctx
    , MonadSlotsData ctx m
    , MonadDBRead m
    , MonadReporting ctx m
    , CanLogInParallel m
    , HasConfiguration
    )
    => OldestFirst NE Blund -> m SomeBatchOp
onApplyBlocksWebWallet blunds = setLogger . reportTimeouts "apply" $ do
    let oldestFirst = getOldestFirst blunds
        txsWUndo = concatMap gbTxsWUndo oldestFirst
    currentTipHH <- GS.getTip
    mapM_ (catchInSync "apply" $ syncWallet currentTipHH txsWUndo)
       =<< WS.getWalletIds

    -- It's silly, but when the wallet is migrated to RocksDB, we can write
    -- something a bit more reasonable.
    pure mempty
  where
    syncWallet
        :: HeaderHash
        -> [(TxAux, TxUndo, BlockHeader)]
        -> CId Wal
        -> m ()
    syncWallet curTip blkTxsWUndo wid = walletGuard curTip wid $ do
        blkHeaderTs <- blkHeaderTsGetter
        allAddresses <- getWalletAddrMetas WS.Ever wid
        encSK <- getSKById wid
        let fInfo bh = (gbDiff bh, blkHeaderTs bh, ptxBlkInfo bh)
        let mapModifier = trackingApplyTxs encSK allAddresses fInfo blkTxsWUndo
        blocksSModifierVar <- view (lensOf @BlocksStorageModifierVar)
        atomically $
            STM.modifyTVar blocksSModifierVar $
            applyWalModifier (wid, mapModifier)
        logMsg "Applied" (getOldestFirst blunds) wid mapModifier

    gbDiff = Just . view difficultyL
    ptxBlkInfo = either (const Nothing) (Just . view difficultyL)

-- Perform this action under block lock.
onRollbackBlocksWebWallet
    :: forall ctx m .
    ( AccountMode ctx m
    , HasBlocksStorageModifier ctx
    , WS.MonadWalletDB ctx m
    , MonadDBRead m
    , MonadSlots ctx m
    , MonadReporting ctx m
    , CanLogInParallel m
    , HasConfiguration
    )
    => NewestFirst NE Blund -> m SomeBatchOp
onRollbackBlocksWebWallet blunds = setLogger . reportTimeouts "rollback" $ do
    let newestFirst = getNewestFirst blunds
        txs = concatMap (reverse . gbTxsWUndo) newestFirst
    curSlot <- getCurrentSlotInaccurate
    currentTipHH <- GS.getTip
    mapM_ (catchInSync "rollback" $ syncWallet curSlot currentTipHH txs)
        =<< WS.getWalletIds

    -- It's silly, but when the wallet is migrated to RocksDB, we can write
    -- something a bit more reasonable.
    pure mempty
  where
    syncWallet
        :: SlotId
        -> HeaderHash
        -> [(TxAux, TxUndo, BlockHeader)]
        -> CId Wal
        -> m ()
    syncWallet curSlot curTip txs wid = walletGuard curTip wid $ do
        allAddresses <- getWalletAddrMetas WS.Ever wid
        encSK <- getSKById wid
        blkHeaderTs <- blkHeaderTsGetter
        let mapModifier = trackingRollbackTxs encSK allAddresses curSlot (\bh -> (gbDiff bh, blkHeaderTs bh)) txs
        blocksSModifierVar <- view (lensOf @BlocksStorageModifierVar)
        atomically $
            STM.modifyTVar blocksSModifierVar $
            applyWalModifier (wid, mapModifier)
        logMsg "Rolled back" (getNewestFirst blunds) wid mapModifier

    gbDiff = Just . view difficultyL

blkHeaderTsGetter
    :: ( MonadSlotsData ctx m
       , MonadDBRead m
       , HasConfiguration
       )
    => m (BlockHeader -> Maybe Timestamp)
blkHeaderTsGetter = do
    systemStart <- getSystemStartM
    sd <- GS.getSlottingData
    let mainBlkHeaderTs mBlkH =
            getSlotStartPure systemStart (mBlkH ^. headerSlotL) sd
    return $ either (const Nothing) mainBlkHeaderTs

gbTxsWUndo :: Blund -> [(TxAux, TxUndo, BlockHeader)]
gbTxsWUndo (Left _, _) = []
gbTxsWUndo (blk@(Right mb), undo) =
    zip3 (mb ^. mainBlockTxPayload . to flattenTxPayload)
            (undoTx undo)
            (repeat $ getBlockHeader blk)

setLogger :: HasLoggerName m => m a -> m a
setLogger = modifyLoggerName (<> "wallet" <> "blistener")

reportTimeouts
    :: (MonadSlotsData ctx m, CanLogInParallel m)
    => Text -> m a -> m a
reportTimeouts desc action = do
    slotDuration <- getCurrentEpochSlotDuration
    let firstWarningTime = convertUnit slotDuration `div` 2
    logWarningWaitInf firstWarningTime tag action
  where
    tag = "Wallet blistener " <> desc

logMsg
    :: (MonadIO m, WithLogger m)
    => Text
    -> NonEmpty Blund
    -> CId Wal
    -> WalletModifier
    -> m ()
logMsg action (NE.length -> bNums) wid accModifier =
    logInfoS $
        sformat (build%" "%build%" block(s) to wallet "%build%", "%build)
             action bNums wid accModifier

catchInSync
    :: (MonadReporting ctx m)
    => Text -> (CId Wal -> m ()) -> CId Wal -> m ()
catchInSync desc syncWallet wId =
    syncWallet wId `catchAny` reportOrLogW prefix
  where
    -- REPORT:ERROR 'reportOrLogW' in wallet sync.
    fmt = "Failed to sync wallet "%build%" in BListener ("%build%"): "
    prefix = sformat fmt wId desc
