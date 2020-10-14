{-|
Module      : Morloc.Frontend.Desugar
Description : Write Module objects to resolve type aliases and such
Copyright   : (c) Zebulun Arendsee, 2020
License     : GPL-3
Maintainer  : zbwrnz@gmail.com
Stability   : experimental
-}

module Morloc.Frontend.Desugar (desugar, desugarType) where

import Morloc.Frontend.Namespace
import qualified Morloc.Monad as MM
import qualified Morloc.Data.Doc as MD
import qualified Morloc.Data.DAG as MDD
import qualified Morloc.Data.Text as MT
import qualified Data.Map as Map
import qualified Data.Set as Set
import qualified Morloc.Frontend.PartialOrder as MTP

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
  -- Add packer map
  >>= addPackerMap


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
    , preparedNodeExports = parserNodeExports n1
    }

checkForSelfRecursion :: Map.Map TVar (UnresolvedType, [TVar]) -> MorlocMonad ()
checkForSelfRecursion h = mapM_ (uncurry f) [(v,t) | (v,(t,_)) <- Map.toList h] where
  f :: TVar -> UnresolvedType -> MorlocMonad ()
  f v (VarU v')
    | v == v' = MM.throwError . SelfRecursiveTypeAlias $ v
    | otherwise = return ()
  f _ (ExistU _ _ _) = MM.throwError $ CallTheMonkeys "existential crisis"
  f v (ForallU _ t) = f v t
  f v (FunU t1 t2) = f v t1 >> f v t2
  f v (ArrU v0 ts)
    | v == v0 = MM.throwError . SelfRecursiveTypeAlias $ v
    | otherwise = mapM_ (f v) ts
  f v (NamU v0 rs)
    | v == v0 = MM.throwError . SelfRecursiveTypeAlias $ v
    | otherwise = mapM_ (f v) (map snd rs)

desugarParserNode
  :: DAG MVar [(EVar, EVar)] ParserNode
  -> MVar
  -> ParserNode
  -> MorlocMonad ParserNode
desugarParserNode d k n = do
  nodeBody <- mapM (desugarExpr d k) (parserNodeBody n)
  return $ n { parserNodeBody = nodeBody }

desugarExpr
  :: DAG MVar [(EVar, EVar)] ParserNode
  -> MVar
  -> Expr
  -> MorlocMonad Expr
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

desugarType
  :: [TVar]
  -> DAG MVar [(EVar, EVar)] ParserNode
  -> MVar
  -> UnresolvedType
  -> MorlocMonad UnresolvedType
desugarType s d k t0@(VarU v)
  | elem v s = MM.throwError . MutuallyRecursiveTypeAlias $ s
  | otherwise = case lookupTypedefs v k d of
    [] -> return t0
    ts'@(t':_) -> do
      (t, _) <- foldlM (mergeAliases v 0) t' ts'
      desugarType (v:s) d k t
desugarType s d k (ExistU v ts ds) = do
  ts' <- mapM (desugarType s d k) ts
  ds' <- mapM (desugarType s d k) ds
  return $ ExistU v ts' ds'
desugarType s d k (ForallU v t) = ForallU v <$> desugarType s d k t
desugarType s d k (FunU t1 t2) = FunU <$> desugarType s d k t1 <*> desugarType s d k t2
desugarType s d k t0@(ArrU v ts)
  | elem v s = MM.throwError . MutuallyRecursiveTypeAlias $ s
  | otherwise = case lookupTypedefs v k d of
      [] -> ArrU v <$> mapM (desugarType s d k) ts
      (t':ts') -> do
        (t, vs) <- foldlM (mergeAliases v (length ts)) t' ts'
        if length ts == length vs
          -- substitute parameters into alias
          then desugarType (v:s) d k (foldr parsub t (zip vs ts))
          else MM.throwError $ BadTypeAliasParameters v (length vs) (length ts)
desugarType s d k (NamU v rs) = do
  let keys = map fst rs
  vals <- mapM (desugarType s d k) (map snd rs)
  return (NamU v (zip keys vals))

lookupTypedefs
  :: TVar
  -> MVar
  -> DAG MVar [(EVar, EVar)] ParserNode
  -> [(UnresolvedType, [TVar])]
lookupTypedefs t@(TV lang v) k h
  = catMaybes
  . MDD.nodes
  . MDD.mapNode (\(EVar v', typemap) -> Map.lookup (TV lang v') typemap)
  $ MDD.lookupAliasedTerm (EVar v) k parserNodeTypedefs h


-- When a type alias is imported from two places, this function reconciles them, if possible
mergeAliases
  :: TVar
  -> Int
  -> (UnresolvedType, [TVar])
  -> (UnresolvedType, [TVar])
  -> MorlocMonad (UnresolvedType, [TVar])
mergeAliases v i t@(t1, ts1) (t2, ts2)
  | i /= length ts1 = MM.throwError $ BadTypeAliasParameters v i (length ts1)
  |    MTP.isSubtypeOf t1' t2'
    && MTP.isSubtypeOf t2' t1'
    && length ts1 == length ts2 = return t
  | otherwise = MM.throwError (ConflictingTypeAliases (unresolvedType2type t1) (unresolvedType2type t2))
  where
    t1' = foldl (\t v -> ForallU v t) t1 ts1
    t2' = foldl (\t v -> ForallU v t) t2 ts2


parsub :: (TVar, UnresolvedType) -> UnresolvedType -> UnresolvedType
parsub (v, t2) t1@(VarU v0)
  | v0 == v = t2 -- substitute
  | otherwise = t1 -- keep the original
parsub _ (ExistU _ _ _) = error "What the bloody hell is an existential doing down here?"
parsub pair (ForallU v t1) = ForallU v (parsub pair t1)
parsub pair (FunU a b) = FunU (parsub pair a) (parsub pair b)
parsub pair (ArrU v ts) = ArrU v (map (parsub pair) ts)
parsub pair (NamU v rs) = NamU v (zip (map fst rs) (map (parsub pair . snd) rs))




addPackerMap
  :: (DAG MVar [(EVar, EVar)] PreparedNode)
  -> MorlocMonad (DAG MVar [(EVar, EVar)] PreparedNode)
addPackerMap d = do
  maybeDAG <- MDD.synthesizeDAG gatherPackers d
  case maybeDAG of
    Nothing -> MM.throwError CyclicDependency
    (Just d') -> return d'

gatherPackers
  :: MVar
  -> PreparedNode
  -> [(MVar, [(EVar, EVar)], PreparedNode)]
  -> MorlocMonad PreparedNode
gatherPackers k n1 es = do
  let packers   = starpack n1 Pack
      unpackers = starpack n1 Unpack
  nodepackers <- makeNodePackers packers unpackers n1
  let m = Map.unionsWith (<>) $ map (\(_, e, n2) -> inheritPackers e n2) es
  return $ n1 { preparedNodePackers = Map.unionWith (<>) nodepackers m }

starpack :: PreparedNode -> Property -> [(EVar, UnresolvedType, [Source])]
starpack n pro
  = map (\(v,t) -> (v, t, maybeToList $ Map.lookup (v, fromJust $ langOf t) (preparedNodeSourceMap n)))
  $ [(v, t) | (Signature v (EType t p c)) <- preparedNodeBody n, Set.member pro p]

makeNodePackers
  :: [(EVar, UnresolvedType, [Source])]
  -> [(EVar, UnresolvedType, [Source])]
  -> PreparedNode
  -> MorlocMonad (Map.Map (TVar, Int) [UnresolvedPacker])
makeNodePackers xs ys n
  = return . Map.fromList
  $ [ ((TV (langOf t1) (unEVar v1), parity t1), [UnresolvedPacker (packerType t1) ss1 ss2])
    | (v1, t1, ss1) <- xs, (v2, t2, ss2) <- ys, v1 == v2, packerTypesMatch t1 t2]

parity :: UnresolvedType -> Int
parity = length . fst . splitArgs

packerTypesMatch :: UnresolvedType -> UnresolvedType -> Bool
packerTypesMatch t1 t2 = case (splitArgs t1, splitArgs t2) of
  ((vs1@[_,_], [t11, t12]), (vs2@[_,_], [t21, t22]))
    -> MTP.equivalent (qualify vs1 t11) (qualify vs2 t22)
    && MTP.equivalent (qualify vs1 t12) (qualify vs2 t21)
  _ -> False

packerType :: UnresolvedType -> UnresolvedType
packerType t = case splitArgs t of
  (_, [t1, _]) -> t1
  _ -> error "bad packer"

nargsU :: UnresolvedType -> Int
nargsU (ForallU _ t) = nargsU t
nargsU (FunU _ t) = 1 + nargsU t
nargsU _ = 0

qualify :: [TVar] -> UnresolvedType -> UnresolvedType
qualify [] t = t
qualify (v:vs) t = ForallU v (qualify vs t)

splitArgs :: UnresolvedType -> ([TVar], [UnresolvedType])
splitArgs (ForallU v u) =
  let (vs, ts) = splitArgs u
  in (v:vs, ts)
splitArgs (FunU t1 t2) =
  let (vs, ts) = splitArgs t2
  in (vs, t1:ts)
splitArgs t = ([], [t])

inheritPackers
  :: [(EVar, EVar)]
  -> PreparedNode
  -> Map.Map (TVar, Int) [UnresolvedPacker]
inheritPackers es n =
  let names = Set.fromList (map (unEVar . fst) es)
  in   Map.mapKeysWith (<>)
        (\(TV l v, i) -> (TV l . unEVar . fromJust . lookup (EVar v) $ es, i))
     $ Map.filterWithKey (\(TV _ v, _) _ -> Set.member v names) (preparedNodePackers n)
