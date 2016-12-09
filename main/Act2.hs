{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleContexts    #-}
module Act2
  ( main
  ) where

import           BasicPrelude hiding ( ByteString, (</>), (<.>), hash, length, readFile, find )
import           Codec.Compression.GZip
import           Control.Monad.Trans.Resource
import           Data.Aeson.Encode
import           Data.ByteString ( length )
import qualified Data.ByteString.Lazy as BL
import           Data.Text ( pack, strip )
import           Data.Text.Lazy ( toStrict )
import           Data.Text.Lazy.Builder hiding ( fromText )
import           Data.Yaml hiding ( Parser )
import           Filesystem.Path ( (<.>), dropExtension )
import           Network.AWS.Data.Crypto
import           Network.AWS.Flow
import           Options
import           Options.Applicative hiding ( action )
import           Shelly hiding ( FilePath, (<.>), bash )

data Args = Args
  { aConfig      :: FilePath
  , aQueue       :: Queue
  , aCommandLine :: Text
  , aGzipless    :: Bool
  } deriving ( Eq, Read, Show )

args :: Parser Args
args = Args              <$>
  configFile             <*>
  (pack <$> queue)       <*>
  (pack <$> commandLine) <*>
  gzipless

parser :: ParserInfo Args
parser =
  info ( helper <*> args ) $ fullDesc
    <> header   "act: Workflow activity"
    <> progDesc "Workflow activity"

data Control = Control
  { cUid :: Uid
  } deriving ( Eq, Read, Show )

instance ToJSON Control where
  toJSON Control{..} = object
    [ "run_uid" .= cUid
    ]

encodeText :: ToJSON a => a -> Text
encodeText = toStrict . toLazyText . encodeToTextBuilder . toJSON

handler :: MonadBaseControl IO m => m () -> m (Maybe SomeException)
handler a = handle (return . Just) $ a >> return Nothing

exec :: MonadIO m => Args -> Text -> Uid -> Metadata -> [Blob] -> m (Metadata, [Artifact], Maybe SomeException)
exec Args{..} cmdline uid metadata blobs =
  shelly $ withDir $ \dir dataDir storeDir -> do
    control $ dataDir </> pack "control.json"
    storeInput $ storeDir </> pack "input"
    dataInput $ dataDir </> pack "input.json"
    e <- bash dir
    result <- dataOutput $ dataDir </> pack "output.json"
    artifacts <- storeOutput $ storeDir </> pack "output"
    return (result, artifacts, e) where
      withDir action =
        withTmpDir $ \dir -> do
          mkdir $ dir </> pack "data"
          mkdir $ dir </> pack "store"
          mkdir $ dir </> pack "store/input"
          mkdir $ dir </> pack "store/output"
          action dir (dir </> pack "data") (dir </> pack "store")
      control file =
        writefile file $ encodeText $ Control uid
      writeArtifact file blob =
        if aGzipless then
          writeBinary file $ BL.toStrict blob
        else
          writeBinary (dropExtension file) $ BL.toStrict $ decompress blob
      readArtifact dir file = do
        key <- relativeTo dir file
        if aGzipless then do
          blob <- readBinary file
          return ( toTextIgnore key
                 , hash blob
                 , fromIntegral $ length blob
                 , BL.fromStrict blob
                 )
        else do
          blob <- BL.toStrict . compress . BL.fromStrict <$> readBinary file
          return ( toTextIgnore (key <.> "gz")
                 , hash blob
                 , fromIntegral $ length blob
                 , BL.fromStrict blob
                 )
      dataInput file =
        maybe (return ()) (writefile file) metadata
      dataOutput file =
        catch_sh_maybe (readfile file) where
          catch_sh_maybe action =
            catch_sh (liftM Just action) $ \(_ :: SomeException) -> return Nothing
      storeInput dir =
        forM_ blobs $ \(key, blob) -> do
          paths <- liftM strip $ run "dirname" [key]
          mkdir_p $ dir </> paths
          writeArtifact (dir </> key) blob
      storeOutput dir = do
        artifacts <- findWhen test_f dir
        forM artifacts $ readArtifact dir
      bash dir =
        handler $ do
          bashDir <- pwd
          files <- ls bashDir
          forM_ files $ flip cp_r dir
          cd dir
          maybe (return ()) (uncurry $ run_ . fromText) $ uncons $ words cmdline

call :: Args -> IO ()
call Args{..} = do
  config <- decodeFile aConfig >>= maybeThrow (userError "Bad Config")
  env <- flowEnv config
  forever $ runResourceT $ runFlowT env $
    act aQueue $ exec Args{..} aCommandLine

main :: IO ()
main = execParser parser >>= call
