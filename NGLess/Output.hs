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

import Text.Printf
import System.IO
import System.IO.Unsafe
import Data.Maybe
import Data.IORef
import Data.Aeson
import Data.Aeson.TH (deriveToJSON, defaultOptions)
import Data.Time
import System.Console.ANSI
import Control.Applicative
import Control.Monad
import System.Console.CmdArgs.Verbosity
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Lazy.Char8 as BL8


import Data.FastQ (FastQEncoding(..), encodingName)
import qualified FastQStatistics as FQ

data OutputType = DebugOutput | InfoOutput | ResultOutput | WarningOutput | ErrorOutput
    deriving (Eq, Ord)

instance Show OutputType where
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

outputListLno :: OutputType -> Maybe Int -> [String] -> IO ()
outputListLno ot lno ms = output ot (fromMaybe 0 lno) (concat ms)

outputListLno' :: OutputType -> [String] -> IO ()
outputListLno' !ot ms = do
    lno <- readIORef curLine
    outputListLno ot lno ms

outputLno' :: OutputType -> String -> IO ()
outputLno' !ot m = outputListLno' ot [m]

output :: OutputType -> Int -> String -> IO ()
output !ot !lno !msg = do
    isTerm <- hIsTerminalDevice stdout
    verb <- getVerbosity
    t <- getZonedTime
    modifyIORef savedOutput (OutputLine lno ot msg:)
    when (isTerm && (verb == Loud || ot >= InfoOutput) && (verb /= Quiet || ot >= ResultOutput)) $ do
        let st = setSGRCode [SetColor Foreground Dull (colorFor ot)]
        putStrLn $ printf "%s[%s]: Line %s: %s" st (show t) (show lno) msg

colorFor :: OutputType -> Color
colorFor DebugOutput = White
colorFor InfoOutput = Blue
colorFor ResultOutput = Black
colorFor WarningOutput = Yellow
colorFor ErrorOutput = Red


encodeBPStats :: FQ.Result -> FastQEncoding -> [BPosInfo]
encodeBPStats res enc = map encode1 (FQ._calculateStatistics res enc)
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

writeOutput :: FilePath -> IO ()
writeOutput fname = do
    fullOutput <- reverse <$> readIORef savedOutput
    fqStats <- reverse <$> readIORef savedFQOutput
    BL.writeFile fname (encode $ object
                    [ "output" .= fullOutput
                    , "fqStats" .= fqStats
                    ])

