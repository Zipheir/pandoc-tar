-- Copyright 2021 John MacFarlane (pandoc-server)
-- Copyright 2021 Lassi Kortela (pandoc-tar)
-- SPDX-License-Identifier: BSD-3-Clause

{-# LANGUAGE FlexibleContexts #-}

module Main where

import Text.Pandoc
import Data.Text (Text)
import Data.Text.Encoding
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import qualified Data.Text.Lazy.Encoding as TLE
import Data.Maybe (fromMaybe)
import Data.Char (isAlphaNum)

import qualified Codec.Archive.Tar as Tar
import qualified Codec.Archive.Tar.Entry as Tar.Entry
import qualified Data.ByteString.Lazy as BS
import System.Console.GetOpt
import System.Environment
import Control.Monad.Except

data Params = Params
  { text           :: Text
  , from           :: Maybe Text
  , to             :: Maybe Text
  , wrapText       :: Maybe WrapOption
  , columns        :: Maybe Int
  , standalone     :: Maybe Bool
  , template       :: Maybe Text
  } deriving (Show)

defaultParams :: Params
defaultParams = Params
  { text       = T.empty
  , from       = Nothing
  , to         = Nothing
  , wrapText   = Nothing
  , columns    = Nothing
  , standalone = Nothing
  , template   = Nothing
  }

-- We use runPure for the pandoc conversions, which ensures that
-- they will do no IO.  This makes the server safe to use.  However,
-- it will mean that features requiring IO, like RST includes, will not work.
-- Changing this to
--    handleErr =<< liftIO (runIO (convertDocument' params))
-- will allow the IO operations.
convertDocument :: MonadError (IO a) m => Params -> m Text
convertDocument params = handleErr $ runPure (convertDocument' params)

convertDocument' :: PandocMonad m => Params -> m Text
convertDocument' params = do
  let readerFormat = fromMaybe (T.pack "markdown") $ from params
  let writerFormat = fromMaybe (T.pack "json") $ to params
  (readerSpec, readerExts) <- getReader readerFormat
  (writerSpec, writerExts) <- getWriter writerFormat
  let isStandalone = fromMaybe False (standalone params)
  let toformat     = T.toLower $ T.takeWhile isAlphaNum $ writerFormat
  mbTemplate <- if isStandalone
    then case template params of
      Nothing -> Just <$> compileDefaultTemplate toformat
      Just t  -> do
        res <- runWithPartials
          (compileTemplate ("custom." <> T.unpack toformat) t)
        case res of
          Left  e   -> throwError $ PandocTemplateError (T.pack e)
          Right tpl -> return $ Just tpl
    else return Nothing
  -- We don't yet handle binary formats:
  reader <- case readerSpec of
    TextReader r -> return r
    _ ->
      throwError
        $  PandocAppError
        $  readerFormat
        <> (T.pack " is not a text reader")
  writer <- case writerSpec of
    TextWriter w -> return w
    _ ->
      throwError
        $  PandocAppError
        $  readerFormat
        <> (T.pack " is not a text reader")
  reader
      def { readerExtensions = readerExts, readerStandalone = isStandalone }
      (text params)
    >>= writer def { writerExtensions = writerExts
                   , writerWrapText   = fromMaybe WrapAuto (wrapText params)
                   , writerColumns    = fromMaybe 72 (columns params)
                   , writerTemplate   = mbTemplate
                   }

handleErr :: MonadError (IO a1) m => Either PandocError a2 -> m a2
handleErr (Right t) = return t
handleErr (Left err) =
  throwError $ ioError (userError (T.unpack (renderError err)))

convertTarEntry :: Params -> Tar.Entry -> Tar.Entry
convertTarEntry params entry = case Tar.entryContent entry of
  Tar.NormalFile bytes _ ->
    ( ( let oldPath = Tar.Entry.entryPath entry
            newPath =
              ( case Tar.Entry.toTarPath False oldPath of
                Left  _        -> Tar.Entry.entryTarPath entry
                Right newPath' -> newPath'
              )
        in  case
              ( convertDocument params
                { text = Data.Text.Encoding.decodeUtf8 (BS.toStrict bytes)
                }
              )
            of
              Left _ -> entry
              Right newText ->
                ( Tar.Entry.fileEntry newPath
                                      (TLE.encodeUtf8 (TL.fromStrict newText))
                )
      )
    )
  _ -> entry

convertTarEntries :: Params -> Tar.Entries e -> [Tar.Entry.Entry]
convertTarEntries params entries = Tar.foldEntries
  (\entry newEntries -> (convertTarEntry params entry) : newEntries)
  []
  (\_error -> [])
  entries

data Flag
 = Verbose
 | Version
 | Help
 | FromFormat String
 | ToFormat String
   deriving Show

commandLineOptions :: [OptDescr Flag]
commandLineOptions =
  [ Option ['h'] ["help"] (NoArg Help) "show usage and exit"
  , Option ['V'] ["version"] (NoArg Version) "show version and exit"
  , Option ['v'] ["verbose"] (NoArg Verbose) "write details to stderr"
  , Option ['f'] ["from"] (ReqArg FromFormat "FORMAT") "read this markup format"
  , Option ['t'] ["to"] (ReqArg ToFormat "FORMAT") "write this markup format"
  ]

parseCommandLine :: [String] -> IO ([Flag], [String])
parseCommandLine args = case getOpt Permute commandLineOptions args of
  (o, n, []) -> return (o, n)
  (_, _, errs) ->
    ioError (userError (concat errs ++ usageInfo header commandLineOptions))
  where header = "Usage: pandoc-tar [-f FORMAT] -t FORMAT <in.tar >out.tar"

main :: IO ()
main = do
  args                  <- getArgs
  (actions, nonOptions) <- parseCommandLine args
  contents              <- BS.getContents
  BS.putStr (Tar.write (convertTarEntries defaultParams (Tar.read contents)))
