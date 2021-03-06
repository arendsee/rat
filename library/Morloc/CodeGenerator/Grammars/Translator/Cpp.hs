{-# LANGUAGE TemplateHaskell, QuasiQuotes #-}

{-|
Module      : Morloc.CodeGenerator.Grammars.Translator.Cpp
Description : C++ translator
Copyright   : (c) Zebulun Arendsee, 2021
License     : GPL-3
Maintainer  : zbwrnz@gmail.com
Stability   : experimental
-}

module Morloc.CodeGenerator.Grammars.Translator.Cpp
  ( 
    translate
  , preprocess
  ) where

import Morloc.CodeGenerator.Namespace
import Morloc.CodeGenerator.Internal (typeP2typeM)
import Morloc.CodeGenerator.Serial ( isSerializable
                                   , prettySerialOne
                                   , serialAstToType
                                   , serialAstToType'
                                   , shallowType
                                   )
import Morloc.CodeGenerator.Grammars.Common
import qualified Morloc.CodeGenerator.Grammars.Translator.Source.CppInternals as Src
import Morloc.Data.Doc
import Morloc.Quasi
import qualified Morloc.System as MS
import Morloc.CodeGenerator.Grammars.Macro (expandMacro)
import qualified Morloc.Monad as MM
import qualified Data.Map as Map
import qualified Morloc.Data.Text as MT

-- | @RecEntry@ stores the common name, keys, and types of records that are not
-- imported from C++ source. These records are generated as structs in the C++
-- pool. @unifyRecords@ takes all such records and "unifies" ones with the same
-- name and keys. The unified records may have different types, but they will
-- all be instances of the same generic struct. That is, any fields that differ
-- between instances will be made generic.
data RecEntry = RecEntry {
    recName :: MDoc -- ^ the automatically generated name for this anonymous type
  , recFields :: [( PVar -- The field key
                  , Maybe TypeP -- The field type if not generic
                  )]
}

-- | @RecMap@ is used to lookup up the struct name shared by all records that
-- are not imported from C++ source.
type RecMap = [((PVar, [PVar]), RecEntry)]

-- tree rewrites
preprocess :: ExprM Many -> MorlocMonad (ExprM Many)
preprocess = invertExprM

translate :: [Source] -> [ExprM One] -> MorlocMonad MDoc
translate srcs es = do
  -- translate sources
  includeDocs <- mapM
    translateSource
    (unique . catMaybes . map srcPath $ srcs)

  -- diagnostics
  liftIO . putDoc . vsep $ "-- C++ translation --" : map prettyExprM es

  let recmap = unifyRecords . conmap collectRecords $ es
      (autoDecl, autoSerial) = generateAnonymousStructs recmap
      (srcDecl, srcSerial) = generateSourcedSerializers es
      dispatch = makeDispatch es
      signatures = map (makeSignature recmap) es
      serializationCode = autoDecl ++ srcDecl ++ autoSerial ++ srcSerial

  -- translate each manifold tree, rooted on a call from nexus or another pool
  mDocs <- mapM (translateManifold recmap) es

  -- create and return complete pool script
  return $ makeMain includeDocs signatures serializationCode mDocs dispatch

letNamer :: Int -> MDoc
letNamer i = "a" <> viaShow i

manNamer :: Int -> MDoc
manNamer i = "m" <> viaShow i

bndNamer :: Int -> MDoc
bndNamer i = "x" <> viaShow i

serialType :: MDoc
serialType = "std::string"

makeSignature :: RecMap -> ExprM One -> MDoc
makeSignature recmap e0@(ManifoldM _ _ _) = vsep (f e0) where
  f :: ExprM One -> [MDoc]
  f (ManifoldM (metaId->i) args e) =
    let t = typeOfExprM e
        sig = showTypeM recmap t <+> manNamer i <> tupled (map (makeArg recmap) args) <> ";"
    in sig : f e
  f (LetM _ e1 e2) = f e1 ++ f e2
  f (AppM e es) = f e ++ conmap f es
  f (LamM _ e) = f e
  f (AccM e _) = f e
  f (ListM _ es) = conmap f es
  f (TupleM _ es) = conmap f es
  f (RecordM _ entries) = conmap f (map snd entries)
  f (SerializeM _ e) = f e
  f (DeserializeM _ e) = f e
  f (ReturnM e) = f e
  f _ = []
makeSignature _ _ = error "Expected ManifoldM"

makeArg :: RecMap -> Argument -> MDoc
makeArg _ (SerialArgument i _) = serialType <+> bndNamer i
makeArg recmap (NativeArgument i c) = showTypeM recmap (Native c) <+> bndNamer i
makeArg _ (PassThroughArgument i) = serialType <+> bndNamer i

argName :: Argument -> MDoc
argName (SerialArgument i _) = bndNamer i
argName (NativeArgument i _) = bndNamer i
argName (PassThroughArgument i) = bndNamer i

tupleKey :: Int -> MDoc -> MDoc
tupleKey i v = [idoc|std::get<#{pretty i}>(#{v})|]

recordAccess :: MDoc -> MDoc -> MDoc
recordAccess record field = record <> "." <> field

-- TLDR: Use `#include "foo.h"` rather than `#include <foo.h>`
-- Include statements in C can be either wrapped in angle brackets (e.g.,
-- `<stdio.h>`) or in quotes (e.g., `"myfile.h"`). The difference between these
-- is implementation specific. I currently use the GCC compiler. For quoted
-- strings, it first searches relative to the working directory and then, if
-- nothing is found, searches system files. For angle brackets, it searches
-- only system files: <https://gcc.gnu.org/onlinedocs/cpp/Search-Path.html>. So
-- quoting seems more reasonable, for now. This might change only if I start
-- loading the morloc libraries into the system directories (which might be
-- reasonable), though still, quotes would work.
--
-- UPDATE: The build system will now read the source paths from the Script
-- object and write an `-I${MORLOC_HOME}/lib/${MORLOC_PACKAGE}` argument for
-- g++. This will tell g++ where to look for headers. So now in the generated
-- source code I can just write the basename. This makes the generated code
-- neater (no hard-coded local paths), but now the g++ compiler will search
-- through all the module paths for each file, which introduces the possibility
-- of name conflicts.
translateSource
  :: Path -- ^ Path to a header (e.g., `$MORLOC_HOME/src/foo.h`)
  -> MorlocMonad MDoc
translateSource path = return $
  "#include" <+> (dquotes . pretty . MS.takeFileName) path


serialize
  :: RecMap
  -> Int -- The let index `i`
  -> MDoc -- A variable name pointing to e1
  -> SerialAST One
  -> MorlocMonad [MDoc]
serialize recmap letIndex datavar0 s0 = do
  (x, before) <- serialize' datavar0 s0
  t0 <- (showTypeM recmap . Native) <$> serialAstToType s0
  let schemaName = [idoc|#{letNamer letIndex}_schema|]
      schema = [idoc|#{t0} #{schemaName};|]
      final = [idoc|#{serialType} #{letNamer letIndex} = serialize(#{x}, #{schemaName});|]
  return (before ++ [schema, final])

  where
    serialize'
      :: MDoc -- a variable name that stores the data described by the SerialAST object
      -> SerialAST One -> MorlocMonad (MDoc, [MDoc])
    serialize' v s
      | isSerializable s = return (v, [])
      | otherwise = construct v s

    construct :: MDoc -> SerialAST One -> MorlocMonad (MDoc, [MDoc])
    construct v (SerialPack _ (One (p, s))) = do
      unpacker <- case typePackerReverse p of
        [] -> MM.throwError . SerializationError $ "No unpacker found"
        (src:_) -> return . pretty . srcName $ src
      serialize' [idoc|#{unpacker}(#{v})|] s

    construct v lst@(SerialList s) = do
      idx <- fmap pretty $ MM.getCounter
      t <- serialAstToType lst
      let v' = "s" <> idx 
          decl = [idoc|#{showType recmap t} #{v'};|]
      (x, before) <- serialize' [idoc|#{v}[i#{idx}]|] s
      let push = [idoc|#{v'}.push_back(#{x});|]
          loop  = block 4 [idoc|for(size_t i#{idx} = 0; i#{idx} < #{v}.size(); i#{idx}++)|] 
                         (vsep (before ++ [push]))
      return (v', [decl, loop])

    construct v tup@(SerialTuple ss) = do
      (ss', befores) <- fmap unzip $ zipWithM (\i s -> serialize' (tupleKey i v) s) [0..] ss
      idx <- fmap pretty $ MM.getCounter
      t <- serialAstToType tup
      let v' = "s" <> idx
          x = [idoc|#{showType recmap t} #{v'} = std::make_tuple#{tupled ss'};|]
      return (v', concat befores ++ [x]);

    construct v rec@(SerialObject NamRecord _ _ rs) = do
      (ss', befores) <- fmap unzip $ mapM (\(PV _ _ k,s) -> serialize' (recordAccess v (pretty k)) s) rs
      idx <- fmap pretty $ MM.getCounter
      t <- (showType recmap) <$> serialAstToType rec
      let v' = "s" <> idx
          decl = encloseSep "{" "}" "," ss'
          x = [idoc|#{t} #{v'} = #{decl};|]
      return (v', concat befores ++ [x]);

    construct _ s = MM.throwError . SerializationError . render
      $ "construct: " <> prettySerialOne s

-- reverse of serialize, parameters are the same
deserialize :: RecMap -> Int -> MDoc -> MDoc -> SerialAST One -> MorlocMonad [MDoc]
deserialize recmap letIndex typestr0 varname0 s0
  | isSerializable s0 = do 
      let schemaName = [idoc|#{letNamer letIndex}_schema|]
          schema = [idoc|#{typestr0} #{schemaName};|]
          deserializing = [idoc|#{typestr0} #{letNamer letIndex} = deserialize(#{varname0}, #{schemaName});|]
      return [schema, deserializing]
  | otherwise = do
      idx <- fmap pretty $ MM.getCounter
      t <- serialAstToType s0
      let rawtype = showType recmap $ t
          schemaName = [idoc|#{letNamer letIndex}_schema|]
          rawvar = "s" <> idx
          schema = [idoc|#{rawtype} #{schemaName};|]
          deserializing = [idoc|#{rawtype} #{rawvar} = deserialize(#{varname0}, #{schemaName});|]
      (x, before) <- construct rawvar s0
      let final = [idoc|#{typestr0} #{letNamer letIndex} = #{x};|]
      return ([schema, deserializing] ++ before ++ [final])

  where
    check :: MDoc -> SerialAST One -> MorlocMonad (MDoc, [MDoc])
    check v s
      | isSerializable s = return (v, [])
      | otherwise = construct v s

    construct :: MDoc -> SerialAST One -> MorlocMonad (MDoc, [MDoc])
    construct v (SerialPack _ (One (p, s'))) = do
      packer <- case typePackerForward p of
        [] -> MM.throwError . SerializationError $ "No packer found"
        (x:_) -> return . pretty . srcName $ x
      (x, before) <- check v s'
      let deserialized = [idoc|#{packer}(#{x})|]
      return (deserialized, before)

    construct v lst@(SerialList s) = do
      idx <- fmap pretty $ MM.getCounter
      t <- fmap (showType recmap) $ shallowType lst
      let v' = "s" <> idx 
          decl = [idoc|#{t} #{v'};|]
      (x, before) <- check [idoc|#{v}[i#{idx}]|] s
      let push = [idoc|#{v'}.push_back(#{x});|]
          loop = block 4 [idoc|for(size_t i#{idx} = 0; i#{idx} < #{v}.size(); i#{idx}++)|] 
                         (vsep (before ++ [push]))
      return (v', [decl, loop])

    construct v tup@(SerialTuple ss) = do
      idx <- fmap pretty $ MM.getCounter
      (ss', befores) <- fmap unzip $ zipWithM (\i s -> check (tupleKey i v) s) [0..] ss
      t <- shallowType tup
      let v' = "s" <> idx
          x = [idoc|#{showType recmap $ t} #{v'} = std::make_tuple#{tupled ss'};|]
      return (v', concat befores ++ [x]);

    construct v rec@(SerialObject NamRecord _ _ rs) = do
      idx <- fmap pretty $ MM.getCounter
      (ss', befores) <- fmap unzip $ mapM (\(PV _ _ k,s) -> check (recordAccess v (pretty k)) s) rs
      t <- fmap (showType recmap) $ shallowType rec
      let v' = "s" <> idx
          decl = encloseSep "{" "}" "," ss'
          x = [idoc|#{t} #{v'} = #{decl};|]
      return (v', concat befores ++ [x]);

    construct _ s = MM.throwError . SerializationError . render
      $ "deserializeDescend: " <> prettySerialOne s

translateManifold :: RecMap -> ExprM One -> MorlocMonad MDoc
translateManifold recmap m0@(ManifoldM _ args0 _) = do
  MM.startCounter
  (vsep . punctuate line . (\(x,_,_)->x)) <$> f args0 m0
  where

  f :: [Argument]
    -> ExprM One
    -> MorlocMonad
       ( [MDoc] -- the collection of final manifolds
       , MDoc -- a call tag for this expression
       , [MDoc] -- a list of statements that should precede this assignment
       )

  f args (LetM i (SerializeM s e1) e2) = do
    (ms1, e1', ps1) <- f args e1
    (ms2, e2', ps2) <- f args e2
    serialized <- serialize recmap i e1' s
    return (ms1 ++ ms2, vsep $ ps1 ++ ps2 ++ serialized ++ [e2'], [])

  f args (LetM i (DeserializeM s e1) e2) = do
    (ms1, e1', ps1) <- f args e1
    (ms2, e2', ps2) <- f args e2
    t <- showNativeTypeM recmap (typeOfExprM e1)
    deserialized <- deserialize recmap i t e1' s
    return (ms1 ++ ms2, vsep $ ps1 ++ ps2 ++ deserialized ++ [e2'], [])

  f _ (SerializeM _ _) = MM.throwError . SerializationError
    $ "SerializeM should only appear in an assignment"

  f _ (DeserializeM _ _) = MM.throwError . SerializationError
    $ "DeserializeM should only appear in an assignment"

  f args (LetM i e1 e2) = do
    (ms1', e1', ps1) <- (f args) e1
    (ms2', e2', ps2) <- (f args) e2
    let t = showTypeM recmap (typeOfExprM e1)
        ps = ps1 ++ ps2 ++ [[idoc|#{t} #{letNamer i} = #{e1'};|], e2']
    return (ms1' ++ ms2', vsep ps, [])

  f args (AppM (SrcM (Function inputs output) src) xs) = do
    (mss', xs', pss) <- mapM (f args) xs |>> unzip3
    let
        name = pretty $ srcName src
        mangledName = mangleSourceName name
        inputBlock = cat (punctuate "," (map (showTypeM recmap) inputs))
        sig = [idoc|#{showTypeM recmap output}(*#{mangledName})(#{inputBlock}) = &#{name};|]
    return (concat mss', mangledName <> tupled xs', sig : concat pss)

  f _ (AppM _ _) = error "Can only apply functions"

  f _ (SrcM _ src) = return ([], pretty $ srcName src, [])

  f pargs (ManifoldM (metaId->i) args e) = do
    (ms', body, ps1) <- f args e
    let t = typeOfExprM e
        decl = showTypeM recmap t <+> manNamer i <> tupled (map (makeArg recmap) args)
        mdoc = block 4 decl body
        mname = manNamer i
    (call, ps2) <- case (splitArgs args pargs, nargsTypeM t) of
      ((rs, []), _) -> return (mname <> tupled (map (bndNamer . argId) rs), [])
      (([], _ ), _) -> return (mname, [])
      ((rs, vs), _) -> do
        let v = mname <> "_fun"
        lhs <- stdFunction recmap t vs |>> (\x -> x <+> v)
        castFunction <- staticCast recmap t args mname
        let vs' = take
                  (length vs)
                  (map (\j -> "std::placeholders::_" <> viaShow j) ([1..] :: [Int]))
            rs' = map (bndNamer . argId) rs
            rhs = stdBind $ castFunction : (rs' ++ vs')
            sig = nest 4 (vsep [lhs <+> "=", rhs]) <> ";"
        return (v, [sig])
    return (mdoc : ms', call, ps1 ++ ps2)

  f _ (PoolCallM _ _ cmds args) = do
    let bufDef = "std::ostringstream s;"
        callArgs = map dquotes cmds ++ map argName args
        cmd = "s << " <> cat (punctuate " << \" \" << " callArgs) <> ";"
        call = [idoc|foreign_call(s.str())|] 
    return ([], call, [bufDef, cmd])

  f _ (ForeignInterfaceM _ _) = MM.throwError . CallTheMonkeys $
    "Foreign interfaces should have been resolved before passed to the translators"

  f _ (LamM _ _) = undefined

  f args (AccM e k) = do
    (ms, e', ps) <- f args e
    return (ms, e' <> "." <> pretty k, ps)

  f args (ListM _ es) = do
    (mss', es', pss) <- mapM (f args) es |>> unzip3
    let x' = encloseSep "{" "}" "," es'
    return (concat mss', x', concat pss)

  f args (TupleM _ es) = do
    (mss', es', pss) <- mapM (f args) es |>> unzip3
    return (concat mss', "std::make_tuple" <> tupled es', concat pss)

  f args (RecordM c entries) = do
    (mss', es', pss) <- mapM (f args . snd) entries |>> unzip3
    idx <- fmap pretty $ MM.getCounter
    let t = showTypeM recmap c
        v' = "a" <> idx
        decl = encloseSep "{" "}" "," es'
        x = [idoc|#{t} #{v'} = #{decl};|]
    return (concat mss', v', concat pss ++ [x])

  f _ (BndVarM _ i) = return ([], bndNamer i, [])
  f _ (LetVarM _ i) = return ([], letNamer i, [])
  f _ (LogM _ x) = return ([], if x then "true" else "false", [])
  f _ (NumM _ x) = return ([], viaShow x, [])
  f _ (StrM _ x) = return ([], dquotes $ pretty x, [])
  f _ (NullM _) = return ([], "null", [])

  f args (ReturnM e) = do
    (ms, e', ps) <- f args e
    return (ms, "return(" <> e' <> ");", ps)
translateManifold _ _ = error "Every ExprM object must start with a Manifold term"

-- take a name from the source and return a new function name
-- this must work even if there is a namespace, for example:
--   SimpleNoise::noise  -->  noise__fun
mangleSourceName :: MDoc -> MDoc
mangleSourceName var = case MT.breakOnEnd "::" (render var) of
  (_, var') -> pretty $ var' <> "_fun"

stdFunction :: RecMap -> TypeM -> [Argument] -> MorlocMonad MDoc
stdFunction recmap t args = 
  let argList = cat (punctuate "," (map (argTypeM recmap) args))
  in return [idoc|std::function<#{showTypeM recmap t}(#{argList})>|]

stdBind :: [MDoc] -> MDoc
stdBind xs = [idoc|std::bind(#{args})|] where
  args = cat (punctuate "," xs)

staticCast :: RecMap -> TypeM -> [Argument] -> MDoc -> MorlocMonad MDoc
staticCast recmap t args name = do
  let output = showTypeM recmap t
      inputs = map (argTypeM recmap) args
      argList = cat (punctuate "," inputs)
  return $ [idoc|static_cast<#{output}(*)(#{argList})>(&#{name})|]

argTypeM :: RecMap -> Argument -> MDoc
argTypeM _ (SerialArgument _ _) = serialType
argTypeM recmap (NativeArgument _ c) = showType recmap c
argTypeM _ (PassThroughArgument _) = serialType

makeDispatch :: [ExprM One] -> MDoc
makeDispatch ms = block 4 "switch(cmdID)" (vsep (map makeCase ms))
  where
    makeCase :: ExprM One -> MDoc
    makeCase (ManifoldM (metaId->i) args _) =
      let args' = take (length args) $ map (\j -> "argv[" <> viaShow j <> "]") ([2..] :: [Int])
      in
        (nest 4 . vsep)
          [ "case" <+> viaShow i <> ":"
          , "result = " <> manNamer i <> tupled args' <> ";"
          , "break;"
          ]
    makeCase _ = error "Every ExprM must start with a manifold object"

showType :: RecMap -> TypeP -> MDoc
showType _ (UnkP _) = serialType
showType _ (VarP (PV _ _ v)) = pretty v 
showType recmap t@(FunP _ _) = showTypeM recmap (typeP2typeM t)
showType recmap (ArrP (PV _ _ v) ts) = pretty $ expandMacro v (map (render . showType recmap) ts)
showType recmap (NamP _ v@(PV _ _ "struct") _ rs) =
  -- handle autogenerated structs
  case lookup (v, map fst rs) recmap of
    (Just rec) -> recName rec <> typeParams recmap (zip (map snd (recFields rec)) (map snd rs))
    Nothing -> error "Should not happen"
showType recmap (NamP _ (PV _ _ s) ps _) =
    pretty s <>  encloseSep "<" ">" "," (map (showType recmap) ps)

typeParams :: RecMap -> [(Maybe TypeP, TypeP)] -> MDoc
typeParams recmap ts
  = case [showTypeM recmap (Native t) | (Nothing, t) <- ts] of
      [] -> ""
      ds -> encloseSep "<" ">" "," ds

showTypeM :: RecMap -> TypeM -> MDoc
showTypeM _ Passthrough = serialType
showTypeM _ (Serial _) = serialType
showTypeM recmap (Native t) = showType recmap t
showTypeM recmap (Function ts t)
  = "std::function<" <> showTypeM recmap t
  <> "(" <> cat (punctuate "," (map (showTypeM recmap) ts)) <> ")>"

-- for use in making schema, where the native type is needed
showNativeTypeM :: RecMap -> TypeM -> MorlocMonad MDoc
showNativeTypeM recmap (Serial t) = return $ showTypeM recmap (Native t)
showNativeTypeM recmap (Native t) = return $ showTypeM recmap (Native t)
showNativeTypeM _ _ = MM.throwError . OtherError $ "Expected a native or serialized type"


collectRecords :: ExprM One -> [(PVar, GMeta, [(PVar, TypeP)])]
collectRecords e0 = f (gmetaOf e0) e0 where
  f _ (ManifoldM m _ e) = f m e
  f m (ForeignInterfaceM t e) = cleanRecord m t ++ f m e
  f m (PoolCallM t _ _ _) = cleanRecord m t
  f m (LetM _ e1 e2) = f m e1 ++ f m e2
  f m (AppM e es) = f m e ++ conmap (f m) es
  f m (LamM _ e) = f m e
  f m (AccM e _) = f m e
  f m (ListM t es) = cleanRecord m t ++ conmap (f m) es
  f m (TupleM t es) = cleanRecord m t ++ conmap (f m) es
  f m (RecordM t rs) = cleanRecord m t ++ conmap (f m . snd) rs
  f m (SerializeM s e)
    = cleanRecord m (Native (serialAstToType' s)) ++ f m e
  f m (DeserializeM s e)
    = cleanRecord m (Serial (serialAstToType' s)) ++ f m e
  f m (ReturnM e) = f m e
  f m (BndVarM t _) = cleanRecord m t
  f m (LetVarM t _) = cleanRecord m t
  f _ _ = []

cleanRecord :: GMeta -> TypeM -> [(PVar, GMeta, [(PVar, TypeP)])]
cleanRecord m tm = case typeOfTypeM tm of
  (Just t) -> toRecord t
  Nothing -> []
  where
    toRecord :: TypeP -> [(PVar, GMeta, [(PVar, TypeP)])]
    toRecord (UnkP _) = []
    toRecord (VarP _) = []
    toRecord (FunP t1 t2) = toRecord t1 ++ toRecord t2
    toRecord (ArrP _ ts) = conmap toRecord ts
    toRecord (NamP _ v@(PV _ _ "struct") _ rs) = (v, m, rs) : conmap toRecord (map snd rs)
    toRecord (NamP _ _ _ rs) = conmap toRecord (map snd rs)

-- unify records with the same name/keys
unifyRecords
  :: [(PVar -- The "v" in (NamP _ v@(PV _ _ "struct") _ rs)
     , GMeta -- The GMeta object stored in the records ManifoldM term
     , [(PVar, TypeP)]) -- key/type terms for this record
     ] -> RecMap
unifyRecords xs
  = zipWith (\i ((v,ks),es) -> ((v,ks), RecEntry (structName i v) es)) [1..]
  . map (\((v,m,ks), rss) -> ((v,ks), [unifyField m fs | fs <- transpose rss]))
  . map (\((v,ks), rss) -> ((v, fst (head rss),ks), map snd rss))
  -- [((record_name, record_keys), [(GMeta, [(key,type)])])]
  -- associate unique pairs of record name and keys with their edge types
  . groupSort
  . unique
  $ [((v, map fst es), (m, es)) | (v, m, es) <- xs]

structName :: Int -> PVar -> MDoc
structName i (PV _ (Just v1) "struct") = "mlc_" <> pretty v1 <> "_" <> pretty i 
structName _ (PV _ _ v) = pretty v

unifyField :: GMeta -> [(PVar, TypeP)] -> (PVar, Maybe TypeP)
unifyField _ [] = error "Empty field"
unifyField _ rs@((v,_):_)
  | not (all ((==) v) (map fst rs))
      = error $ "Bad record - unequal fields: " <> show (unique rs)
  | otherwise = case unique (map snd rs) of
      [t] -> (v, Just t)
      _ -> (v, Nothing)

generateAnonymousStructs :: RecMap -> ([MDoc],[MDoc])
generateAnonymousStructs recmap
  = (\xs -> (conmap fst xs, conmap snd xs))
  . map (makeSerializers recmap)
  . reverse
  . map snd
  $ recmap

makeSerializers :: RecMap -> RecEntry -> ([MDoc],[MDoc])
makeSerializers recmap rec
  = ([structDecl, serialDecl, deserialDecl], [serializer, deserializer])
  where
    templateTerms = zipWith (<>) (repeat "T") (map pretty ([1..] :: [Int]))
    rs' = zip templateTerms (recFields rec)

    params = [t | (t, (_, Nothing)) <- rs']
    rname = recName rec
    rtype = rname <> recordTemplate [v | (v, (_, Nothing)) <- rs']
    fields = [(pretty k, maybe t (showType recmap) v') | (t, (PV _ _ k, v')) <- rs']

    structDecl = structTypedefTemplate params rname fields
    serialDecl = serialHeaderTemplate params rtype
    deserialDecl = deserialHeaderTemplate params rtype

    serializer = serializerTemplate params rtype fields
    deserializer = deserializerTemplate False params rtype fields



generateSourcedSerializers :: [ExprM One] -> ([MDoc],[MDoc])
generateSourcedSerializers
  = foldl groupQuad ([],[])
  . Map.elems
  . Map.mapMaybeWithKey makeSerial
  . foldl collect' Map.empty
  where
    collect'
      :: Map.Map TVar (Type, [TVar])
      -> ExprM One
      -> Map.Map TVar (Type, [TVar])
    collect' m (ManifoldM g _ e) = collect' (Map.union m (metaTypedefs g)) e
    collect' m (ForeignInterfaceM _ e) = collect' m e
    collect' m (LetM _ e1 e2) = Map.union (collect' m e1) (collect' m e2)
    collect' m (AppM e es) = Map.unions $ collect' m e : map (collect' m) es
    collect' m (LamM _ e) = collect' m e
    collect' m (AccM e _) = collect' m e
    collect' m (ListM _ es) = Map.unions $ map (collect' m) es
    collect' m (TupleM _ es) = Map.unions $ map (collect' m) es
    collect' m (RecordM _ entries) = Map.unions $ map (collect' m) (map snd entries)
    collect' m (SerializeM _ e) = collect' m e
    collect' m (DeserializeM _ e) = collect' m e
    collect' m (ReturnM e) = collect' m e
    collect' m _ = m

    groupQuad :: ([a],[a]) -> (a, a, a, a) -> ([a],[a])
    groupQuad (xs,ys) (x1, y1, x2, y2) = (x1:x2:xs, y1:y2:ys)

    makeSerial :: TVar -> (Type, [TVar]) -> Maybe (MDoc, MDoc, MDoc, MDoc)
    makeSerial _ (NamT _ (TV _ "struct") _ _, _) = Nothing
    makeSerial (TV (Just CppLang) _) (NamT r (TV _ v) _ rs, ps)
      = Just (serialDecl, serializer, deserialDecl, deserializer) where

        templateTerms = ["T" <> pretty p | (TV _ p) <- ps]

        params = map (\p -> "T" <> pretty (unTVar p)) ps
        rtype = pretty v <> recordTemplate templateTerms
        fields = [(pretty k, showDefType ps t) | (k, t) <- rs]

        serialDecl = serialHeaderTemplate params rtype
        deserialDecl = deserialHeaderTemplate params rtype

        serializer = serializerTemplate params rtype fields

        deserializer = deserializerTemplate (r == NamObject) params rtype fields
    makeSerial _ _ = Nothing

    showDefType :: [TVar] -> Type -> MDoc 
    showDefType ps (UnkT v@(TV _ s))
      | elem v ps = "T" <> pretty s
      | otherwise = pretty s
    showDefType ps (VarT v@(TV _ s))
      | elem v ps = "T" <> pretty s
      | otherwise = pretty s
    showDefType _ (FunT _ _) = error "Cannot serialize functions"
    showDefType ps (ArrT (TV _ v) ts) = pretty $ expandMacro v (map (render . showDefType ps) ts)
    showDefType ps (NamT _ (TV _ v) ts _)
      = pretty v <> encloseSep "<" ">" "," (map (showDefType ps) ts)


makeTemplateHeader :: [MDoc] -> MDoc
makeTemplateHeader [] = ""
makeTemplateHeader ts = "template" <+> encloseSep "<" ">" "," ["class" <+> t | t <- ts]

recordTemplate :: [MDoc] -> MDoc
recordTemplate [] = ""
recordTemplate ts = encloseSep "<" ">" "," ts



-- Example
-- > template <class T>
-- > struct Person
-- > {
-- >     std::vector<std::string> name;
-- >     std::vector<T> info;
-- > };
structTypedefTemplate
  :: [MDoc] -- template parameters (e.g., ["T"])
  -> MDoc -- the name of the structure (e.g., "Person")
  -> [(MDoc, MDoc)] -- key and type for all fields
  -> MDoc -- structure definition
structTypedefTemplate params rname fields = vsep [template, struct] where
  template = makeTemplateHeader params
  struct = block 4 ("struct" <+> rname)
                   (vsep [t <+> k <> ";" | (k,t) <- fields]) <> ";"



-- Example
-- > template <class T>
-- > std::string serialize(person<T> x, person<T> schema);
serialHeaderTemplate :: [MDoc] -> MDoc -> MDoc
serialHeaderTemplate params rtype = vsep [template, prototype]
  where
  template = makeTemplateHeader params
  prototype = [idoc|std::string serialize(#{rtype} x, #{rtype} schema);|]



-- Example:
-- > template <class T>
-- > bool deserialize(const std::string json, size_t &i, person<T> &x);
deserialHeaderTemplate :: [MDoc] -> MDoc -> MDoc
deserialHeaderTemplate params rtype = vsep [template, prototype]
  where
  template = makeTemplateHeader params
  prototype = [idoc|bool deserialize(const std::string json, size_t &i, #{rtype} &x);|]



serializerTemplate
  :: [MDoc] -- template parameters
  -> MDoc -- type of thing being serialized
  -> [(MDoc, MDoc)] -- key and type for all fields
  -> MDoc -- output serializer function
serializerTemplate params rtype fields = [idoc|
#{makeTemplateHeader params}
std::string serialize(#{rtype} x, #{rtype} schema){
    #{schemata}
    std::ostringstream json;
    json << "{" << #{align $ vsep (punctuate " << ',' <<" writers)} << "}";
    return json.str();
}
|] where
  schemata = align $ vsep (map (\(k,t) -> t <+> k <> "_" <> ";") fields)
  writers = map (\(k,_) -> dquotes ("\\\"" <> k <> "\\\"" <> ":")
          <+> "<<" <+> [idoc|serialize(x.#{k}, #{k}_)|] ) fields



deserializerTemplate
  :: Bool -- build object with constructor
  -> [MDoc] -- ^ template parameters
  -> MDoc -- ^ type of thing being deserialized
  -> [(MDoc, MDoc)] -- ^ key and type for all fields
  -> MDoc -- ^ output deserializer function
deserializerTemplate isObj params rtype fields
  = [idoc|
#{makeTemplateHeader params}
bool deserialize(const std::string json, size_t &i, #{rtype} &x){
    #{schemata}
    try {
        whitespace(json, i);
        if(! match(json, "{", i))
            throw 1;
        whitespace(json, i);
        #{fieldParsers}
        if(! match(json, "}", i))
            throw 1;
        whitespace(json, i);
    } catch (int e) {
        return false;
    }
    #{assign}
    return true;
}
|] where
  schemata = align $ vsep (map (\(k,t) -> t <+> k <> "_" <> ";") fields)
  fieldParsers = align $ vsep (punctuate parseComma (map (makeParseField . fst) fields))
  values = [k <> "_" | (k,_) <- fields]
  assign = if isObj
           then [idoc|#{rtype} y#{tupled values}; x = y;|]
           else let obj = encloseSep "{" "}" "," values
                in [idoc|#{rtype} y = #{obj}; x = y;|]

parseComma = [idoc|
if(! match(json, ",", i))
    throw 800;
whitespace(json, i);|]

makeParseField :: MDoc -> MDoc
makeParseField field = [idoc|
if(! match(json, "\"#{field}\"", i))
    throw 1;
whitespace(json, i);
if(! match(json, ":", i))
    throw 1;
whitespace(json, i);
if(! deserialize(json, i, #{field}_))
    throw 1;
whitespace(json, i);|]



makeMain :: [MDoc] -> [MDoc] -> [MDoc] -> [MDoc] -> MDoc -> MDoc
makeMain includes signatures serialization manifolds dispatch = [idoc|#include <string>
#include <iostream>
#include <sstream>
#include <functional>
#include <vector>
#include <string>
#include <algorithm> // for std::transform

#{Src.foreignCallFunction}

#{Src.serializationHandling}

#{vsep includes}

#{vsep signatures}

#{vsep serialization}

#{vsep manifolds}

int main(int argc, char * argv[])
{
    int cmdID;
    #{serialType} result;
    cmdID = std::stoi(argv[1]);
    #{dispatch}
    std::cout << result << std::endl;
    return 0;
}
|]
