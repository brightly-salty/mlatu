{-# LANGUAGE PatternSynonyms #-}

module Mlatu.Erlang.Optimize (rewrite) where

import Control.Arrow ((***))
import Mlatu.Erlang.AST (Expr (..), Pattern (..), VarIdent, mkAnd, pattern ECallCouple, pattern ECouple, pattern ESetCouple, pattern ESetVar)
import Relude

rewrite :: Expr -> Expr
rewrite = \case
  (ECase scrutinee cases) -> rewriteCase scrutinee cases
  (ECallFun name args) -> rewriteCall name args
  (EVar name) -> EVar name
  (ESet pat expr) -> rewriteSet pat expr
  (EAnd xs) -> rewriteAnd xs
  (ENil) -> ENil
  (ECons h t) -> rewriteCons h t
  (EAtom atom) -> EAtom atom
  (EInt i) -> EInt i
  (EString s) -> EString s
  (EOp left op right) -> rewriteOp left op right
  (ETuple xs) -> rewriteTuple xs
  (EFun name arity) -> EFun name arity
  (EIf xs) -> rewriteIf xs

unify :: Expr -> Pattern -> Maybe [Expr]
unify (ECons h1 t1) (PCons h2 t2) | Just h <- unify h1 h2, Just t <- unify t1 t2 = Just (h <> t)
unify (EInt i1) (PInt i2) | i1 == i2 = Just []
unify (EAtom i1) (PAtom i2) | i1 == i2 = Just []
unify (EVar v1) (PVar v2) | v1 == v2 = Just []
unify x (PVar v) = Just [ESetVar v x]
unify _ _ = Nothing

rewriteCase scrutinee cases = case (rewrite scrutinee, concatMap re cases) of
  (scrutinee, (p, e) : _)
    | Just es <- unify scrutinee p -> rewrite (mkAnd (es ++ [e]))
  (scrutinee, _ : (p, e) : _)
    | Just es <- unify scrutinee p -> rewrite (mkAnd (es ++ [e]))
  (scrutinee, _ : _ : (p, e) : _)
    | Just es <- unify scrutinee p -> rewrite (mkAnd (es ++ [e]))
  (scrutinee, _ : _ : _ : (p, e) : _)
    | Just es <- unify scrutinee p -> rewrite (mkAnd (es ++ [e]))
  (scrutinee, cases) -> ECase scrutinee cases
  where
    re (p, b) = case rewrite b of
      (EIf guards) -> (\(g, b) -> (PWhen p g, b)) <$> guards
      b -> [(p, b)]

rewriteCall name args = case (name, rewrite <$> args) of
  ("not", [EAtom "true"]) -> EAtom "false"
  ("not", [EAtom "false"]) -> EAtom "true"
  ("hd", [ECons x xs]) -> x
  ("tl", [ECons x xs]) -> xs
  (name, args) -> ECallFun name args

rewriteSet pat expr = ESet pat (rewrite expr)

rewriteAnd xs = mkAnd (go xs)
  where
    go [] = []
    go (x : xs) = case rewrite x of
      EAnd ys -> go (xs <> ys)
      ESetCouple (PVar x) (PVar y) expr -> case xs of
        (ESetCouple a b (ECallCouple name (EVar x') (EVar y')) : xs) | x == x' && y == y' -> go (ESetCouple a b (ECallFun name [expr]) : xs)
        (ECallCouple name (EVar x') (EVar y') : xs) | x == x' && y == y' -> go (ECallFun name [expr] : xs)
        (ECouple (EVar x') (EVar y') : xs) | x == x' && y == y' -> go (expr : xs)
        _ -> (ESetCouple (PVar x) (PVar y) expr) : (go xs)
      ESetVar v e -> case e of
        ECons _ _ -> go (replaceVar (v, e) <$> xs)
        EInt _ -> go (replaceVar (v, e) <$> xs)
        EAtom _ -> go (replaceVar (v, e) <$> xs)
        ETuple _ -> go (replaceVar (v, e) <$> xs)
        EVar _ -> go (replaceVar (v, e) <$> xs)
        EOp _ _ _ -> go (replaceVar (v, e) <$> xs)
        _ -> (ESetVar v e) : (go xs)
      x -> x : (go xs)

rewriteCons h t = ECons (rewrite h) (rewrite t)

rewriteOp left op right = case (rewrite left, op, rewrite right) of
  (EOp lLeft "+" lRight, "+", right) -> rewrite (EOp lLeft "+" (EOp lRight "+" right))
  (EOp lLeft "*" lRight, "*", right) -> rewrite (EOp lLeft "*" (EOp lRight "*" right))
  (x, "+", EInt 0) -> x
  (EInt 0, "+", x) -> x
  (x, "-", EInt 0) -> x
  (x, "*", EInt 1) -> x
  (EInt 1, "*", x) -> x
  (EInt i1, "+", EInt i2) -> EInt (i1 + i2)
  (EInt i1, "-", EInt i2) -> EInt (i1 - i2)
  (EInt i1, "*", EInt i2) -> EInt (i1 * i2)
  (EInt i1, "/", EInt i2) -> EInt (i1 `div` i2)
  (EAtom first, "and", EAtom second)
    | first == "true" && second == "true" -> EAtom "true"
    | otherwise -> EAtom "false"
  (EAtom first, "or", EAtom second)
    | first == "true" || second == "true" -> EAtom "true"
    | otherwise -> EAtom "false"
  (EAtom first, "xor", EAtom second)
    | (first == "true") /= (second == "true") -> EAtom "true"
    | otherwise -> EAtom "false"
  (x, op, y) -> EOp x op y

rewriteTuple = ETuple . fmap rewrite

rewriteIf = EIf . fmap (rewrite *** rewrite)

replaceVar :: (VarIdent, Expr) -> Expr -> Expr
replaceVar (name, val) expr = case expr of
  (ECase scrutinee cases) -> ECase (replace scrutinee) ((replacePat *** replace) <$> cases)
  (ECallFun name args) -> ECallFun name (replace <$> args)
  (EVar n) | n == name -> val
  (ESet pat expr) -> ESet (replacePat pat) (replace expr)
  (EAnd xs) -> EAnd (replace <$> xs)
  (ECons h t) -> ECons (replace h) (replace t)
  (EOp left op right) -> EOp (replace left) op (replace right)
  (ETuple xs) -> ETuple (replace <$> xs)
  (EIf xs) -> EIf ((replace *** replace) <$> xs)
  _ -> expr
  where
    replace = replaceVar (name, val)

    replacePat = \case
      PCons h t -> PCons (replacePat h) (replacePat t)
      PVar n | n == name, Just r <- exprToPat val -> r
      PTuple pats -> PTuple (replacePat <$> pats)
      PWhen pat expr -> PWhen (replacePat pat) (replace expr)
      pat -> pat

exprToPat :: Expr -> Maybe Pattern
exprToPat (EInt i) = Just (PInt i)
exprToPat (EAtom a) = Just (PAtom a)
exprToPat (EVar v) = Just (PVar v)
exprToPat (ETuple es) = PTuple <$> mapM exprToPat es
exprToPat ENil = Just PNil
exprToPat (ECons h t) = liftA2 PCons (exprToPat h) (exprToPat t)
exprToPat _ = Nothing