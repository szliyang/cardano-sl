{-# LANGUAGE DataKinds    #-}
{-# LANGUAGE TypeFamilies #-}

-- | NTP-based implementation of slotting.

module Pos.Slotting.Impl.Ntp
       (
         -- * State
         NtpSlottingState
       , NtpSlottingVar

         -- * Mode
       , NtpMode
       , NtpWorkerMode

         -- * MonadSlots, redirects, etc.
       , askNtpSlotting
       , mkNtpSlottingVar
       , NtpSlotsRedirect
       , runNtpSlotsRedirect

       -- * Workers
       , ntpWorkers
       ) where

import           Universum

import qualified Control.Concurrent.STM       as STM
import           Control.Lens                 (makeLenses)
import           Control.Monad.Trans.Control  (MonadBaseControl)
import           Control.Monad.Trans.Identity (IdentityT (..))
import           Data.Coerce                  (coerce)
import           Data.List                    ((!!))
import           Data.Time.Units              (Microsecond)
import qualified Ether
import           Formatting                   (int, sformat, shown, stext, (%))
import           Mockable                     (Catch, CurrentTime, Delay, Fork, Mockables,
                                               Throw, currentTime, delay)
import           NTP.Client                   (NtpClientSettings (..), ntpSingleShot,
                                               startNtpClient)
import           NTP.Example                  ()
import           Serokell.Util                (sec)
import           System.Wlog                  (WithLogger, logDebug, logInfo, logWarning)

import qualified Pos.Core.Constants           as C
import           Pos.Core.Slotting            (unflattenSlotId)
import           Pos.Core.Types               (EpochIndex, SlotId (..), Timestamp (..))
import           Pos.Slotting.Class           (MonadSlots (..))
import qualified Pos.Slotting.Constants       as C
import           Pos.Slotting.Impl.Util       (approxSlotUsingOutdated, slotFromTimestamp)
import           Pos.Slotting.MemState.Class  (MonadSlotsData (..))
import           Pos.Slotting.Types           (SlottingData (..))

----------------------------------------------------------------------------
-- TODO
----------------------------------------------------------------------------

-- TODO: it's not exported from 'node-sketch' and it's too hard to do
-- it because of the mess in 'node-sketch' branches.
--
-- It should be exported and used here, I think.
type NtpMonad m =
    ( MonadIO m
    , MonadBaseControl IO m
    , WithLogger m
    , Mockables m
        [ Fork
        , Throw
        , Catch
        ]
    , MonadMask m
    )

----------------------------------------------------------------------------
-- State
----------------------------------------------------------------------------

-- | Data needed for the slotting algorithm to work.
data NtpSlottingState = NtpSlottingState
    {
    -- | Slot which was returned from getCurrentSlot last time.
       _nssLastSlot     :: !SlotId
    -- | Margin (difference between global time and local time) which
    -- we got from NTP server last time.
    , _nssLastMargin    :: !Microsecond
    -- | Time (local) for which we got margin in last time.
    , _nssLastLocalTime :: !Timestamp
    }

type NtpSlottingVar = TVar NtpSlottingState

makeLenses ''NtpSlottingState

mkNtpSlottingVar
    :: ( NtpMonad m
       , Mockables m
           [ CurrentTime
           , Delay
           ]
       )
    => m NtpSlottingVar
mkNtpSlottingVar = do
    let _nssLastMargin = 0
    _nssLastLocalTime <- Timestamp <$> currentTime
    -- current time isn't quite valid value, but it doesn't matter (@pva701)
    let _nssLastSlot = unflattenSlotId 0
    res <- newTVarIO NtpSlottingState {..}
    -- We don't want to wait too much at the very beginning,
    -- 1 second should be enough.
    let settings = (ntpSettings res) { ntpResponseTimeout = 1 & sec }
    res <$ singleShot settings
  where
    singleShot settings = unless C.isDevelopment $ do
        logInfo $ "Waiting for response from NTP servers"
        ntpSingleShot settings

----------------------------------------------------------------------------
-- Mode
----------------------------------------------------------------------------

type NtpMode m =
    ( MonadIO m
    , WithLogger m
    , MonadSlotsData m
    , Mockables m
        [ CurrentTime
        , Delay
        ]
    )

type NtpWorkerMode m = NtpMonad m

----------------------------------------------------------------------------
-- MonadSlots implementation
----------------------------------------------------------------------------

-- | Monad which implements NTP-based solution for slotting.
type MonadNtpSlotting = Ether.MonadReader' NtpSlottingVar

askNtpSlotting :: MonadNtpSlotting m => m NtpSlottingVar
askNtpSlotting = Ether.ask'

data NtpSlotsRedirectTag

type NtpSlotsRedirect =
    Ether.TaggedTrans NtpSlotsRedirectTag IdentityT

runNtpSlotsRedirect :: NtpSlotsRedirect m a -> m a
runNtpSlotsRedirect = coerce

instance (MonadNtpSlotting m, NtpMode m, t ~ IdentityT) =>
         MonadSlots (Ether.TaggedTrans NtpSlotsRedirectTag t m) where
    getCurrentSlot = ntpGetCurrentSlot
    getCurrentSlotBlocking = ntpGetCurrentSlotBlocking
    getCurrentSlotInaccurate = ntpGetCurrentSlotInaccurate
    currentTimeSlotting = ntpCurrentTime

ntpCurrentTime
    :: (NtpMode m, MonadNtpSlotting m)
    => m Timestamp
ntpCurrentTime = do
    var <- askNtpSlotting
    lastMargin <- view nssLastMargin <$> atomically (STM.readTVar var)
    Timestamp . (+ lastMargin) <$> currentTime

----------------------------------------------------------------------------
-- Getting current slot
----------------------------------------------------------------------------

data SlotStatus
    = CantTrust Text                    -- ^ We can't trust local time.
    | OutdatedSlottingData !EpochIndex  -- ^ We don't know recent
                                        -- slotting data, last known
                                        -- penult epoch is attached.
    | CurrentSlot !SlotId               -- ^ Slot is calculated successfully.

ntpGetCurrentSlot
    :: (NtpMode m, MonadNtpSlotting m)
    => m (Maybe SlotId)
ntpGetCurrentSlot = ntpGetCurrentSlotImpl >>= \case
    CurrentSlot slot -> pure $ Just slot
    OutdatedSlottingData i -> do
        logWarning $ sformat
            ("Can't get current slot, because slotting data"%
             " is outdated. Last known penult epoch = "%int)
            i
        Nothing <$ printSlottingData
    CantTrust t -> do
        logWarning $
            "Can't get current slot, because we can't trust local time, details: " <> t
        Nothing <$ printSlottingData
  where
    printSlottingData = do
        sd <- getSlottingData
        logWarning $ "Slotting data: " <> show sd

ntpGetCurrentSlotInaccurate
    :: (NtpMode m, MonadNtpSlotting m)
    => m SlotId
ntpGetCurrentSlotInaccurate = do
    res <- ntpGetCurrentSlotImpl
    case res of
        CurrentSlot slot -> pure slot
        CantTrust _        -> do
            var <- askNtpSlotting
            _nssLastSlot <$> atomically (STM.readTVar var)
        OutdatedSlottingData penult ->
            ntpCurrentTime >>= approxSlotUsingOutdated penult

ntpGetCurrentSlotImpl
    :: (NtpMode m, MonadNtpSlotting m)
    => m SlotStatus
ntpGetCurrentSlotImpl = do
    var <- askNtpSlotting
    NtpSlottingState {..} <- atomically $ STM.readTVar var
    t <- Timestamp . (+ _nssLastMargin) <$> currentTime
    case canWeTrustLocalTime _nssLastLocalTime t of
      Nothing -> do
          penult <- sdPenultEpoch <$> getSlottingData
          res <- fmap (max _nssLastSlot) <$> slotFromTimestamp t
          let setLastSlot s =
                  atomically $ STM.modifyTVar' var (nssLastSlot %~ max s)
          whenJust res setLastSlot
          pure $ maybe (OutdatedSlottingData penult) CurrentSlot res
      Just reason -> pure $ CantTrust reason
  where
    -- We can trust getCurrentTime if it is:
    -- • not bigger than 'time for which we got margin (last time)
    --   + NTP delay (+ some eps, for safety)'
    -- • not less than 'last time - some eps'
    canWeTrustLocalTime :: Timestamp -> Timestamp -> Maybe Text
    canWeTrustLocalTime t1@(Timestamp lastLocalTime) t2@(Timestamp t) = do
        let ret = sformat ("T1: "%shown%", T2: "%shown%", reason: "%stext) t1 t2
        if | t > lastLocalTime + C.ntpPollDelay + C.ntpMaxError ->
             Just $ ret $ "curtime is bigger then last local: " <>
                    show C.ntpPollDelay <> ", " <> show C.ntpMaxError
           | t < lastLocalTime - C.ntpMaxError ->
             Just $ ret $ "curtime is less then last - error: " <> show C.ntpMaxError
           | otherwise -> Nothing

ntpGetCurrentSlotBlocking
    :: (NtpMode m, MonadNtpSlotting m)
    => m SlotId
ntpGetCurrentSlotBlocking = ntpGetCurrentSlotImpl >>= \case
    CantTrust _ -> do
        delay C.ntpPollDelay
        ntpGetCurrentSlotBlocking
    OutdatedSlottingData penult -> do
        waitPenultEpochEquals (penult + 1)
        ntpGetCurrentSlotBlocking
    CurrentSlot slot -> pure slot

----------------------------------------------------------------------------
-- Workers
----------------------------------------------------------------------------

-- | Workers necessary for NTP slotting.
ntpWorkers :: NtpWorkerMode m => NtpSlottingVar -> [m ()]
ntpWorkers = one . ntpSyncWorker

-- Worker for synchronization of local time and global time.
ntpSyncWorker
    :: NtpWorkerMode m
    => NtpSlottingVar -> m ()
ntpSyncWorker = void . startNtpClient . ntpSettings

ntpHandlerDo
    :: (MonadIO m, WithLogger m)
    => NtpSlottingVar -> (Microsecond, Microsecond) -> m ()
ntpHandlerDo var (newMargin, transmitTime) = do
    logDebug $ sformat ("Callback on new margin: "%int% " mcs") newMargin
    let realTime = Timestamp $ transmitTime + newMargin
    atomically $ STM.modifyTVar var ( set nssLastMargin newMargin
                                    . set nssLastLocalTime realTime)

ntpSettings
    :: (MonadIO m, WithLogger m)
    => NtpSlottingVar -> NtpClientSettings m
ntpSettings var = NtpClientSettings
    { -- list of servers addresses
      ntpServers         = [ "time.windows.com"
                           , "clock.isc.org"
                           , "ntp5.stratum2.ru"]
    -- got time margin callback
    , ntpHandler         = ntpHandlerDo var
    -- logger name modifier
    , ntpLogName         = "ntp"
    -- delay between making requests and response collection;
    -- it also means that handler will be invoked with this lag
    , ntpResponseTimeout = C.ntpResponseTimeout
    -- how often to send responses to server
    , ntpPollDelay       = C.ntpPollDelay
    -- way to sumarize results received from different servers.
    , ntpMeanSelection   = \l -> let len = length l in sort l !! ((len - 1) `div` 2)
    }