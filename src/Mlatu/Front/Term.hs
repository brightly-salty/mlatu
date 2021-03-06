{-# LANGUAGE GADTs #-}
{-# LANGUAGE StrictData #-}

-- |
-- Module      : Mlatu.Term
-- Description : The core language
-- Copyright   : (c) Caden Haustin, 2021
-- License     : MIT
-- Maintainer  : mlatu@brightlysalty.33mail.com
-- Stability   : experimental
-- Portability : GHC
module Mlatu.Front.Term
  ( CoercionHint (..),
    Permit (..),
    Term (..),
    Value (..),
    Specialness (..),
    asCoercion,
    compose,
    decompose,
    identityCoercion,
    origin,
    permissionCoercion,
    quantifierCount,
    stripMetadata,
    stripValue,
    typ,
    defaultElseBody,
  )
where

import Data.List (partition)
import Mlatu.Base.Kind qualified as Kind
import Mlatu.Base.Name
  ( Closed,
    ClosureIndex (..),
    ConstructorIndex (..),
    GeneralName (..),
    LocalIndex (..),
    Qualified (..),
    Unqualified (..),
  )
import Mlatu.Base.Origin (Origin)
import Mlatu.Base.Type (Type, TypeId)
import Mlatu.Base.Vocabulary
import Mlatu.Front.Parameter (Parameter (..))
import Mlatu.Front.Signature (Signature)
import Mlatu.Front.Signature qualified as Signature

-- | This is the core language. It permits pushing values to the stack, invoking
-- definitions, and moving values between the stack and local variables.
--
-- It also permits empty programs and program concatenation. Together these form
-- a monoid over programs. The denotation of the concatenation of two programs
-- is the composition of the denotations of those two programs. In other words,
-- there is a homomorphism from the syntactic monoid onto the semantic monoid.
--
-- A value of type @'Term' a@ is a term annotated with a value of type @a@. A
-- parsed term may have a type like @'Term' ()@, while a type-inferred term may
-- have a type like @'Term' 'Type'@.
data Term a where
  Coercion :: Origin -> a -> CoercionHint -> Term a
  Compose :: a -> Term a -> Term a -> Term a
  Generic :: Origin -> Unqualified -> TypeId -> Term a -> Term a
  Group :: Term a -> Term a
  Lambda :: Origin -> a -> Unqualified -> a -> Term a -> Term a
  Match :: Origin -> a -> [(Origin, GeneralName, Term a)] -> (Origin, Either a (Term a)) -> Term a
  New :: Origin -> a -> ConstructorIndex -> Int -> Specialness -> Term a
  NewClosure :: Origin -> a -> Int -> Term a
  Push :: Origin -> a -> Value a -> Term a
  Word :: Origin -> a -> GeneralName -> [Type] -> Term a
  deriving (Ord, Eq, Show)

data Specialness = NatLike | ListLike | NonSpecial
  deriving (Ord, Eq, Show)

-- | The type of coercion to perform.
data CoercionHint
  = -- | The identity coercion, generated by empty terms.
    IdentityCoercion
  | -- | A coercion to a particular type.
    AnyCoercion !Signature
  deriving (Ord, Eq, Show)

defaultElseBody :: Origin -> a -> Term a
defaultElseBody o a = Word o a (QualifiedName (Global "abort-now")) []

-- | A permission to grant or revoke in a @with@ expression.
data Permit = Permit
  { permitted :: !Bool,
    permitName :: !GeneralName
  }
  deriving (Ord, Eq, Show)

-- | A value, used to represent literals in a parsed program, as well as runtime
-- values in the interpreter.
data Value a where
  Capture :: [Closed] -> Term a -> Value a
  Character :: Char -> Value a
  Closed :: ClosureIndex -> Value a
  Local :: LocalIndex -> Value a
  Name :: Qualified -> Value a
  Quotation :: Term a -> Value a
  Text :: Text -> Value a
  deriving (Ord, Eq, Show)

compose :: Origin -> a -> [Term a] -> Term a
compose o x = foldr (Compose x) (identityCoercion o x)

asCoercion :: Origin -> a -> [Signature] -> Term a
asCoercion o x ts = Coercion o x (AnyCoercion signature)
  where
    signature = Signature.Quantified [] (Signature.Function ts ts [] o) o

identityCoercion :: Origin -> a -> Term a
identityCoercion o x = Coercion o x IdentityCoercion

permissionCoercion :: Origin -> a -> [Permit] -> Term a
permissionCoercion o x permits = Coercion o x (AnyCoercion signature)
  where
    signature =
      Signature.Quantified
        [ Parameter o "R" Kind.Stack,
          Parameter o "S" Kind.Stack
        ]
        ( Signature.Function
            [ Signature.StackFunction
                (Signature.Variable "R" o)
                []
                (Signature.Variable "S" o)
                []
                (permitName <$> grants)
                o
            ]
            [ Signature.StackFunction
                (Signature.Variable "R" o)
                []
                (Signature.Variable "S" o)
                []
                (permitName <$> revokes)
                o
            ]
            []
            o
        )
        o
    (grants, revokes) = partition permitted permits

decompose :: Term a -> [Term a]
-- TODO: Verify that this is correct.
decompose (Generic _ _ _ t) = decompose t
decompose (Compose _ a b) = decompose a ++ decompose b
decompose (Coercion _ _ IdentityCoercion) = []
decompose (Group (Group a)) = [Group a]
decompose term = [term]

origin :: Term a -> Origin
origin term = case term of
  Coercion o _ _ -> o
  Compose _ a _ -> origin a
  Generic o _ _ _ -> o
  Group a -> origin a
  Lambda o _ _ _ _ -> o
  New o _ _ _ _ -> o
  NewClosure o _ _ -> o
  Match o _ _ _ -> o
  Push o _ _ -> o
  Word o _ _ _ -> o

quantifierCount :: Term a -> Int
quantifierCount = countFrom 0
  where
    countFrom !c (Generic _ _ _ body) = countFrom (c + 1) body
    countFrom c _ = c

-- Deduces the explicit type of a term.

typ :: Term Type -> Type
typ = metadata

metadata :: Term a -> a
metadata term = case term of
  Coercion _ t _ -> t
  Compose t _ _ -> t
  Generic _ _ _ term' -> metadata term'
  Group term' -> metadata term'
  Lambda _ t _ _ _ -> t
  Match _ t _ _ -> t
  New _ t _ _ _ -> t
  NewClosure _ t _ -> t
  Push _ t _ -> t
  Word _ t _ _ -> t

stripMetadata :: Term a -> Term ()
stripMetadata term = case term of
  Coercion a _ b -> Coercion a () b
  Compose _ a b -> Compose () (stripMetadata a) (stripMetadata b)
  Generic a b c term' -> Generic a b c (stripMetadata term')
  Group term' -> stripMetadata term'
  Lambda a _ b _ c -> Lambda a () b () (stripMetadata c)
  Match a _ b c -> Match a () (stripCase <$> b) (stripElse c)
  New a _ b c d -> New a () b c d
  NewClosure a _ b -> NewClosure a () b
  Push a _ b -> Push a () (stripValue b)
  Word a _ b c -> Word a () b c
  where
    stripCase :: (Origin, GeneralName, Term a) -> (Origin, GeneralName, Term ())
    stripCase = over _3 stripMetadata

    stripElse :: (Origin, Either a (Term a)) -> (Origin, Either () (Term ()))
    stripElse (o, Left _) = (o, Left ())
    stripElse (o, Right t) = (o, Right (stripMetadata t))

stripValue :: Value a -> Value ()
stripValue v = case v of
  Capture a b -> Capture a (stripMetadata b)
  Character a -> Character a
  Closed a -> Closed a
  Local a -> Local a
  Name a -> Name a
  Quotation a -> Quotation (stripMetadata a)
  Text a -> Text a
