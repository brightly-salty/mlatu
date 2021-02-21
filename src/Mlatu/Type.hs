-- |
-- Module      : Mlatu.Type
-- Description : Types
-- Copyright   : (c) Caden Haustin, 2021
-- License     : MIT
-- Maintainer  : mlatu@brightlysalty.33mail.com
-- Stability   : experimental
-- Portability : GHC
module Mlatu.Type
  ( Constructor (..),
    Type (..),
    TypeId (..),
    Var (..),
    bottom,
    fun,
    join,
    prod,
    setOrigin,
    origin,
  )
where

import Data.HashMap.Strict qualified as HashMap
import Data.List (findIndex)
import Mlatu.Kind (Kind (..))
import Mlatu.Name (Qualified (..), Unqualified (..))
import Mlatu.Origin (Origin)
import Mlatu.Pretty qualified as Pretty
import Mlatu.Vocabulary qualified as Vocabulary
import Relude hiding (Type, join, void)
import Text.PrettyPrint qualified as Pretty
import Text.PrettyPrint.HughesPJClass (Pretty (..))

-- | This is the type language. It describes a system of conventional Hindley–
-- Milner types, with type constructors joined by type application, as well as
-- type variables and constants for constraint solving and instance checking,
-- respectively. It syntactically permits higher-ranked quantification, though
-- there are semantic restrictions on this, discussed in the presentation of the
-- inference algorithm. Type variables have explicit kinds.
data Type
  = !Type :@ !Type
  | TypeConstructor !Origin !Constructor
  | TypeVar !Origin !Var
  | TypeConstant !Origin !Var
  | Forall !Origin !Var !Type
  | TypeValue !Origin !Int
  deriving (Ord, Show)

infixl 1 :@

newtype Constructor = Constructor Qualified
  deriving (Ord, Eq, Hashable, Show)

data Var = Var
  { varNameHint :: !Unqualified,
    varTypeId :: !TypeId,
    varKind :: !Kind
  }
  deriving (Ord, Show)

instance Eq Var where
  -- We ignore the name hint for equality tests.
  Var _ a b == Var _ c d = (a, b) == (c, d)

bottom :: Origin -> Type
bottom o = TypeConstructor o "Bottom"

fun :: Origin -> Type -> Type -> Type -> Type
fun o a b e = TypeConstructor o "Fun" :@ a :@ b :@ e

prod :: Origin -> Type -> Type -> Type
prod o a b = TypeConstructor o "Prod" :@ a :@ b

join :: Origin -> Type -> Type -> Type
join o a b = TypeConstructor o "Join" :@ a :@ b

origin :: Type -> Origin
origin = \case
  a :@ _ -> origin a
  TypeConstructor o _ -> o
  TypeVar o _ -> o
  TypeConstant o _ -> o
  Forall o _ _ -> o
  TypeValue o _ -> o

setOrigin :: Origin -> Type -> Type
setOrigin o = go
  where
    go = \case
      a :@ b -> go a :@ go b
      TypeConstructor _ constructor -> TypeConstructor o constructor
      TypeVar _ var -> TypeVar o var
      TypeConstant _ var -> TypeConstant o var
      Forall _ var t -> Forall o var $ go t
      TypeValue _ x -> TypeValue o x

-- | Type variables are distinguished by globally unique identifiers. This makes
-- it easier to support capture-avoiding substitution on types.
newtype TypeId = TypeId Int
  deriving (Enum, Bounded, Eq, Hashable, Ord, Show)

instance Eq Type where
  (a :@ b) == (c :@ d) = (a, b) == (c, d)
  TypeConstructor _ a == TypeConstructor _ b = a == b
  TypeVar _ a == TypeVar _ b = a == b
  TypeConstant _ a == TypeConstant _ b = a == b
  Forall _ a b == Forall _ c d = (a, b) == (c, d)
  _ == _ = False

instance Hashable Type where
  hashWithSalt s = \case
    a :@ b -> hashWithSalt s (0 :: Int, a, b)
    TypeConstructor _ a -> hashWithSalt s (1 :: Int, a)
    TypeVar _ a -> hashWithSalt s (2 :: Int, a)
    TypeConstant _ a -> hashWithSalt s (3 :: Int, a)
    Forall _ a b -> hashWithSalt s (4 :: Int, a, b)
    TypeValue _ a -> hashWithSalt s (5 :: Int, a)

instance Hashable Var where
  -- We ignore the name hint when hashing.
  hashWithSalt s (Var _ a b) = hashWithSalt s (0 :: Int, a, b)

instance IsString Constructor where
  fromString =
    Constructor
      . Qualified Vocabulary.global
      . Unqualified
      . toText

instance Pretty Constructor where
  pPrint (Constructor name) = pPrint name

instance Pretty Type where
  pPrint type0 = recur type0
    where
      context = buildContext type0
      recur typ = case typ of
        TypeConstructor _ "Fun" :@ a :@ b :@ p ->
          Pretty.parens $
            Pretty.hsep [recur a, "->", recur b, recur p]
        TypeConstructor _ "Fun" :@ a :@ b ->
          Pretty.parens $
            Pretty.hsep [recur a, "->", recur b]
        TypeConstructor _ "Fun" :@ a ->
          Pretty.parens $
            Pretty.hsep [recur a, "->"]
        TypeConstructor _ "Fun" -> Pretty.parens "->"
        TypeConstructor _ "Prod" :@ a :@ b ->
          Pretty.hcat [recur a, ", ", recur b]
        TypeConstructor _ "Prod" :@ a ->
          Pretty.parens $ Pretty.hcat [recur a, ", "]
        TypeConstructor _ "Prod" ->
          Pretty.parens ","
        TypeConstructor _ "Sum" :@ a :@ b ->
          Pretty.hcat [recur a, " | ", recur b]
        TypeConstructor _ "Join" :@ a :@ b ->
          Pretty.hcat ["+", recur a, " ", recur b]
        TypeConstructor _ "Join" :@ a ->
          Pretty.parens $ Pretty.hcat ["+", recur a]
        a :@ b -> Pretty.hcat [recur a, Pretty.brackets $ recur b]
        TypeConstructor _ constructor -> pPrint constructor
        TypeVar _ var@(Var name i k) ->
          -- The default cases here shouldn't happen if the context was built
          -- correctly, so it's fine if we fall back to something ugly.
          fromMaybe (pPrint var) $ do
            ids <- HashMap.lookup name context
            case ids of
              -- Only one variable with this name: print without index.
              [(i', _)] | i == i' -> pure $ prettyKinded name k
              -- No variables with this name: ugly-print.
              [] -> pure $ pPrint var
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
        TypeConstant o var -> Pretty.hcat ["∃", recur $ TypeVar o var]
        Forall {} -> prettyForall typ []
          where
            prettyForall (Forall _ x t) vars = prettyForall t (x : vars)
            prettyForall t vars =
              Pretty.hcat
                [ Pretty.brackets $
                    Pretty.list $
                      map (recur . TypeVar (origin t)) vars,
                  Pretty.parens $ recur t
                ]
        TypeValue _ value -> Pretty.int value

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

instance Pretty TypeId where
  pPrint (TypeId i) = Pretty.hcat [Pretty.char 'T', Pretty.int i]

instance Pretty Var where
  pPrint (Var (Unqualified unqualified) i k) =
    prettyKinded
      ( Unqualified $
          mconcat
            [ unqualified,
              "_",
              toText $ Pretty.render $ pPrint i
            ]
      )
      k

prettyKinded :: Unqualified -> Kind -> Pretty.Doc
prettyKinded name k = Pretty.hcat $ case k of
  Permission -> ["+", pPrint name]
  Stack -> [pPrint name, "..."]
  _otherKind -> [pPrint name]
