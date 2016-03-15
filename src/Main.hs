{- Main -- main entry point
Copyright (C) 2013, 2014  Benjamin Barenblat <bbaren@mit.edu>

This file is a part of decafc.

decafc is free software: you can redistribute it and/or modify it under the
terms of the MIT (X11) License as described in the LICENSE file.

decafc is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
PARTICULAR PURPOSE.  See the X11 license for more details. -}
{-# LANGUAGE ScopedTypeVariables #-}
module Main where

import Prelude hiding (readFile)
import qualified Prelude

import Control.Exception (bracket)
import Control.Monad (forM_, void)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Except (ExceptT(..), runExceptT)
import Data.Either (partitionEithers)
import GHC.IO.Handle (hDuplicate)
import System.Environment (getProgName)
import qualified System.Exit
import System.IO (IOMode(..), hClose, hPutStrLn, openFile, stdout, stderr)
import Text.Printf (printf)
import Data.List.Split (splitOn)

import qualified CLI
import Configuration (Configuration, CompilerStage(..))
import qualified Configuration
import qualified Parser
import qualified Scanner
import qualified SemanticChecker
import qualified CodeGen

import qualified LLIR

import qualified Data.Map

import Data.Aeson
import Data.Aeson.Encode.Pretty (encodePretty)
import qualified Data.ByteString.Lazy (putStrLn)

------------------------ Impure code: Fun with ExceptT ------------------------

main :: IO ()
main = do
  {- Compiler work can be split into three stages: reading input (impure),
  processing it (pure), and writing output (impure).  Of course, input might be
  malformed or there might be an error in processing.  Thus, it makes most
  sense to think of the compiler as having type ExceptT String IO [IO ()] --
  that is, computation might fail with a String or succeed with a series of IO
  actions. -}
  result <- runExceptT $ do
    -- Part I: Get input
    configuration <- ExceptT CLI.getConfiguration
    input <- readFile $ Configuration.input configuration
    -- Part II: Process it
    hoistEither $ process configuration (input ++ "\n")
  case result of
    -- Part III: Write output
    Left errorMessage -> fatal errorMessage
    Right actions -> do
      sequence_ actions
  where hoistEither = ExceptT . return

readFile :: FilePath -> ExceptT String IO String
readFile name = liftIO $ Prelude.readFile name

fatal :: String -> IO ()
fatal message = do
  progName <- getProgName
  hPutStrLn stderr $ printf "%s: %s" progName message
  System.Exit.exitFailure

---------------------------- Pure code: Processing ----------------------------

{- Since our compiler only handles single files, the 'Configuration' struct
doesn't currently get passed through to the scanner and parser code.  (This may
change--one can see the scanner and parser as acting in a reader monad.)  The
big problem with this is that error messages generated in the scanner and
parser won't contain the file name--the file name has to get added in this
function. -}
mungeErrorMessage :: Configuration -> Either String a -> Either String a
mungeErrorMessage configuration =
  ifLeft ((Prelude.last (Data.List.Split.splitOn "/" (Configuration.input configuration)) ++ " ")++)
  where ifLeft f (Left v) = Left $ f v
        ifLeft _ (Right a) = Right a

{- The pure guts of the compiler convert input to output.  Exactly what output
they produce, though, depends on the configuration. -}
process :: Configuration -> String -> Either String [IO ()]
process configuration input =
  -- Dispatch on the configuration, modifying error messages appropriately.
  case Configuration.target configuration of
    Scan -> scan configuration input
    Parse -> parse configuration input
    Inter -> semanticCheck configuration input
    Assembly -> codeGen configuration input
    AST -> printAst configuration input
    phase -> Left $ show phase ++ " not implemented\n"

scan :: Configuration -> String -> Either String [IO ()]
scan configuration input =
  let tokensAndErrors =
        Scanner.scan input |>
        Prelude.map (mungeErrorMessage configuration) |>
        Prelude.map Scanner.formatTokenOrError
  in
  {- We have to interleave output to standard error (for errors) and standard
  output or a file (for output), so we need to actually build an appropriate
  set of IO actions. -}
  Right $ [ bracket openOutputHandle hClose $ \hOutput ->
             forM_ tokensAndErrors $ \tokOrError ->
               case tokOrError of
                 Left err -> hPutStrLn {--stderr--} hOutput err
                 Right tok -> hPutStrLn hOutput tok
          ]
  where v |> f = f v            -- like a Unix pipeline, but pure
        openOutputHandle = maybe (hDuplicate stdout) (flip openFile WriteMode) $ Configuration.outputFileName configuration


semanticCheck :: Configuration -> String -> Either String [IO ()]
semanticCheck configuration input = do
  let (errors, tokens) = partitionEithers $ Scanner.scan input
  -- If errors occurred, bail out.
  mapM_ (mungeErrorMessage configuration . Left) errors
  -- Otherwise, attempt a parse.
  case (Parser.parse tokens) of
    Left  a -> Left a
    Right ast ->
      let ( mod, ( SemanticChecker.Context ios asts ) ) = SemanticChecker.semanticVerifyProgram ast (SemanticChecker.Module Nothing (Data.Map.empty) SemanticChecker.Other) in
      if length ios /= 0
        then Right $ ios
        else Right $ (LLIR.debugs asts )++ [ do
            hOutput <- maybe (hDuplicate stdout) (flip openFile WriteMode) $ Configuration.outputFileName configuration
            hPutStrLn hOutput (show $ LLIR.pmod asts)
            hClose hOutput
          ]
        Right a -> Right []

codeGen :: Configuration -> String -> Either String [IO ()]
codeGen configuration input = do
  let (errors, tokens) = partitionEithers $ Scanner.scan input
  -- If errors occurred, bail out.
  mapM_ (mungeErrorMessage configuration . Left) errors
  -- Otherwise, attempt a parse.
  case (Parser.parse tokens) of
    Left  a -> Left a
    Right ast -> do
      let ( mod, asts ) = SemanticChecker.semanticVerifyProgram ast (SemanticChecker.Module Nothing (Data.Map.empty) SemanticChecker.Other) (Right SemanticChecker.Dummy)
      case asts of
        Left errors -> Right errors
        Right a -> do
          let asm = CodeGen.gen asts
          let maybePath = Configuration.outputFileName configuration
          case maybePath of
            Just path -> Right [writeFile path asm]
            Nothing -> Right [putStrLn asm]


printAst :: Configuration -> String -> Either String [IO ()]
printAst configuration input = do
  let (errors, tokens) = partitionEithers $ Scanner.scan input
  -- If errors occurred, bail out.
  mapM_ (mungeErrorMessage configuration . Left) errors
  -- Otherwise, attempt a parse.
  case (Parser.parse tokens) of
    Left  a -> Left a
    Right ast -> Right [ Data.ByteString.Lazy.putStrLn (encodePretty $ ast) ]

parse :: Configuration -> String -> Either String [IO ()]
parse configuration input = do
  let (errors, tokens) = partitionEithers $ Scanner.scan input
  -- If errors occurred, bail out.
  mapM_ (mungeErrorMessage configuration . Left) errors
  -- Otherwise, attempt a parse.
  void $ mungeErrorMessage configuration $ Parser.parse tokens
  Right []
