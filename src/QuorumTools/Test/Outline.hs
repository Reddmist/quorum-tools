{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module QuorumTools.Test.Outline where

import           Control.Concurrent        (threadDelay)
import           Control.Concurrent.Async  (Async, async, cancel, poll)
import           Control.Concurrent.MVar   (readMVar, newEmptyMVar, putMVar)
import           Control.Lens
import           Control.Monad             (forM_)
import           Control.Monad.Except
import           Control.Monad.Managed     (MonadManaged)
import           Control.Monad.Reader      (ReaderT (runReaderT), MonadReader,
                                            ask)
import           Data.Monoid               (Last (Last))
import           Data.Monoid.Same          (Same (NotSame, Same), allSame)
import           Data.Set                  (Set)
import qualified Data.Set                  as Set
import           Data.Text                 (Text, pack)
import qualified Data.Text                 as T
import qualified Data.Text.IO              as T
import           Data.Time                 (defaultTimeLocale, formatTime,
                                            getZonedTime)
import           Data.Time.Units           (Second)
import           Data.Vector               (Vector)
import qualified QuorumTools.IpTables      as IPT
import qualified QuorumTools.PacketFilter  as PF
import           Prelude                   hiding (FilePath)
import           System.Info
import           Turtle

import           QuorumTools.Client
import           QuorumTools.Cluster
import           QuorumTools.Constellation
import           QuorumTools.Control       (Behavior, awaitAll, convergence,
                                            observe, timeLimit)
import           QuorumTools.Types
import           QuorumTools.Util          (lastOrEmpty)

newtype TestNum = TestNum { unTestNum :: Int } deriving (Enum, Num)
newtype NumNodes = NumNodes { unNumNodes :: Int }

data FailureReason
  = WrongOrder (Last Block) (Last Block)
  | NoBlockFound
  | TerminatedUnexpectedly
  | LostTxes (Set TxId)
  -- Expected @Int@, received @Either Text Int@
  | WrongValue Int (Either Text Int)
  | AddNodeFailure
  | RemoveNodeFailure
  | BlockDivergence (Vector (Last Block))
  | BlockConvergenceTimeout
  deriving Show

data Validity
  = Verified
  | Falsified FailureReason
  deriving Show

instance Monoid Validity where
  mempty = Verified

  mappend Verified falsified@(Falsified _) = falsified
  mappend falsified@(Falsified _) _        = falsified
  mappend _ _                              = Verified

second :: Int
second = 10 ^ (6 :: Int)

failedTestCode :: ExitCode
failedTestCode = ExitFailure 1

data ShouldTerminate
  = DoTerminateSuccess
  | DoTerminateFailure
  | DontTerminate

instance Monoid ShouldTerminate where
  mempty = DontTerminate
  mappend DoTerminateSuccess _ = DoTerminateSuccess
  mappend DoTerminateFailure _ = DoTerminateFailure
  mappend DontTerminate      t = t

type TestPredicate = TestNum -> ShouldTerminate

type TestM = ExceptT FailureReason (ReaderT ClusterEnv Shell)

-- | Run this test up to @TestNum@ times or until it fails
tester
  :: TestPredicate
  -> PrivacySupport
  -> NumNodes
  -> ([(Geth, NodeInstrumentation)] -> TestM ())
  -> IO ()
tester p privacySupport numNodes cb = foldr go mempty [0..] >>= \case
  DoTerminateSuccess -> return ()
  DoTerminateFailure -> exit failedTestCode
  DontTerminate      -> putStrLn "all successful!"

  where
    go :: TestNum -> IO ShouldTerminate -> IO ShouldTerminate
    go testNum runMoreTests = do
      let numNodes' = unNumNodes numNodes
          password = CleartextPassword "abcd"
          gids = [1..GethId numNodes']

      keys <- generateClusterKeys gids password

      let cEnv = mkLocalEnv keys
               & clusterPrivacySupport .~ privacySupport
               & clusterPassword       .~ password

      putStrLn $ "test #" ++ show (unTestNum testNum)

      result <- runTestM cEnv $ do
        _ <- when (os == "darwin") PF.acquirePf

        geths <- wipeAndSetupNodes Nothing "gdata" gids
        when (privacySupport == PrivacyEnabled) (startConstellationNodes geths)
        instruments <- traverse (runNode numNodes') geths

        timestampedMessage "awaiting a successful raft election"
        awaitAll (assumedRole <$> instruments)
        timestampedMessage "initial election succeeded"

        -- perform the actual test
        cb (zip geths instruments)

        -- pause a second before checking last block
        td 1

        let verifier = verify (lastBlock <$> instruments)
                              (outstandingTxes <$> instruments)
                              (nodeTerminated <$> instruments)

        -- wait an extra five seconds to guarantee raft has a chance to
        -- converge
        liftIO $ runTestM cEnv verifier >>= \case
          Left (WrongOrder _ _) -> td 5
          Left NoBlockFound     -> td 5
          _                     -> pure ()

        verifier

      print result
      case result of
        Left reason -> print reason >> pure DoTerminateFailure
        Right ()    -> case p testNum of
          DontTerminate -> runMoreTests
          term          -> pure term

-- Run nodes in a local cluster environment.
runTestM :: ClusterEnv -> TestM a -> IO (Either FailureReason a)
runTestM cEnv action = do
  var <- newEmptyMVar
  sh $ do
    result <- runReaderT (runExceptT action) cEnv
    liftIO $ putMVar var result
  readMVar var

testNTimes
  :: Int
  -> PrivacySupport
  -> NumNodes
  -> ([(Geth, NodeInstrumentation)] -> TestM ())
  -> IO ()
testNTimes times = tester predicate
  where
    predicate (TestNum n) | n == times - 1 = DoTerminateSuccess
                          | otherwise      = DontTerminate

-- | Verify nodes show normal behavior:
--
-- * None have exited (this assumes termination is an error)
-- * There are no lost transactions
-- * The nodes all have the same last block
verify
  :: [Behavior Block]
  -> [Behavior OutstandingTxes]
  -> [Async NodeTerminated]
  -> TestM ()
verify lastBlockBs outstandingTxesBs terminatedAsyncs = do
  lastBlocks        <- liftIO $ traverse observe lastBlockBs
  outstandingTxes_  <- liftIO $ fmap lastOrEmpty <$>
                         traverse observe outstandingTxesBs
  earlyTerminations <- liftIO $ traverse poll terminatedAsyncs

  forM_ outstandingTxes_ $ \(OutstandingTxes txes) -> do
    let num = Set.size txes
    when (num > 0) $ liftIO $ putStrLn $ "Outstanding txes: " ++ show num

  let noEarlyTerminations = mconcat $ flip map earlyTerminations $ \case
        Just _  -> Falsified TerminatedUnexpectedly
        Nothing -> Verified
      validity = mconcat [ noEarlyTerminations
                         , verifyLastBlocks lastBlocks
                         , verifyOutstandingTxes outstandingTxes_
                         ]

  case validity of
    Falsified reason -> throwError reason
    Verified         -> pure ()

verifyLastBlocks :: [Last Block] -> Validity
verifyLastBlocks blocks = case allSame blocks of
  NotSame a b         -> Falsified $ WrongOrder a b
  Same (Last Nothing) -> Falsified NoBlockFound
  _                   -> Verified

verifyOutstandingTxes :: [OutstandingTxes] -> Validity
verifyOutstandingTxes txes =
  let lostTxes :: Set TxId
      lostTxes = unOutstandingTxes (mconcat txes)
  in if Set.null lostTxes
     then Verified
     else Falsified (LostTxes lostTxes)

partition :: MonadManaged m => FilePath -> Millis -> GethId -> m ()
partition gdata millis node =
  if os == "darwin"
  then PF.partition gdata millis node >> PF.flushPf
  else IPT.partition gdata millis node

spamTransactions :: MonadIO m => [Geth] -> m ()
spamTransactions = mapM_ $ \geth -> spamGeth BenchEmptyTx geth $ perSecond 10

-- | Spawn an asynchronous cluster action.
--
-- Note: We force a return type of @()@ so we can use @sh@, discarding any
-- unused values from the shell. It would be possible to get a return value, if
-- we need it, but you'd have to supply a fold.
clusterAsync
  :: (MonadIO m, HasEnv m)
  => ReaderT ClusterEnv Shell a
  -> m (Async ())
clusterAsync m = do
  clusterEnv <- ask
  liftIO $ async $ sh (runReaderT m clusterEnv)

withSpammer :: (MonadIO m, MonadReader ClusterEnv m) => [Geth] -> m () -> m ()
withSpammer geths action = do
  spammer <- clusterAsync $ spamTransactions geths
  action
  liftIO $ cancel spammer

td :: MonadIO m => Int -> m ()
td = liftIO . threadDelay . (* second)

timestampedMessage :: MonadIO m => Text -> m ()
timestampedMessage msg = liftIO $ do
  zonedTime <- getZonedTime
  let locale = defaultTimeLocale
      formattedTime = pack $ formatTime locale "%I:%M:%S.%q" zonedTime
  T.putStrLn $ formattedTime <> ": " <> msg

addsNode :: Geth -> Geth -> TestM ()
existingMember `addsNode` newcomer = do
  let message = "adding node " <> T.pack (show (gId (gethId newcomer)))
  timestampedMessage $ "waiting before " <> message
  td 2
  timestampedMessage message
  result <- addNode existingMember (gethEnodeId newcomer)
  case result of
    Left _err -> throwError AddNodeFailure
    Right _raftId -> return ()

removesNode :: Geth -> Geth -> TestM ()
existingMember `removesNode` target = do
  let message = "removing node " <> T.pack (show (gId (gethId target)))
  timestampedMessage $ "waiting before " <> message
  td 2
  timestampedMessage message
  result <- removeNode existingMember (gethId target)
  case result of
    Left _err -> throwError RemoveNodeFailure
    Right () -> return ()

-- NOTE: This currently assumes raft-based consensus, due to the short duration.
-- Once we have first-class support for multiple types of consensus, this should
-- be aware of the expected latency across consensus mechanisms.
blockConvergence :: (MonadManaged m, Traversable t)
                 => t NodeInstrumentation
                 -> m (Async (Maybe (Either (Vector (Last Block)) Block)))
blockConvergence = timeLimit (10 :: Second)
               <=< convergence (1 :: Second) . fmap lastBlock

awaitBlockConvergence
  :: (MonadManaged m, MonadError FailureReason m, Traversable t)
  => t NodeInstrumentation
  -> m ()
awaitBlockConvergence instruments = do
  result <- wait =<< blockConvergence instruments
  case result of
    Nothing -> throwError BlockConvergenceTimeout
    Just (Left lastBlocks) -> throwError $ BlockDivergence lastBlocks
    Just (Right _block) -> return ()
