-- |
-- Module      : Mlatu.Occurrences
-- Description : Occurrences of a variable in a type
-- Copyright   : (c) Caden Haustin, 2021
-- License     : MIT
-- Maintainer  : mlatu@brightlysalty.33mail.com
-- Stability   : experimental
-- Portability : GHC
module Mlatu.Occurrences
  ( occurrences,
    occurs,
  )
where

import Data.Map qualified as Map
import Mlatu.Ice (ice)
import Mlatu.Type (Type (..), TypeId, Var (..))
import Mlatu.TypeEnv (TypeEnv)
import Mlatu.TypeEnv qualified as TypeEnv
import Optics
import Relude hiding (Type)

-- | We need to be able to count occurrences of a type variable in a type, not
-- just check for its presence. This is for two reasons: to prevent infinite
-- types (the \"occurs check\"), and to determine whether a stack variable can
-- be generalized to a higher rank. (See "Mlatu.Regeneralize".)
occurrences :: TypeEnv -> TypeId -> Type -> Int
occurrences tenv0 x = recur
  where
    recur t = case t of
      TypeConstructor {} -> 0
      TypeVar _ (Var _name y _) -> case Map.lookup y (view TypeEnv.tvs tenv0) of
        Nothing -> if x == y then 1 else 0
        Just t' -> recur t'
      TypeConstant {} -> 0
      Forall _ (Var _name x' _) t' -> if x == x' then 0 else recur t'
      a :@ b -> recur a + recur b

occurs :: TypeEnv -> TypeId -> Type -> Bool
occurs tenv0 x t = occurrences tenv0 x t > 0
