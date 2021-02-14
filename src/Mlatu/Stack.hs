{-# LANGUAGE TemplateHaskell #-}

-- |
-- Module      : Mlatu.Stack
-- Description : Strict stack
-- Copyright   : (c) Caden Haustin, 2021
-- License     : MIT
-- Maintainer  : mlatu@brightlysalty.33mail.com
-- Stability   : experimental
-- Portability : GHC
module Mlatu.Stack
  ( Stack (..),
    Mlatu.Stack.empty,
    Mlatu.Stack.fromList,
    popMaybe,
    popNote,
    pops,
    pushes,
    _Bottom,
    (.:::)
  )
where

import Relude
import Optics.TH (makePrisms)

infixr 5 :::

-- | A stack with strictly evaluated elements and spine.
data Stack a = Bottom | !a ::: !(Stack a)
  deriving (Functor, Foldable)

makePrisms ''Stack

empty :: Stack a -> Bool
empty Bottom = True
empty _ = False

fromList :: [a] -> Stack a
fromList = foldr (:::) Bottom

popMaybe :: Stack a -> Maybe (a, Stack a)
popMaybe Bottom = Nothing
popMaybe (a ::: s) = Just (a, s)

popNote :: Stack a -> Stack a
popNote Bottom = error "Mlatu.Stack.drop: empty stack"
popNote (_ ::: s) = s

pushes :: [a] -> Stack a -> Stack a
pushes xs s = foldr (:::) s xs

pops :: Int -> Stack a -> ([a], Stack a)
pops n s
  | n <= 0 = ([], s)
  | otherwise = case s of
    Bottom -> ([], s)
    a ::: s' ->
      let (as, s'') = pops (n - 1) s'
       in (a : as, s'')
