{-# LANGUAGE TemplateHaskell #-}

-- |
-- Module      : Mlatu.Name
-- Description : Program identifiers
-- Copyright   : (c) Caden Haustin, 2021
-- License     : MIT
-- Maintainer  : mlatu@brightlysalty.33mail.com
-- Stability   : experimental
-- Portability : GHC
module Mlatu.Name
  ( GeneralName (..),
    Closed (..),
    ClosureIndex (..),
    ConstructorIndex (..),
    LocalIndex (..),
    Qualified (..),
    Qualifier (..),
    Root (..),
    Unqualified (..),
    isOperatorName,
    toParts,
    qualifiedFromQualifier,
    qualifierFromName,
    unqualifiedName,
    qualifierName,
    _Relative,
    _Absolute,
    _ClosedLocal,
    _ClosedClosure,
    _QualifiedName,
    _UnqualifiedName,
  _LocalName
  )
where

import Data.Char (isLetter)
import Data.Text qualified as Text
import Optics (view)
import Optics.TH (makeLenses, makePrisms)
import Relude
import Text.PrettyPrint qualified as Pretty
import Text.PrettyPrint.HughesPJClass (Pretty (..))

-- | An index into a closure.
newtype ClosureIndex = ClosureIndex Int
  deriving (Eq, Ord, Show)

-- | The index of a data type constructor.
newtype ConstructorIndex = ConstructorIndex Int
  deriving (Eq, Ord, Show)

-- | The De Bruijn index of a local variable.
newtype LocalIndex = LocalIndex Int
  deriving (Eq, Ord, Show)

-- | A qualifier is a list of vocabulary names, rooted globally or within the
-- current vocabulary.
data Qualifier = Qualifier !Root ![Text]
  deriving (Eq, Ord, Show)

-- | A 'Relative' qualifier refers to a sub-vocabulary of the current one. An
-- 'Absolute' qualifier refers to the global vocabulary.
data Root = Relative | Absolute
  deriving (Eq, Ord, Show)

makePrisms ''Root

-- | An unqualified name is an ordinary symbol.
newtype Unqualified = Unqualified Text
  deriving (Eq, Ord, Show)

-- | A closed name is a local or closure variable that was captured by a
-- quotation. FIXME: this can be removed if closure variables are rewritten into
-- implicit locals.
data Closed
  = ClosedLocal !LocalIndex
  | ClosedClosure !ClosureIndex
  deriving (Eq, Show)

makePrisms ''Closed

-- | A qualified name is an unqualified name (@x@) plus a qualifier (@q::@).
data Qualified = Qualified
  { _qualifierName :: !Qualifier,
    _unqualifiedName :: !Unqualified
  }
  deriving (Eq, Ord, Show)

makeLenses ''Qualified

-- | A dynamic name, which might be 'Qualified', 'Unqualified', or local.
data GeneralName
  = QualifiedName !Qualified
  | UnqualifiedName !Unqualified
  | LocalName !LocalIndex
  deriving (Eq, Ord, Show)

makePrisms ''GeneralName

instance IsString GeneralName where
  fromString = UnqualifiedName . fromString

-- TODO: Use types, not strings.
isOperatorName :: Qualified -> Bool
isOperatorName = match . view unqualifiedName
  where
    match (Unqualified name) =
      not $
        liftA2 (||) (Text.all isLetter) (== "_") $
          Text.take 1 name

toParts :: Qualified -> [Text]
toParts (Qualified (Qualifier _root parts) (Unqualified part)) =
  parts ++ [part]

qualifiedFromQualifier :: Qualifier -> Maybe Qualified
qualifiedFromQualifier (Qualifier root parts) =
  viaNonEmpty
    ( \nonEmptyParts ->
        Qualified
          (Qualifier root (init nonEmptyParts))
          ( Unqualified (last nonEmptyParts)
          )
    )
    parts

qualifierFromName :: Qualified -> Qualifier
qualifierFromName (Qualified (Qualifier root parts) (Unqualified name)) =
  Qualifier root (parts ++ [name])

instance Hashable Qualified where
  hashWithSalt s (Qualified qualifier unqualified) =
    hashWithSalt s (0 :: Int, qualifier, unqualified)

instance Hashable Qualifier where
  hashWithSalt s (Qualifier root parts) =
    hashWithSalt s (0 :: Int, root, Text.concat parts)

instance Hashable Root where
  hashWithSalt s Relative = hashWithSalt s (0 :: Int)
  hashWithSalt s Absolute = hashWithSalt s (1 :: Int)

instance Hashable Unqualified where
  hashWithSalt s (Unqualified name) = hashWithSalt s (0 :: Int, name)

instance IsString Unqualified where
  fromString = Unqualified . toText

instance Pretty Qualified where
  pPrint (Qualified qualifier unqualified) =
    pPrint qualifier
      <> "::"
      <> pPrint unqualified

instance Pretty Qualifier where
  pPrint (Qualifier Absolute parts) = pPrint $ Qualifier Relative $ "_" : parts
  pPrint (Qualifier Relative parts) =
    Pretty.text $
      toString $ Text.intercalate "::" parts

instance Pretty Unqualified where
  pPrint (Unqualified unqualified) = Pretty.text $ toString unqualified

instance Pretty GeneralName where
  pPrint (QualifiedName qualified) = pPrint qualified
  pPrint (UnqualifiedName unqualified) = pPrint unqualified
  pPrint (LocalName index) = pPrint index

instance Pretty LocalIndex where
  pPrint (LocalIndex i) = "local." Pretty.<> Pretty.int i

instance Pretty ClosureIndex where
  pPrint (ClosureIndex i) = "closure." Pretty.<> Pretty.int i

instance Pretty Closed where
  pPrint (ClosedLocal index) = pPrint index
  pPrint (ClosedClosure (ClosureIndex index)) = pPrint index
