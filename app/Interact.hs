module Interact
  ( run,
  )
where

import Mlatu (Prelude (..), compilePrelude)
import Mlatu qualified
import Mlatu.Codegen qualified as Codegen
import Mlatu.Dictionary (Dictionary)
import Mlatu.Enter qualified as Enter
import Mlatu.Infer (typeFromSignature, typecheck)
import Mlatu.Informer (errorCheckpoint, ice, runMlatu, warnCheckpoint)
import Mlatu.Instantiated (Instantiated (Instantiated))
import Mlatu.Kind (Kind (..))
import Mlatu.Name
  ( GeneralName (QualifiedName),
    Qualified (Qualified),
    Qualifier (Qualifier),
    Root (Absolute),
    Unqualified (Unqualified),
  )
import Mlatu.Origin qualified as Origin
import Mlatu.Pretty (printQualified, printType)
import Mlatu.Signature qualified as Signature
import Mlatu.Term qualified as Term
import Mlatu.TypeEnv qualified as TypeEnv
import Mlatu.Unify qualified as Unify
import Mlatu.Vocabulary
import Optics
import Prettyprinter (vcat)
import Relude
import Report (reportAll)
import System.Console.Repline
import System.Directory (createDirectory, removeDirectoryRecursive, removeFile, withCurrentDirectory)
import System.IO (hPrint)
import System.Process.Typed (proc, runProcess_)

type MRepl = HaskelineT (ReaderT Dictionary (StateT (Text, Int) IO))

cmd :: String -> MRepl ()
cmd input = do
  (text, lineNumber) <- get
  commonDictionary <- ask
  let entryNameUnqualified = toText $ "entry" ++ show lineNumber
      entryName =
        Qualified
          (Qualifier Absolute ["interactive"])
          $ Unqualified entryNameUnqualified
  update <- liftIO $ do
    writeFile "interactive.mlt" input
    (result, reports) <- runMlatu $ do
      fragment <-
        Mlatu.fragmentFromSource
          [QualifiedName $ Global "io"]
          (Just entryName)
          lineNumber
          "interactive.mlt"
          (text <> " " <> toText input)
      errorCheckpoint
      dictionary <- Enter.fragment fragment commonDictionary
      errorCheckpoint
      pure dictionary
    reportAll reports
    removeFile "interactive.mlt"
    case result of
      Nothing -> pure False
      Just dictionary -> do
        contents <- Codegen.generate dictionary (Just entryName)
        writeFileBS "t/src/main.rs" contents
        withCurrentDirectory "t" (runProcess_ "cargo +nightly run --quiet")
        pure True
  when update $ put (text <> " " <> toText input, lineNumber + 1)

-- TODO
completer :: String -> ReaderT Dictionary (StateT (Text, Int) IO) [String]
completer n = pure []

helpCmd :: String -> MRepl ()
helpCmd s = liftIO $ case words (toText s) of
  ["help"] -> putStrLn helpHelp
  _ -> traverse_ putStrLn [helpHelp]
  where
    helpHelp = ":help - Show this help."

opts :: [(String, String -> MRepl ())]
opts = [("help", helpCmd)]

ini :: MRepl ()
ini = liftIO $ putStrLn "Welcome!"

final :: MRepl ExitDecision
final = liftIO (putStrLn "Bye!") >> pure Exit

run :: Prelude -> IO Int
run prelude = do
  (result, reports) <- runMlatu $ Mlatu.compilePrelude prelude [QualifiedName $ Global "io"] Nothing
  reportAll reports
  case result of
    Nothing -> pure 1
    Just commonDictionary -> do
      liftIO $ do
        createDirectory "t"
        writeFileBS "t/Cargo.toml" cargoToml
        createDirectory "t/.cargo"
        writeFileBS "t/.cargo/config.toml" configToml
        createDirectory "t/src"
      execStateT (runReaderT (evalReplOpts replOpts) commonDictionary) ("", 1)
      liftIO $ removeDirectoryRecursive "t"
      pure 0
  where
    cargoToml =
      "[package] \n\
      \name = \"output\" \n\
      \version = \"0.1.0\" \n\
      \[dependencies.smallvec] \n\
      \version = \"1.6.1\" \n\
      \features = [\"union\"]"
    configToml =
      "[target.x86_64-unknown-linux-gnu]\n\
      \linker = \"/usr/bin/clang\"\n\
      \rustflags = [\"-Clink-arg=-fuse-ld=lld\", \"-Zshare-generics=y\"]\n\
      \[target.x86_64-apple-darwin]\n\
      \rustflags = [\"-C\", \"link-arg=-fuse-ld=/usr/local/bin/zld\", \"-Zshare-generics=y\", \"-Csplit-debuginfo=unpacked\"]\n\
      \[target.x86_64-pc-windows-msvc]\n\
      \linker = \"rust-lld.exe\"\n\
      \rustflags = [\"-Zshare-generics=y\"]"
    replOpts =
      ReplOpts
        { banner = \case
            SingleLine -> pure "> "
            MultiLine -> pure "| ",
          command = cmd,
          options = opts,
          prefix = Just ':',
          multilineCommand = Just "paste",
          tabComplete = Word completer,
          initialiser = ini,
          finaliser = final
        }
