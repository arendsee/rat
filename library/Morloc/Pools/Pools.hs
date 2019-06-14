{-# LANGUAGE OverloadedStrings #-}

{-|
Module      : Morloc.Pools.Pools
Description : Generate language-specific code
Copyright   : (c) Zebulun Arendsee, 2018
License     : GPL-3
Maintainer  : zbwrnz@gmail.com
Stability   : experimental
-}

module Morloc.Pools.Pools
(
    generate
  , hsparql
) where

import Morloc.Global
import Morloc.Operators
import Morloc.Sparql
import qualified Morloc.Language as ML
import qualified Morloc.Monad as MM
import qualified Morloc.Data.Text as MT
import qualified Morloc.Pools.Template.R as RLang
import qualified Morloc.Pools.Template.Python3 as Py3
import qualified Morloc.Pools.Template.C as C

import qualified Control.Monad as CM

generate :: SparqlDatabaseLike db => db -> MorlocMonad [Script]
generate db = (sparqlSelect "pools" hsparql db) >>= CM.mapM (generateLang db)

-- | If you want to add a new language, this is the function you currently need
-- to modify. Add a case for the new language name, and then the function that
-- will generate the code for a script in that language.
generateLang :: SparqlDatabaseLike db => db -> [Maybe MT.Text] -> MorlocMonad Script
generateLang db [Just langStr] = case (ML.readLangName langStr) of
    (Just RLang)       -> RLang.generate db
    (Just Python3Lang) -> Py3.generate   db
    (Just CLang)       -> C.generate     db
    (Just MorlocLang)  -> MM.throwError . GeneratorError $ "Too much meta, don't generate morloc code"
    (Just x) -> MM.throwError . GeneratorError $ ML.showLangName x <> " is not yet supported"
    Nothing -> MM.throwError . GeneratorError $ "Language '" <> langStr <> "' not recognized"
generateLang _ x = MM.throwError . SparqlFail $ "Bad SPARQL query:" <> MT.show' x

-- | Find all languages that are used in the Morloc script
hsparql :: Query SelectQuery
hsparql = do
  i_    <- var
  lang_ <- var
  triple_ i_ PType OSource
  triple_ i_ PLang lang_
  distinct_
  selectVars [lang_]
