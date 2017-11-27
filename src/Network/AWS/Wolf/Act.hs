{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}

-- | SWF Actor logic.
--
module Network.AWS.Wolf.Act
  ( act
  , actMain
  ) where

import Data.Aeson
import Data.Time
import Network.AWS.Wolf.Ctx
import Network.AWS.Wolf.File
import Network.AWS.Wolf.Prelude
import Network.AWS.Wolf.S3
import Network.AWS.Wolf.SWF
import Network.AWS.Wolf.Types
import System.Directory
import System.Exit
import System.Process

-- | Download artifacts to the store input directory.
--
download :: MonadAmazonStore c m => FilePath -> m ()
download dir = do
  traceInfo "download" [ "dir" .= dir ]
  ks <- listArtifacts
  forM_ ks $ \k -> do
    traceInfo "download" [ "dir" .= dir, "key" .= k ]
    touchDirectory (dir </> k)
    getArtifact (dir </> k) k

-- | Upload artifacts from the store output directory.
--
upload :: MonadAmazonStore c m => FilePath -> m ()
upload dir = do
  traceInfo "upload" [ "dir" .= dir ]
  ks <- findRelativeFiles dir
  forM_ ks $ \k -> do
    traceInfo "upload" [ "dir" .= dir, "key" .= k ]
    putArtifact (dir </> k) k

-- | callCommand wrapper that maybe returns an exception.
--
callCommand' :: MonadControl m => String -> m (Maybe SomeException)
callCommand' command =
  handle (pure . Just) $ do
    liftIO $ callCommand command
    pure Nothing

-- | Run command and maybe returns an exception.
--
run :: MonadStatsCtx c m => String -> m (Maybe SomeException)
run command =
  preCtx [ "command" .= command ] $ do
    traceInfo "begin" mempty
    e <- callCommand' command
    traceInfo "end" [ "exception" .= (displayException <$> e) ]
    pure e

-- | Check if quiesce file is present.
--
check :: MonadIO m => Maybe FilePath -> m Bool
check = maybe (pure False) (liftIO . doesFileExist)

-- | Actor logic - poll for work, download artifacts, run command, upload artifacts.
--
act :: MonadConf c m => Text -> Bool -> Bool -> String -> m ()
act queue nocopy local command =
  preConfCtx [ "label" .= LabelAct ] $
    runAmazonWorkCtx queue $ do
      traceInfo "poll" mempty
      t0 <- liftIO getCurrentTime
      (token, uid, input) <- pollActivity
      t1 <- liftIO getCurrentTime
      statsIncrement "wolf.act.poll.count" [ "queue" =. queue ]
      statsHistogram "wolf.act.poll.elapsed" (realToFrac (diffUTCTime t1 t0) :: Double) [ "queue" =. queue ]
      maybe_ token $ \token' ->
        maybe_ uid $ \uid' ->
          withCurrentWorkDirectory uid' nocopy local $ \wd ->
            runAmazonStoreCtx uid' $ do
              traceInfo "start" [ "dir" .= wd ]
              t2  <- liftIO getCurrentTime
              dd  <- dataDirectory wd
              sd  <- storeDirectory wd
              isd <- inputDirectory sd
              osd <- outputDirectory sd
              writeJson (dd </> "control.json") (Control uid')
              writeText (dd </> "input.json") input
              download isd
              e <- run command
              upload osd
              output <- readText (dd </> "output.json")
              maybe (completeActivity token' output) (const $ failActivity token') e
              t3 <- liftIO getCurrentTime
              traceInfo "finish" [ "dir" .= wd ]
              let status = textFromString $ maybe "complete" (const "fail") e
              statsIncrement "wolf.act.activity.count" [ "queue" =. queue, "status" =. status ]
              statsHistogram "wolf.act.activity.elapsed" (realToFrac (diffUTCTime t3 t2) :: Double) [ "queue" =. queue ]


-- | Run actor from main with config file.
--
actMain :: MonadControl m => FilePath -> Maybe FilePath -> Text -> Int -> Bool -> Bool -> String -> m ()
actMain cf quiesce queue num nocopy local command =
  runCtx $
    runStatsCtx $ do
      conf <- readYaml cf
      runConfCtx conf $
        runConcurrent $ replicate num $ forever $ do
          ok <- check quiesce
          when ok $
            liftIO exitSuccess
          act queue nocopy local command
