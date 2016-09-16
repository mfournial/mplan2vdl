module Config ( Config(..)
              , ColInfo(..)
              , checkColInfo
              , makeConfig
              , isPkey
              , isFKRef
              , lookupPkey
              , isPartialFk
              , isPartialPk
              , AggStrategy(..)
              , FKCols
              , PKCols
              , BoundsRec
              , StorageRec
              , DictRec
              , FKJoinOrder(..)
              , MType(..)
              , SType(..)
              , resolveTypeSpec
              , sizeOf
              , bitwidthOf
              , getSTypeOfMType
              ) where

import Data.Foldable
import Data.Data
import Data.Int
import Name as NameTable
--import Data.Int
import SchemaParser(Table(..),Key(..))
import qualified Data.Vector as V
--import Control.Monad(foldM)
import Control.DeepSeq(NFData)
import GHC.Generics
import Control.Exception.Base
import qualified Data.Map.Strict as Map
--import qualified Data.Set as Set
import Data.List.NonEmpty(NonEmpty(..))
import qualified Data.List.NonEmpty as N
import qualified Data.ByteString.Lazy as B
import Data.Hashable
import qualified Data.ByteString.Lazy.Char8 as C
import qualified Data.HashMap.Strict as HashMap
type HashMap = HashMap.HashMap
type Map = Map.Map
--type Set = Set.Set


-- we use integer in the rec so that strings get
-- parsed to Integer.
-- Parsing a string as an Int8, for example,  can silently
-- wraps the around the input string value and return an Int8
-- which is not the behavior we want here.
-- The same thing happens with wider types.
-- We want any type bound errors (such as being <  0 when it shouldnt) to
-- be the result of errors inherent in the input data, not of
-- errors due to overflwoing numbers within the program.


type BoundsRec = (B.ByteString, B.ByteString, Integer, Integer, Integer, Integer)

-- contents of select * from storage
type StorageRec = ( C.ByteString -- schema
                  , C.ByteString -- table
                  , C.ByteString -- column
                  , C.ByteString -- type
                  , C.ByteString -- location
                  , Integer -- count
                  , Integer -- typewidth (bytes)
                  , Integer -- columnsize (bytes)
                  , Integer -- heapsize
                  , Integer -- hashes
                  , Integer -- imprints
                  , C.ByteString  -- sorted (boolean)
                  )


type DictRec = ( C.ByteString -- schema
               , C.ByteString -- table
               , C.ByteString -- column
               , Integer -- encoding
               )


--- repr info from Monet tpch001
-- sql>select distinct "type","columnsize"/"count" as rep_size from storage where "schema"='sys' and ("table"='lineitem' or "table"='orders' or "table"='customer' or "table"='partsupp' or "table"='supplier' or "table"='part' or "table"='nation' or "table"='region') order by "type","rep_size";
-- +---------+----------+
-- | type    | rep_size |
-- +=========+==========+
-- | char    |        1 |
-- | char    |        2 |
-- | date    |        4 |
-- | decimal |        8 |
-- | int     |        4 |
-- | oid     |        8 |
-- | varchar |        2 |
-- | varchar |        4 |
-- +---------+----------+

--- repr info from Monet tpch10
-- select distinct "type","columnsize"/"count" as rep_size from storage where "schema"='sys' and ("table"='lineitem' or "table"='orders' or "table"='customer' or "table"='partsupp' or "table"='supplier' or "table"='part' or "table"='nation' or "table"='region') order by "type","rep_size";
-- +---------+----------+
-- | type    | rep_size |
-- +=========+==========+
-- | char    |        1 |
-- | char    |        2 |
-- | char    |        4 |
-- | date    |        4 |
-- | decimal |        8 |
-- | int     |        4 |
-- | oid     |        8 |
-- | varchar |        2 |
-- | varchar |        4 |
-- +---------+----------+


-- these are storage types used in monet tpch.
-- for different tables, other types may show up.
--- right now, we immediately convert literals to the types they are used with
-- (eg, dates, millisecs, months to days.)
-- Date gets stored as integer startig from 0 (4 bytes)
-- Char and Varchar get treated the same way here.
-- Decimal is needed here in order to correctly do conversions between decimals.
--Precision is the number of digits in a number.
-- Scale is the number of digits to the right of the decimal point in a number.
-- For example, the number 123.45 has a precision of 5 and a scale of 2.

data SType  = -- limited to the storage types we actually have?
  SDecimal {precision::Integer, scale::Integer}  -- as an integer?. 1<=P<=18. 0<=S<=P.
  | SInt32   -- 2's compliment?
  | SInt64    -- 2's compliment unsigned?
  deriving (Eq,Show,Generic,Data)
instance NFData SType
instance Hashable SType

sizeOf :: SType -> Integer
sizeOf (SDecimal {}) = 8
sizeOf SInt32 = 4
sizeOf SInt64 = 8
bitwidthOf :: SType -> Integer
bitwidthOf t = 8 * sizeOf t

boundsOf :: SType -> (Integer, Integer)
boundsOf stype = case stype of
  SDecimal {} -> ( toInteger (minBound :: Int64 )
                 , toInteger (maxBound :: Int64 ) )
  SInt32 -> ( toInteger (minBound :: Int32 )
            , toInteger (maxBound :: Int32 ) )
  SInt64 -> ( toInteger (minBound :: Int64 )
            , toInteger (maxBound :: Int64 ) )

withinBounds :: (Integer,Integer) -> SType -> Bool
withinBounds (l,u) stype =
  let (ll,uu) = boundsOf stype
  in (ll <= l && l <= u && u <= uu)

-- these are more general monet types that show
-- up as literals in tpch plans, but not as columns in storage.
-- we convert them as soon as possible to the stypes that fit them
-- so that we only need to think about fewer types.
data MType =
  MTinyint
  | MInt
  | MBigInt
  | MSmallint
  | MDate
  | MMillisec
  | MMonth
  | MDouble
  | MOid
  | MChar Integer
  | MVarchar Integer
  | MDecimal Integer Integer
  | MSecInterval Integer
  | MMonthInterval
  | MBoolean
  deriving (Eq, Show, Generic, Data)
instance NFData MType
instance Hashable MType


makeDictionary :: V.Vector DictRec -> (HashMap C.ByteString Integer)
makeDictionary vec =
  let merge mp (_,_,str,i) = HashMap.insert str i mp
  in V.foldl' merge HashMap.empty vec

resolveTypeSpec :: TypeSpec -> MType
resolveTypeSpec TypeSpec { tname, tparams } = f tname tparams
  where f "int" [] = MInt
        f "tinyint" [] = MTinyint
        f "smallint" [] = MSmallint
        f "bigint" [] = MBigInt
        f "date" []  = MDate
        f "char" [len] =  MChar len
        f "char" [] = MChar (-1) -- beh
        f "varchar" [maxlength] =  MVarchar maxlength
        f "decimal" [precision,scale] = MDecimal precision scale
        f "sec_interval" [_] = MMillisec -- they use millisecs to express their seconds
        f "month_interval" [] = MMonth
        f "double" [] = MDouble -- used for averages even if columns arent doubles
        f "boolean" [] = MBoolean
        f "oid" [] = MOid -- used in storage files
        -- capitalized forms come from schema file.
        f "INTEGER" [] = MInt
        f "CHAR" [len] = MChar len
        f "DECIMAL" [precision,scale] = MDecimal precision scale
        f "VARCHAR" [maxlength] = MVarchar maxlength
        f "DATE" [] = MDate
        f name _ = error $ "unsupported typespec: " ++ show name

toKeyPair :: (NameTable TypeSpec) -> StorageRec -> [ (Name, StorageInfo) ]
toKeyPair ns (_,tab,col,typstring,_,colcount,bytewidth,colsize,_,_,_,_) =
      do let name = Name [tab,col]
         tspec <- if typstring /= "oid"
                  then
                    case NameTable.lookup name ns of
                      Left _ -> []
                      Right  (_,b) -> [b]
                  else [TypeSpec { tname="oid", tparams=[] }]
         let mtype = resolveTypeSpec tspec
         let storagesize = colsize `quot` colcount
         let off = colsize `rem` colcount
         let matches = (case mtype of
                           MChar _ -> True
                           MVarchar _ -> True
                           _ -> storagesize == bytewidth )
         return $ assert (matches &&  (off == 0))  (name, StorageInfo{mtype,storagesize})

-- holds the names of the matching columns for an fk.
-- the order matters, watch out. left is fact, right is dim.
type FKCols = NonEmpty (Name, Name)
type PKCols = NonEmpty Name

-- we use Integer values here so that our metadata calculations
-- don't overflow.
data ColInfo = ColInfo
  { bounds::(Integer,Integer)
    -- bounds on element values
    --this is a bound on the array size (num elts) needed to hold it
  , trailing_zeros::Integer -- largest power of two known to divide all values in column
  , count::Integer
  , stype::SType
  } deriving (Eq,Show,Generic)

instance Hashable ColInfo

data StorageInfo = StorageInfo
  { mtype :: MType
  , storagesize :: Integer
  }

instance NFData ColInfo

checkColInfo :: ColInfo -> ColInfo
checkColInfo i@(ColInfo {bounds=(l,u), count, stype, trailing_zeros}) =
  if l <= u && count > 0 && withinBounds (l,u) stype && trailing_zeros >=0
  then i
  else i -- error $ "info does not pass validation: " ++ show i ++ "\ntype bounds: " ++ (show $  boundsOf stype)

getSTypeOfMType :: MType -> SType
getSTypeOfMType mtype = case mtype of
  MInt -> SInt32
  MDate -> SInt32
  MOid -> SInt64
  MChar _ -> SInt64
  MVarchar _ -> SInt64
  MDecimal precision scale  -> SDecimal {precision, scale}
  MSmallint -> SInt32
  MTinyint -> SInt32
  MBigInt -> SInt64
  ow -> error $ "we don't expect reading this type from the monet columns/queries at the moment: " ++ (show ow)


addEntry :: [Name] -> NameTable StorageInfo -> NameTable ColInfo -> BoundsRec -> NameTable ColInfo
addEntry constraints storagetab nametab (tab,col,colmin,colmax,colcount,trailing_zeros) =
  let StorageInfo {mtype}  = snd $ NameTable.lookup_err (Name [tab,col]) storagetab
      stype = getSTypeOfMType mtype
      colinfo = checkColInfo $ ColInfo { bounds=(colmin, colmax), count=colcount, stype, trailing_zeros }
      plain = NameTable.insert (Name [tab,col]) colinfo nametab
  in if elem (Name[tab,col]) constraints
     then NameTable.insert (Name [tab, B.append "%" col]) colinfo plain -- constraints get marked with % as well
     else plain

makeConfig :: Double -> Bool -> AggStrategy -> V.Vector BoundsRec -> (V.Vector StorageRec) -> [Table] -> V.Vector DictRec -> Config
makeConfig sparsity_threshold metadata aggregation_strategy boundslist storagelist tables dictlist =
  let show_metadata = metadata
      dictionary = makeDictionary dictlist
      constraints = foldMap getTableConstraints tables
      tspecs = NameTable.fromList $ foldMap getTspecs tables
      storagemap = NameTable.fromList $ foldMap (toKeyPair tspecs)  (V.toList storagelist)
      colinfo =  foldl' (addEntry constraints storagemap) NameTable.empty boundslist
      allrefs = foldMap makeFKEntries tables
      straighten qual (a,b) = case qual of
        FactDim -> (a,b)
        DimFact -> (b,a)
      make_partials (nelist,(qual,_)) = N.toList $ N.map (\n -> (n, (qual,N.map (straighten qual) nelist))) nelist
      partialfks = Map.fromList $ foldMap make_partials allrefs
      allpkeys = map makePKeys tables -- sort the non-empty lists
      partialpks = Map.fromList $
           foldMap (\(pkl,_) -> map (\col -> (col,pkl)) (N.toList pkl)) allpkeys
      pktable = map pkpair tables
  in Config { sparsity_threshold, show_metadata, aggregation_strategy, dictionary, colinfo, fkrefs=Map.fromList allrefs, pkeys=Map.fromList allpkeys,
              tablePKeys=Map.fromList pktable, partialfks, partialpks }

pkpair :: Table -> (Name,Name)
pkpair Table{name, pkey=PKey{pkconstraint}} = (name, concatName name pkconstraint)
pkpair _ = error "table with no pkey"

concatName :: Name -> Name -> Name
concatName (Name a) (Name b) = Name (a ++ b)

getTableConstraints :: Table -> [Name]
getTableConstraints Table {name, pkey, fkeys}
  = map (concatName name) (getConstraint pkey : map getConstraint fkeys)

getTspecs :: Table -> [(Name, TypeSpec)]
getTspecs tab = map (\(n,ts) -> (concatName (name tab) n, ts)) $ N.toList $ columns tab

getConstraint :: Key -> Name
getConstraint PKey {pkconstraint} = pkconstraint
getConstraint FKey {fkconstraint} = fkconstraint

makePKeys :: Table -> (NonEmpty Name, Name)
makePKeys Table { pkey=FKey {} }  = error "fkey in place of pkey"
makePKeys Table { name, pkey=PKey { pkcols, pkconstraint } } = (N.sort (N.map (concatName name) pkcols), concatName name pkconstraint)

data FKJoinOrder = FactDim | DimFact deriving (Show,Eq,Generic,Ord)
instance Hashable FKJoinOrder

makeFKEntries :: Table -> [(FKCols, (FKJoinOrder, Name))]
makeFKEntries Table { name, fkeys } =
  do FKey { references, colmap, fkconstraint } <- fkeys
     let (local,remote) = N.unzip colmap
     let localcols = fmap (concatName name) local
     let remotecols = fmap (concatName references) remote
     let joinidx = concatName name fkconstraint
     let implicit = N.sort (N.zip localcols remotecols) -- sort for canonical order
     let implicit_back = N.sort (N.zip remotecols localcols)
     let tidname = concatName references (Name ["%TID%"])
     let explicit = ( joinidx
                    , tidname ) :|[]
     let explicit_back = (tidname, joinidx) :| []
     let fkrefs = [ (implicit, (FactDim, joinidx))
                  , (implicit_back, (DimFact, joinidx))
                  , (explicit, (FactDim, joinidx))
                  , (explicit_back, (DimFact, joinidx)) ]
     fkrefs


data AggStrategy = AggHierarchical Integer | AggSerial | AggShuffle deriving (Show, Eq, Data, Typeable)

data Config =  Config  { sparsity_threshold :: Double
                       , aggregation_strategy :: AggStrategy
                       , show_metadata :: Bool
                       , dictionary :: HashMap C.ByteString Integer
                       , colinfo :: NameTable ColInfo
                       , fkrefs :: Map FKCols (FKJoinOrder,Name)
                                   -- shows the fact -> dimension direction of the dependence
                       , pkeys :: Map (NonEmpty Name) Name -- maps set of columns to pkconstraint if there is one
                                   -- fully qualifed column mames
                       , tablePKeys :: Map Name Name -- maps table to its pkconstraints
                       , partialfks :: Map (Name,Name) (FKJoinOrder, FKCols)
                       , partialpks :: Map Name  PKCols
                       } deriving (Show)

-- if this list is a primary key, value is Just the table name, otherwise nothing
isPkey :: Config -> (NonEmpty Name) -> Maybe Name
isPkey conf nelist = let canon = N.sort nelist
                     in Map.lookup canon (pkeys conf)

lookupPkey :: Config -> Name -> Name
lookupPkey config tab =
  let x = Map.lookup tab (tablePKeys config)
  in case x of
    Nothing -> error "every table has a pkey. no info for table loaded?"
    Just n -> n

-- if this list of pairs matches a known fk constraint, then the value shows is which is the dim/fact
-- and what the name of the constraint is
isFKRef :: Config -> FKCols -> Maybe (FKJoinOrder, Name)
isFKRef conf cols = let canon = N.sort cols
                    in Map.lookup canon (fkrefs conf)

isPartialFk :: Config -> (Name,Name) -> Maybe (FKJoinOrder, FKCols)
isPartialFk config (a,b) = Map.lookup (a,b) (partialfks config)


isPartialPk :: Config -> Name -> Maybe PKCols
isPartialPk config n = Map.lookup n (partialpks config)


--- which queries do we want.
--- really: given colname
