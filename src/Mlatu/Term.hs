{-# LANGUAGE TemplateHaskell #-}

-- |
-- Module      : Mlatu.Term
-- Description : The core language
-- Copyright   : (c) Caden Haustin, 2021
-- License     : MIT
-- Maintainer  : mlatu@brightlysalty.33mail.com
-- Stability   : experimental
-- Portability : GHC
module Mlatu.Term
  ( Case (..),
    CoercionHint (..),
    Else (..),
    MatchHint (..),
    Permit (..),
    Term (..),
    Value (..),
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
    permitted,
    permitName,
    _Capture,
    _Character,
    _Closed,
    _Float,
    _Integer,
    _Local,
    _Name,
    _Quotation,
    _Text,
    _Coercion,
    _Compose,
    _Generic,
    _Group, 
    _Lambda,
    _Match,
    _New,
    _NewClosure,
    _NewVector,
    _Push,
    _Word,
    _IdentityCoercion,
    _AnyCoercion,
    _BooleanMatch,
    _AnyMatch
  )
where

import Data.List (partition)
import Mlatu.Entry.Parameter (Parameter (..))
import Mlatu.Kind qualified as Kind
import Mlatu.Literal (FloatLiteral, IntegerLiteral)
import Mlatu.Name
  ( Closed,
    ClosureIndex (..),
    ConstructorIndex (..),
    GeneralName,
    LocalIndex (..),
    Qualified,
    Unqualified,
  )
import Mlatu.Operator (Fixity)
import Mlatu.Origin (Origin)
import Mlatu.Pretty qualified as Pretty
import Mlatu.Signature (Signature)
import Mlatu.Signature qualified as Signature
import Mlatu.Type (Type, TypeId)
import Optics.TH (makeLenses, makePrisms)
import Optics (view)
import Relude hiding (Compose, Type)
import Text.PrettyPrint qualified as Pretty
import Text.PrettyPrint.HughesPJClass (Pretty (..))

-- | The type of coercion to perform.
data CoercionHint
  = -- | The identity coercion, generated by empty terms.
    IdentityCoercion
  | -- | A coercion to a particular type.
    AnyCoercion !Signature
  deriving (Eq, Show)

makePrisms ''CoercionHint

-- | The original source of a @match@ expression
data MatchHint
  = -- | @match@ generated from @if@.
    BooleanMatch
  | -- | @match@ explicitly in the source.
    AnyMatch
  deriving (Eq, Show)

makePrisms ''MatchHint

-- | A permission to grant or revoke in a @with@ expression.
data Permit = Permit
  { _permitted :: !Bool,
    _permitName :: !GeneralName
  }
  deriving (Eq, Show)

makeLenses ''Permit

-- | A value, used to represent literals in a parsed program, as well as runtime
-- values in the interpreter.
data Value a
  = -- | A quotation with explicit variable capture; see "Mlatu.Scope".
    Capture ![Closed] !(Term a)
  | -- | A character literal.
    Character !Char
  | -- | A captured variable.
    Closed !ClosureIndex
  | -- | A floating-point literal.
    Float !FloatLiteral
  | -- | An integer literal.
    Integer !IntegerLiteral
  | -- | A local variable.
    Local !LocalIndex
  | -- | A reference to a name.
    Name !Qualified
  | -- | A parsed quotation.
    Quotation !(Term a)
  | -- | A text literal.
    Text !Text
  deriving (Eq, Show)

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
data Term a
  = -- | @id@, @as (T)@, @with (+A -B)@: coerces the stack to a particular type.
    Coercion !CoercionHint !a !Origin
  | -- | @e1 e2@: composes two terms.
    Compose !a !(Term a) !(Term a)
  | -- | @Λx. e@: generic terms that can be specialized.
    Generic !Unqualified !TypeId !(Term a) !Origin
  | -- | @(e)@: precedence grouping for infix operators.
    Group !(Term a)
  | -- | @→ x; e@: local variable introductions.
    Lambda !a !Unqualified !a !(Term a) !Origin
  | -- | @match { case C {...}... else {...} }@, @if {...} else {...}@:
    -- pattern-matching.
    Match !MatchHint !a ![Case a] !(Else a) !Origin
  | -- | @new.n@: ADT allocation.
    New !a !ConstructorIndex !Int !Origin
  | -- | @new.closure.n@: closure allocation.
    NewClosure !a !Int !Origin
  | -- | @new.vec.n@: vector allocation.
    NewVector !a !Int !a !Origin
  | -- | @push v@: push of a value.
    Push !a !(Value a) !Origin
  | -- | @f@: an invocation of a word.
    Word !a !Fixity !GeneralName ![Type] !Origin
  deriving (Eq, Show)

-- | A case branch in a @match@ expression.
data Case a = Case !GeneralName !(Term a) !Origin
  deriving (Eq, Show)

-- | An @else@ branch in a @match@ (or @if@) expression.
data Else a = Else !(Term a) !Origin
  deriving (Eq, Show)

makePrisms ''Value
makePrisms ''Term

-- FIXME: 'compose' should work on 'Term ()'.
compose :: a -> Origin -> [Term a] -> Term a
compose x o = foldr (Compose x) (identityCoercion x o)

asCoercion :: a -> Origin -> [Signature] -> Term a
asCoercion x o ts = Coercion (AnyCoercion signature) x o
  where
    signature = Signature.Quantified [] (Signature.Function ts ts [] o) o

identityCoercion :: a -> Origin -> Term a
identityCoercion = Coercion IdentityCoercion

permissionCoercion :: [Permit] -> a -> Origin -> Term a
permissionCoercion permits x o = Coercion (AnyCoercion signature) x o
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
                (map (view permitName) grants)
                o
            ]
            [ Signature.StackFunction
                (Signature.Variable "R" o)
                []
                (Signature.Variable "S" o)
                []
                (map (view permitName) revokes)
                o
            ]
            []
            o
        )
        o
    (grants, revokes) = partition (view permitted) permits

decompose :: Term a -> [Term a]
-- TODO: Verify that this is correct.
decompose (Generic _name _id t _origin) = decompose t
decompose (Compose _ a b) = decompose a ++ decompose b
decompose (Coercion IdentityCoercion _ _) = []
decompose term = [term]

origin :: Term a -> Origin
origin term = case term of
  Coercion _ _ o -> o
  Compose _ a _ -> origin a
  Generic _ _ _ o -> o
  Group a -> origin a
  Lambda _ _ _ _ o -> o
  New _ _ _ o -> o
  NewClosure _ _ o -> o
  NewVector _ _ _ o -> o
  Match _ _ _ _ o -> o
  Push _ _ o -> o
  Word _ _ _ _ o -> o

quantifierCount :: Term a -> Int
quantifierCount = countFrom 0
  where
    countFrom !count (Generic _ _ body _) = countFrom (count + 1) body
    countFrom count _ = count

-- Deduces the explicit type of a term.

typ :: Term Type -> Type
typ = metadata

metadata :: Term a -> a
metadata term = case term of
  Coercion _ t _ -> t
  Compose t _ _ -> t
  Generic _ _ term' _ -> metadata term'
  Group term' -> metadata term'
  Lambda t _ _ _ _ -> t
  Match _ t _ _ _ -> t
  New t _ _ _ -> t
  NewClosure t _ _ -> t
  NewVector t _ _ _ -> t
  Push t _ _ -> t
  Word t _ _ _ _ -> t

stripMetadata :: Term a -> Term ()
stripMetadata term = case term of
  Coercion a _ b -> Coercion a () b
  Compose _ a b -> Compose () (stripMetadata a) (stripMetadata b)
  Generic a b term' c -> Generic a b (stripMetadata term') c
  Group term' -> stripMetadata term'
  Lambda _ a _ b c -> Lambda () a () (stripMetadata b) c
  Match a _ b c d -> Match a () (map stripCase b) (stripElse c) d
  New _ a b c -> New () a b c
  NewClosure _ a b -> NewClosure () a b
  NewVector _ a _ b -> NewVector () a () b
  Push _ a b -> Push () (stripValue a) b
  Word _ a b c d -> Word () a b c d
  where
    stripCase :: Case a -> Case ()
    stripCase case_ = case case_ of
      Case a b c -> Case a (stripMetadata b) c

    stripElse :: Else a -> Else ()
    stripElse else_ = case else_ of
      Else a b -> Else (stripMetadata a) b

stripValue :: Value a -> Value ()
stripValue v = case v of
  Capture a b -> Capture a (stripMetadata b)
  Character a -> Character a
  Closed a -> Closed a
  Float a -> Float a
  Integer a -> Integer a
  Local a -> Local a
  Name a -> Name a
  Quotation a -> Quotation (stripMetadata a)
  Text a -> Text a

instance Pretty (Term a) where
  pPrint term = case term of
    Coercion {} -> Pretty.empty
    Compose _ a b -> pPrint a Pretty.$+$ pPrint b
    Generic name i body _ ->
      Pretty.hsep
        [ Pretty.angles $ Pretty.hcat [pPrint name, "/*", pPrint i, "*/"],
          pPrint body
        ]
    Group a -> Pretty.parens (pPrint a)
    Lambda _ name _ body _ ->
      "->"
        Pretty.<+> pPrint name
        Pretty.<> ";"
        Pretty.$+$ pPrint body
    Match _ _ cases else_ _ ->
      Pretty.vcat
        [ "match:",
          Pretty.nest 4 $
            Pretty.vcat $
              map pPrint cases
                ++ [pPrint else_]
        ]
    New _ (ConstructorIndex index) _size _ -> "new." Pretty.<> Pretty.int index
    NewClosure _ size _ -> "new.closure." Pretty.<> pPrint size
    NewVector _ size _ _ -> "new.vec." Pretty.<> pPrint size
    Push _ value _ -> pPrint value
    Word _ _ name [] _ -> pPrint name
    Word _ _ name args _ ->
      Pretty.hcat $
        pPrint name : "::<" : intersperse ", " (map pPrint args) ++ [">"]

instance Pretty (Case a) where
  pPrint (Case name body _) =
    Pretty.vcat
      [ Pretty.hcat ["case ", pPrint name, ":"],
        Pretty.nest 4 $ pPrint body
      ]

instance Pretty (Else a) where
  pPrint (Else body _) = Pretty.vcat ["else:", Pretty.nest 4 $ pPrint body]

instance Pretty Permit where
  pPrint (Permit allow name) =
    Pretty.hcat
      [if allow then "+" else "-", pPrint name]

instance Pretty (Value a) where
  pPrint value = case value of
    Capture names term ->
      Pretty.hcat
        [ Pretty.char '$',
          Pretty.parens $ Pretty.list $ map pPrint names,
          Pretty.braces $ pPrint term
        ]
    Character c -> Pretty.quotes $ Pretty.char c
    Closed (ClosureIndex index) -> "closure." Pretty.<> Pretty.int index
    Float f -> pPrint f
    Integer i -> pPrint i
    Local (LocalIndex index) -> "local." Pretty.<> Pretty.int index
    Name n -> Pretty.hcat ["\\", pPrint n]
    Quotation body -> Pretty.braces $ pPrint body
    Text t -> Pretty.doubleQuotes $ Pretty.text $ toString t
