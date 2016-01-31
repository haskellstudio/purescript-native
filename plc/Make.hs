-----------------------------------------------------------------------------
--
-- Module      :  Make
-- Copyright   :  (c) 2013-14 Phil Freeman, (c) 2014 Gary Burgess, and other contributors
-- License     :  MIT
--
-- Maintainer  :  Andy Arvanitis
-- Stability   :  experimental
-- Portability :
--
-- |
--
-----------------------------------------------------------------------------

{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TemplateHaskell #-}

module Make
  ( Make(..)
  , runMake
  , buildMakeActions
  ) where

import Control.Monad
import Control.Monad.Error.Class (MonadError(..))
import Control.Monad.Reader

-- import Data.FileEmbed (embedFile)
import Data.List (intercalate)
import Data.Maybe (fromMaybe)
import Data.String (fromString)
import Data.Time.Clock
import Data.Version (showVersion)
import qualified Data.Map as M
import qualified Data.ByteString.Char8 as B

import System.Directory (doesDirectoryExist, doesFileExist, getModificationTime, createDirectoryIfMissing)
import System.FilePath ((</>), takeDirectory, addExtension, dropExtension)
import System.IO.Error (tryIOError)
import System.IO.UTF8

import Language.PureScript.Errors
import Language.PureScript (Make, runMake)

import qualified Language.PureScript as P
import qualified Language.PureScript.CodeGen.Lisp as Lisp
import qualified Language.PureScript.Pretty.Lisp as Lisp
import qualified Language.PureScript.CoreFn as CF
import qualified Paths_purescript as Paths

makeIO :: (IOError -> P.ErrorMessage) -> IO a -> Make a
makeIO f io = do
  e <- liftIO $ tryIOError io
  either (throwError . P.singleError . f) return e

-- Traverse (Either e) instance (base 4.7)
traverseEither :: Applicative f => (a -> f b) -> Either e a -> f (Either e b)
traverseEither _ (Left x) = pure (Left x)
traverseEither f (Right y) = Right <$> f y

buildMakeActions :: FilePath
                 -> M.Map P.ModuleName (Either P.RebuildPolicy FilePath)
                 -> Bool
                 -> P.MakeActions Make
buildMakeActions outputDir filePathMap usePrefix =
  P.MakeActions getInputTimestamp getOutputTimestamp readExterns codegen progress
  where

  getInputFile :: P.ModuleName -> FilePath
  getInputFile mn =
    let path = fromMaybe (error "Module has no filename in 'make'") $ M.lookup mn filePathMap in
    case path of
      Right path' -> path'
      Left _ -> error  "Module has no filename in 'make'"

  getInputTimestamp :: P.ModuleName -> Make (Either P.RebuildPolicy (Maybe UTCTime))
  getInputTimestamp mn = do
    let path = fromMaybe (error "Module has no filename in 'make'") $ M.lookup mn filePathMap
    traverseEither getTimestamp path

  getOutputTimestamp :: P.ModuleName -> Make (Maybe UTCTime)
  getOutputTimestamp mn = do

    let filePath = dotsTo '/' $ P.runModuleName mn
        fileBase = outputDir </> "src" </> filePath
        srcFile = addExtension (fileBase </> "core") "clj"
        externsFile = outputDir </> "externs" </> filePath </> "externs.purs"
    min <$> getTimestamp srcFile <*> getTimestamp externsFile

  readExterns :: P.ModuleName -> Make (FilePath, P.Externs)
  readExterns mn = do
    let path = outputDir </> "externs" </> (dotsTo '/' $ P.runModuleName mn) </> "externs.purs"
    (path, ) <$> readTextFile path

  codegen :: CF.Module CF.Ann -> P.Environment -> P.Externs -> P.SupplyT Make ()
  codegen m env exts = do
    let mn = CF.moduleName m
    let filePath = dotsTo '/' $ P.runModuleName mn
        fileBase = outputDir </> "src" </> filePath
        srcFile = addExtension (fileBase </> "core") "clj"
        externsFile = outputDir </> "externs" </> filePath </> "externs.purs"
        prefix = ["Generated by plc version " ++ showVersion Paths.version | usePrefix]
    srcs <- Lisp.moduleToLisp env m Nothing
    psrcs <- Lisp.prettyPrintLisp <$> pure srcs
    let src = unlines $ map (";; " ++) prefix ++ [psrcs]

    lift $ do
      writeTextFile srcFile src
      writeTextFile externsFile exts

      let projectFile = outputDir </> "project.clj"
      projectFileExists <- textFileExists projectFile
      when (not projectFileExists) $ do
        writeTextFile projectFile (fromString projectTxt)
        -- writeTextFile (supportDir </> "PureScript.hh") $ B.unpack $(embedFile "plc/include/purescript.hh")

      let inputPath = dropExtension $ getInputFile mn
          sfile = addExtension inputPath "clj"
      sfileExists <- textFileExists sfile
      when (sfileExists) $ do
        text' <- readTextFile sfile
        writeTextFile (addExtension (fileBase </> "foreign") "clj") text'

  requiresForeign :: CF.Module a -> Bool
  requiresForeign = not . null . CF.moduleForeign

  dirExists :: FilePath -> Make Bool
  dirExists path = makeIO (const (ErrorMessage [] $ CannotReadFile path)) $ do
    doesDirectoryExist path

  textFileExists :: FilePath -> Make Bool
  textFileExists path = makeIO (const (ErrorMessage [] $ CannotReadFile path)) $ do
    doesFileExist path

  getTimestamp :: FilePath -> Make (Maybe UTCTime)
  getTimestamp path = makeIO (const (ErrorMessage [] $ CannotGetFileInfo path)) $ do
    exists <- doesFileExist path
    traverse (const $ getModificationTime path) $ guard exists

  readTextFile :: FilePath -> Make String
  readTextFile path = makeIO (const (ErrorMessage [] $ CannotReadFile path)) $ readUTF8File path

  writeTextFile :: FilePath -> String -> Make ()
  writeTextFile path text = makeIO (const (ErrorMessage [] $ CannotWriteFile path)) $ do
    mkdirp path
    writeFile path text
    where
    mkdirp :: FilePath -> IO ()
    mkdirp = createDirectoryIfMissing True . takeDirectory

  -- | Render a progress message
  renderProgressMessage :: P.ProgressMessage -> String
  renderProgressMessage (P.CompilingModule mn) = "Compiling " ++ P.runModuleName mn

  progress :: P.ProgressMessage -> Make ()
  progress = liftIO . putStrLn . renderProgressMessage

dotsTo :: Char -> String -> String
dotsTo chr = map (\c -> if c == '.' then chr else c)

projectTxt :: String
projectTxt = intercalate "\n" lines'
  where lines' = [ "(defproject main \"\""
                 , "  :description \"PureScript output\""
                 , "  :dependencies [[org.clojure/clojure \"1.7.0\"]]"
                 , "  :main Main.core)"
                 ]