{-# LANGUAGE GADTs #-}
{-# OPTIONS_GHC -Wno-orphans #-}

-- |
-- Module      : Mlatu.Pretty
-- Description : Pretty-printing utilities
-- Copyright   : (c) Caden Haustin, 2021
-- License     : MIT
-- Maintainer  : mlatu@brightlysalty.33mail.com
-- Stability   : experimental
-- Portability : GHC
module Mlatu.Pretty
  ( printConstructor,
    printGeneralName,
    printOrigin,
    printQualified,
    printSignature,
    printTerm,
    printType,
    printInstantiated,
    printKind,
    printEntry,
    printFragment,
    printQualifier,
  )
where

import Data.Char (isLetter)
import Data.HashMap.Strict qualified as HashMap
import Data.List (findIndex, groupBy)
import Data.Text qualified as Text
import Mlatu.Base qualified as Base
import Mlatu.DataConstructor qualified as DataConstructor
import Mlatu.Declaration (Declaration (..))
import Mlatu.Declaration qualified as Declaration
import Mlatu.Definition (Definition (Definition), mainName)
import Mlatu.Entry (Entry)
import Mlatu.Entry qualified as Entry
import Mlatu.Entry.Category qualified as Category
import Mlatu.Entry.Parameter (Parameter (..))
import Mlatu.Entry.Parent qualified as Parent
import Mlatu.Fragment (Fragment (..))
import Mlatu.Fragment qualified as Fragment
import Mlatu.Instantiated (Instantiated (..))
import Mlatu.Kind (Kind (..))
import Mlatu.Literal (FloatLiteral (..), IntegerLiteral (..), floatValue)
import Mlatu.Metadata (Metadata (..))
import Mlatu.Metadata qualified as Metadata
import Mlatu.Name (Closed (..), ClosureIndex (..), ConstructorIndex (..), GeneralName (..), LocalIndex (..), Qualified (..), Qualifier (..), Root (..), Unqualified (..))
import Mlatu.Operator qualified as Operator
import Mlatu.Origin qualified as Origin
import Mlatu.Signature (Constraint (..), Signature (..))
import Mlatu.Synonym (Synonym (Synonym))
import Mlatu.Term (Case (..), CoercionHint (..), Else (..), MatchHint (..), Term (..), Value (..))
import Mlatu.Term qualified as Term
import Mlatu.Token qualified as Token
import Mlatu.Type (Constructor (..), Type (..), TypeId (..), Var (..))
import Mlatu.Type qualified as Type
import Mlatu.TypeDefinition (TypeDefinition (..))
import Numeric (showIntAtBase)
import Prettyprinter
import Relude hiding (Compose, Constraint, Type)
import Relude.Unsafe qualified as Unsafe
import Text.Show qualified

printIntegerLiteral :: IntegerLiteral -> Doc a
printIntegerLiteral literal =
  hsep $
    catMaybes
      [ sign,
        case integerBase literal of
          Base.Binary -> Just "0b"
          Base.Octal -> Just "0o"
          Base.Decimal -> Nothing
          Base.Hexadecimal -> Just "0x",
        Just $ pretty $ showIntAtBase base (\i -> Unsafe.fromJust (digits !!? i)) (abs value) ""
      ]
  where
    sign = if value < 0 then Just "-" else Nothing
    value = integerValue literal
    (base, digits) = case integerBase literal of
      Base.Binary -> (2, "01")
      Base.Octal -> (8, ['0' .. '7'])
      Base.Decimal -> (10, ['0' .. '9'])
      Base.Hexadecimal -> (16, ['0' .. '9'] ++ ['A' .. 'F'])

printFloatLiteral :: FloatLiteral -> Doc a
printFloatLiteral literal =
  if value < 0 then "-" else "" <> pretty value
  where
    value :: Double
    value = floatValue literal

printParameter :: Parameter -> Doc a
printParameter (Parameter _ name Value) = printUnqualified name
printParameter (Parameter _ name Stack) = printUnqualified name <> "..."
printParameter (Parameter _ name Label) = "+" <> printUnqualified name
printParameter (Parameter _ name Permission) = "+" <> printUnqualified name
printParameter (Parameter _ name (_ :-> _)) = printUnqualified name <> "[_]"

printQualified :: Qualified -> Doc a
printQualified (Qualified (Qualifier Absolute []) unqualifiedName) = printUnqualified unqualifiedName
printQualified (Qualified qualifier unqualifiedName) =
  printQualifier qualifier <> "::" <> printUnqualified unqualifiedName

printQualifier :: Qualifier -> Doc a
printQualifier (Qualifier Absolute parts) = printQualifier $ Qualifier Relative ("_" : parts)
printQualifier (Qualifier Relative parts) =
  pretty $ Text.intercalate "::" parts

printOrigin :: Origin.Origin -> Doc a
printOrigin origin =
  hsep $
    [ pretty $ Origin.name origin,
      ":",
      pretty al,
      ".",
      pretty ac,
      "-"
    ]
      ++ (if al == bl then [pretty bc] else [pretty bl, ".", pretty bc])
  where
    al = Origin.beginLine origin
    bl = Origin.endLine origin
    ac = Origin.beginColumn origin
    bc = Origin.endColumn origin

printCategory :: Category.Category -> Doc a
printCategory Category.Constructor = "constructor"
printCategory Category.Instance = "instance"
printCategory Category.Permission = "permission"
printCategory Category.Word = "word"

printKind :: Kind -> Doc a
printKind Value = "value"
printKind Stack = "stack"
printKind Label = "label"
printKind Permission = "permission"
printKind (a :-> b) =
  parens $
    printKind a <+> "->" <+> printKind b

printUnqualified :: Unqualified -> Doc a
printUnqualified (Unqualified unqualified) = pretty unqualified

printGeneralName :: GeneralName -> Doc a
printGeneralName (QualifiedName qualified) = printQualified qualified
printGeneralName (UnqualifiedName unqualified) = printUnqualified unqualified
printGeneralName (LocalName index) = printLocalIndex index

printLocalIndex :: LocalIndex -> Doc a
printLocalIndex (LocalIndex i) = "local." <> pretty i

printClosureIndex :: ClosureIndex -> Doc a
printClosureIndex (ClosureIndex i) = "closure." <> pretty i

printClosed :: Closed -> Doc a
printClosed (ClosedLocal index) = printLocalIndex index
printClosed (ClosedClosure index) = printClosureIndex index

printSynonym :: Synonym -> Doc a
printSynonym (Synonym name1 name2 _) = "synonym" <+> printQualified name1 <> printGeneralName name2

printConstructor :: Constructor -> Doc a
printConstructor (Constructor name) = printQualified name

printType :: Type -> Doc a
printType type0 = recur type0
  where
    context = buildContext type0
    recur typ = case typ of
      TypeConstructor _ "Fun" :@ a :@ b :@ p ->
        parens $
          recur a <+> "->" <> recur b <+> recur p
      TypeConstructor _ "Fun" :@ a :@ b ->
        parens $
          recur a <+> "->" <+> recur b
      TypeConstructor _ "Fun" :@ a ->
        parens $
          recur a <+> "->"
      TypeConstructor _ "Fun" -> parens "->"
      TypeConstructor _ "Prod" :@ a :@ b ->
        recur a <+> comma <+> recur b
      TypeConstructor _ "Prod" :@ a ->
        parens $ recur a <+> ", "
      TypeConstructor _ "Prod" ->
        parens ","
      TypeConstructor _ "Sum" :@ a :@ b ->
        recur a <+> "|" <+> recur b
      TypeConstructor _ "Join" :@ a :@ b ->
        "+" <> recur a <+> recur b
      TypeConstructor _ "Join" :@ a ->
        parens $ "+" <> recur a
      a :@ b -> recur a <> brackets (recur b)
      TypeConstructor _ constructor -> printConstructor constructor
      TypeVar _ var@(Var name i k) ->
        -- The default cases here shouldn't happen if the context was built
        -- correctly, so it's fine if we fall back to something ugly.
        fromMaybe (printVar var) $ do
          ids <- HashMap.lookup name context
          case ids of
            -- Only one variable with this name: print without index.
            [(i', _)] | i == i' -> pure $ prettyKinded name k
            -- No variables with this name: ugly-print.
            [] -> pure $ printVar var
            -- Multiple variables with this name: print with index.
            _list -> do
              index <- findIndex ((== i) . fst) ids
              let Unqualified unqualified = name
              pure $
                prettyKinded
                  ( Unqualified
                      (unqualified <> "_" <> show (index + 1))
                  )
                  k
      TypeConstant o var -> "∃" <> recur (TypeVar o var)
      Forall {} -> prettyForall typ []
        where
          prettyForall (Forall _ x t) vars = prettyForall t (x : vars)
          prettyForall t vars =
            list (map (recur . TypeVar (Type.origin t)) vars)
              <> parens (recur t)
      TypeValue _ value -> pretty value

type PrettyContext = HashMap Unqualified [(TypeId, Kind)]

buildContext :: Type -> PrettyContext
buildContext = go mempty
  where
    go :: PrettyContext -> Type -> PrettyContext
    go context typ = case typ of
      a :@ b -> go context a <> go context b
      TypeConstructor {} -> context
      TypeVar _ (Var name i k) -> record name i k context
      TypeConstant _ (Var name i k) -> record name i k context
      Forall _ (Var name i k) t -> go (record name i k context) t
      TypeValue {} -> context
      where
        record name i k = HashMap.insertWith (<>) name [(i, k)]

printTypeId :: TypeId -> Doc a
printTypeId (TypeId i) = "T" <> pretty i

printVar :: Var -> Doc a
printVar (Var (Unqualified unqualified) i k) =
  prettyKinded
    ( Unqualified $
        mconcat
          [ unqualified,
            "_",
            show $ printTypeId i
          ]
    )
    k

prettyKinded :: Unqualified -> Kind -> Doc a
prettyKinded name k = case k of
  Permission -> "+" <> printUnqualified name
  Stack -> printUnqualified name <> "..."
  _otherKind -> printUnqualified name

printConstraint :: Constraint -> Doc a
printConstraint (Constraint name params) = printUnqualified name <> list (map printParameter params)

printSignature :: Signature -> Doc a
printSignature (Application firstA b _) =
  printSignature finalA <> list (map printSignature (as ++ [b]))
  where
    (finalA, as) = go [] firstA
    go l (Application x y _) = go (l ++ [y]) x
    go l x = (x, l)
printSignature (Bottom _) = "<bottom>"
printSignature (Function as bs es _) =
  parens $
    maybeSpace (hsep . punctuate comma . map printSignature) as
      <> "->"
      <> spaceMaybe (hsep . punctuate comma . map printSignature) bs
      <> spaceMaybe (hsep . map (("+" <>) . printGeneralName)) es
printSignature (Quantified names constraints typ _) =
  list (map printParameter names)
    <+> printSignature typ
    <> if not $ null constraints then " where" <+> hsep (map printConstraint constraints) else emptyDoc
printSignature (Variable name _) = printGeneralName name
printSignature (StackFunction r as s bs es _) =
  parens $
    (hsep . punctuate comma) ((printSignature r <> "...") : map printSignature as)
      <+> "->"
      <+> hsep (punctuate comma ((printSignature s <> "...") : map printSignature bs) ++ map (("+" <>) . printGeneralName) es)
printSignature (Type t) = printType t

printToken :: Token.Token l -> Doc a
printToken = \case
  Token.About -> "about"
  Token.AngleBegin -> "<"
  Token.AngleEnd -> ">"
  Token.Arrow -> "->"
  Token.As -> "as"
  Token.BlockBegin -> "{"
  Token.BlockEnd -> "}"
  Token.Case -> "case"
  Token.Character c -> squotes $ pretty c
  Token.Colon -> ":"
  Token.Comma -> ","
  Token.Define -> "define"
  Token.Do -> "do"
  Token.Ellipsis -> "..."
  Token.Else -> "else"
  Token.Float a -> pretty (floatValue a :: Double)
  Token.GroupBegin -> "("
  Token.GroupEnd -> ")"
  Token.If -> "if"
  Token.Ignore -> "_"
  Token.Instance -> "instance"
  Token.Integer literal -> printIntegerLiteral literal
  Token.Intrinsic -> "intrinsic"
  Token.Match -> "match"
  Token.Operator name -> printUnqualified name
  Token.Permission -> "permission"
  Token.Reference -> "\\"
  Token.Return -> "return"
  Token.Synonym -> "synonym"
  Token.Text t -> dquotes $ pretty t
  Token.Trait -> "trait"
  Token.Type -> "type"
  Token.VectorBegin -> "["
  Token.VectorEnd -> "]"
  Token.Vocab -> "vocab"
  Token.VocabLookup -> "::"
  Token.Where -> "where"
  Token.With -> "with"
  Token.Word name -> printUnqualified name

-- Minor hack because Parsec requires 'Show'.
instance Show (Token.Token l) where
  show = show . printToken

printInstantiated :: Instantiated -> Doc a
printInstantiated (Instantiated n ts) =
  printQualified n <> "::" <> list (map printType ts) <> ""

printDataConstructor :: DataConstructor.DataConstructor -> Doc a
printDataConstructor (DataConstructor.DataConstructor fields name _) =
  "case"
    <+> printUnqualified name
    <> printedFields
  where
    printedFields = if not $ null fields then space <> tupled (map printSignature fields) else ""

printDeclaration :: Declaration -> Doc a
printDeclaration (Declaration category name _ signature) = printedCategory <+> printUnqualified (unqualifiedName name) <+> printSignature signature
  where
    printedCategory = case category of
      Declaration.Trait -> "trait"
      Declaration.Intrinsic -> "intrinsic"

printTypeDefinition :: TypeDefinition -> Doc a
printTypeDefinition (TypeDefinition constructors name _ parameters) =
  blockMaybeMulti ("type" <+> typeName) printDataConstructor constructors
  where
    typeName =
      printQualified name
        <> if not $ null $ fst parameters then (list . map printParameter . fst) parameters else ""

printTerm :: Term a -> Doc b
printTerm t = fromMaybe "" (maybePrintTerm t)

maybePrintTerm :: Term a -> Maybe (Doc b)
maybePrintTerm t = case Term.decompose t of
  [] -> Nothing
  (Group a : Match BooleanMatch _ cases _ _ : xs) -> printIf (Just a) cases `justVertical` xs
  (Group a : Match AnyMatch _ cases (DefaultElse _ _) _ : xs) -> printMatch (Just a) cases Nothing `justVertical` xs
  (Group a : Match AnyMatch _ cases (Else elseBody _) _ : xs) -> printMatch (Just a) cases (Just elseBody) `justVertical` xs
  (Push _ (Quotation body) _ : Group a : xs) -> printDo a body `vertical` xs
  (Coercion (AnyCoercion (Quantified [Parameter _ r1 Stack, Parameter _ s1 Stack] [] (Function [StackFunction (Variable r2 _) [] (Variable s2 _) [] grantNames _] [StackFunction (Variable r3 _) [] (Variable s3 _) [] revokeNames _] [] _) _)) _ _ : Word _ _ (QualifiedName (Qualified _ u)) _ _ : xs)
    | r1 == "R" && s1 == "S" && r2 == "R" && s2 == "S" && r3 == "R" && s3 == "S" && u == "call" ->
      ("with" <> space <> tupled (map (\g -> "+" <> printGeneralName g) grantNames ++ map (\r -> "-" <> printGeneralName r) revokeNames)) `justHoriz` xs
  (Coercion (AnyCoercion _) _ _ : xs) -> nothingHoriz xs
  (Group a : xs) -> printGroup a `horiz` xs
  (Lambda _ name _ body _ : xs) -> printLambda name body `justHoriz` xs
  (Match BooleanMatch _ cases _ _ : xs) -> printIf Nothing cases `justVertical` xs
  (Match AnyMatch _ cases (DefaultElse _ _) _ : xs) -> vsep [printMatch Nothing cases Nothing] `justVertical` xs
  (Match AnyMatch _ cases (Else elseBody _) _ : xs) -> vsep [printMatch Nothing cases (Just elseBody)] `justVertical` xs
  (Push _ value _ : xs) -> printValue value `justHoriz` xs
  (Word _ Operator.Postfix (QualifiedName (Qualified _ name)) [] o : xs)
    | name == "drop" -> do
      let lambda = printToken Token.Arrow <+> hsep (punctuate comma (reverse (map printUnqualified (name : names)))) <> semi
      ( case maybePrintTerm newBody of
          Nothing -> Just lambda
          Just a -> Just (vsep [lambda, a])
        )
    where
      (names, newBody) = go [] (Term.compose () o (map Term.stripMetadata xs))
      go ns (Lambda _ n _ b _) = go (n : ns) b
      go ns b = (ns, b)
  (Word _ fixity name args _ : xs) -> printWord fixity name args `justHoriz` xs
  (New _ (ConstructorIndex i) _ _ : xs) -> printNew i `justHoriz` xs
  (NewClosure _ i _ : xs) -> printClosure i `justHoriz` xs
  (NewVector _ i _ _ : xs) -> printVector i `justHoriz` xs
  _ -> error "Formatting failed"
  where
    nothingHoriz :: [Term a] -> Maybe (Doc b)
    nothingHoriz l = case mapMaybe maybePrintTerm l of
      [] -> Nothing
      xs -> Just $ hsep xs

    horiz :: Maybe (Doc b) -> [Term a] -> Maybe (Doc b)
    horiz = \case
      Nothing -> nothingHoriz
      Just a -> justHoriz a

    justHoriz :: Doc b -> [Term a] -> Maybe (Doc b)
    justHoriz a l = Just $ case mapMaybe maybePrintTerm l of
      [] -> a
      xs -> hsep (a : xs)

    nothingVertical :: [Term a] -> Maybe (Doc b)
    nothingVertical l = case mapMaybe maybePrintTerm l of
      [] -> Nothing
      xs -> Just $ vsep xs

    vertical :: Maybe (Doc b) -> [Term a] -> Maybe (Doc b)
    vertical = \case
      Nothing -> nothingVertical
      Just a -> justVertical a

    justVertical :: Doc b -> [Term a] -> Maybe (Doc b)
    justVertical a l = Just $ case mapMaybe maybePrintTerm l of
      [] -> a
      xs -> vsep (a : xs)

printDo :: Term a -> Term a -> Maybe (Doc b)
printDo a body = includeBlockMaybe (maybe "do" ("do" <+>) (printGroup a)) (maybePrintTerm body)

printGroup :: Term a -> Maybe (Doc b)
printGroup (Group a) = printGroup a
printGroup a = parens <$> maybePrintTerm a

printLambda :: Unqualified -> Term a -> Doc b
printLambda name body = do
  let lambda = printToken Token.Arrow <+> hsep (punctuate comma (reverse (map printUnqualified (name : names)))) <> semi
  case maybePrintTerm newBody of
    Nothing -> lambda
    Just a -> vsep [lambda, a]
  where
    (names, newBody) = go [] body
    go ns (Lambda _ n _ b _) = go (n : ns) b
    go ns b = (ns, b)

printIf :: Maybe (Term a) -> [Case a] -> Doc b
printIf cond [Case _ trueBody _, Case _ falseBody _] =
  vsep $
    blockMaybe
      (maybe "if" ("if" <+>) (cond >>= printGroup))
      (maybePrintTerm trueBody) :
    maybeToList (includeBlockMaybe "else" (maybePrintTerm falseBody))
printIf _ _ = error "Expected a true and false case"

printMatch :: Maybe (Term a) -> [Case a] -> Maybe (Term a) -> Doc b
printMatch cond cases else_ =
  nestTwo $
    vsep
      ( (maybe "match" ("match" <+>) (cond >>= printGroup) <> colon) :
        catMaybes
          ( map
              (\(Case n b _) -> includeBlockMaybe ("case" <+> printGeneralName n) (maybePrintTerm b))
              cases
              ++ maybe [] (\e -> [includeBlockMaybe "else" (maybePrintTerm e)]) else_
          )
      )

printWord :: Operator.Fixity -> GeneralName -> [Type] -> Doc a
printWord Operator.Postfix (UnqualifiedName (Unqualified name)) []
  | not (Text.all isLetter name) = parens $ pretty name
printWord _ word [] = printGeneralName word
printWord _ word args = printGeneralName word <> "::" <> list (map printType args)

printNew :: Int -> Doc a
printNew i = "new" <> dot <> pretty i

printClosure :: Int -> Doc a
printClosure i = "new" <> dot <> "closure" <> dot <> pretty i

printVector :: Int -> Doc a
printVector 0 = lbracket <> rbracket
printVector i = "new" <> dot <> "vec" <> dot <> pretty i

printValue :: Value a -> Doc b
printValue value = case value of
  Capture names term ->
    "$"
      <> tupled (map printClosed names)
      <> braces (printTerm term)
  Character c -> squotes (pretty c)
  Closed (ClosureIndex index) -> "closure" <> dot <> pretty index
  Float f -> printFloatLiteral f
  Integer i -> printIntegerLiteral i
  Local (LocalIndex index) -> "local" <> dot <> pretty index
  Name n -> backslash <> printQualified n
  Quotation w@Word {} -> backslash <> printTerm w
  Quotation body -> lbrace <+> printTerm body <+> rbrace
  Text text -> (if Text.count "\n" text > 1 then multiline else singleline) text
    where
      multiline :: Text -> Doc a
      multiline t = vsep ([multilineQuote] ++ map pretty (lines t) ++ [multilineQuote])
        where
          multilineQuote = dquote <> dquote <> dquote

      singleline :: Text -> Doc a
      singleline t = dquotes $ pretty t

printMetadata :: Metadata -> Doc a
printMetadata metadata =
  nestTwo $
    vsep $
      ("about" <+> printGeneralName (Metadata.name metadata) <> colon) :
      map
        (\(key, term) -> blockMaybe (printUnqualified key) (maybePrintTerm term))
        ( HashMap.toList $
            fields metadata
        )

printDefinition :: (Show a) => Definition a -> Doc b
printDefinition (Definition Category.Constructor _ _ _ _ _ _ _ _) = emptyDoc
printDefinition (Definition Category.Permission name body _ _ _ _ signature _) =
  blockMaybe ("permission" <+> (printQualified name <+> printSignature signature)) (maybePrintTerm body)
printDefinition (Definition Category.Instance name body _ _ _ _ signature _) =
  blockMaybe ("instance" <+> (printQualified name <+> printSignature signature)) (maybePrintTerm body)
printDefinition (Definition Category.Word name body _ _ _ _ _ _)
  | name == mainName = printTerm body
printDefinition (Definition Category.Word name body _ _ _ _ signature _) =
  blockMaybe ("define" <+> (printQualified name <+> printSignature signature)) (maybePrintTerm body)

printEntry :: Entry -> Doc a
printEntry (Entry.Word category _ origin mParent mSignature _) =
  vsep
    [ printCategory category,
      hsep ["defined at", printOrigin origin],
      case mSignature of
        Just signature ->
          hsep
            ["with signature", dquotes $ printSignature signature]
        Nothing -> "with no signature",
      case mParent of
        Just parent ->
          hsep
            [ "with parent",
              case parent of
                Parent.Trait a -> "trait" <+> printQualified a
                Parent.Type a -> "type" <+> printQualified a
            ]
        Nothing -> "with no parent"
    ]
printEntry (Entry.Metadata origin term) =
  vsep
    [ "metadata",
      hsep ["defined at", printOrigin origin],
      hsep ["with contents", printTerm term]
    ]
printEntry (Entry.Synonym origin name) =
  vsep
    [ "synonym",
      hsep ["defined at", printOrigin origin],
      hsep ["standing for", printQualified name]
    ]
printEntry (Entry.Trait origin signature) =
  vsep
    [ "trait",
      hsep ["defined at", printOrigin origin],
      hsep ["with signature", printSignature signature]
    ]
printEntry (Entry.Type origin parameters constraints ctors) =
  vsep
    [ "type",
      hsep ["defined at", printOrigin origin],
      hsep $
        "with parameters [" :
        intersperse ", " (map printParameter parameters)
          ++ ["] constrained so that "]
          ++ intersperse "," (map printConstraint constraints),
      nestTwo $ vsep $ "and data constructors" : map constructor ctors
    ]
  where
    constructor ctor =
      hsep
        [ printUnqualified $ DataConstructor.name ctor,
          " with fields (",
          hsep $
            intersperse ", " $
              map printSignature $ DataConstructor.fields ctor,
          ")"
        ]
printEntry (Entry.InstantiatedType origin size) =
  vsep
    [ "instantiated type",
      hsep ["defined at", printOrigin origin],
      hsep ["with size", pretty size]
    ]

printFragment :: (Show a, Ord a) => Fragment a -> Doc b
printFragment fragment =
  vcat
    ( map
        (\g -> printGrouped g <> line)
        groupedDeclarations
        ++ map
          (\s -> printSynonym s <> line)
          ( sort (synonyms fragment)
          )
        ++ map
          (\t -> printTypeDefinition t <> line)
          ( sort (Fragment.types fragment)
          )
        ++ map
          (\d -> printDefinition d <> line)
          ( sort (definitions fragment)
          )
        ++ map
          (\m -> printMetadata m <> line)
          ( sort (metadata fragment)
          )
    )
  where
    groupedDeclarations = groupBy (\a b -> (qualifierName . Declaration.name) a == (qualifierName . Declaration.name) b) (declarations fragment)
    printGrouped decls =
      if noVocab
        then vsep (map (\d -> printDeclaration d <> line) $ sort decls)
        else nestTwo $ vsep $ ("vocab" <+> printQualifier commonName <> ":") : map printDeclaration (sort decls)
      where
        (commonName, noVocab) = case qualifierName $ Declaration.name $ decls Unsafe.!! 0 of
          (Qualifier Absolute parts) -> (Qualifier Relative parts, null parts)
          n -> (n, False)

nestTwo :: Doc a -> Doc a
nestTwo = nest 2

blockMaybe :: Doc a -> Maybe (Doc a) -> Doc a
blockMaybe d Nothing = d <+> lbrace <> rbrace
blockMaybe d (Just b) = nestTwo (vsep [d <> colon, b])

blockMaybeMulti :: Doc a -> (b -> Doc a) -> [b] -> Doc a
blockMaybeMulti d f l = case l of
  [] -> d <+> lbrace <> rbrace
  xs -> nestTwo (vsep ((d <> colon) : map f xs))

includeBlockMaybe :: Doc a -> Maybe (Doc a) -> Maybe (Doc a)
includeBlockMaybe _ Nothing = Nothing
includeBlockMaybe d (Just b) = Just $ nestTwo (vsep [d <> colon, b])

spaceMaybe :: ([b] -> Doc a) -> [b] -> Doc a
spaceMaybe _ [] = ""
spaceMaybe f l = space <> f l

maybeSpace :: ([b] -> Doc a) -> [b] -> Doc a
maybeSpace _ [] = ""
maybeSpace f l = f l <> space