-----------------------------------------------------------------------------
-----------------------------------------------------------------------------
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeFamilies #-}

-- |
-- Module      :  Swarm.Game.Entity
-- Copyright   :  Brent Yorgey
-- Maintainer  :  byorgey@gmail.com
--
-- SPDX-License-Identifier: BSD-3-Clause
--
-- An 'Entity' represents an object that exists in the world.  Each
-- entity has a way to be displayed, some metadata such as a name and
-- description, some properties, and possibly an inventory of other
-- entities.
--
-- This module also defines the 'Inventory' type, since the two types
-- are mutually recursive (an inventory contains entities, which can
-- have inventories).
module Swarm.Game.Entity (
  -- * Properties
  EntityProperty (..),
  GrowthTime (..),
  defaultGrowthTime,

  -- * Entities
  Entity,
  mkEntity,
  displayEntity,

  -- ** Lenses
  -- $lenses
  entityDisplay,
  entityName,
  entityPlural,
  entityNameFor,
  entityDescription,
  entityOrientation,
  entityGrowth,
  entityYields,
  entityProperties,
  hasProperty,
  entityCapabilities,
  entityInventory,
  entityHash,

  -- ** Entity map
  EntityMap,
  loadEntities,
  lookupEntityName,
  deviceForCap,

  -- * Inventories
  Inventory,
  Count,

  -- ** Construction
  empty,
  singleton,
  fromList,

  -- ** Lookup
  lookup,
  lookupByName,
  contains,
  elems,

  -- ** Modification
  insert,
  insertCount,
  delete,
  deleteCount,
  deleteAll,
) where

import Brick (Widget)
import Control.Arrow ((&&&))
import Control.Lens (Getter, Lens', lens, to, view, (^.))
import Control.Monad.IO.Class
import Data.Bifunctor (bimap, second)
import Data.Char (toLower)
import Data.Function (on)
import Data.Hashable
import Data.Int (Int64)
import Data.IntMap (IntMap)
import qualified Data.IntMap as IM
import Data.IntSet (IntSet)
import qualified Data.IntSet as IS
import Data.List (foldl')
import Data.Map (Map)
import qualified Data.Map as M
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as T
import GHC.Generics (Generic)
import Linear
import Text.Read (readMaybe)
import Witch
import Prelude hiding (lookup)

import Data.Yaml

import Swarm.Game.Display
import Swarm.Language.Capability
import Swarm.Language.Syntax (toDirection)

import Paths_swarm
import Swarm.Util (plural)

------------------------------------------------------------
-- Properties
------------------------------------------------------------

-- | Various properties that an entity can have, which affect how
--   robots can interact with it.
data EntityProperty
  = -- | Robots can't move onto a cell containing this entity.
    Unwalkable
  | -- | Robots can pick this up (via 'Swarm.Language.Syntax.Grab').
    Portable
  | -- | Regrows from a seed after it is grabbed.
    Growable
  | -- | Robots drown if they walk on this.
    Liquid
  deriving (Eq, Ord, Show, Read, Enum, Bounded, Generic, Hashable)

instance ToJSON EntityProperty where
  toJSON = String . from . map toLower . show

instance FromJSON EntityProperty where
  parseJSON = withText "EntityProperty" tryRead
   where
    tryRead :: Text -> Parser EntityProperty
    tryRead t = case readMaybe . from . T.toTitle $ t of
      Just c -> return c
      Nothing -> fail $ "Unknown entity property " ++ from t

-- | How long an entity takes to regrow.  This represents the minimum
--   and maximum amount of time taken by one growth stage (there are
--   two stages).  The actual time for each stage will be chosen
--   uniformly at random between these two values.
newtype GrowthTime = GrowthTime (Integer, Integer)
  deriving (Eq, Ord, Show, Read, Generic, Hashable, FromJSON, ToJSON)

defaultGrowthTime :: GrowthTime
defaultGrowthTime = GrowthTime (100, 200)

------------------------------------------------------------
-- Entity
------------------------------------------------------------

-- | A record to hold information about an entity.
--
--   The constructor for 'Entity' is intentionally not exported.  To
--   construct one manually, use the 'mkEntity' function.
--
--   There are two main constraints on the way entities are stored:
--
--   1. We want to be able to easily modify an entity in one
--      particular cell of the world (for example, painting one
--      tree red).
--   2. In an inventory, we want to store identical entities only
--      once, along with a count.
--
--   We could get (2) nicely by storing only names of entities, and
--   having a global lookup table from names to entity records.
--   However, storing names instead of actual entity records in the
--   world makes (1) more complex: every time we modify an entity we
--   would have to generate a fresh name for the modified entity and
--   add it to the global entity table.  This approach is also
--   annoying because it means we can't just uses lenses to drill down
--   into the properties of an entity in the world or in an inventory,
--   but have to do an intermediate lookup in the global (mutable!)
--   entity table.
--
--   On the other hand, if we just store entity records everywhere,
--   checking them for equality becomes expensive.  Having an
--   inventory be a map with entities themselves as keys sounds awful.
--
--   The solution we adopt here is that every @Entity@ record carries
--   along a hash value of all the other fields.  We just assume that
--   these hashes are unique (a collision is of course possible but
--   extremely unlikely).  Entities can be efficiently compared just
--   by looking at their hashes; they can be stored in a map using
--   hash values as keys; and we provide lenses which automatically
--   recompute the hash value when modifying a field of an entity
--   record.  Note also that world storage is still efficient, too:
--   thanks to referential transparency, in practice most of the
--   entities stored in the world that are the same will literally
--   just be stored as pointers to the same shared record.
data Entity = Entity
  { -- | A hash value computed
    --   from the other fields
    _entityHash :: Int
  , -- | The way this entity
    --   should be displayed on
    --   the world map.
    _entityDisplay :: Display
  , -- | The name of the
    --   entity, used /e.g./ in
    --   an inventory display.
    _entityName :: Text
  , -- | The plural of the
    --   entity name, in case
    --   it is irregular.  If
    --   this field is
    --   @Nothing@, default
    --   pluralization
    --   heuristics will be
    --   used (see 'plural').
    _entityPlural :: Maybe Text
  , -- | A longer-form
    --   description. Each
    --   'Text' value is one
    --   paragraph.
    _entityDescription :: [Text]
  , -- | The entity's
    --   orientation (if it has
    --   one).  For example,
    --   when a robot moves, it
    --   moves in the direction
    --   of its orientation.
    _entityOrientation :: Maybe (V2 Int64)
  , -- | If this entity grows,
    --   how long does it take?
    _entityGrowth :: Maybe GrowthTime
  , -- | The name of a
    --   different entity
    --   obtained when this
    --   entity is grabbed.
    _entityYields :: Maybe Text
  , -- | Properties of the entity.
    _entityProperties :: [EntityProperty]
  , -- | Capabilities provided
    --   by this entity.
    _entityCapabilities :: [Capability]
  , -- | Inventory of other
    --   entities held by this
    --   entity.
    _entityInventory :: Inventory
  }
  -- Note that an entity does not have a location, because the
  -- location of an entity is implicit in the way it is stored (by
  -- location).

  deriving (Show, Generic)

-- | The @Hashable@ instance for @Entity@ ignores the cached hash
--   value and simply combines the other fields.
instance Hashable Entity where
  hashWithSalt s (Entity _ disp nm pl descr orient grow yld props caps inv) =
    s `hashWithSalt` disp
      `hashWithSalt` nm
      `hashWithSalt` pl
      `hashWithSalt` descr
      `hashWithSalt` orient
      `hashWithSalt` grow
      `hashWithSalt` yld
      `hashWithSalt` props
      `hashWithSalt` caps
      `hashWithSalt` inv

-- | Entities are compared by hash for efficiency.
instance Eq Entity where
  (==) = (==) `on` _entityHash

-- | Entities are compared by hash for efficiency.
instance Ord Entity where
  compare = compare `on` _entityHash

-- | Recompute an entity's hash value.
rehashEntity :: Entity -> Entity
rehashEntity e = e {_entityHash = hash e}

-- | Create an entity with no orientation, an empty inventory,
--   providing no capabilities (automatically filling in the hash
--   value).
mkEntity ::
  -- | Display
  Display ->
  -- | Entity name
  Text ->
  -- | Entity description
  [Text] ->
  -- | Properties
  [EntityProperty] ->
  Entity
mkEntity disp nm descr props =
  rehashEntity $ Entity 0 disp nm Nothing descr Nothing Nothing Nothing props [] empty

------------------------------------------------------------
-- Entity map
------------------------------------------------------------

-- | An 'EntityMap' is a data structure containing all the loaded
--   entities, allowing them to be looked up either by name or by what
--   capabilities they provide (if any).
data EntityMap = EntityMap
  { entitiesByName :: Map Text Entity
  , entitiesByCap :: Map Capability Entity
  }

-- | Find an entity with the given name.
lookupEntityName :: Text -> EntityMap -> Maybe Entity
lookupEntityName nm = M.lookup nm . entitiesByName

-- | Find an entity which is a device that provides the given
--   capability.
deviceForCap :: Capability -> EntityMap -> Maybe Entity
deviceForCap cap = M.lookup cap . entitiesByCap

-- | Build an 'EntityMap' from a list of entities.  The idea is that
--   this will be called once at startup, when loading the entities
--   from a file; see 'loadEntities'.
buildEntityMap :: [Entity] -> EntityMap
buildEntityMap es =
  EntityMap
    { entitiesByName = M.fromList . map (view entityName &&& id) $ es
    , entitiesByCap = M.fromList . concatMap (\e -> map (,e) (e ^. entityCapabilities)) $ es
    }

------------------------------------------------------------
-- Serialization
------------------------------------------------------------

instance FromJSON Entity where
  parseJSON = withObject "Entity" $ \v ->
    rehashEntity
      <$> ( Entity
              <$> pure 0
              <*> v .: "display"
              <*> v .: "name"
              <*> v .:? "plural"
              <*> (map reflow <$> (v .: "description"))
              <*> v .:? "orientation"
              <*> v .:? "growth"
              <*> v .:? "yields"
              <*> v .:? "properties" .!= []
              <*> v .:? "capabilities" .!= []
              <*> pure empty
          )
   where
    reflow = T.unwords . T.words

instance ToJSON Entity where
  toJSON e =
    object $
      [ "display" .= (e ^. entityDisplay)
      , "name" .= (e ^. entityName)
      , "description" .= (e ^. entityDescription)
      ]
        ++ ["plural" .= (e ^. entityPlural) | isJust (e ^. entityPlural)]
        ++ ["orientation" .= (e ^. entityOrientation) | isJust (e ^. entityOrientation)]
        ++ ["growth" .= (e ^. entityGrowth) | isJust (e ^. entityGrowth)]
        ++ ["yields" .= (e ^. entityYields) | isJust (e ^. entityYields)]
        ++ ["properties" .= (e ^. entityProperties) | not . null $ e ^. entityProperties]
        ++ ["capabilities" .= (e ^. entityCapabilities) | not . null $ e ^. entityCapabilities]

-- | Load entities from a data file called @entities.yaml@, producing
--   either an 'EntityMap' or a pretty-printed parse error.
loadEntities :: MonadIO m => m (Either Text EntityMap)
loadEntities = liftIO $ do
  fileName <- getDataFileName "entities.yaml"
  bimap (from . prettyPrintParseException) buildEntityMap <$> decodeFileEither fileName

------------------------------------------------------------
-- Entity lenses
------------------------------------------------------------

-- $lenses
-- Our own custom lenses which properly recompute the cached hash
-- value each time something gets updated.  See
-- https://byorgey.wordpress.com/2021/09/17/automatically-updated-cached-views-with-lens/
-- for the approach used here.

-- | Make a lens for Entity that recomputes the hash after setting.
hashedLens :: (Entity -> a) -> (Entity -> a -> Entity) -> Lens' Entity a
hashedLens get set = lens get (\e a -> rehashEntity $ set e a)

-- | Get the hash of an entity.  Note that this is a getter, not a
--   lens; the "Swarm.Game.Entity" module carefully maintains some
--   internal invariants ensuring that hashes work properly, and by
--   golly, no one else is going to mess that up.
entityHash :: Getter Entity Int
entityHash = to _entityHash

-- | The 'Display' explaining how to draw this entity in the world display.
entityDisplay :: Lens' Entity Display
entityDisplay = hashedLens _entityDisplay (\e x -> e {_entityDisplay = x})

-- | The name of the entity.
entityName :: Lens' Entity Text
entityName = hashedLens _entityName (\e x -> e {_entityName = x})

-- | The irregular plural version of the entity's name, if there is
--   one.
entityPlural :: Lens' Entity (Maybe Text)
entityPlural = hashedLens _entityPlural (\e x -> e {_entityPlural = x})

-- | Get a version of the entity's name appropriate to the
--   number---the singular name for 1, and a plural name for any other
--   number.  The plural name is obtained either by looking it up if
--   irregular, or by applying standard heuristics otherwise.
entityNameFor :: Int -> Getter Entity Text
entityNameFor 1 = entityName
entityNameFor _ = to $ \e ->
  case e ^. entityPlural of
    Just pl -> pl
    Nothing -> plural (e ^. entityName)

-- | A longer, free-form description of the entity.  Each 'Text' value
--   represents a paragraph.
entityDescription :: Lens' Entity [Text]
entityDescription = hashedLens _entityDescription (\e x -> e {_entityDescription = x})

-- | The direction this entity is facing (if it has one).
entityOrientation :: Lens' Entity (Maybe (V2 Int64))
entityOrientation = hashedLens _entityOrientation (\e x -> e {_entityOrientation = x})

-- | How long this entity takes to grow, if it regrows.
entityGrowth :: Lens' Entity (Maybe GrowthTime)
entityGrowth = hashedLens _entityGrowth (\e x -> e {_entityGrowth = x})

-- | The name of a different entity yielded when this entity is
--   grabbed, if any.
entityYields :: Lens' Entity (Maybe Text)
entityYields = hashedLens _entityYields (\e x -> e {_entityYields = x})

-- | The properties enjoyed by this entity.
entityProperties :: Lens' Entity [EntityProperty]
entityProperties = hashedLens _entityProperties (\e x -> e {_entityProperties = x})

-- | Test whether an entity has a certain property.
hasProperty :: Entity -> EntityProperty -> Bool
hasProperty e p = p `elem` (e ^. entityProperties)

-- | The capabilities this entity provides when installed.
entityCapabilities :: Lens' Entity [Capability]
entityCapabilities = hashedLens _entityCapabilities (\e x -> e {_entityCapabilities = x})

-- | The inventory of other entities carried by this entity.
entityInventory :: Lens' Entity Inventory
entityInventory = hashedLens _entityInventory (\e x -> e {_entityInventory = x})

-- | Display an entity as a single character.
displayEntity :: Entity -> Widget n
displayEntity e = displayWidget ((e ^. entityOrientation) >>= toDirection) (e ^. entityDisplay)

------------------------------------------------------------
-- Inventory
------------------------------------------------------------

-- | A convenient synonym to remind us when an 'Int' is supposed to
--   represent /how many/ of something we have.
type Count = Int

-- | An inventory is really just a bag/multiset of entities.  That is,
--   it contains some entities, along with the number of times each
--   occurs.  Entities can be looked up directly, or by name.
data Inventory = Inventory
  { counts :: IntMap (Count, Entity) -- main map
  , byName :: Map Text IntSet -- Mirrors the main map; just
  -- caching the ability to
  -- look up by name.
  }
  deriving (Show, Generic)

instance Hashable Inventory where
  -- Don't look at Entity records themselves --- just hash their keys,
  -- which are already a hash.
  hashWithSalt = hashUsing (map (second fst) . IM.assocs . counts)

-- | Look up an entity in an inventory, returning the number of copies
--   contained.
lookup :: Entity -> Inventory -> Count
lookup e (Inventory cs _) = maybe 0 fst $ IM.lookup (e ^. entityHash) cs

-- | Look up an entity by name in an inventory, returning a list of
--   matching entities.
lookupByName :: Text -> Inventory -> [Entity]
lookupByName name (Inventory cs byN) =
  maybe [] (map (snd . (cs IM.!)) . IS.elems) (M.lookup (T.toLower name) byN)

-- | The empty inventory.
empty :: Inventory
empty = Inventory IM.empty M.empty

-- | Create an inventory containing one entity.
singleton :: Entity -> Inventory
singleton = flip insert empty

-- | Insert an entity into an inventory.  If the inventory already
--   contains this entity, then only its count will be incremented.
insert :: Entity -> Inventory -> Inventory
insert = insertCount 1

-- | Create an inventory from a list of entities.
fromList :: [Entity] -> Inventory
fromList = foldl' (flip insert) empty

-- | Insert a certain number of copies of an entity into an inventory.
--   If the inventory already contains this entity, then only its
--   count will be incremented.
insertCount :: Count -> Entity -> Inventory -> Inventory
insertCount cnt e (Inventory cs byN) =
  Inventory
    (IM.insertWith (\(m, _) (n, _) -> (m + n, e)) (e ^. entityHash) (cnt, e) cs)
    (M.insertWith IS.union (T.toLower $ e ^. entityName) (IS.singleton (e ^. entityHash)) byN)

-- | Check whether an inventory contains a given entity.
contains :: Inventory -> Entity -> Bool
contains inv e = lookup e inv > 0

-- | Delete a single copy of a certain entity from an inventory.
delete :: Entity -> Inventory -> Inventory
delete = deleteCount 1

-- | Delete a specified number of copies of an entity from an inventory.
deleteCount :: Count -> Entity -> Inventory -> Inventory
deleteCount k e (Inventory cs byN) = Inventory cs' byN'
 where
  cs' = IM.alter removeCount (e ^. entityHash) cs
  newCount = lookup e (Inventory cs' byN)

  byN'
    | newCount == 0 = M.adjust (IS.delete (e ^. entityHash)) (e ^. entityName) byN
    | otherwise = byN

  removeCount :: Maybe (Count, a) -> Maybe (Count, a)
  removeCount Nothing = Nothing
  removeCount (Just (n, a))
    | k >= n = Nothing
    | otherwise = Just (n - k, a)

-- | Delete all copies of a certain entity from an inventory.
deleteAll :: Entity -> Inventory -> Inventory
deleteAll e (Inventory cs byN) =
  Inventory
    (IM.alter (const Nothing) (e ^. entityHash) cs)
    (M.adjust (IS.delete (e ^. entityHash)) (e ^. entityName) byN)

-- | Get the entities in an inventory and their associated counts.
elems :: Inventory -> [(Count, Entity)]
elems (Inventory cs _) = IM.elems cs
