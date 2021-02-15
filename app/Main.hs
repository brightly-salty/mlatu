module Main where

import Arguments (Arguments, parseArguments)
import Arguments qualified
import Interact qualified
import Mlatu (compile, runMlatu)
import Mlatu.Interpret (interpret)
import Mlatu.Name (GeneralName (..), Qualified (..))
import Mlatu.Vocabulary qualified as Vocabulary
import Paths_Mlatu (getDataDir)
import Relude hiding (find)
import Report (reportAll)
import System.IO (hPutStrLn, hSetEncoding, utf8)
import System.Directory (doesFileExist)
import System.FilePath.Find (always, fileName, find, (~~?))

main :: IO ()
main = do
  hSetEncoding stdout utf8
  arguments <- parseArguments
  case Arguments.inputPaths arguments of
    [] -> case Arguments.compileMode arguments of
      Arguments.CheckMode -> do
        hPutStrLn stderr "Cannot run interactively in check mode."
        exitFailure
      Arguments.CompileMode {} -> do
        hPutStrLn stderr "Cannot run interactively in compile mode."
        exitFailure
      Arguments.InterpretMode -> Interact.run
      Arguments.FormatMode -> do
        hPutStrLn stderr "Cannot run interactively in format mode."
        exitFailure
    (_ : _) -> runBatch arguments

runBatch :: Arguments -> IO ()
runBatch arguments = do
  let paths = Arguments.inputPaths arguments
  commonPaths <- getCommonPaths
  result <- runMlatu $ compile mainPermissions Nothing (commonPaths ++ paths)
  case result of
    Left reports -> do
      reportAll reports
      exitFailure
    Right program -> case Arguments.compileMode arguments of
      Arguments.CheckMode -> pass
      Arguments.CompileMode _format -> pass
      Arguments.InterpretMode ->
        void $
          interpret
            program
            Nothing
            []
            stdin
            stdout
            stderr
            []
      Arguments.FormatMode -> pass
  where
    mainPermissions =
      [ QualifiedName $ Qualified Vocabulary.global "IO",
        QualifiedName $ Qualified Vocabulary.global "Fail"
      ]

getCommonPaths :: IO [FilePath]
getCommonPaths = do
  dir <- getDataDir
  files <- search dir
  filterM doesFileExist files
  where
    search :: FilePath -> IO [FilePath]
    search = find always (fileName ~~? "*.mlt")
