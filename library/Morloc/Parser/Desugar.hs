{-|
Module      : Morloc.Parser.Desugar
Description : Write Module objects to resolve type aliases and such
Copyright   : (c) Zebulun Arendsee, 2020
License     : GPL-3
Maintainer  : zbwrnz@gmail.com
Stability   : experimental
-}

module Morloc.Parser.Desugar (desugar, desugarType) where

import Morloc.Namespace
import qualified Morloc.Monad as MM
import qualified Morloc.Data.Doc as MD
import qualified Morloc.Data.DAG as MDD
import qualified Morloc.Data.Text as MT
import qualified Data.Map as Map
import qualified Data.Set as Set

desugar
  :: DAG MVar Import ParserNode
  -> MorlocMonad (DAG MVar [(EVar, EVar)] PreparedNode)
desugar s
  -- DAG MVar Import ParserNode
  = resolveImports s
  -- DAG MVar (Map EVar EVar) ParserNode
  >>= desugarDag
  -- DAG MVar (Map EVar EVar) PreparedNode
  >>= simplify

-- | Consider export/import information to determine which terms are imported
-- into each module. This step reduces the Import edge type to an m-to-n source
-- name to alias map.
resolveImports
  :: DAG MVar Import ParserNode
  -> MorlocMonad (DAG MVar [(EVar, EVar)] ParserNode)
resolveImports = MDD.mapEdgeWithNodeM resolveImport where
  resolveImport
    :: ParserNode
    -> Import
    -> ParserNode
    -> MorlocMonad [(EVar, EVar)]
  resolveImport _ (Import v Nothing exc _) n2
    = return
    . map (\x -> (x,x)) -- alias is identical
    . Set.toList
    $ Set.difference (parserNodeExports n2) (Set.fromList exc)
  resolveImport _ (Import v (Just inc) exc _) n2
    | length contradict > 0
        = MM.throwError . CallTheMonkeys
        $ "Error: The following terms are both included and excluded: " <>
          MD.render (MD.tupledNoFold $ map MD.pretty contradict)
    | length missing > 0
        = MM.throwError . CallTheMonkeys
        $ "Error: The following terms are not exported: " <>
          MD.render (MD.tupledNoFold $ map MD.pretty missing)
    | otherwise = return inc
    where
      missing = [n | (n, _) <- inc, not $ Set.member n (parserNodeExports n2)]
      contradict = [n | (n, _) <- inc, elem n exc]

desugarDag
  :: DAG MVar [(EVar, EVar)] ParserNode
  -> MorlocMonad (DAG MVar [(EVar, EVar)] ParserNode)
desugarDag m = do
  mapM_ checkForSelfRecursion (map parserNodeTypedefs (MDD.nodes m))
  MDD.mapNodeWithKeyM (desugarParserNode m) m

simplify
  :: (DAG MVar [(EVar, EVar)] ParserNode)
  -> MorlocMonad (DAG MVar [(EVar, EVar)] PreparedNode)
simplify = return . MDD.mapNode prepare where
  prepare :: ParserNode -> PreparedNode
  prepare n1 = PreparedNode
    { preparedNodePath = parserNodePath n1
    , preparedNodeBody = parserNodeBody n1
    , preparedNodeSourceMap = parserNodeSourceMap n1
    }

checkForSelfRecursion :: Map.Map TVar (Type, [TVar]) -> MorlocMonad ()
checkForSelfRecursion h = mapM_ (uncurry f) [(v,t) | (v,(t,_)) <- Map.toList h] where
  f :: TVar -> Type -> MorlocMonad ()
  f v (VarT v')
    | v == v' = MM.throwError . SelfRecursiveTypeAlias $ v
    | otherwise = return ()
  f _ (ExistT _ _ _) = MM.throwError $ CallTheMonkeys "existential crisis"
  f v (Forall _ t) = f v t
  f v (FunT t1 t2) = f v t1 >> f v t2
  f v (ArrT v0 ts)
    | v == v0 = MM.throwError . SelfRecursiveTypeAlias $ v
    | otherwise = mapM_ (f v) ts
  f v (NamT v0 rs)
    | v == v0 = MM.throwError . SelfRecursiveTypeAlias $ v
    | otherwise = mapM_ (f v) (map snd rs)

desugarParserNode :: DAG MVar [(EVar, EVar)] ParserNode -> MVar -> ParserNode -> MorlocMonad ParserNode
desugarParserNode d k n = do
  nodeBody <- mapM (desugarExpr d k) (parserNodeBody n)
  return $ n { parserNodeBody = nodeBody }  

desugarExpr :: DAG MVar [(EVar, EVar)] ParserNode -> MVar -> Expr -> MorlocMonad Expr
desugarExpr _ _ e@(SrcE _) = return e
desugarExpr d k (Signature v t) = Signature v <$> desugarEType d k t
desugarExpr d k (Declaration v e) = Declaration v <$> desugarExpr d k e
desugarExpr _ _ UniE = return UniE
desugarExpr _ _ e@(VarE _) = return e
desugarExpr d k (ListE xs) = ListE <$> mapM (desugarExpr d k) xs
desugarExpr d k (TupleE xs) = TupleE <$> mapM (desugarExpr d k) xs
desugarExpr d k (LamE v e) = LamE v <$> desugarExpr d k e
desugarExpr d k (AppE e1 e2) = AppE <$> desugarExpr d k e1 <*> desugarExpr d k e2
desugarExpr d k (AnnE e ts) = AnnE <$> desugarExpr d k e <*> mapM (desugarType [] d k) ts
desugarExpr _ _ e@(NumE _) = return e
desugarExpr _ _ e@(LogE _) = return e
desugarExpr _ _ e@(StrE _) = return e
desugarExpr d k (RecE rs) = do
  es <- mapM (desugarExpr d k) (map snd rs)
  return (RecE (zip (map fst rs) es))

desugarEType :: DAG MVar [(EVar, EVar)] ParserNode -> MVar -> EType -> MorlocMonad EType
desugarEType d k (EType t ps cs) = EType <$> desugarType [] d k t <*> pure ps <*> pure cs

desugarType :: [TVar] -> DAG MVar [(EVar, EVar)] ParserNode -> MVar -> Type -> MorlocMonad Type
desugarType s d k t0@(VarT v)
  | elem v s = MM.throwError . MutuallyRecursiveTypeAlias $ s
  | otherwise = case lookupTypedefs v k d of
    [] -> return t0
    [(t, [])] -> desugarType (v:s) d k t
    [(t, vs)] -> MM.throwError $ BadTypeAliasParameters v 0 (length vs)
    (_:_) -> MM.throwError . CallTheMonkeys $ "Conflicting type aliases"
desugarType s d k (ExistT v ts ds) = do
  ts' <- mapM (desugarType s d k) ts
  ds' <- mapM (desugarType s d k) (map unDefaultType ds)
  return $ ExistT v ts' (map DefaultType ds')
desugarType s d k (Forall v t) = Forall v <$> desugarType s d k t
desugarType s d k (FunT t1 t2) = FunT <$> desugarType s d k t1 <*> desugarType s d k t2
desugarType s d k t0@(ArrT v ts)
  | elem v s = MM.throwError . MutuallyRecursiveTypeAlias $ s
  | otherwise = case lookupTypedefs v k d of
      [] -> ArrT v <$> mapM (desugarType s d k) ts
      [(t, vs)] ->
        if length ts == length vs
        then desugarType (v:s) d k (foldr parsub t (zip vs ts)) -- substitute parameters into alias
        else MM.throwError $ BadTypeAliasParameters v (length vs) (length ts)
      (_:_) -> MM.throwError . CallTheMonkeys $ "Conflicting type aliases"
desugarType s d k (NamT v rs) = do
  let keys = map fst rs
  vals <- mapM (desugarType s d k) (map snd rs)
  return (NamT v (zip keys vals))

lookupTypedefs :: TVar -> MVar -> DAG MVar [(EVar, EVar)] ParserNode -> [(Type, [TVar])]
lookupTypedefs t@(TV _ v) k h
  = catMaybes
  . MDD.nodes
  $ MDD.lookupAliasedTerm (EVar v) k (\n -> Map.lookup t (parserNodeTypedefs n)) h

parsub :: (TVar, Type) -> Type -> Type
parsub (v, t2) t1@(VarT v0)
  | v0 == v = t2 -- substitute
  | otherwise = t1 -- keep the original
parsub _ (ExistT _ _ _) = error "What the bloody hell is an existential doing down here?"
parsub pair (Forall v t1) = Forall v (parsub pair t1)
parsub pair (FunT a b) = FunT (parsub pair a) (parsub pair b)
parsub pair (ArrT v ts) = ArrT v (map (parsub pair) ts)
parsub pair (NamT v rs) = NamT v (zip (map fst rs) (map (parsub pair . snd) rs))
