-----------------------------------------------------------------------------
-----------------------------------------------------------------------------
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}

-- |
-- Module      :  Swarm.Game.World
-- Copyright   :  Brent Yorgey
-- Maintainer  :  byorgey@gmail.com
--
-- SPDX-License-Identifier: BSD-3-Clause
--
-- A /world/ refers to the grid on which the game takes place, and the
-- things in it (besides robots). A world has a base, immutable
-- /terrain/ layer, where each cell contains a terrain type, and a
-- mutable /entity/ layer, with at most one entity per cell.
--
-- A world is technically finite but practically infinite (worlds are
-- indexed by 64-bit signed integers, so they correspond to a
-- \( 2^{64} \times 2^{64} \) torus).
module Swarm.Game.World (
  -- * World coordinates
  Coords (..),
  locToCoords,
  coordsToLoc,

  -- * Worlds
  WorldFun,
  World,

  -- ** Tile management
  loadCell,
  loadRegion,

  -- ** World functions
  newWorld,
  lookupTerrain,
  lookupEntity,
  update,

  -- ** Monadic variants
  lookupTerrainM,
  lookupEntityM,
  updateM,
) where

import Control.Arrow ((&&&))
import Control.Lens
import Control.Monad.State.Class
import qualified Data.Array as A
import Data.Array.IArray
import qualified Data.Array.Unboxed as U
import Data.Bits
import Data.Foldable (foldl')
import Data.Int (Int64)
import qualified Data.Map.Strict as M
import GHC.Generics (Generic)
import Linear
import Prelude hiding (lookup)

import Swarm.Util

------------------------------------------------------------
-- World coordinates
------------------------------------------------------------

-- | World coordinates use (row,column) format, with the row
--   increasing as we move down the screen.  This format plays nicely
--   with drawing the screen.
newtype Coords = Coords {unCoords :: (Int64, Int64)}
  deriving (Eq, Ord, Show, Ix, Generic)

instance Rewrapped Coords t
instance Wrapped Coords

-- | Convert an (x,y) location to a 'Coords' value.
locToCoords :: V2 Int64 -> Coords
locToCoords (V2 x y) = Coords (- y, x)

-- | Convert 'Coords' to an (x,y) location.
coordsToLoc :: Coords -> V2 Int64
coordsToLoc (Coords (r, c)) = V2 c (- r)

-- | A @WorldFun t e@ represents a 2D world with terrain of type @t@
-- (exactly one per cell) and entities of type @e@ (at most one per
-- cell).
type WorldFun t e = Coords -> (t, Maybe e)

-- XXX Allow smaller, finite worlds Too?  Maybe add a variant of
-- newWorld that creates a finite world from an array.  This could
-- be used e.g. to create puzzle levels, which can be loaded from a
-- file instead of generated via noise functions.

-- | The number of bits we need in each coordinate to represent all
--   the locations in a tile.  In other words, each tile has a size of
--   @2^tileBits x 2^tileBits@.
--
--   Currently, 'tileBits' is set to 6, giving us 64x64 tiles, with
--   4096 cells in each tile. That seems intuitively like a good size,
--   but I don't have a good sense for the tradeoffs here, and I don't
--   know how much the choice of tile size matters.
tileBits :: Int
tileBits = 6

-- | The number consisting of 'tileBits' many 1 bits.  We can use this
--   to mask out the tile offset of a coordinate.
tileMask :: Int64
tileMask = (1 `shiftL` tileBits) - 1

-- | If we think of the world as a grid of /tiles/, we can assign each
--   tile some coordinates in the same way we would if each tile was a
--   single cell.  These are the tile coordinates.
newtype TileCoords = TileCoords {unTileCoords :: Coords}
  deriving (Eq, Ord, Show, Ix, Generic)

instance Rewrapped TileCoords t
instance Wrapped TileCoords

-- | Convert from a cell's coordinates to the coordinates of its tile,
--   simply by shifting out 'tileBits' many bits.
tileCoords :: Coords -> TileCoords
tileCoords = TileCoords . over (_Wrapped . both) (`shiftR` tileBits)

-- | Find the coordinates of the upper-left corner of a tile.
tileOrigin :: TileCoords -> Coords
tileOrigin = over (_Wrapped . both) (`shiftL` tileBits) . unTileCoords

-- | A 'TileOffset' represents an offset from the upper-left corner of
--   some tile to a cell in its interior.
newtype TileOffset = TileOffset Coords
  deriving (Eq, Ord, Show, Ix, Generic)

-- | The offsets of the upper-left and lower-right corners of a tile:
--   (0,0) to ('tileMask', 'tileMask').
tileBounds :: (TileOffset, TileOffset)
tileBounds = (TileOffset (Coords (0, 0)), TileOffset (Coords (tileMask, tileMask)))

-- | Compute the offset of a given coordinate within its tile.
tileOffset :: Coords -> TileOffset
tileOffset = TileOffset . over (_Wrapped . both) (.&. tileMask)

-- | Add a tile offset to the coordinates of the tile's upper left
--   corner.  NOTE that for efficiency, this function only works when
--   the first argument is in fact the coordinates of a tile's
--   upper-left corner (/i.e./ it is an output of 'tileOrigin').  In
--   that case the coordinates will end with all 0 bits, and we can
--   add the tile offset just by doing a coordinatewise 'xor'.
plusOffset :: Coords -> TileOffset -> Coords
plusOffset (Coords (x1, y1)) (TileOffset (Coords (x2, y2))) = Coords (x1 `xor` x2, y1 `xor` y2)

instance Rewrapped TileOffset t
instance Wrapped TileOffset

-- | A terrain tile is an unboxed array of terrain values.
type TerrainTile t = U.UArray TileOffset t

-- | An entity tile is an array of possible entity values.  Note it
--   cannot be an unboxed array since entities are complex records
--   which have to be boxed.
type EntityTile e = A.Array TileOffset (Maybe e)

-- | A 'World' consists of a 'WorldFun' that specifies the initial
--   world, a cache of loaded square tiles to make lookups faster, and
--   a map storing locations whose entities have changed from their
--   initial values.
--
--   Right now the 'World' simply holds on to all the tiles it has
--   ever loaded.  Ideally it would use some kind of LRU caching
--   scheme to keep memory usage bounded, but it would be a bit
--   tricky, and in any case it's probably not going to matter much
--   for a while.  Once tile loads can trigger robots to spawn, it
--   would also make for some difficult decisions in terms of how to
--   handle respawning.
data World t e = World
  { _worldFun :: WorldFun t e
  , _tileCache :: M.Map TileCoords (TerrainTile t, EntityTile e)
  , _changed :: M.Map Coords (Maybe e)
  }

-- | Create a new 'World' from a 'WorldFun'.
newWorld :: WorldFun t e -> World t e
newWorld f = World f M.empty M.empty

-- | Look up the terrain value at certain coordinates: try looking it
--   up in the tile cache first, and fall back to running the 'WorldFun'
--   otherwise.
--
--   This function does /not/ ensure that the tile containing the
--   given coordinates is loaded.  For that, see 'lookupTerrainM'.
lookupTerrain :: IArray U.UArray t => Coords -> World t e -> t
lookupTerrain i (World f t _) =
  ((U.! tileOffset i) . fst <$> M.lookup (tileCoords i) t)
    ? fst (f i)

-- | A stateful variant of 'lookupTerrain', which first loads the tile
--   containing the given coordinates if it is not already loaded,
--   then looks up the terrain value.
lookupTerrainM :: (MonadState (World t e) m, IArray U.UArray t) => Coords -> m t
lookupTerrainM c = do
  modify $ loadCell c
  lookupTerrain c <$> get

-- | Look up the entity at certain coordinates: first, see if it is in
--   the map of locations with changed entities; then try looking it
--   up in the tile cache first; and finally fall back to running the
--   'WorldFun'.
--
--   This function does /not/ ensure that the tile containing the
--   given coordinates is loaded.  For that, see 'lookupEntityM'.
lookupEntity :: Coords -> World t e -> Maybe e
lookupEntity i (World f t m) =
  M.lookup i m
    ? ((A.! tileOffset i) . snd <$> M.lookup (tileCoords i) t)
    ? snd (f i)

-- | A stateful variant of 'lookupTerrain', which first loads the tile
--   containing the given coordinates if it is not already loaded,
--   then looks up the terrain value.
lookupEntityM :: (MonadState (World t e) m, IArray U.UArray t) => Coords -> m (Maybe e)
lookupEntityM c = do
  modify $ loadCell c
  lookupEntity c <$> get

-- | Update the entity (or absence thereof) at a certain location,
--   returning an updated 'World'.  See also 'updateM'.
update :: Coords -> (Maybe e -> Maybe e) -> World t e -> World t e
update i g w@(World f t m) =
  World f t (M.insert i (g (lookupEntity i w)) m)

-- | A stateful variant of 'update', which also ensures the tile
--   containing the given coordinates is loaded.
updateM :: (MonadState (World t e) m, IArray U.UArray t) => Coords -> (Maybe e -> Maybe e) -> m ()
updateM c g = modify $ update c g . loadCell c

-- | Load the tile containing a specific cell.
loadCell :: IArray U.UArray t => Coords -> World t e -> World t e
loadCell c = loadRegion (c, c)

-- | Load all the tiles which overlap the given rectangular region
--   (specified as an upper-left and lower-right corner).
loadRegion :: forall t e. IArray U.UArray t => (Coords, Coords) -> World t e -> World t e
loadRegion reg (World f t m) = World f t' m
 where
  tiles = range (over both tileCoords reg)
  t' = foldl' (\hm (i, tile) -> maybeInsert i tile hm) t (map (id &&& loadTile) tiles)

  maybeInsert k v tm
    | k `M.member` tm = tm
    | otherwise = M.insert k v tm

  loadTile :: TileCoords -> (TerrainTile t, EntityTile e)
  loadTile tc = (listArray tileBounds terrain, listArray tileBounds entities)
   where
    tileCorner = tileOrigin tc
    (terrain, entities) = unzip $ map (f . plusOffset tileCorner) (range tileBounds)
