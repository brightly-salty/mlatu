-- |
-- Module      : Mlatu.Entry.Parameter
-- Description : Type parameters
-- Copyright   : (c) Caden Haustin, 2021
-- License     : MIT
-- Maintainer  : mlatu@brightlysalty.33mail.com
-- Stability   : experimental
-- Portability : GHC
module Mlatu.Front.Parameter
  ( Parameter (..),
  )
where

import Mlatu.Base.Kind (Kind (..))
import Mlatu.Base.Name (Unqualified)
import Mlatu.Base.Origin (Origin)

-- | A generic type parameter for a data type, like @T@ in @List[T]@.
data Parameter = Parameter !Origin !Unqualified !Kind
  deriving (Ord, Show)

-- | Parameters are compared regardless of origixn.
instance Eq Parameter where
  Parameter _ a b == Parameter _ c d = (a, b) == (c, d)
