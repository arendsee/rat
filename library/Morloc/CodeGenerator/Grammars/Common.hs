{-|
Module      : Morloc.CodeGenerator.Grammars.Common
Description : A common set of utility functions for language templates
Copyright   : (c) Zebulun Arendsee, 2018
License     : GPL-3
Maintainer  : zbwrnz@gmail.com
Stability   : experimental
-}
module Morloc.CodeGenerator.Grammars.Common
  ( SAnno(..)
  , SExpr(..)
  , SerialMap(..)
  , GMeta(..)
  , CMeta(..)
  , Argument(..)
  , argName
  , argType
  , One(..)
  , Many(..)
  , Grammar(..)
  , TryDoc(..)
  , GeneralFunction(..)
  , GeneralAssignment(..)
  , UnpackerDoc(..)
  , ForeignCallDoc(..)
  , PoolMain(..)
  ) where

import Morloc.Data.Doc
import Morloc.Namespace
import Morloc.Pretty () -- just for mshow instances
import qualified Data.Map.Strict as Map
import qualified Morloc.Config as MC
import qualified Morloc.Data.Text as MT
import qualified Morloc.Language as ML
import qualified Morloc.Monad as MM
import qualified Morloc.System as MS

import Data.Scientific (Scientific)
import qualified Data.Set as Set

-- g: an annotation for the group of child trees (what they have in common)
-- f: a collection - before realization this will probably be Set
--                 - after realization it will be One
-- c: an annotation for the specific child tree
data SAnno g f c = SAnno (f (SExpr g f c, c)) g

data One a = One a
data Many a = Many [a]

instance Functor One where
  fmap f (One x) = One (f x)

data SExpr g f c
  = UniS
  | VarS EVar
  | ListS [SAnno g f c]
  | TupleS [SAnno g f c]
  | LamS [EVar] (SAnno g f c)
  | AppS (SAnno g f c) [SAnno g f c]
  | NumS Scientific
  | LogS Bool
  | StrS MT.Text
  | RecS [(EVar, SAnno g f c)]
  | CallS Source
  | ForeignS Int Lang

-- | Description of the general manifold
data GMeta = GMeta {
    metaId :: Int
  , metaGeneralType :: Maybe GeneralType
  , metaName :: Maybe EVar -- the name, if relevant
  , metaProperties :: Set.Set Property
  , metaConstraints :: Set.Set Constraint
} deriving (Show, Ord, Eq)

-- | Intrinsic description of a language-specific manifold 
data CMeta = CMeta {
    metaLang :: Lang
  , metaType :: ConcreteType
  , metaModule :: MVar -- useful for debugging, though not currently used
} deriving (Show, Ord, Eq)

data SerialMap = SerialMap {
    packers :: Map.Map ConcreteType (Name, Path)
  , unpackers :: Map.Map ConcreteType (Name, Path)
} deriving (Show, Ord, Eq)

-- | An argument that is passed to a manifold
data Argument
  = PackedArgument EVar ConcreteType (Maybe Name)
  -- ^ A serialized (e.g., JSON string) argument.  The parameters are 1)
  -- argument name (e.g., x), 2) argument type (e.g., double), and 3) packer
  -- name (e.g., packDouble).  The packer name is optional. Some types may not
  -- be serializable. This is OK, so long as they are only used in functions of
  -- the same language.
  | UnpackedArgument EVar ConcreteType (Maybe Name)
  -- ^ A native argument with the same parameters as above (except #3 is the
  -- unpacker name, e.g., unpackDouble)
  deriving (Show, Ord, Eq)

argName :: Argument -> EVar
argName (PackedArgument v _ _) = v
argName (UnpackedArgument v _ _) = v

argType :: Argument -> ConcreteType
argType (PackedArgument _ t _) = t
argType (UnpackedArgument _ t _) = t

data Grammar =
  Grammar
    { gLang :: Lang
    , gSerialType :: ConcreteType
    , gAssign :: GeneralAssignment -> MDoc
    , gCall :: MDoc -> [MDoc] -> MDoc
    , gFunction :: GeneralFunction -> MDoc
    , gSignature :: GeneralFunction -> MDoc
    , gId2Function :: Integer -> MDoc
    , gCurry :: MDoc -- function name
             -> [MDoc] -- arguments that are partially applied
             -> Int -- number of remaining arguments
             -> MDoc
    , gComment :: [MDoc] -> MDoc
    , gReturn :: MDoc -> MDoc
    , gQuote :: MDoc -> MDoc
    , gImport :: MDoc -> MDoc -> MDoc
    , gPrepImport :: Path -> MorlocMonad MDoc
    ---------------------------------------------
    , gNull :: MDoc
    , gBool :: Bool -> MDoc
    , gReal :: Scientific -> MDoc
    , gList :: [MDoc] -> MDoc
    , gTuple :: [MDoc] -> MDoc
    , gRecord :: [(MDoc, MDoc)] -> MDoc
    ---------------------------------------------
    , gIndent :: MDoc -> MDoc
    , gUnpacker :: UnpackerDoc -> MDoc
    , gTry :: TryDoc -> MDoc
    , gForeignCall :: ForeignCallDoc -> MDoc
    , gSwitch
        :: (([EVar], GMeta, ConcreteType) -> MDoc)
        -> (([EVar], GMeta, ConcreteType) -> MDoc)
        -> [([EVar], GMeta, ConcreteType)]
        -> MDoc
        -> MDoc
        -> MDoc
    , gCmdArgs :: [MDoc] -- ^ infinite list of main arguments (e.g. "argv[2]")
    , gShowType :: ConcreteType -> MDoc
    , gMain :: PoolMain -> MorlocMonad MDoc
    }

data GeneralAssignment =
  GeneralAssignment
    { gaType :: Maybe MDoc
    , gaName :: MDoc
    , gaValue :: MDoc
    , gaArg :: Maybe MData
    }
  deriving (Show)

data GeneralFunction =
  GeneralFunction
    { gfComments :: [MDoc]
    , gfReturnType :: Maybe MDoc -- ^ concrete return type
    , gfName :: MDoc -- ^ function name
    , gfArgs :: [(Maybe MDoc, MDoc)] -- ^ (variable concrete type, variable name)
    , gfBody :: MDoc
    }
  deriving (Show)

data TryDoc =
  TryDoc
    { tryCmd :: MDoc -- ^ The function we attempt to run
    , tryRet :: MDoc -- ^ A name for the returned variable?
    , tryArgs :: [MDoc] -- ^ Arguments passed to function
    , tryMid :: MDoc -- ^ The name of the calling manifold (for debugging)
    , tryFile :: MDoc -- ^ The file where the issue occurs (for debugging)
    }
  deriving (Show)

data UnpackerDoc =
  UnpackerDoc
    { udValue :: MDoc -- ^ The expression that will be unpacked
    , udUnpacker :: MDoc -- ^ The function for unpacking the value
    , udMid :: MDoc -- ^ Manifold name for debugging messages
    , udFile :: MDoc -- ^ File name for debugging messages
    }
  deriving (Show)

data ForeignCallDoc =
  ForeignCallDoc
    { fcdForeignPool :: MDoc -- ^ the name of the foreign pool (e.g., "R.pool")
    , fcdForeignExe :: MDoc -- ^ path to the foreign executable
    , fcdMid :: MDoc -- ^ the function integer identifier
    , fcdArgs :: [MDoc] -- ^ CLI arguments passed to foreign function
    , fcdCall :: [MDoc] -- ^ make a list of CLI arguments from first two
                        -- inputs -- since fcdArgs will likely be
                        -- variables, they are not included in this call.
    , fcdFile :: MDoc -- ^ for debugging
    }
  deriving (Show)

data PoolMain =
  PoolMain
    { pmSources :: [MDoc]
    , pmSignatures :: [MDoc]
    , pmPoolManifolds :: [MDoc]
    , pmDispatchManifold :: MDoc -> MDoc -> MDoc
    }
