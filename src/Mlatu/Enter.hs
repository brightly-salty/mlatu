-- |
-- Module      : Mlatu.Enter
-- Description : Inserting entries into the dictionary
-- Copyright   : (c) Caden Haustin, 2021
-- License     : MIT
-- Maintainer  : mlatu@brightlysalty.33mail.com
-- Stability   : experimental
-- Portability : GHC
module Mlatu.Enter
  ( fragment,
    fragmentFromSource,
    resolveAndDesugarWord,
  )
where

import Data.Map.Strict qualified as Map
import Mlatu.Class (Class, Method)
import Mlatu.Class qualified as Class
import Mlatu.Definition (ConstructorDefinition, PermissionDefinition, WordDefinition)
import Mlatu.Definition qualified as Definition
import Mlatu.Desugar.Infix qualified as Infix
import Mlatu.Desugar.Quotations qualified as Quotations
import Mlatu.Dictionary (Dictionary)
import Mlatu.Dictionary qualified as Dictionary
import Mlatu.Entry qualified as Entry
import Mlatu.Entry.Merge qualified as Merge
import Mlatu.Fragment (Fragment)
import Mlatu.Fragment qualified as Fragment
import Mlatu.Ice (ice)
import Mlatu.Infer (mangleInstance, typecheck)
import Mlatu.Informer (errorCheckpoint, report)
import Mlatu.Instance qualified as Instance
import Mlatu.Instantiated (Instantiated (Instantiated))
import Mlatu.Intrinsic (Intrinsic)
import Mlatu.Intrinsic qualified as Intrinsic
import Mlatu.Metadata (Metadata)
import Mlatu.Metadata qualified as Metadata
import Mlatu.Monad (M)
import Mlatu.Name
  ( GeneralName (QualifiedName),
    Qualified (Qualified, qualifierName),
    Unqualified,
    qualifierFromName,
  )
import Mlatu.Parse qualified as Parse
import Mlatu.Pretty (printQualified)
import Mlatu.Quantify qualified as Quantify
import Mlatu.Report qualified as Report
import Mlatu.Resolve qualified as Resolve
import Mlatu.Scope (scope)
import Mlatu.Signature qualified as Signature
import Mlatu.Term (Term)
import Mlatu.Term qualified as Term
import Mlatu.Tokenize (tokenize)
import Mlatu.TypeDefinition (TypeDefinition)
import Mlatu.TypeDefinition qualified as TypeDefinition
import Optics
import Prettyprinter (dquotes, hsep)
import Relude

-- | Enters a program fragment into a dictionary.
fragment :: Fragment () -> Dictionary -> M Dictionary
fragment f d0 = do
  d1 <- foldlM declareType d0 (view Fragment.types f)
  -- We enter declarations of all intrinsics
  d2 <- foldlM enterIntrinsic d1 (view Fragment.intrinsics f)
  -- We enter declarations of all classes
  d3 <- foldlM enterClass d2 (view Fragment.classes f)
  -- We declare all permissions
  d4 <- foldlM declarePermission d3 (view Fragment.permissionDefinitions f)
  -- We resolve intrinsic type signatures
  d5 <- foldlM resolveSignature d4 (view Intrinsic.name <$> view Fragment.intrinsics f)
  -- We resolve class type signatures
  d6 <- foldlM resolveSignature d5 (concatMap (fmap (view Class.name) . view Class.methods) (view Fragment.classes f))
  -- We declare all words
  d7 <- foldlM declareWord d6 (view Fragment.wordDefinitions f)
  -- We declare all words
  d8 <- foldlM declareConstructor d7 (view Fragment.constructorDefinitions f)
  -- We resolve the signatures of all words
  d9 <- foldlM resolveSignature d8 (view Definition.wordName <$> view Fragment.wordDefinitions f)
  -- We resolve the signatures of all permissions
  d10 <- foldlM resolveSignature d9 (view Definition.permissionName <$> view Fragment.permissionDefinitions f)
  --  We add metadata
  d11 <- foldlM addMetadata d10 (view Fragment.metadata f)
  -- We enter the definitions of instances
  d12 <- foldlM defineInstance d11 (concatMap (view Instance.methods) (view Fragment.instances f))
  -- We enter the definitions of words
  d13 <- foldlM defineWord d12 (view Fragment.wordDefinitions f)
  -- We enter the definitions of permissions
  d14 <- foldlM definePermission d13 (view Fragment.permissionDefinitions f)
  -- We enter the definitions of constructors
  foldlM defineConstructor d14 (view Fragment.constructorDefinitions f)

addMetadata :: Dictionary -> Metadata -> M Dictionary
addMetadata dictionary0 metadata =
  foldlM addField dictionary0 $ Map.toList $ view Metadata.fields metadata
  where
    QualifiedName qualified = view Metadata.name metadata
    origin = view Metadata.origin metadata
    qualifier = qualifierFromName qualified

    addField :: Dictionary -> (Unqualified, Term ()) -> M Dictionary
    addField dictionary (unqualified, term) = do
      let name = Qualified qualifier unqualified
      pure $ case Dictionary.lookup (Instantiated name []) dictionary of
        Just {} -> dictionary -- TODO: Report duplicates or merge?
        Nothing ->
          Dictionary.insert
            (Instantiated name [])
            (Entry.Metadata origin term)
            dictionary

enterIntrinsic :: Dictionary -> Intrinsic -> M Dictionary
enterIntrinsic dictionary declaration = do
  let name = view Intrinsic.name declaration
      signature = view Intrinsic.signature declaration
      origin = view Intrinsic.origin declaration
  case Dictionary.lookup (Instantiated name []) dictionary of
    -- TODO: Check signatures.
    Just _existing -> pure dictionary
    Nothing -> do
      let entry =
            Entry.Word
              Merge.Deny
              origin
              (Just signature)
              Nothing
      pure $ Dictionary.insert (Instantiated name []) entry dictionary

enterClass :: Dictionary -> Class -> M Dictionary
enterClass dictionary c =
  foldlM (`enterClassMethod` c) dictionary (view Class.methods c)

enterClassMethod :: Dictionary -> Class -> Method -> M Dictionary
enterClassMethod dictionary c method = do
  let name = view Class.name method
      origin = view Class.origin method
      signature = Signature.Quantified (view Class.parameters c) (view Class.signature method) origin
  case Dictionary.lookup (Instantiated name []) dictionary of
    -- TODO: Check signatures.
    Just _existing -> pure dictionary
    Nothing -> do
      let entry = Entry.ClassMethod origin signature
      pure $ Dictionary.insert (Instantiated name []) entry dictionary

-- declare type, declare & define constructors
declareType :: Dictionary -> TypeDefinition -> M Dictionary
declareType dictionary typ =
  let name = view TypeDefinition.name typ
   in case Dictionary.lookup (Instantiated name []) dictionary of
        -- Not previously declared.
        Nothing -> do
          let entry =
                Entry.Type
                  (view TypeDefinition.origin typ)
                  (view TypeDefinition.parameters typ)
                  (view TypeDefinition.constructors typ)
          pure $ Dictionary.insert (Instantiated name []) entry dictionary
        -- Previously declared with the same parameters.
        Just (Entry.Type _origin parameters _ctors)
          | parameters == view TypeDefinition.parameters typ ->
            pure dictionary
        -- Already declared or defined differently.
        Just {} ->
          ice $
            show $
              hsep
                [ "Mlatu.Enter.declareType - type",
                  dquotes $ printQualified name,
                  "already declared or defined differently"
                ]

declarePermission ::
  Dictionary -> PermissionDefinition () -> M Dictionary
declarePermission dictionary definition =
  let name = view Definition.permissionName definition
      signature = view Definition.permissionSignature definition
   in case Dictionary.lookup (Instantiated name []) dictionary of
        -- Not previously declared or defined.
        Nothing -> do
          let entry =
                Entry.Permission
                  (view Definition.permissionOrigin definition)
                  signature
                  Nothing
          pure $ Dictionary.insert (Instantiated name []) entry dictionary
        -- Already declared with the same signature.
        Just (Entry.Permission originalOrigin mSignature _)
          | mSignature == signature ->
            pure dictionary
          | otherwise ->
            do
              report $
                Report.makeError $
                  Report.WordRedeclaration
                    (Signature.origin signature)
                    name
                    signature
                    originalOrigin
                    (Just mSignature)
              pure dictionary
        -- Already declared or defined with a different signature.
        Just {} ->
          ice $
            show $
              hsep
                [ "Mlatu.Enter.declarePermission - permission",
                  dquotes $ printQualified name,
                  "already declared or defined without signature or as a non-permission"
                ]

declareWord ::
  Dictionary -> WordDefinition () -> M Dictionary
declareWord dictionary definition =
  let name = view Definition.wordName definition
      signature = view Definition.wordSignature definition
   in case Dictionary.lookup (Instantiated name []) dictionary of
        -- Not previously declared or defined.
        Nothing -> do
          let entry =
                Entry.Word
                  (view Definition.wordMerge definition)
                  (view Definition.wordOrigin definition)
                  (Just signature)
                  Nothing
          pure $ Dictionary.insert (Instantiated name []) entry dictionary
        -- Already declared with the same signature.
        Just (Entry.Word _ originalOrigin mSignature _)
          | view Definition.wordInferSignature definition || mSignature == Just signature ->
            pure dictionary
          | otherwise ->
            do
              report $
                Report.makeError $
                  Report.WordRedeclaration
                    (Signature.origin signature)
                    name
                    signature
                    originalOrigin
                    mSignature
              pure dictionary
        -- Already declared or defined with a different signature.
        Just {} ->
          ice $
            show $
              hsep
                [ "Mlatu.Enter.declarePermission - permission",
                  dquotes $ printQualified name,
                  "already declared or defined without signature or as a non-permission"
                ]

declareConstructor ::
  Dictionary -> ConstructorDefinition () -> M Dictionary
declareConstructor dictionary definition =
  let name = view Definition.constructorName definition
      signature = view Definition.constructorSignature definition
   in case Dictionary.lookup (Instantiated name []) dictionary of
        -- Not previously declared or defined.
        Nothing -> do
          let entry =
                Entry.Constructor
                  (view Definition.constructorOrigin definition)
                  (view Definition.constructorParent definition)
                  signature
                  Nothing
          pure $ Dictionary.insert (Instantiated name []) entry dictionary
        -- Already declared with the same signature.
        Just (Entry.Constructor originalOrigin _ mSignature _)
          | mSignature == signature ->
            pure dictionary
          | otherwise ->
            do
              report $
                Report.makeError $
                  Report.WordRedeclaration
                    (Signature.origin signature)
                    name
                    signature
                    originalOrigin
                    (Just signature)
              pure dictionary
        -- Already declared or defined with a different signature.
        Just {} ->
          ice $
            show $
              hsep
                [ "Mlatu.Enter.declareWord - word",
                  dquotes $ printQualified name,
                  "already declared or defined without signature or as a non-word"
                ]

resolveSignature :: Dictionary -> Qualified -> M Dictionary
resolveSignature dictionary name = do
  let qualifier = qualifierName name
  case Dictionary.lookup (Instantiated name []) dictionary of
    Just (Entry.Word merge origin (Just signature) body) -> do
      signature' <- Resolve.run $ Resolve.signature dictionary qualifier signature
      let entry = Entry.Word merge origin (Just signature') body
      pure $ Dictionary.insert (Instantiated name []) entry dictionary
    Just (Entry.Permission origin signature body) -> do
      signature' <- Resolve.run $ Resolve.signature dictionary qualifier signature
      let entry = Entry.Permission origin signature' body
      pure $ Dictionary.insert (Instantiated name []) entry dictionary
    Just (Entry.ClassMethod origin signature) -> do
      signature' <- Resolve.run $ Resolve.signature dictionary qualifier signature
      let entry = Entry.ClassMethod origin signature'
      pure $ Dictionary.insert (Instantiated name []) entry dictionary
    _noResolution -> pure dictionary

defineInstance ::
  Dictionary ->
  WordDefinition () ->
  M Dictionary
defineInstance dictionary definition = do
  let name = view Definition.wordName definition
  resolved <- resolveAndDesugarWord dictionary definition
  errorCheckpoint
  let resolvedSignature = view Definition.wordSignature resolved
  -- Note that we use the resolved signature here.
  (typecheckedBody, typ) <-
    typecheck
      dictionary
      ( if view Definition.wordInferSignature definition
          then Nothing
          else Just resolvedSignature
      )
      $ view Definition.wordBody resolved
  errorCheckpoint
  case Dictionary.lookup (Instantiated name []) dictionary of
    -- Already declared or defined as a trait.
    Just (Entry.ClassMethod _origin traitSignature) ->
      do
        mangledName <-
          mangleInstance
            dictionary
            name
            resolvedSignature
            traitSignature
        -- Should this use the mangled name?
        (flattenedBody, dictionary') <-
          Quotations.desugar
            dictionary
            (qualifierFromName name)
            $ Quantify.term typ typecheckedBody
        let entry =
              Entry.Word
                (view Definition.wordMerge definition)
                (view Definition.wordOrigin definition)
                (Just resolvedSignature)
                (Just flattenedBody)
        pure $ Dictionary.insert mangledName entry dictionary'
    -- Previously declared with same signature, but not defined.
    Just (Entry.Word merge origin' signature' Nothing)
      | maybe True (resolvedSignature ==) signature' -> do
        (flattenedBody, dictionary') <-
          Quotations.desugar
            dictionary
            (qualifierFromName name)
            $ Quantify.term typ typecheckedBody
        let entry =
              Entry.Word
                merge
                origin'
                ( Just $
                    if view Definition.wordInferSignature definition
                      then Signature.Type typ
                      else resolvedSignature
                )
                $ Just flattenedBody
        pure $ Dictionary.insert (Instantiated name []) entry dictionary'
    -- Already defined as concatenable.
    Just
      ( Entry.Word
          merge@Merge.Compose
          origin'
          mSignature
          body
        )
        | view Definition.wordInferSignature definition
            || Just resolvedSignature == mSignature -> do
          composedBody <- case body of
            Just existing -> do
              let strippedBody = Term.stripMetadata existing
              pure $ Term.Compose () strippedBody $ view Definition.wordBody resolved
            Nothing -> pure $ view Definition.wordBody resolved
          (composed, composedType) <-
            typecheck
              dictionary
              ( if view Definition.wordInferSignature definition
                  then Nothing
                  else Just resolvedSignature
              )
              composedBody
          (flattenedBody, dictionary') <-
            Quotations.desugar
              dictionary
              (qualifierFromName name)
              $ Quantify.term composedType composed
          let entry =
                Entry.Word
                  merge
                  origin'
                  ( if view Definition.wordInferSignature definition
                      then Nothing -- Just (Signature.Type composedType)
                      else mSignature
                  )
                  $ Just flattenedBody
          pure $ Dictionary.insert (Instantiated name []) entry dictionary'
    -- Already defined, not concatenable.
    Just (Entry.Word Merge.Deny originalOrigin (Just _sig) _) -> do
      report $
        Report.makeError $
          Report.WordRedefinition
            (view Definition.wordOrigin definition)
            name
            originalOrigin

      pure dictionary
    -- Not previously declared as word.
    _nonDeclared ->
      ice $
        show $
          hsep
            [ "Mlatu.Enter.defineInstance - defining word",
              dquotes $ printQualified name,
              "not previously declared"
            ]

defineWord ::
  Dictionary ->
  WordDefinition () ->
  M Dictionary
defineWord dictionary definition = do
  let name = view Definition.wordName definition
  resolved <- resolveAndDesugarWord dictionary definition
  errorCheckpoint
  let resolvedSignature = view Definition.wordSignature resolved
  -- Note that we use the resolved signature here.
  (typecheckedBody, typ) <-
    typecheck
      dictionary
      ( if view Definition.wordInferSignature definition
          then Nothing
          else Just resolvedSignature
      )
      $ view Definition.wordBody resolved
  errorCheckpoint
  case Dictionary.lookup (Instantiated name []) dictionary of
    Just (Entry.Word merge origin' signature' Nothing)
      | maybe True (resolvedSignature ==) signature' -> do
        (flattenedBody, dictionary') <-
          Quotations.desugar
            dictionary
            (qualifierFromName name)
            $ Quantify.term typ typecheckedBody
        let entry =
              Entry.Word
                merge
                origin'
                ( Just $
                    if view Definition.wordInferSignature definition
                      then Signature.Type typ
                      else resolvedSignature
                )
                $ Just flattenedBody
        pure $ Dictionary.insert (Instantiated name []) entry dictionary'
    -- Already defined as concatenable.
    Just
      ( Entry.Word
          merge@Merge.Compose
          origin'
          mSignature
          body
        )
        | view Definition.wordInferSignature definition
            || Just resolvedSignature == mSignature -> do
          composedBody <- case body of
            Just existing -> do
              let strippedBody = Term.stripMetadata existing
              pure $ Term.Compose () strippedBody $ view Definition.wordBody resolved
            Nothing -> pure $ view Definition.wordBody resolved
          (composed, composedType) <-
            typecheck
              dictionary
              ( if view Definition.wordInferSignature definition
                  then Nothing
                  else Just resolvedSignature
              )
              composedBody
          (flattenedBody, dictionary') <-
            Quotations.desugar
              dictionary
              (qualifierFromName name)
              $ Quantify.term composedType composed
          let entry =
                Entry.Word
                  merge
                  origin'
                  ( if view Definition.wordInferSignature definition
                      then Nothing -- Just (Signature.Type composedType)
                      else mSignature
                  )
                  $ Just flattenedBody
          pure $ Dictionary.insert (Instantiated name []) entry dictionary'
    -- Already defined, not concatenable.
    Just (Entry.Word Merge.Deny originalOrigin (Just _sig) _) -> do
      report $
        Report.makeError $
          Report.WordRedefinition
            (view Definition.wordOrigin definition)
            name
            originalOrigin

      pure dictionary
    -- Not previously declared as word.
    _nonDeclared ->
      ice $
        show $
          hsep
            [ "Mlatu.Enter.defineWord - defining word",
              dquotes $ printQualified name,
              "not previously declared"
            ]

defineConstructor ::
  Dictionary ->
  ConstructorDefinition () ->
  M Dictionary
defineConstructor dictionary definition = do
  let name = view Definition.constructorName definition
  case Dictionary.lookup (Instantiated name []) dictionary of
    -- Previously declared with same signature, but not defined.
    Just (Entry.Constructor origin' parent signature' Nothing) -> do
      pure $
        Dictionary.insert
          (Instantiated name [])
          ( Entry.Constructor
              origin'
              parent
              (view Definition.constructorSignature definition)
              $ Just (view Definition.constructorBody definition)
          )
          dictionary
    -- Not previously declared as word.
    _nonDeclared ->
      ice $
        show $
          hsep
            [ "Mlatu.Enter.defineConstructor - defining word",
              dquotes $ printQualified name,
              "not previously declared"
            ]

definePermission ::
  Dictionary ->
  PermissionDefinition () ->
  M Dictionary
definePermission dictionary definition = do
  let name = view Definition.permissionName definition
  resolved <- resolveAndDesugarPermission dictionary definition
  errorCheckpoint
  let resolvedSignature = view Definition.permissionSignature resolved
  -- Note that we use the resolved signature here.
  (typecheckedBody, typ) <-
    typecheck dictionary (Just resolvedSignature) $
      view Definition.permissionBody resolved
  errorCheckpoint
  case Dictionary.lookup (Instantiated name []) dictionary of
    -- Previously declared with same signature, but not defined.
    Just (Entry.Permission origin' signature' Nothing)
      | resolvedSignature == signature' -> do
        (flattenedBody, dictionary') <-
          Quotations.desugar
            dictionary
            (qualifierFromName name)
            $ Quantify.term typ typecheckedBody
        let entry = Entry.Permission origin' resolvedSignature $ Just flattenedBody
        pure $ Dictionary.insert (Instantiated name []) entry dictionary'
    -- Already defined, not concatenable.
    Just (Entry.Permission originalOrigin _sig _) -> do
      report $
        Report.makeError $
          Report.WordRedefinition
            (view Definition.permissionOrigin definition)
            name
            originalOrigin

      pure dictionary
    -- Not previously declared as word.
    _nonDeclared ->
      ice $
        show $
          hsep
            [ "Mlatu.Enter.definePermission - defining permission",
              dquotes $ printQualified name,
              "not previously declared"
            ]

-- | Parses a source file into a program fragment.
fragmentFromSource ::
  -- | List of permissions granted to @main@.
  [GeneralName] ->
  -- | Override name of @main@.
  Maybe Qualified ->
  -- | Initial source line (e.g. for REPL offset).
  Int ->
  -- | Source file path for error reporting.
  FilePath ->
  -- | Source itself.
  Text ->
  -- | Parsed program fragment.
  M (Fragment ())
fragmentFromSource mainPermissions mainName line path source = do
  -- Sources are lexed into a stream of tokens.

  tokenized <- tokenize line path source
  errorCheckpoint

  -- We then parse the token stream as a series of top-level program elements.
  -- Datatype definitions are desugared into regular definitions, so that name
  -- resolution can find their names.

  parsed <- Parse.fragment line path mainPermissions mainName tokenized

  errorCheckpoint

  pure parsed

resolveAndDesugarPermission :: Dictionary -> PermissionDefinition () -> M (PermissionDefinition ())
resolveAndDesugarPermission dictionary definition = do
  -- Name resolution rewrites unqualified names into fully qualified names, so
  -- that it's evident from a name which program element it refers to.

  -- needs dictionary for declared names
  resolved <- Resolve.run $ Resolve.permissionDefinition dictionary definition

  errorCheckpoint

  -- After names have been resolved, the precedences of operators are known, so
  -- infix operators can be desugared into postfix syntax.

  -- needs dictionary for operator metadata
  postfix <- Infix.desugarPermission dictionary resolved

  errorCheckpoint

  -- In addition, now that we know which names refer to local variables,
  -- quotations can be rewritten into closures that explicitly capture the
  -- variables they use from the enclosing scope.

  pure $ over Definition.permissionBody scope postfix

resolveAndDesugarWord :: Dictionary -> WordDefinition () -> M (WordDefinition ())
resolveAndDesugarWord dictionary definition = do
  -- Name resolution rewrites unqualified names into fully qualified names, so
  -- that it's evident from a name which program element it refers to.

  -- needs dictionary for declared names
  resolved <- Resolve.run $ Resolve.wordDefinition dictionary definition

  errorCheckpoint

  -- After names have been resolved, the precedences of operators are known, so
  -- infix operators can be desugared into postfix syntax.

  -- needs dictionary for operator metadata
  postfix <- Infix.desugarWord dictionary resolved

  errorCheckpoint

  -- In addition, now that we know which names refer to local variables,
  -- quotations can be rewritten into closures that explicitly capture the
  -- variables they use from the enclosing scope.

  pure $ over Definition.wordBody scope postfix
