{-# LANGUAGE OverloadedStrings, BangPatterns #-}
module Functions
    ( builtinFunctions
    ) where

import Modules
import Language

builtinFunctions =
    [Function (FuncName "fastq") (Just NGLString) NGLReadSet fastqArgs False
    ,Function (FuncName "samfile") (Just NGLString) NGLMappedReadSet samfileArgs False
    ,Function (FuncName "paired") (Just NGLString) NGLReadSet pairedArgs False
    ,Function (FuncName "unique") (Just NGLReadSet) NGLReadSet uniqueArgs False
    ,Function (FuncName "preprocess") (Just NGLReadSet) NGLVoid preprocessArgs False
    ,Function (FuncName "substrim") (Just NGLRead) NGLRead substrimArgs False
    ,Function (FuncName "map") (Just NGLReadSet) NGLMappedReadSet mapArgs False
    ,Function (FuncName "select") (Just NGLMappedReadSet) NGLMappedReadSet selectArgs False
    ,Function (FuncName "count") (Just NGLAnnotatedSet) NGLCounts countArgs False
    ,Function (FuncName "annotate") (Just NGLMappedReadSet) NGLAnnotatedSet annotateArgs False
    ,Function (FuncName "write") (Just NGLAny) NGLVoid writeArgs False
    ,Function (FuncName "print") (Just NGLAny) NGLVoid [] False
    ]

annotateArgs =
    [ArgInformation "features" False (NGList NGLSymbol) (Just ["gene", "cds", "exon"])
    ,ArgInformation "mode" False NGLSymbol (Just ["union", "intersection_strict", "intersection_non_empty"])
    ,ArgInformation "gff" False NGLString Nothing
    ,ArgInformation "keep_ambiguous" False NGLBool Nothing
    ,ArgInformation "strand" False NGLBool Nothing
    ]

writeArgs =
    [ArgInformation "ofile" True NGLString Nothing
    ,ArgInformation "format" False NGLSymbol (Just ["tsv", "csv", "bam", "sam"])
    ,ArgInformation "verbose" False NGLBool Nothing
    ]

countArgs =
    [ArgInformation "counts" False (NGList NGLSymbol) (Just ["gene", "cds", "exon"])
    ,ArgInformation "min" False NGLInteger Nothing
    ]

selectArgs =
    [ArgInformation "keep_if" False (NGList NGLSymbol) (Just ["mapped", "unmapped"])
    ,ArgInformation "drop_if" False (NGList NGLSymbol) (Just ["mapped", "unmapped"])
    ,ArgInformation "__oname" False NGLString Nothing
    ]

fastqArgs =
    [ArgInformation "encoding" False NGLSymbol (Just ["auto", "33", "64", "sanger", "solexa"])]

samfileArgs = []
pairedArgs =
    [ArgInformation "second" True NGLString Nothing
    ,ArgInformation "singles" False NGLString Nothing
    ]

uniqueArgs =
    [ArgInformation "max_copies" False NGLInteger Nothing]

preprocessArgs =
    []

mapArgs =
    [ArgInformation "reference" True NGLString Nothing
    ,ArgInformation "__oname" False NGLString Nothing
    ]

substrimArgs =
    [ArgInformation "min_quality" True NGLInteger Nothing
    ]


