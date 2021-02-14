{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}

-- |
-- Module      : Mlatu.Token
-- Description : Tokens produced by the tokenizer
-- Copyright   : (c) Caden Haustin, 2021
-- License     : MIT
-- Maintainer  : mlatu@brightlysalty.33mail.com
-- Stability   : experimental
-- Portability : GHC
module Mlatu.Token
  ( Token (..),
    fromLayout,
  )
where

import Mlatu.Layoutness (Layoutness (..))
import Mlatu.Literal (FloatLiteral, IntegerLiteral)
import Mlatu.Literal qualified as Literal
import Mlatu.Name (Unqualified)
import Optics (view)
import Relude
import Text.PrettyPrint qualified as Pretty
import Text.PrettyPrint.HughesPJClass (Pretty (..))
import Text.Show qualified
import Unsafe.Coerce (unsafeCoerce)

data Token (l :: Layoutness) where
  -- | @about@
  About :: Token l
  -- | @<@ See note [Angle Brackets].
  AngleBegin :: Token l
  -- | @>@ See note [Angle Brackets].
  AngleEnd :: Token l
  -- | @->@
  Arrow :: Token l
  -- | @as@
  As :: Token l
  -- | @{@, @:@
  BlockBegin :: Token l
  -- | @}@
  BlockEnd :: Token l
  -- | @case@
  Case :: Token l
  -- | @'x'@
  Character :: !Char -> Token l
  -- | @:@
  Colon :: Token 'Layout
  -- | @,@
  Comma :: Token l
  -- | @define@
  Define :: Token l
  -- | @do@
  Do :: Token l
  -- | @...@
  Ellipsis :: Token l
  -- | @elif@
  Elif :: Token l
  -- | @else@
  Else :: Token l
  -- | See note [Float Literals].
  Float :: !FloatLiteral -> Token l
  -- | @(@
  GroupBegin :: Token l
  -- | @)@
  GroupEnd :: Token l
  -- | @if@
  If :: Token l
  -- | @_@
  Ignore :: Token l
  -- | @instance@
  Instance :: Token l
  -- | @1@, 0b1@, @0o1@, @0x1@, @1i64, @1u16@
  Integer :: !IntegerLiteral -> Token l
  -- | @intrinsic@
  Intrinsic :: Token l
  -- | @jump@
  Jump :: Token l
  -- | @match@
  Match :: Token l
  -- | @+@
  Operator :: !Unqualified -> Token l
  -- | @permission@
  Permission :: Token l
  -- | @\@
  Reference :: Token l
  -- | @return@
  Return :: Token l
  -- | @synonym@
  Synonym :: Token l
  -- | @"..."@
  Text :: !Text -> Token l
  -- | @trait@
  Trait :: Token l
  -- | @type@
  Type :: Token l
  -- | @[@
  VectorBegin :: Token l
  -- | @]@
  VectorEnd :: Token l
  -- | @vocab@
  Vocab :: Token l
  -- | @::@
  VocabLookup :: Token l
  -- | @with@
  With :: Token l
  -- | @word@
  Word :: !Unqualified -> Token l

fromLayout :: Token l -> Maybe (Token 'Nonlayout)
fromLayout Colon = Nothing
fromLayout x = Just (unsafeCoerce x)

instance Eq (Token l) where
  About == About = True
  AngleBegin == AngleBegin = True
  AngleEnd == AngleEnd = True
  Arrow == Arrow = True
  As == As = True
  BlockBegin == BlockBegin = True
  BlockEnd == BlockEnd = True
  Case == Case = True
  Character a == Character b = a == b
  Colon == Colon = True
  Comma == Comma = True
  Define == Define = True
  Do == Do = True
  Ellipsis == Ellipsis = True
  Elif == Elif = True
  Else == Else = True
  -- See note [Float Literals].
  Float a == Float b = a == b
  GroupBegin == GroupBegin = True
  GroupEnd == GroupEnd = True
  If == If = True
  Ignore == Ignore = True
  Instance == Instance = True
  Integer a == Integer b = a == b
  Intrinsic == Intrinsic = True
  Jump == Jump = True
  Match == Match = True
  Operator a == Operator b = a == b
  Permission == Permission = True
  Reference == Reference = True
  Return == Return = True
  Synonym == Synonym = True
  Text a == Text b = a == b
  Trait == Trait = True
  Type == Type = True
  VectorBegin == VectorBegin = True
  VectorEnd == VectorEnd = True
  Vocab == Vocab = True
  VocabLookup == VocabLookup = True
  With == With = True
  Word a == Word b = a == b
  _ == _ = False

instance Pretty (Token l) where
  pPrint token = case token of
    About -> "about"
    AngleBegin -> "<"
    AngleEnd -> ">"
    Arrow -> "->"
    As -> "as"
    BlockBegin {} -> "{"
    BlockEnd -> "}"
    Case -> "case"
    Character c -> Pretty.quotes $ Pretty.char c
    Colon -> ":"
    Comma -> ","
    Define -> "define"
    Do -> "do"
    Ellipsis -> "..."
    Elif -> "elif"
    Else -> "else"
    Float a ->
      Pretty.hcat
        [ Pretty.double $ Literal.floatValue a,
          pPrint $ view Literal.floatBits a
        ]
    GroupBegin -> "("
    GroupEnd -> ")"
    If -> "if"
    Ignore -> "_"
    Instance -> "instance"
    Integer literal -> pPrint literal
    Intrinsic -> "intrinsic"
    Jump -> "jump"
    Match -> "match"
    Operator name -> pPrint name
    Permission -> "permission"
    Reference -> "\\"
    Return -> "return"
    Synonym -> "synonym"
    Text t -> Pretty.doubleQuotes $ Pretty.text $ toString t
    Trait -> "trait"
    Type -> "type"
    VectorBegin -> "["
    VectorEnd -> "]"
    Vocab -> "vocab"
    VocabLookup -> "::"
    With -> "with"
    Word name -> pPrint name

-- Minor hack because Parsec requires 'Show'.
instance Show (Token l) where
  show = Pretty.render . pPrint

-- Note [Angle Brackets]:
--
-- Since we separate the passes of tokenization and parsing, we are faced with a
-- classic ambiguity between angle brackets as used in operator names such as
-- '>>' and '<+', and as used in type argument and parameter lists such as
-- 'vector<vector<T>>' and '<+E>'.
--
-- Our solution is to parse a less-than or greater-than character as an 'angle'
-- token if it was immediately followed by a symbol character in the input, with
-- no intervening whitespace. This is enough information for the parser to
-- disambiguate the intent:
--
--   • When parsing an expression, it joins a sequence of angle tokens and
--     an operator token into a single operator token.
--
--   • When parsing a signature, it treats them separately.
--
-- You may ask why we permit this silly ambiguity in the first place. Why not
-- merge the passes of tokenization and parsing, or use a different bracketing
-- character such as '[]' for type argument lists?
--
-- We separate tokenization and parsing for the sake of tool support: it's
-- simply easier to provide token-accurate source locations when we keep track
-- of source locations at the token level, and it's easier to provide a list of
-- tokens to external tools (e.g., for syntax highlighting) if we already have
-- such a list at hand.
--
-- The reason for the choice of bracketing character is for the sake of
-- compatibility with C++ tools. When setting a breakpoint in GDB, for example,
-- it's nice to be able to type:
--
--     break foo::bar<int>
--
-- And for this to refer to the Mlatu definition 'foo::bar<int>' precisely,
-- rather than to some syntactic analogue such as 'foo.bar[int]'. The modest
-- increase in complexity of implementation is justified by fostering a better
-- experience for people.
