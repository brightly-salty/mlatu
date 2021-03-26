-- |
-- Module      : Mlatu.Entry.Word
-- Description : Word definition entries
-- Copyright   : (c) Caden Haustin, 2021
-- License     : MIT
-- Maintainer  : mlatu@brightlysalty.33mail.com
-- Stability   : experimental
-- Portability : GHC
module Mlatu.Entry.Word
  ( Entry (..),
  )
where

import Mlatu.Entry.Category (Category)
import Mlatu.Entry.Parent (Parent)
import Mlatu.Name (Unqualified)
import Mlatu.Operator (Associativity, Precedence)
import Mlatu.Origin (Origin)
import Mlatu.Signature (Signature)
import Mlatu.Term (Term)
import Mlatu.Type (Type)
import Relude hiding (Type)

data Entry = Entry
  -- If present, the associativity (leftward or rightward) of this operator; if
  -- not, defaults to non-associative.

  { associativity :: !(Maybe Associativity),
    -- Whether this is a word/instance, trait, or permission.

    category :: !Category,
    -- If present, the definition of the word; if not, this is a declaration.

    body :: !(Maybe (Term Type)),
    -- Whether this word is visible outside its vocabulary.

    export :: !Bool,
    -- User-defined metadata.

    metadata :: !(Map Unqualified (Term ())),
    -- Source location.

    origin :: !Origin,
    -- If present, the precedence of this operator; if not, defaults to 6.

    precedence :: !(Maybe Precedence),
    -- The type signature of this definition or declaration.

    signature :: !Signature,
    -- If present, the trait declaration of which this definition is an instance, or
    -- the type of which this definition is a constructor; if not, this is a normal
    -- definition.

    parent :: !(Maybe Parent)
  }
  deriving (Show)
