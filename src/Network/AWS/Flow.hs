{-# LANGUAGE LambdaCase #-}

module Network.AWS.Flow
  ( register
  , execute
  , act
  , decide
  , flowEnv
  , runFlowT
  , runDecide
  , nextEvent
  , select
  , maybeThrow
  , Uid
  , Queue
  , Metadata
  , Artifact
  , Blob
  , Task (..)
  , Timer (..)
  , Start (..)
  , Spec (..)
  , End (..)
  , Plan (..)
  ) where

import           Network.AWS.Flow.Env
import           Network.AWS.Flow.Logger
import           Network.AWS.Flow.S3
import           Network.AWS.Flow.SWF
import           Network.AWS.Flow.Types
import           Network.AWS.Flow.Uid
import           Network.AWS.Flow.Prelude hiding ( ByteString, Metadata, handle )

import           Control.Monad.Catch
import           Data.Char
import qualified Data.HashMap.Strict as Map
import           Data.Text ( pack )
import           Data.Typeable
import           Formatting hiding ( string )
import           Network.AWS.SWF
import           Network.HTTP.Types
import           Safe
import           Text.Regex.Applicative

-- Interface

serviceError :: MonadFlow m => ErrorCode -> Error -> m ()
serviceError code = \case
  e@(ServiceError s) ->
    unless check $ throwM e where
      check =
        s ^. serviceStatus == badRequest400 &&
        s ^. serviceAbbrev == "SWF"         &&
        s ^. serviceCode == code
  e -> throwM e

register :: MonadFlow m => Plan -> m ()
register Plan{..} = do
  logInfo' "event=register"
  handle (serviceError "DomainAlreadyExists") registerDomainAction
  handle (serviceError "TypeAlreadyExists") $ registerWorkflowTypeAction
    (tskName $ strtTask plnStart)
    (tskVersion $ strtTask plnStart)
    (tskTimeout $ strtTask plnStart)
  mapM_ go plnSpecs where
    go Work{..} =
      handle (serviceError "TypeAlreadyExists") $ registerActivityTypeAction
        (tskName wrkTask)
        (tskVersion wrkTask)
        (tskTimeout wrkTask)
    go Sleep{..} =
      return ()

execute :: MonadFlow m => Task -> Metadata -> m ()
execute Task{..} input = do
  uid <- newUid
  logInfo' $ sformat ("event=execute uid=" % stext) uid
  startWorkflowExecutionAction uid tskName tskVersion tskQueue input

serializeError :: MonadFlow m => Error -> m ()
serializeError = \case
  e@(SerializeError s) ->
    unless check $ throwM e where
      check =
        s ^. serializeStatus  == ok200 &&
        s ^. serializeAbbrev  == "SWF"
  e -> throwM e

exitCode :: RE Char Int
exitCode =
  many anySym *> string "exit status: " *> num <* many anySym where
    num = read . pack <$> many (psym isDigit)

actException :: MonadFlow m => Token -> SomeException -> m ()
actException token e = do
  logError' $ sformat ("event=act-exception-type " % stext) $ show $ typeOf e
  logError' $ sformat ("event=act-exception " % stext) $ show e
  maybe' ((textToString $ show e) =~ exitCode) (respondActivityTaskFailedAction token) $ \code -> do
    if code == 255 then respondActivityTaskCanceledAction token else
      respondActivityTaskFailedAction token

act :: MonadFlow m => Queue -> (Uid -> Metadata -> [Blob] -> m (Metadata, [Artifact])) -> m ()
act queue action =
  handle serializeError $ do
    logInfo' "event=act"
    (token', uid, input) <- pollForActivityTaskAction queue
    token <- maybeThrow (userError "No Token") token'
    logInfo' $ sformat ("event=act-begin uid=" % stext) uid
    maybe_ input $ logDebug' . sformat ("event=act-input " % stext)
    keys <- listObjectsAction uid
    unless (null keys) $ logInfo' $ sformat ("event=list-blobs uid=" % stext) uid
    blobs <- forM keys $ getObjectAction uid
    unless (null blobs) $ logInfo' $ sformat ("event=blobs uid=" % stext) uid
    handle (actException token) $ do
      (output, artifacts) <- action uid input blobs
      maybe_ output $ logDebug' . sformat ("event=act-output " % stext)
      logInfo' $ sformat ("event=act-finish uid=" % stext) uid
      forM_ artifacts $ putObjectAction uid
      unless (null artifacts) $ logInfo' $ sformat ("event=artifacts uid=" % stext) uid
      respondActivityTaskCompletedAction token output

decide :: MonadFlow m => Plan -> m ()
decide plan@Plan{..} =
  handle serializeError $ do
    logInfo' "event=decide"
    (token', events) <- pollForDecisionTaskAction (tskQueue $ strtTask plnStart)
    token <- maybeThrow (userError "No Token") token'
    logger <- asks feLogger
    decisions <- runDecide logger plan events select
    respondDecisionTaskCompletedAction token decisions

-- Decisions

runDecide :: Log -> Plan -> [HistoryEvent] -> DecideT m a -> m a
runDecide logger plan events =
  runDecideT env where
    env = DecideEnv logger plan events findEvent where
      findEvent =
        flip Map.lookup $ Map.fromList $ flip map events $ \e ->
          (e ^. heEventId, e)

nextEvent :: MonadDecide m => [EventType] -> m HistoryEvent
nextEvent ets = do
  events <- asks deEvents
  maybeThrow (userError "No Next Event") $ flip find events $ \e ->
    e ^. heEventType `elem` ets

workNext :: MonadDecide m => Name -> m (Maybe Spec)
workNext name = do
  specs <- asks (plnSpecs . dePlan)
  return $ tailMay (dropWhile p specs) >>= headMay where
    p Work{..} = tskName wrkTask /= name
    p _ = True

sleepNext :: MonadDecide m => Name -> m (Maybe Spec)
sleepNext name = do
  specs <- asks (plnSpecs . dePlan)
  return $ tailMay (dropWhile p specs) >>= headMay where
    p Sleep{..} = tmrName slpTimer /= name
    p _ = True

select :: MonadDecide m => m [Decision]
select = do
  event <- nextEvent [ WorkflowExecutionStarted
                     , ActivityTaskCompleted
                     , ActivityTaskFailed
                     , ActivityTaskCanceled
                     , TimerFired
                     , StartChildWorkflowExecutionInitiated ]
  case event ^. heEventType of
    WorkflowExecutionStarted             -> start event
    ActivityTaskCompleted                -> completed event
    ActivityTaskFailed                   -> failed event
    ActivityTaskCanceled                 -> canceled event
    TimerFired                           -> timer event
    StartChildWorkflowExecutionInitiated -> child
    _                                    -> throwM (userError "Unknown Select Event")

start :: MonadDecide m => HistoryEvent -> m [Decision]
start event = do
  logInfo' "event=start"
  input <- maybeThrow (userError "No Start Information") $ do
    attrs <- event ^. heWorkflowExecutionStartedEventAttributes
    return $ attrs ^. weseaInput
  specs <- asks (plnSpecs . dePlan)
  schedule input $ headMay specs

completed :: MonadDecide m => HistoryEvent -> m [Decision]
completed event = do
  logInfo' "event=completed"
  findEvent <- asks deFindEvent
  (input, name) <- maybeThrow (userError "No Completed Information") $ do
    attrs <- event ^. heActivityTaskCompletedEventAttributes
    event' <- findEvent $ attrs ^. atceaScheduledEventId
    attrs' <- event' ^. heActivityTaskScheduledEventAttributes
    return (attrs ^. atceaResult, attrs' ^. atseaActivityType ^. atName)
  next <- workNext name
  schedule input next

failed :: MonadDecide m => HistoryEvent -> m [Decision]
failed _event = do
  logInfo' "event=failed"
  return [failWorkflowExecutionDecision]

canceled :: MonadDecide m => HistoryEvent -> m [Decision]
canceled _event = do
  logInfo' "event=canceled"
  return [cancelWorkflowExecutionDecision]

timer :: MonadDecide m => HistoryEvent -> m [Decision]
timer event = do
  logInfo' "event=timer"
  findEvent <- asks deFindEvent
  name <- maybeThrow (userError "No Timer Information") $ do
    attrs <- event ^. heTimerFiredEventAttributes
    event' <- findEvent $ attrs ^. tfeaStartedEventId
    attrs' <- event' ^. heTimerStartedEventAttributes
    attrs' ^. tseaControl
  event' <- nextEvent [WorkflowExecutionStarted, ActivityTaskCompleted]
  case event' ^. heEventType of
    WorkflowExecutionStarted -> timerStart event' name
    ActivityTaskCompleted    -> timerCompleted event' name
    _                        -> throwM (userError "Unknown Timer Event")

timerStart :: MonadDecide m => HistoryEvent -> Name -> m [Decision]
timerStart event name = do
  logInfo' $ sformat ("event=timer-start name=" % stext) name
  input <- maybeThrow (userError "No Timer Start Information") $ do
    attrs <- event ^. heWorkflowExecutionStartedEventAttributes
    return $ attrs ^. weseaInput
  next <- sleepNext name
  schedule input next

timerCompleted :: MonadDecide m => HistoryEvent -> Name -> m [Decision]
timerCompleted event name = do
  logInfo' $ sformat ("event=timer-completed name=" % stext) name
  input <- maybeThrow (userError "No Timer Completed Information") $ do
    attrs <- event ^. heActivityTaskCompletedEventAttributes
    return $ attrs ^. atceaResult
  next <- sleepNext name
  schedule input next

schedule :: MonadDecide m => Metadata -> Maybe Spec -> m [Decision]
schedule input = maybe (scheduleEnd input) (scheduleSpec input)

scheduleSpec :: MonadDecide m => Metadata -> Spec -> m [Decision]
scheduleSpec input spec = do
  uid <- newUid
  logInfo' $ sformat ("event=schedule-spec uid=" % stext) uid
  case spec of
    Work{..} ->
      return [scheduleActivityTaskDecision uid
               (tskName wrkTask)
               (tskVersion wrkTask)
               (tskQueue wrkTask)
               input]
    Sleep{..} ->
      return [startTimerDecision uid
               (tmrName slpTimer)
               (tmrTimeout slpTimer)]

scheduleEnd :: MonadDecide m => Metadata -> m [Decision]
scheduleEnd input = do
  logInfo' "event=schedule-end"
  end <- asks (plnEnd . dePlan)
  case end of
    Stop -> return [completeWorkflowExecutionDecision input]
    Continue -> scheduleContinue

scheduleContinue :: MonadDecide m => m [Decision]
scheduleContinue = do
  logInfo' "event=schedule-continue"
  event <- nextEvent [WorkflowExecutionStarted]
  input <- maybeThrow (userError "No Continue Start Information") $ do
    attrs <- event ^. heWorkflowExecutionStartedEventAttributes
    return $ attrs ^. weseaInput
  uid <- newUid
  task <- asks (strtTask . plnStart . dePlan)
  return [startChildWorkflowExecutionDecision uid
           (tskName task)
           (tskVersion task)
           (tskQueue task)
           input]

child :: MonadDecide m => m [Decision]
child = do
  event <- nextEvent [WorkflowExecutionStarted, ActivityTaskCompleted]
  case event ^. heEventType of
    WorkflowExecutionStarted -> childStart event
    ActivityTaskCompleted    -> childCompleted event
    _                        -> throwM (userError "Unknown Child Event")

childStart :: MonadDecide m => HistoryEvent -> m [Decision]
childStart event = do
  logInfo' "event=child-start"
  input <- maybeThrow (userError "No Child Start Information") $ do
    attrs <- event ^. heWorkflowExecutionStartedEventAttributes
    return $ attrs ^. weseaInput
  return [completeWorkflowExecutionDecision input]

childCompleted :: MonadDecide m => HistoryEvent -> m [Decision]
childCompleted event = do
  logInfo' "event=child-completed"
  input <- maybeThrow (userError "No Child Completed Information") $ do
    attrs <- event ^. heActivityTaskCompletedEventAttributes
    return $ attrs ^. atceaResult
  return [completeWorkflowExecutionDecision input]

-- Helpers

maybeThrow :: (MonadThrow m, Exception e) => e -> Maybe a -> m a
maybeThrow e = maybe (throwM e) return
