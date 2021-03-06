-- |
-- Module      : Mlatu.Basestitute
-- Description : Substituting type variables
-- Copyright   : (c) Caden Haustin, 2021
-- License     : MIT
-- Maintainer  : mlatu@brightlysalty.33mail.com
-- Stability   : experimental
-- Portability : GHC
module Mlatu.TypeSystem.Substitute
  ( term,
    typ,
  )
where

import Data.Set qualified as Set
import Mlatu.Base.Kind qualified as Kind
import Mlatu.Base.Type (Type (..), TypeId, Var (..))
import Mlatu.Front.Term (Term (..))
import Mlatu.Informer (M)
import Mlatu.TypeSystem.Free qualified as Free
import Mlatu.TypeSystem.TypeEnv (TypeEnv, freshTypeId)

-- | Capture-avoiding substitution of a type variable α with a type τ throughout
-- a type σ, [α ↦ τ]σ.
typ :: TypeEnv -> TypeId -> Type -> Type -> M Type
typ tenv0 x a = recur
  where
    recur t = case t of
      Forall origin var@(Var name x' k) t'
        | x == x' -> pure t
        | x' `Set.notMember` Free.tvs tenv0 t' -> Forall origin var <$> recur t'
        | otherwise -> do
          z <- freshTypeId tenv0
          t'' <- typ tenv0 x' (TypeVar origin $ Var name z k) t'
          Forall origin (Var name z k) <$> recur t''
      TypeVar _ (Var _name x' _) | x == x' -> pure a
      m :@ n -> (:@) <$> recur m <*> recur n
      _noSubst -> pure t

term :: TypeEnv -> TypeId -> Type -> Term Type -> M (Term Type)
term tenv x a = recur
  where
    recur t = case t of
      Coercion origin tref hint -> Coercion origin <$> go tref <*> pure hint
      Compose tref t1 t2 -> Compose <$> go tref <*> recur t1 <*> recur t2
      Generic origin name x' body -> do
        -- FIXME: Generics could eventually quantify over non-value kinds.
        let k = Kind.Value
        z <- freshTypeId tenv
        body' <- term tenv x' (TypeVar origin $ Var name z k) body
        Generic origin name z <$> recur body'
      Group body -> recur body
      Lambda origin tref name varType body ->
        Lambda origin <$> go tref
          <*> pure name
          <*> go varType
          <*> recur body
      Match origin tref cases else_ ->
        Match origin <$> go tref
          <*> traverse goCase cases
          <*> goElse else_
        where
          goCase (caseOrigin, name, body) = (caseOrigin,name,) <$> recur body

          goElse (eo, Left a) = pure (eo, Left a)
          goElse (eo, Right a) = (\x -> (eo, Right x)) <$> recur a
      New origin tref index size isNat ->
        New origin <$> go tref <*> pure index <*> pure size <*> pure isNat
      NewClosure origin tref size -> NewClosure origin <$> go tref <*> pure size
      Push origin tref value -> Push origin <$> go tref <*> pure value
      Word origin tref name args ->
        Word origin <$> go tref <*> pure name <*> traverse go args

    go = typ tenv x a
