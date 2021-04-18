module Test.Infer
  ( spec,
  )
where

import Mlatu (Prelude (..), compilePrelude, fragmentFromSource)
import Mlatu.Dictionary qualified as Dictionary
import Mlatu.Enter qualified as Enter
import Mlatu.Entry qualified as Entry
import Mlatu.Informer (errorCheckpoint)
import Mlatu.InstanceCheck (instanceCheck)
import Mlatu.Instantiated (Instantiated (Instantiated))
import Mlatu.Kind (Kind (..))
import Mlatu.Monad (runMlatuExceptT)
import Mlatu.Name (GeneralName (..), Qualified (..))
import Mlatu.Origin qualified as Origin
import Mlatu.Pretty (printEntry, printInstantiated, printType)
import Mlatu.Report (human)
import Mlatu.Term qualified as Term
import Mlatu.Type (Type (..), TypeId (..), Var (..))
import Mlatu.Type qualified as Type
import Mlatu.Vocabulary qualified as Vocabulary
import Prettyprinter (Pretty (pretty), hsep, list, tupled, vcat)
import Relude hiding (Type)
import Test.Common (Sign (..))
import Test.HUnit (assertBool, assertFailure)
import Test.Hspec (Spec, describe, it)

spec :: Spec
spec = do
  describe "with trivial programs" $ do
    it "typechecks empty program" $ do
      testTypecheck
        Positive
        "define test (->) {}"
        $ Type.Fun o r r

    it "typechecks single literals" $ do
      testTypecheck
        Positive
        "define test (-> Int) { 0 }"
        $ Type.Fun o r (Type.Prod o r int)

      testTypecheck
        Positive
        "define test (-> Double) { 1.0 }"
        $ Type.Fun o r (Type.Prod o r float)

    it "typechecks compound literals" $ do
      testTypecheck
        Positive
        "define test (-> List[Pair[Int, Int]]) { [1 1 pair, 2 2 pair, 3 3 pair] }"
        $ Type.Fun o r (Type.Prod o r (ctor "List" :@ (ctor "Pair" :@ int :@ int)))

    it "typechecks intrinsics" $ do
      testTypecheck
        Positive
        "vocab mlatu {\
        \ intrinsic magic[R..., S...] (R... -> S...)\
        \}\
        \define test [R..., S..., +P] (R... -> S... +P) { _::mlatu::magic }"
        $ Type.Fun o r s

      testTypecheck
        Positive
        "define test (-> Int) { 1 2 _::mlatu::add_int64 }"
        $ Type.Fun o r (Type.Prod o r int)

    it "typechecks data types" $ do
      testTypecheck
        Positive
        "type Unit { case unit }\n\
        \define test (-> Unit) { unit }"
        $ Type.Fun o r (Type.Prod o r (ctor "Unit"))

      testTypecheck
        Positive
        "type Unit { case unit () }\n\
        \define test (-> Unit) { unit }"
        $ Type.Fun o r (Type.Prod o r (ctor "Unit"))

    it "typechecks definitions" $ do
      testTypecheck
        Positive
        "define one (-> Int) { 1 }\n\
        \define test (-> Int) { one }"
        $ Type.Fun o r (Type.Prod o r int)

      testTypecheck
        Positive
        "define one (-> Int) { 1 }\n\
        \define two (-> Int) { 2 }\n\
        \define test (-> Int) { one two _::mlatu::add_int64 }"
        $ Type.Fun o r (Type.Prod o r int)

      testTypecheck
        Positive
        "define up (Int -> Int) { 1 _::mlatu::add_int64 }\n\
        \define down (Int -> Int) { -1 _::mlatu::add_int64 }\n\
        \define test (-> Int) { 1 up 2 down _::mlatu::add_int64 }"
        $ Type.Fun o r (Type.Prod o r int)

    it "typechecks operators" $ do
      testTypecheck
        Positive
        "define test (-> Int) { 1 + 1 }"
        $ Type.Fun o r (Type.Prod o r int)

    it "typechecks nested scopes" $ do
      testTypecheck
        Positive
        "intrinsic add (Int, Int -> Int)\n\
        \define test (-> Int, Int) {\n\
        \  1000 -> x1;\n\
        \  100 -> y1;\n\
        \  10\n\
        \  {\n\
        \    -> a1;\n\
        \    a1 x1 add\n\
        \    {\n\
        \      -> b1;\n\
        \      b1 y1 add\n\
        \    } call\n\
        \  } call\n\
        \  \n\
        \  1000 -> x2;\n\
        \  100 -> y2;\n\
        \  10\n\
        \  {\n\
        \    -> a2;\n\
        \    a2 y2 add\n\
        \    {\n\
        \      -> b2;\n\
        \      b2 x2 add\n\
        \    } call\n\
        \  } call\n\
        \}"
        $ Type.Fun o r (Type.Prod o (Type.Prod o r int) int)

    it "typechecks closures with multiple types" $ do
      testTypecheck
        Positive
        "define test (-> (-> Int, Double)) {\n\
        \  0 0.0 -> x, y;\n\
        \  { x y }\n\
        \}"
        $ Type.Fun
          o
          r
          ( Type.Prod
              o
              r
              (Type.Fun o r (Type.Prod o (Type.Prod o r int) float))
          )

  describe "with instance checking" $ do
    it "rejects invalid signature" $ do
      testTypecheck
        Negative
        "type Pair[A, B] { case pair (A, B) }\n\
        \define flip[A, B] (Pair[A, B] -> Pair[A, B]) {\n\
        \  match case pair -> x, y { y x pair }\n\
        \}\n\
        \define test (-> Pair[Char, Double]) { 1 '1' pair flip }"
        $ Type.Fun o r (Type.Prod o r (ctor "Pair" :@ char :@ int))

  describe "with higher-order functions" $ do
    it "typechecks curried functions" $ do
      testTypecheck
        Positive
        "define curried_add (Int -> Int -> Int) {\n\
        \  -> x; { -> y; x y _::mlatu::add_int64 }\n\
        \}\n\
        \define test (-> Int) { 1 2 curried_add call }"
        $ Type.Fun o r (Type.Prod o r int)

  describe "with coercions" $ do
    it "typechecks identity coercions" $ do
      testTypecheck
        Positive
        "define test (-> Int) { 1 as (Int) }"
        $ Type.Fun o r (Type.Prod o r int)
  where
    o = Origin.point "" 0 0
    r = TypeVar o $ Var "R" (TypeId 0) Stack
    s = TypeVar o $ Var "S" (TypeId 1) Stack
    ctor =
      TypeConstructor o . Type.Constructor
        . Qualified Vocabulary.global
    char = ctor "Char"
    int = ctor "Int"
    io = ctor "IO"
    fail_ = ctor "Fail"
    float = ctor "Double"

testTypecheck :: Sign -> Text -> Type -> IO ()
testTypecheck sign input expected = do
  mDictionary <- runMlatuExceptT $ compilePrelude Common Nothing
  case mDictionary of
    Left reports ->
      error $ show $ vcat $ pretty ("unable to set up inference tests:" :: Text) : (human <$> reports)
    Right dictionary -> do
      result <- runMlatuExceptT $ do
        fragment <- fragmentFromSource Nothing 1 "<test>" input
        Enter.fragment fragment dictionary
      case Dictionary.toList <$> result of
        Right definitions -> case find matching definitions of
          Just (_, Entry.Word _ _ _ _ _ (Just term)) -> do
            let actual = Term.typ term
            check <- runMlatuExceptT $ do
              instanceCheck "inferred" actual "declared" expected
              errorCheckpoint
            case sign of
              Positive ->
                assertBool
                  (show $ hsep [printType actual, "<:", printType expected])
                  $ isRight check
              Negative ->
                assertBool
                  (show $ hsep [printType actual, "</:", printType expected])
                  $ isLeft check
          _ ->
            assertFailure $
              show $
                hsep
                  ["missing main word definition:", list $ (\(i, e) -> tupled [printInstantiated i, printEntry e]) <$> definitions]
          where
            matching (Instantiated (Qualified v "test") _, _)
              | v == Vocabulary.global =
                True
            matching _ = False
        Left reports -> case sign of
          Positive ->
            assertFailure $
              toString $
                unlines $
                  show . human <$> reports
          -- FIXME: This might accept a negative test for the wrong
          -- reason.
          Negative -> pass
  where
    ioPermission = [QualifiedName $ Qualified Vocabulary.global "IO"]
