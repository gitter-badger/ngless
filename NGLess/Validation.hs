{- Copyright 2013-2015 NGLess Authors
 - License: MIT
 -}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Validation
    ( validate
    , uses_STDOUT
    ) where

import Data.Maybe
import Data.Foldable (asum)
import qualified Data.Text as T
import Control.Applicative
import Data.List

import Language
import Modules
import Functions

validate :: [Module] -> Script -> Either T.Text Script
validate mods expr = case errors of
        [] -> Right expr
        _ -> Left (T.concat errors)
    where
        errors = catMaybes (map (\f -> f mods expr) checks)
        checks =
            [validate_types
            ,validate_version
            ,validate_pure_function
            ,validate_req_function_args -- check for the existence of required arguments in functions.
            ,validate_symbol_in_args
            ,validate_STDIN_only_used_once
            ]

{- Each checking function has the type
 -
 - Script -> Maybe T.Text
 -
 - If it finds an error, it returns a Just error; otherwise, Nothing.
 -
 - The validate function just runs all checks and either concatenates all the
 - error messages or passes the script unharmed on the Right side.
 -}

-- symbols that can be used directly
symbols :: [T.Text]
symbols = ["union", "intersection_strict", "intersection_non_empty", "allow", "deny", "yes", "no", "csv", "tsv", "bam", "sam"]

-- symbols that can be used inside a list.
symbols_list :: [T.Text]
symbols_list = ["gene", "cds", "exon"]


validate_version :: [Module] -> Script -> Maybe T.Text
validate_version _ sc = nglVersion  <$> nglHeader sc >>= \case
    "0.0" -> Nothing
    version -> Just (T.concat ["Version ", version, " is not supported (only version 0.0 is available)."])

validate_types :: [Module] -> Script -> Maybe T.Text
validate_types _ (Script _ es) = check_toplevel validate_types' es
    where validate_types' (Assignment _ e@(ConstSymbol _)) = validate_symbol symbols e
          validate_types' (Assignment _ (ListExpression e@[ConstSymbol _])) = errors_from_list $ map (validate_symbol symbols_list) e
          validate_types' _ = Nothing

validate_symbol :: [T.Text] -> Expression -> Maybe T.Text
validate_symbol s (ConstSymbol k)
    | elem k s = Nothing
    | otherwise = Just (T.concat ["Used symbol `", k, "` but possible symbols are: ", T.pack . show $ s])
validate_symbol _ _ = Nothing


-- | check whether results of calling pure functions are use
validate_pure_function _ (Script _ es) = check_toplevel validate_pure_function' es
    where
        validate_pure_function' (FunctionCall (FuncName f) _ _ _)
            | f `elem` pureFunctions = Just (T.concat ["Result of calling function ",  f, " should be assigned to something (this function has no effect otherwise)."])
        validate_pure_function' _ = Nothing
        pureFunctions =
                    [ "unique"
                    , "substrim"
                    , "map"
                    , "count"
                    , "select"
                    , "as_reads"
                    ]
findFunction :: [Module] -> FuncName -> Maybe Function
findFunction mods fn = find ((==fn) . funcName) $ builtinFunctions ++ concat (modFunctions <$> mods)

validate_req_function_args :: [Module] -> Script -> Maybe T.Text
validate_req_function_args mods (Script _ es) = check_toplevel validate_req_function_args' es
    where
        validate_req_function_args' (Assignment  _ fc) = validate_req_function_args' fc
        validate_req_function_args' (FunctionCall f _ args _) = has_required_args mods f args
        validate_req_function_args' _ = Nothing

has_required_args :: [Module] -> FuncName -> [(Variable, Expression)] -> Maybe T.Text
has_required_args mods f args = case findFunction mods f of
        Nothing -> Just (T.concat ["Function ", T.pack . show $ f, " not found."])
        Just finfo -> errors_from_list $ map has1 (funcKwArgs finfo)
    where
        used = map (\(Variable k, _) -> k) args
        has1 ainfo = if not (argRequired ainfo) || (argName ainfo) `elem` used
                then Nothing
                else Just (T.concat ["Function ", T.pack . show $ f, " requires argument ", argName ainfo, "."])

validate_symbol_in_args :: [Module] -> Script -> Maybe T.Text
validate_symbol_in_args mods (Script _ es) = check_toplevel (check_recursive validate_symbol_in_args') es
    where
        validate_symbol_in_args' (Assignment  _ fc) = validate_symbol_in_args' fc
        validate_symbol_in_args' (FunctionCall f _ args _) = check_symbol_val_in_arg mods f args
        validate_symbol_in_args' _ = Nothing



validate_STDIN_only_used_once :: [Module] -> Script -> Maybe T.Text
validate_STDIN_only_used_once _ (Script _ code) = check_use Nothing code
    where
        check_use _ [] = Nothing
        check_use ub@(Just p) ((lno,e):es)
            | stdin_used e = Just . T.pack . concat $ ["Error on line ", show lno, " STDIN can only be used once in the script (previously used on line ", show p, ")"]
            | otherwise = check_use ub es
        check_use Nothing ((lno,e):es) = check_use (if stdin_used e then Just lno else Nothing) es
        stdin_used = constant_used "STDIN"


constant_used :: T.Text -> Expression -> Bool
constant_used k (BuiltinConstant (Variable k')) = k == k'
constant_used k (ListExpression es) = constant_used k `any` es
constant_used k (UnaryOp _ e) = constant_used k e
constant_used k (BinaryOp _ a b) = constant_used k a || constant_used k b
constant_used k (Condition a b c) = constant_used k a || constant_used k b || constant_used k c
constant_used k (IndexExpression a ix) = constant_used k a || constant_used_ix k ix
constant_used k (Assignment _ e) = constant_used k e
constant_used k (FunctionCall _ e args b) = constant_used k e || constant_used k `any` [e' | (_,e') <- args] || constant_used_block k b
constant_used k (Sequence es) = constant_used k `any` es
constant_used _ _ = False
constant_used_ix k (IndexOne a) = constant_used k a
constant_used_ix k (IndexTwo a b) = constant_used_maybe k a || constant_used_maybe k b
constant_used_maybe k (Just e) = constant_used k e
constant_used_maybe _ Nothing = False
constant_used_block k (Just (Block _ e)) = constant_used k e
constant_used_block _ _ = False

uses_STDOUT :: Expression -> Bool
uses_STDOUT = constant_used "STDOUT"

check_symbol_val_in_arg :: [Module] -> FuncName -> [(Variable, Expression)]-> Maybe T.Text
check_symbol_val_in_arg mods f args = case findFunction mods f of
        Nothing -> Just (T.concat ["Function '", T.pack . show $ f, "' not found"])
        Just finfo -> errors_from_list $ map (check1 finfo) args
    where
        allowed :: Function -> T.Text -> [T.Text]
        allowed finfo v = case argAllowedSymbols =<< find ((==v) . argName) (funcKwArgs finfo) of
            Just ss -> ss
            Nothing -> []

        allowedStr finfo v = T.concat ["[", showA (allowed finfo v), "]"]
        showA [] = ""
        showA [e] = T.concat ["{", e, "}"]
        showA (e:es) = T.concat ["{", e, "}, ", showA es]
        check1 finfo (Variable v, expr) = case expr of
            ConstSymbol s       -> if s `elem` (allowed finfo v)
                                    then Nothing
                                    else Just (T.concat ["Argument: `", v, "` (for function ", T.pack (show f), ") expects one of ", allowedStr finfo v, " but got {", s, "}"])
            ListExpression es   -> errors_from_list $ map (\e -> check1 finfo (Variable v, e)) es
            _                   -> Nothing

check_toplevel :: (Expression -> Maybe T.Text) -> [(Int, Expression)] -> Maybe T.Text
check_toplevel _ [] = Nothing
check_toplevel f ((lno,e):es) = case f e of
        Nothing -> check_toplevel f es
        Just m -> Just (T.concat ["Line ", T.pack (show lno), ": ", m])


check_recursive :: (Expression -> Maybe T.Text) -> Expression -> Maybe T.Text
check_recursive f e = f e <|> check_recursive' f e

check_recursive' :: (Expression -> Maybe T.Text) -> Expression -> Maybe T.Text
check_recursive' f (ListExpression es) = asum $ check_recursive f `map` es
check_recursive' f (UnaryOp _ e) = check_recursive f e
check_recursive' f (BinaryOp _ e e') = check_recursive f e <|> check_recursive f e'
check_recursive' f (Condition cond ifT ifF) = check_recursive f cond <|> check_recursive f ifT <|> check_recursive f ifF
check_recursive' f (IndexExpression e ix) = check_recursive f e <|> check_recursive_index f ix
check_recursive' f (Assignment _ v) = check_recursive f v
check_recursive' f (FunctionCall _ marg args block) =
    check_recursive f marg <|> check_recursive f (ListExpression [e | (_,e) <- args]) <|> check_recursive_block f block
check_recursive' f (Sequence es) = asum $ check_recursive f `map` es
check_recursive' _ _ = Nothing

check_recursive_index f (IndexOne e) = check_recursive f e
check_recursive_index f (IndexTwo st e) = (st >>= check_recursive f) <|> (e >>= check_recursive f)
check_recursive_block f (Just (Block _ e)) = check_recursive f e
check_recursive_block _ Nothing = Nothing


errors_from_list :: [Maybe T.Text] -> Maybe T.Text
errors_from_list errs = case catMaybes errs of
    [] -> Nothing
    errs' -> Just (T.concat errs')
