-- |
-- Module      : Mlatu.Instantiate
-- Description : Instantiating generic types
-- Copyright   : (c) Caden Haustin, 2021
-- License     : MIT
-- Maintainer  : mlatu@brightlysalty.33mail.com
-- Stability   : experimental
-- Portability : GHC
module Mlatu.TypeSystem.Instantiate
  ( prenex,
    term,
    typ,
  )
where

import Mlatu.Base.Kind (Kind)
import Mlatu.Base.Name (Unqualified)
import Mlatu.Base.Origin (Origin)
import Mlatu.Base.Type (Type (..), TypeId, Var (..))
import Mlatu.Front.Term (Term (..))
import Mlatu.Front.Term qualified as Term
import Mlatu.Informer (M, halt, reportTypeArgumentCountMismatch, while)
import Mlatu.Pretty (printType)
import Mlatu.TypeSystem.Substitute qualified as Substitute
import Mlatu.TypeSystem.TypeEnv (TypeEnv, freshTypeId)
import Mlatu.TypeSystem.Zonk qualified as Zonk
import Prettyprinter (hsep, squotes)

-- | To instantiate a type scheme, we simply replace all quantified variables
-- with fresh ones and remove the quantifier, pureing the types with which the
-- variables were instantiated, in order. Because type identifiers are globally
-- unique, we know a fresh type variable will never be erroneously captured.
typ ::
  TypeEnv ->
  Origin ->
  Unqualified ->
  TypeId ->
  Kind ->
  Type ->
  M (Type, Type, TypeEnv)
typ tenv0 origin name x k t = do
  ia <- freshTypeId tenv0
  let a = TypeVar origin $ Var name ia k
  replaced <- Substitute.typ tenv0 x a t
  pure (replaced, a, tenv0)

-- | When generating an instantiation of a generic definition, we only want to
-- instantiate the rank-1 quantifiers; all other quantifiers are irrelevant.
prenex :: TypeEnv -> Type -> M (Type, [Type], TypeEnv)
prenex tenv0 q@(Forall origin (Var name x k) t) =
  while origin (hsep ["instantiating", squotes $ printType q]) $ do
    (t', a, tenv1) <- typ tenv0 origin name x k t
    (t'', as, tenv2) <- prenex tenv1 t'
    pure (t'', a : as, tenv2)
prenex tenv0 t = pure (t, [], tenv0)

-- | Instantiates a generic expression with the given type arguments.
term :: TypeEnv -> Term Type -> [Type] -> M (Term Type)
term tenv t args = foldlM go t args
  where
    go (Generic _origin _name x expr) arg = Substitute.term tenv x arg expr
    go _ _ = do
      reportTypeArgumentCountMismatch t (Zonk.typ tenv <$> args) (Term.origin t)
      halt
    {-# INLINEABLE go #-}
{-# INLINEABLE term #-}
