{- Copyright 2013-2015 NGLess Authors
 - License: MIT
 -}
{-# LANGUAGE TemplateHaskell #-}

module Output
    ( OutputType(..)
    , outputLno'
    , outputListLno
    , outputListLno'
    , setOutputLno
    , outputFQStatistics
    , writeOutput
    ) where

import Text.Printf (printf)
import System.IO
import System.IO.Unsafe (unsafePerformIO)
import Data.Maybe
import Data.IORef
import Data.Aeson
import Data.Aeson.TH (deriveToJSON, defaultOptions)
import Data.Time (getZonedTime)
import Data.Time.Format (formatTime)
import System.Locale (defaultTimeLocale)
import System.Console.ANSI
import Control.Applicative
import Control.Monad
import Control.Monad.IO.Class (liftIO)
import System.Console.CmdArgs.Verbosity (getVerbosity, Verbosity(..))
import qualified Data.Text as T
import qualified Data.ByteString.Lazy as BL


import Data.FastQ (FastQEncoding(..), encodingName)
import qualified Data.FastQStatistics as FQ
import Configuration
import NGLess

data OutputType = TraceOutput | DebugOutput | InfoOutput | ResultOutput | WarningOutput | ErrorOutput
    deriving (Eq, Ord)

instance Show OutputType where
    show TraceOutput = "trace"
    show DebugOutput = "debug"
    show InfoOutput = "info"
    show ResultOutput = "result"
    show WarningOutput = "warning"
    show ErrorOutput = "error"

data OutputLine = OutputLine !Int !OutputType !String
    deriving (Eq)

instance ToJSON OutputLine where
    toJSON (OutputLine lno ot m) = object ["lno" .= lno, "otype" .= show ot, "message" .= m]


data BPosInfo = BPosInfo
                    { mean :: !Int
                    , median :: !Int
                    , lowerQuartile :: !Int
                    , upperQuartile :: !Int
                    } deriving (Show)
$(deriveToJSON defaultOptions ''BPosInfo)

data FQInfo = FQInfo
                { fileName :: String
                , gcContent :: Double
                , encoding :: String
                , numSeqs :: Int
                , seqLength :: (Int,Int)
                , perBaseQ :: [BPosInfo]
                } deriving (Show)

$(deriveToJSON defaultOptions ''FQInfo)

curLine :: IORef (Maybe Int)
{-# NOINLINE curLine #-}
curLine = unsafePerformIO (newIORef Nothing)

savedOutput :: IORef [OutputLine]
{-# NOINLINE savedOutput #-}
savedOutput = unsafePerformIO (newIORef [])

savedFQOutput :: IORef [FQInfo]
{-# NOINLINE savedFQOutput #-}
savedFQOutput = unsafePerformIO (newIORef [])

setOutputLno :: Maybe Int -> IO ()
setOutputLno = writeIORef curLine

outputListLno :: OutputType -> Maybe Int -> [String] -> NGLessIO ()
outputListLno ot lno ms = output ot (fromMaybe 0 lno) (concat ms)

outputListLno' :: OutputType -> [String] -> NGLessIO ()
outputListLno' !ot ms = do
    lno <- liftIO $ readIORef curLine
    outputListLno ot lno ms

outputLno' :: OutputType -> String -> NGLessIO ()
outputLno' !ot m = outputListLno' ot [m]

shouldPrint :: Bool -> OutputType -> Verbosity -> Bool
shouldPrint _ TraceOutput _ = False
shouldPrint _      _ Loud = True
shouldPrint False ot Quiet = ot == ErrorOutput
shouldPrint False ot Normal = ot > InfoOutput
shouldPrint True  ot Quiet = ot >= WarningOutput
shouldPrint True  ot Normal = ot >= InfoOutput

output :: OutputType -> Int -> String -> NGLessIO ()
output !ot !lno !msg = do
    isTerm <- liftIO $ hIsTerminalDevice stdout
    verb <- liftIO getVerbosity
    traceSet <- traceFlag
    colorOpt <- nConfColor <$> nglConfiguration
    let sp = traceSet || shouldPrint isTerm ot verb
        doColor = case colorOpt of
            ForceColor -> True
            NoColor -> False
            AutoColor -> isTerm
    liftIO $ do
        t <- getZonedTime
        modifyIORef savedOutput (OutputLine lno ot msg:)
        when sp $ do
            let st = if doColor
                        then setSGRCode [SetColor Foreground Dull (colorFor ot)]
                        else ""
                rst = if doColor
                        then setSGRCode [Reset]
                        else ""
                tformat = if traceSet -- when trace is set, output seconds
                                then "%a %d-%m-%Y %T"
                                else "%a %d-%m-%Y %R"
                tstr = formatTime defaultTimeLocale tformat t
                lineStr = if lno > 0
                                then printf " Line %s" (show lno)
                                else "" :: String
            putStrLn $ printf "%s[%s]%s: %s%s" st tstr lineStr msg rst

colorFor :: OutputType -> Color
colorFor TraceOutput = White
colorFor DebugOutput = White
colorFor InfoOutput = Blue
colorFor ResultOutput = Black
colorFor WarningOutput = Yellow
colorFor ErrorOutput = Red


encodeBPStats :: FQ.Result -> FastQEncoding -> [BPosInfo]
encodeBPStats res enc = map encode1 (FQ.calculateStatistics res enc)
    where encode1 (mean, median, lq, uq) = BPosInfo mean median lq uq

outputFQStatistics :: FilePath -> FQ.Result -> FastQEncoding -> IO ()
outputFQStatistics fname stats enc = do
    let enc'    = encodingName enc
        sSize'  = FQ.seqSize stats
        nSeq'   = FQ.nSeq stats
        gc'     = FQ.gcFraction stats
        st      = encodeBPStats stats enc
        binfo   = FQInfo fname gc' enc' nSeq' sSize' st
    modifyIORef savedFQOutput (binfo:)


data FilesProcessed = FilesProcessed String String T.Text deriving (Show, Eq)
instance ToJSON FilesProcessed where
   toJSON (FilesProcessed a b c) = object [ "name" .= a,
                                            "time" .= b,
                                            "script" .=c ]

createFilesProcessed :: FilePath -> T.Text -> IO FilesProcessed
createFilesProcessed template script = do
    t <- getZonedTime
    return $ FilesProcessed template (show t) script

writeOutput :: FilePath -> FilePath -> T.Text -> IO ()
writeOutput fname scriptName script = do
    fullOutput <- reverse <$> readIORef savedOutput
    fqStats <- reverse <$> readIORef savedFQOutput
    processed <- createFilesProcessed scriptName script
    BL.writeFile fname (BL.concat
                    ["var output = "
                    , encode $ object
                        [ "output" .= fullOutput
                        , "processed" .= processed
                        , "fqStats" .= fqStats
                        ]
                    ,";\n"])

