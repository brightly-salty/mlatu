{-# LANGUAGE DataKinds #-}

-- |
-- Module      : Mlatu.Parser
-- Description : Parsing utilities
-- Copyright   : (c) Caden Haustin, 2021
-- License     : MIT
-- Maintainer  : mlatu@brightlysalty.33mail.com
-- Stability   : experimental
-- Portability : GHC
module Mlatu.Parser
  ( Bracketer,
    Parser,
    getTokenOrigin,
    parserMatch,
    parserMatch_,
    tokenSatisfy,
  )
where

import Mlatu.Layoutness (Layoutness (..))
import Mlatu.Located (Located)
import Mlatu.Located qualified as Located
import Mlatu.Name (Qualifier)
import Mlatu.Origin (Origin)
import Mlatu.Origin qualified as Origin
import Mlatu.Token (Token)
import Optics (view)
import Relude
import Text.Parsec (ParsecT, (<?>))
import Text.Parsec qualified as Parsec
import Text.Parsec.Pos (SourcePos)

type Bracketer a = GeneralParser 'Layout a

type Parser a = GeneralParser 'Nonlayout a

type GeneralParser l a = ParsecT [Located (Token l)] Qualifier Identity a

getTokenOrigin :: GeneralParser l Origin
getTokenOrigin =
  view Located.origin
    <$> Parsec.lookAhead (tokenSatisfy (const True))

tokenSatisfy ::
  (Located (Token l) -> Bool) ->
  GeneralParser l (Located (Token l))
tokenSatisfy predicate =
  Parsec.tokenPrim
    show
    advance
    (\token -> if predicate token then Just token else Nothing)
  where
    advance ::
      SourcePos ->
      Located (Token l) ->
      [Located (Token l)] ->
      SourcePos
    advance _ _ (token : _) = Origin.begin (view Located.origin token)
    advance sourcePos _ _ = sourcePos

parserMatch :: Token l -> GeneralParser l (Located (Token l))
parserMatch token = tokenSatisfy (\l -> token == view Located.item l) <?> show token

parserMatch_ :: Token l -> GeneralParser l ()
parserMatch_ = void . parserMatch
