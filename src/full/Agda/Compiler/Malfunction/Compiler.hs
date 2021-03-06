{-# LANGUAGE RecordWildCards #-}
{- |
Module      :  Agda.Compiler.Malfunction.Compiler
Maintainer  :  janmasrovira@gmail.com, hanghj@student.chalmers.se

This module includes functions that compile from <agda.readthedocs.io Agda> to
<https://github.com/stedolan/malfunction Malfunction>.
-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ConstraintKinds #-}
module Agda.Compiler.Malfunction.Compiler
  (
  -- * Translation functions
    translateTerms
  , translateDef
  , nameToIdent
  , compile
  , runTranslate
  -- * Data needed for compilation
  , Env(..)
  , ConRep(..)
  , Arity
  -- , mkCompilerEnv
  , mkCompilerEnv2
  -- * Others
  , qnameNameId
  , errorT
  , boolT
  , wildcardTerm
  , namedBinding
  , nameIdToIdent
  , nameIdToIdent'
  , mlfTagRange
  -- * Primitives
  , compilePrim
  , compileAxiom
  -- * Malfunction AST
  , module Agda.Compiler.Malfunction.AST
  ) where

import           Agda.Syntax.Common (NameId(..))
import           Agda.Syntax.Literal
import           Agda.Syntax.Treeless

import           Control.Monad
import           Control.Monad.Extra
import           Control.Monad.Identity
import           Data.List.Extra
import           Control.Monad.Reader
import           Data.Graph
import           Data.Ix
import           Data.List
import           Data.Map (Map)
import qualified Data.Map as Map
import           Data.Maybe
import           Data.Set (Set)
import qualified Data.Set as Set
import           Data.Tuple.Extra
import           Numeric (showHex)
import           Data.Char

import           Agda.Compiler.Malfunction.AST
import qualified Agda.Compiler.Malfunction.Primitive as Primitive

data Env = Env
  { _conMap :: Map NameId ConRep
  , _qnameConcreteMap :: Map NameId String
  , _level :: Int
  , _biBool :: Maybe (NameId, NameId)
  }
  deriving (Show)

-- | Data needed to represent a constructor
data ConRep = ConRep
  { _conTag   :: Int
  , _conArity :: Int
  } deriving (Show)

type Translate a = Reader Env a
type Arity = Int

runTranslate :: Reader Env a -> Env -> a
runTranslate = runReader

translateDefM :: MonadReader Env m => QName -> TTerm -> m Binding
translateDefM qnm t
  | isRecursive = do
      tt <- translateM t
      iden <- nameToIdent qnm
      return . Recursive . pure $ (iden, tt)
  | otherwise = do
      tt <- translateM t
      namedBinding qnm tt
  where
    -- TODO: I don't believe this is enough, consider the example
    -- where functions are mutually recursive.
    --     a = b
    --     b = a
    isRecursive = Set.member (qnameNameId qnm) (qnamesIdsInTerm t) -- TODO: is this enough?

mkCompilerEnv :: [QName] -> Map NameId ConRep -> Env
mkCompilerEnv allNames conMap = Env {
  _conMap = conMap
  , _level = 0
  , _qnameConcreteMap = qnameMap
  , _biBool = Nothing
  }
  where
    qnameMap = Map.fromList [ (qnameNameId qn, concreteName qn) | qn <- allNames ]
    showNames = intercalate "." . map (concatMap toValid . show . nameConcrete)
    concreteName qn = showNames (mnameToList (qnameModule qn) ++ [qnameName qn])
    toValid :: Char -> String
    toValid c
      | any (`inRange`c) [('0','9'), ('a', 'z'), ('A', 'Z')]
        || c`elem`"_" = [c]
      | otherwise      = "{" ++ show (ord c) ++ "}"

mlfTagRange :: (Int, Int)
mlfTagRange = (0, 199)

mkCompilerEnv2 :: [QName] -> [[(QName, Arity)]] -> Env
mkCompilerEnv2 allNames consByDtype = Env {
  _conMap = conMap
  , _level = 0
  , _qnameConcreteMap = qnameMap
  , _biBool = findBuiltinBool (map (map fst) consByDtype)
  }
  where
    conMap = Map.fromList [ (qnameNameId qn, ConRep {..} )
                          | typeCons <- consByDtype
                           , (length consByDtype <= rangeSize mlfTagRange)
                             || (error "too many constructors")
                           , (_conTag, (qn, _conArity)) <- zip (range mlfTagRange) typeCons ]
    qnameMap = Map.fromList [ (qnameNameId qn, concreteName qn) | qn <- allNames ]
    showNames = intercalate "." . map (concatMap toValid . show . nameConcrete)
    concreteName qn = showNames (mnameToList (qnameModule qn) ++ [qnameName qn])
    toValid :: Char -> String
    toValid c
      | any (`inRange`c) [('0','9'), ('a', 'z'), ('A', 'Z')]
        || c`elem`"_" = [c]
      | otherwise      = "{" ++ show (ord c) ++ "}"

-- | Translate a single treeless term to a list of malfunction terms.
--
-- Note that this does not handle mutual dependencies correctly. For this you
-- would need @compile@.
translateDef :: Env -> QName -> TTerm -> Binding
translateDef env qn = (`runTranslate` env) . translateDefM qn

-- | Translates a list treeless terms to a list of malfunction terms.
--
-- Pluralized version of @translateDef@.
translateTerms :: Env -> [TTerm] -> [Term]
translateTerms env = (`runTranslate` env) . mapM translateM

translateM :: MonadReader Env m => TTerm -> m Term
translateM = translateTerm

translateTerm :: MonadReader Env m => TTerm -> m Term
translateTerm tt = case tt of
  TVar i            -> indexToVarTerm i
  TPrim tp          -> return $ translatePrimApp tp []
  TDef name         -> translateName name
  TApp t0 args      -> translateApp t0 args
  TLam{}            -> translateLam tt
  TLit lit          -> return $ translateLit lit
  TCon nm           -> translateCon nm []
  TLet t0 t1        -> do
    t0' <- translateTerm t0
    (var, t1') <- introVar (translateTerm t1)
    return (Mlet [Named var t0'] t1')
  -- @deflt@ is the default value if all @alt@s fail.
  TCase i _ deflt alts -> do
    t <- indexToVarTerm i
    alts' <- alternatives t
    return $ Mswitch t alts'
    where
      -- Case expressions may not have an alternative, this is encoded
      -- by @deflt@ being TError TUnreachable.
      alternatives t = case deflt of
        TError TUnreachable -> translateAltsChain t Nothing alts
        _ -> do
          d <- translateTerm deflt
          translateAltsChain t (Just d) alts
  TUnit             -> return unitT
  TSort             -> error ("Unimplemented " ++ show tt)
  TErased           -> return wildcardTerm -- TODO: so... anything can go here?
  TError TUnreachable -> return wildcardTerm

-- | We use this when we don't care about the translation.
wildcardTerm :: Term
wildcardTerm = nullary $ errorT "__UNREACHABLE__"

nullary :: Term -> Term
nullary = Mlambda []

indexToVarTerm :: MonadReader Env m => Int -> m Term
indexToVarTerm i = do
  ni <- asks _level
  return (Mvar (ident (ni - i - 1)))

-- translateSwitch :: MonadReader m => Term -> TAlt -> m ([Case], Term)
-- translateSwitch tcase alt = case alt of
-- --  TAGuard c t -> liftM2 (,) (pure <$> translateCase c) (translateTerm t)
--   TALit pat body -> do
--     b <- translateTerm body
--     let c = pure $ litToCase pat
--     return (c, b)
--   TACon con arity t -> do
--     tg <- nameToTag con
--     usedFields <- snd <$> introVars arity
--       (Set.map (\ix -> arity - ix - 1) . Set.filter (<arity) <$> usedVars t)
--     (vars, t') <- introVars arity (translateTerm t)
--     let bt = bindFields vars usedFields tcase t'
--           -- TODO: It is not clear how to deal with bindings in a pattern
--     return (pure tg, bt)
--   TAGuard gd rhs -> return ([], Mvar "TAGuard.undefined")

translateAltsChain :: MonadReader Env m => Term -> Maybe Term -> [TAlt] -> m [([Case], Term)]
translateAltsChain tcase defaultt [] = return $ maybe [] (\d -> [(defaultCase, d)]) defaultt
translateAltsChain tcase defaultt (ta:tas) =
  case ta of
    TALit pat body -> do
      b <- translateTerm body
      let c = litToCase pat
      (([c], b):) <$> go
    TACon con arity t -> do
      tg <- nameToTag con
      usedFields <- snd <$> introVars arity
        (Set.map (\ix -> arity - ix - 1) . Set.filter (<arity) <$> usedVars t)
      (vars, t') <- introVars arity (translateTerm t)
      let bt = bindFields vars usedFields tcase t'
      -- TODO: It is not clear how to deal with bindings in a pattern
      (([tg], bt):) <$> go
    TAGuard grd t -> do
      tgrd <- translateTerm grd
      t' <- translateTerm t
      tailAlts <- go
      return [(defaultCase,
                Mswitch tgrd
                [(trueCase, t')
                , (defaultCase, Mswitch tcase tailAlts)])]
  where
    go = translateAltsChain tcase defaultt tas

defaultCase :: [Case]
defaultCase = [CaseAnyInt, Deftag]

bindFields :: [Ident] -> Set Int -> Term -> Term -> Term
bindFields vars used termc body = case map bind varsRev of
  [] -> body
  binds -> Mlet binds body
  where
    varsRev = zip [0..] (reverse vars)
    arity = length vars
    bind (ix, iden)
      -- TODO: we bind all fields. The detection of used fields is bugged.
      | True || Set.member ix used = Named iden (Mfield ix termc)
      | otherwise = Named iden wildcardTerm

litToCase :: Literal -> Case
litToCase l = case l of
  LitNat _ i -> CaseInt . fromInteger $ i
  _          -> error "Unimplemented"

-- The argument is the lambda itself and not its body.
translateLam :: MonadReader Env m => TTerm -> m Term
translateLam lam = do
  (is, t) <- translateLams lam
  return $ Mlambda is t
  where
    translateLams :: MonadReader Env m => TTerm -> m ([Ident], Term)
    translateLams (TLam body) = do
      (thisVar, (xs, t)) <- introVar (translateLams body)
      return (thisVar:xs, t)
    translateLams e = do
      e' <- translateTerm e
      return ([], e')

introVars :: MonadReader Env m => Int -> m a -> m ([Ident], a)
introVars k ma = do
  (names, env') <- nextIdxs k
  r <- local (const env') ma
  return (names, r)
  where
    nextIdxs :: MonadReader Env m => Int -> m ([Ident], Env)
    nextIdxs k = do
      i0 <- asks _level
      e <- ask
      return (map ident $ reverse [i0..i0 + k - 1], e{_level = _level e + k})

introVar :: MonadReader Env m => m a -> m (Ident, a)
introVar ma = first head <$> introVars 1 ma

-- This is really ugly, but I've done this for the reason mentioned
-- in `translatePrim'`. Note that a similiar "optimization" could be
-- done for chained lambda-expressions:
--   TLam (TLam ...)
translateApp :: MonadReader Env m => TTerm -> [TTerm] -> m Term
translateApp ft xst = case ft of
  TPrim p -> translatePrimApp p <$> mapM translateTerm xst
  TCon nm -> translateCon nm xst
  _       -> do
    f <- translateTerm ft
    xs <- mapM translateTerm xst
    return $ Mapply f xs

ident :: Int -> Ident
ident i = "v" ++ show i

translateLit :: Literal -> Term
translateLit l = case l of
  LitNat _ x -> Mint (CBigint x)
  LitString _ s -> Mstring s
  LitChar _ c-> Mint . CInt . fromEnum $ c
  _ -> error "unsupported literal type"

translatePrimApp :: TPrim -> [Term] -> Term
translatePrimApp tp args =
  case tp of
    PAdd -> intbinop Add
    PSub -> intbinop Sub
    PMul -> intbinop Mul
    PQuot -> intbinop Div
    PRem -> intbinop Mod
    PGeq -> intbinop Gte
    PLt -> intbinop Lt
    PEqI -> intbinop Eq
    PEqF -> wrong
    PEqS -> wrong
    PEqC -> intbinop Eq
    PEqQ -> wrong
    PIf -> wrong
    PSeq -> pseq
  where
    aType = TInt
    intbinop op = case args of
      [a, b] -> Mintop2 op aType a b
      [a] -> Mlambda ["b"] $ Mintop2 op aType a (Mvar "b")
      [] -> Mlambda ["a", "b"] $ Mintop2 op aType (Mvar "a") (Mvar "b")
      _ -> wrongargs
    -- NOTE: pseq is simply (\a b -> b) because malfunction is a strict language
    pseq      = case args of
      [_, b] -> b
      [_] -> Mlambda ["b"] $ Mvar "b"
      [] -> Mlambda ["a", "b"] $ Mvar "b"
      _ -> wrongargs
    -- TODO: Stub!
    -- wrong = return $ errorT $ "stub : " ++ show tp
    wrongargs = error "unexpected number of arguments"
    wrong = undefined


-- FIXME: Please not the multitude of interpreting QName in the following
-- section. This may be a problem.
-- This is due to the fact that QName can refer to constructors and regular
-- bindings, I think we want to handle these two cases separately.

-- Questionable implementation:
nameToTag :: MonadReader Env m => QName -> m Case
nameToTag nm = do
  e <- ask
  builtinbool <- builtinBool (qnameNameId nm)
  case builtinbool of
    Just b -> return (CaseInt (boolToInt b))
    Nothing ->
      ifM (isConstructor nm)
      (Tag <$> askConTag nm)
      (error $ "nameToTag only implemented for constructors, qname=" ++ show nm
       ++ "\nenv:" ++ show e)
    -- (return . Tag . fromEnum . nameId . qnameName $ nm)


isConstructor :: MonadReader Env m => QName -> m Bool
isConstructor nm = (qnameNameId nm`Map.member`) <$> askConMap

askConMap :: MonadReader Env m => m (Map NameId ConRep)
askConMap = asks _conMap

-- |
-- Set of indices of the variables that are referenced inside the term.
--
-- Example
-- λλ Env{_level = 2} usedVars (λ(λ ((Var 3) (λ (Var 4)))) ) == {1}
usedVars :: MonadReader Env m => TTerm -> m (Set Int)
usedVars term = asks _level >>= go mempty term
   where
     go vars t topnext = goterm vars t
       where
         goterms vars = foldM (\acvars tt -> goterm acvars tt) vars
         goterm vars t = do
           nextix <- asks _level
           case t of
             (TVar v) -> return $ govar vars v nextix
             (TApp t args) -> goterms vars (t:args)
             (TLam t) -> snd <$> introVar (goterm vars t)
             (TLet t1 t2) -> do
               vars1 <- goterm vars t1
               snd <$> introVar (goterm vars1 t2)
             (TCase v _ def alts) -> do
               vars1 <- goterm (govar vars v nextix) def
               foldM (\acvars alt -> goalt acvars alt) vars1 alts
             _ -> return vars
         govar vars v nextix
           | 0 <= v' && v' < topnext = Set.insert v' vars
           | otherwise = vars
           where v' = v + topnext - nextix
         goalt vars alt = case alt of
           TACon _ _ b -> goterm vars b
           TAGuard g b -> goterms vars [g, b]
           TALit{} -> return vars


-- TODO: Translate constructors differently from names.
-- Don't know if we should do the same when translating TDef's, but here we
-- should most likely use malfunction "blocks" to represent constructors
-- in an "untyped but injective way". That is, we only care that each
-- constructor maps to a unique number such that we will be able to
-- distinguish it in malfunction. This also means that we should carry
-- some state around mapping each constructor to it's corresponding
-- "block-representation".
--
-- An example for clarity. Consider type:
--
--   T a b = L a | R b | B a b | E
--
-- We need to encode the constructors in an injective way and we need to
-- encode the arity of the constructors as well.
--
--   translate (L a)   = (block (tag 2) (tag 0) a')
--   translate (R b)   = (block (tag 2) (tag 1) b')
--   translate (B a b) = (block (tag 3) (tag 2) a' b')
--   translate E       = (block (tag 1) (tag 3))
-- TODO: If the length of `ts` does not match the arity of `nm` then a lambda-expression must be returned.
translateCon :: MonadReader Env m => QName -> [TTerm] -> m Term
translateCon nm ts = do
  builtinbool <- builtinBool (qnameNameId nm)
  case builtinbool of
    Just t -> return (boolT t)
    Nothing -> do
      ts' <- mapM translateTerm ts
      tag <- askConTag nm
      arity <- askArity nm
      let diff = arity - length ts'
          vs   = take diff $ map pure ['a'..]
      return $ if diff == 0
      then Mblock tag ts'
      else Mlambda vs (Mblock tag (ts' ++ map Mvar vs))

-- | Ugly hack to represent builtin bools as integers.
-- For now it checks whether the concrete name ends with "Bool.true" or "Bool.false"
builtinBool :: MonadReader Env m => NameId -> m (Maybe Bool)
builtinBool qn = do
  isTrue <- isBuiltinTrue qn
  if isTrue then return (Just True)
    else do
    isFalse <- isBuiltinFalse qn
    if isFalse then return (Just False)
      else return Nothing
  where
    isBuiltinTrue :: MonadReader Env m => NameId -> m Bool
    isBuiltinTrue qn = maybe False ((==qn) . snd) <$> asks _biBool
    isBuiltinFalse :: MonadReader Env m => NameId -> m Bool
    isBuiltinFalse qn = maybe False ((==qn) . fst) <$> asks _biBool

-- | The argument are all data constructors grouped by datatype.
-- returns Maybe (false NameId, true NameId)
findBuiltinBool :: [[QName]] -> Maybe (NameId, NameId)
findBuiltinBool =  firstJust maybeBool
  where maybeBool l@[_,_] = firstJust falseTrue (permutations l)
          where falseTrue [f, t]
                  | "Bool.false" `isSuffixOf` show f
                  && "Bool.true" `isSuffixOf` show t = Just (qnameNameId f, qnameNameId t)
                falseTrue _ = Nothing
        maybeBool _ = Nothing

askArity :: MonadReader Env m => QName -> m Int
askArity = fmap _conArity . nontotalLookupConRep

askConTag :: MonadReader Env m => QName -> m Int
askConTag = fmap _conTag . nontotalLookupConRep

nontotalLookupConRep :: MonadReader Env f => QName -> f ConRep
nontotalLookupConRep q = fromMaybe err <$> lookupConRep q
  where
    err = error $ "Could not find constructor with qname: " ++ show q

lookupConRep :: MonadReader Env f => QName -> f (Maybe ConRep)
lookupConRep ns = Map.lookup (qnameNameId ns) <$> asks _conMap

-- Unit is treated as a glorified value in Treeless, luckily it's fairly
-- straight-forward to encode using the scheme described in the documentation
-- for `translateCon`.
unitT :: Term
unitT = Mblock 0 []

translateName :: MonadReader Env m => QName -> m Term
translateName qn = Mvar <$> nameToIdent qn

-- | Translate a Treeless name to a valid identifier in Malfunction
--
-- Not all names in agda are valid names in Treleess. Valid names in Agda are
-- given by [1]. Valid identifiers in Malfunction is subject to change:
--
-- "Atoms: sequences of ASCII letters, digits, or symbols (the exact set of
-- allowed symbols isn't quite nailed down yet)"[2]
--
-- [1. The Agda Wiki]: <http://wiki.portal.chalmers.se/agda/pmwiki.php?n=ReferenceManual2.Identifiers>
-- [2. Malfunction Spec]: <https://github.com/stedolan/malfunction/blob/master/docs/spec.md>
nameToIdent :: MonadReader Env m => QName -> m Ident
nameToIdent qn = nameIdToIdent (qnameNameId qn)

nameIdToIdent' :: NameId -> Maybe String -> Ident
nameIdToIdent' (NameId a b) msuffix = (hex a ++ "." ++ hex b ++ suffix)
  where
    suffix = maybe "" ('.':) msuffix
    hex = (`showHex` "") . toInteger

nameIdToIdent :: MonadReader Env m => NameId -> m Ident
nameIdToIdent nid = do
  x <- Map.lookup nid <$> asks _qnameConcreteMap
  return (nameIdToIdent' nid x)

-- | Translates a treeless identifier to a malfunction identifier.
qnameNameId :: QName -> NameId
qnameNameId = nameId . qnameName

-- | Compiles treeless "bindings" to a malfunction module given groups of defintions.
compile
  :: Env                -- ^ Environment.
  -> [(QName, TTerm)] -- ^ List of treeless bindings.
  -> Mod
compile env bs = runTranslate (compileM bs) env


compileM :: MonadReader Env m => [(QName, TTerm)] -> m Mod
compileM allDefs = do
  bs <- mapM translateSCC recGrps
  return $ MMod bs []
  where
    translateSCC scc = case scc of
      AcyclicSCC single -> uncurry translateBinding single
      CyclicSCC grp -> translateMutualGroup grp
    recGrps :: [SCC (QName, TTerm)]
    recGrps = dependencyGraph allDefs

translateMutualGroup :: MonadReader Env m => [(QName, TTerm)] -> m Binding
translateMutualGroup bs = Recursive <$> mapM (uncurry translateBindingPair) bs

translateBinding :: MonadReader Env m => QName -> TTerm -> m Binding
translateBinding q t = uncurry Named <$> translateBindingPair q t

translateBindingPair :: MonadReader Env m => QName -> TTerm -> m (Ident, Term)
translateBindingPair q t = do
  iden <- nameToIdent q
  (\t' -> (iden, t')) <$> translateTerm t

dependencyGraph :: [(QName, TTerm)] -> [SCC (QName, TTerm)]
dependencyGraph qs = stronglyConnComp [ ((qn, tt), qnameNameId qn, edgesFrom tt)
                                    | (qn, tt) <- qs ]
  where edgesFrom = Set.toList . qnamesIdsInTerm


qnamesIdsInTerm :: TTerm -> Set NameId
qnamesIdsInTerm t = go t mempty
  where
    insertId q = Set.insert (qnameNameId q)
    go :: TTerm -> Set NameId -> Set NameId
    go t qs = case t of
      TDef q -> insertId q qs
      TApp f args -> foldr go qs (f:args)
      TLam b -> go b qs
      TCon q -> insertId q qs
      TLet a b -> foldr go qs [a, b]
      TCase _ _ p alts -> foldr qnamesInAlt (go p qs) alts
      _  -> qs
      where
        qnamesInAlt a qs = case a of
          TACon q _ t -> insertId q (go t qs)
          TAGuard t b -> foldr go qs [t, b]
          TALit _ b -> go b qs

-- | Defines a run-time error in Malfunction - equivalent to @error@ in Haskell.
errorT :: String -> Term
errorT err = Mapply (Mglobal ["Pervasives", "failwith"]) [Mstring err]

-- | Encodes a boolean value as a numerical Malfunction value.
boolT :: Bool -> Term
boolT b = Mint (CInt $ boolToInt b)

boolToInt :: Bool -> Int
boolToInt b = if b then 1 else 0

trueCase :: [Case]
trueCase = [CaseInt 1]

-- TODO: Stub implementation!
-- Translating axioms seem to be problematic. For the other compiler they are
-- defined in Agda.TypeChecking.Monad.Base. It is a field of
-- `CompiledRepresentation`. We do not have this luxury. So what do we do?
--
-- | Translates an axiom to a malfunction binding. Returns `Nothing` if the axiom is unmapped.
compileAxiom ::
  MonadReader Env m =>
  QName                   -- The name of the axiomm
  -> m (Maybe Binding)    -- The resulting binding
compileAxiom q = Just <$> namedBinding q x
  where
    x = fromMaybe unknownAxiom
      $ Map.lookup (show q') Primitive.axioms
    unknownAxiom = Mlambda [] $ errorT $ "Unknown axiom: " ++ show q'
    q' = last . qnameToList $ q

-- | Translates a primitive to a malfunction binding. Returns `Nothing` if the primitive is unmapped.
compilePrim
  :: MonadReader Env m =>
    QName -- ^ The qname of the primitive
  -> String -- ^ The name of the primitive
  -> m (Maybe Binding)
compilePrim q s = Just <$> namedBinding q x
  where
    x = fromMaybe unknownPrimitive
      $ Map.lookup s Primitive.primitives
    unknownPrimitive = Mlambda [] $ errorT $ "Unknown primitive: " ++ s

namedBinding :: MonadReader Env m => QName -> Term -> m Binding
namedBinding q t = (`Named`t) <$> nameToIdent q
