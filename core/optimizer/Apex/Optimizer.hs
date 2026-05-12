{-# LANGUAGE DataKinds, GADTs, RankNTypes, TypeFamilies,
             ScopedTypeVariables, OverloadedStrings,
             LambdaCase, TupleSections, StrictData #-}

{- |
APEX Query Optimizer: Cascades-style top-down CBO with memoization,
physical property enforcement (sort order, partitioning, colocation),
and cardinality estimation via compressed statistics sketches.

Architecture:
  ┌───────────────────────┐
  │   Logical Plan Tree   │
  └───────────┬───────────┘
              │  explore (rule application)
  ┌───────────▼───────────┐
  │     Memo Groups       │ ← sharing-equivalent logical expressions
  └───────────┬───────────┘
              │  implement (physical operators)
  ┌───────────▼───────────┐
  │  Physical Plan Forest │ ← multiple physical alternatives
  └───────────┬───────────┘
              │  enforcer insertion
  ┌───────────▼───────────┐
  │   Optimal Plan Tree   │
  └───────────────────────┘
-}

module Apex.Optimizer where

import Control.Monad
import Control.Monad.State.Strict
import Control.Monad.Reader
import Control.Monad.Except
import Control.Monad.Trans.Class
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.IntMap.Strict (IntMap)
import qualified Data.IntMap.Strict as IMap
import Data.List (minimumBy, foldl')
import Data.Ord (comparing)
import Data.Maybe (catMaybes, fromMaybe)
import Data.IORef

-- ── Schema & Statistics ──────────────────────────────────────────────

data Type = TInt | TBigInt | TDouble | TText | TTimestamp | TBool
  deriving (Show, Eq, Ord)

data Column = Column
  { colName   :: !String
  , colType   :: !Type
  , colTable  :: !String
  , colNullable :: !Bool
  } deriving (Show, Eq, Ord)

-- HyperLogLog for distinct-count, Count-Min for frequency estimation
data ColumnStats = ColumnStats
  { csNdv        :: !Double   -- number of distinct values
  , csMcv        :: [(String, Double)]  -- most-common-values + freq
  , csHistBounds :: [Double]  -- equi-depth histogram boundaries
  , csHistFreqs  :: [Double]
  , csNullFrac   :: !Double
  , csAvgWidth   :: !Double
  } deriving Show

data TableStats = TableStats
  { tsRowCount  :: !Double
  , tsPageCount :: !Int
  , tsColumns   :: Map String ColumnStats
  } deriving Show

type Catalog = Map String TableStats  -- tableName → stats

-- ── Logical Plan ─────────────────────────────────────────────────────

data LogicalPlan
  = Scan      { lpTable :: String, lpAlias :: String, lpPreds :: [Pred] }
  | Filter    { lpChild :: LogicalPlan, lpPred :: Pred }
  | Project   { lpChild :: LogicalPlan, lpExprs :: [(String, Expr)] }
  | Join      { lpLeft  :: LogicalPlan
              , lpRight :: LogicalPlan
              , lpJoinType :: JoinType
              , lpJoinPred :: Pred }
  | Agg       { lpChild :: LogicalPlan
              , lpGroupBy :: [Expr]
              , lpAggs :: [(String, AggFunc, Expr)] }
  | Sort      { lpChild :: LogicalPlan, lpOrderBy :: [SortKey] }
  | Limit     { lpChild :: LogicalPlan, lpN :: Int }
  | Union     { lpLeft :: LogicalPlan, lpRight :: LogicalPlan, lpAll :: Bool }
  | Window    { lpChild :: LogicalPlan
              , lpWinFns :: [(String, WinFunc, WinSpec)] }
  deriving (Show, Eq)

data JoinType  = Inner | LeftOuter | RightOuter | FullOuter | Semi | AntiSemi
  deriving (Show, Eq)
data AggFunc   = Count | Sum | Avg | Min | Max | StdDev | Percentile Double
  deriving (Show, Eq)
data SortKey   = SortKey { skExpr :: Expr, skAsc :: Bool, skNullsFirst :: Bool }
  deriving (Show, Eq)
data WinFunc   = WinRow | WinRank | WinDenseRank | WinLag Int | WinLead Int
               | WinAgg AggFunc
  deriving (Show, Eq)
data WinSpec   = WinSpec
  { wsPartBy :: [Expr], wsOrderBy :: [SortKey]
  , wsFrame  :: WinFrame } deriving (Show, Eq)
data WinFrame  = Rows | Range | Groups
  deriving (Show, Eq)

data Pred
  = PTrue | PFalse
  | PComp CompOp Expr Expr
  | PAnd [Pred] | POr [Pred] | PNot Pred
  | PInList Expr [Expr]
  | PIsNull Expr
  | PBetween Expr Expr Expr
  | PExists LogicalPlan
  | PAny CompOp Expr LogicalPlan
  deriving (Show, Eq)

data CompOp = Eq | Ne | Lt | Le | Gt | Ge | Like | ILike
  deriving (Show, Eq)

data Expr
  = ECol String         -- column ref (possibly qualified: "t.col")
  | ELit Lit
  | EBinOp BinOp Expr Expr
  | EFunc String [Expr]
  | ECase [(Pred, Expr)] (Maybe Expr)
  | ESubquery LogicalPlan
  | ECast Expr Type
  deriving (Show, Eq)

data Lit = LInt Int | LDouble Double | LText String | LBool Bool | LNull
  deriving (Show, Eq)
data BinOp = Add | Sub | Mul | Div | Mod | Concat
  deriving (Show, Eq)

-- ── Physical Plan ──────────────────────────────────────────────────

data PhysicalPlan
  = SeqScan        { ppTable :: String, ppPreds :: [Pred], ppCost :: !Cost }
  | IndexScan      { ppTable :: String, ppIndex :: String
                   , ppRanges :: [(Pred, Pred)], ppCost :: !Cost }
  | BitmapScan     { ppTable :: String, ppBitmaps :: [String], ppCost :: !Cost }
  | HashJoin       { ppLeft :: PhysicalPlan, ppRight :: PhysicalPlan
                   , ppJoinPred :: Pred, ppCost :: !Cost }
  | MergeJoin      { ppLeft :: PhysicalPlan, ppRight :: PhysicalPlan
                   , ppJoinPred :: Pred, ppSortL :: [SortKey]
                   , ppSortR :: [SortKey], ppCost :: !Cost }
  | NestedLoopJoin { ppOuter :: PhysicalPlan, ppInner :: PhysicalPlan
                   , ppJoinPred :: Pred, ppCost :: !Cost }
  | HashAgg        { ppChild :: PhysicalPlan, ppGroupBy :: [Expr]
                   , ppAggs :: [(String, AggFunc, Expr)], ppCost :: !Cost }
  | SortAgg        { ppChild :: PhysicalPlan, ppGroupBy :: [Expr]
                   , ppAggs :: [(String, AggFunc, Expr)], ppCost :: !Cost }
  | Sort_          { ppChild :: PhysicalPlan, ppKeys :: [SortKey], ppCost :: !Cost }
  | HashDistinct   { ppChild :: PhysicalPlan, ppCost :: !Cost }
  | Materialize    { ppChild :: PhysicalPlan, ppCost :: !Cost }
  | Append         [PhysicalPlan] !Cost
  deriving Show

type Cost = Double

-- ── Memo structure ─────────────────────────────────────────────────

newtype GroupID = GroupID Int deriving (Show, Eq, Ord)

data MemoGroup = MemoGroup
  { mgLogical   :: [LogicalPlan]     -- equivalent logical exprs (explored)
  , mgPhysical  :: [PhysicalPlan]    -- generated physical alternatives
  , mgBestCost  :: Maybe (Cost, PhysicalPlan)
  } deriving Show

type Memo = IntMap MemoGroup

-- ── Optimizer Monad ────────────────────────────────────────────────

data OptEnv = OptEnv
  { oeCatalog  :: Catalog
  , oeRules    :: [TransformRule]
  , oeProps    :: PhysProps           -- required physical properties
  }

data PhysProps = PhysProps
  { ppSortOrder  :: Maybe [SortKey]
  , ppPartKey    :: Maybe [Expr]
  , ppRowLimit   :: Maybe Int
  } deriving (Show, Eq)

noProps :: PhysProps
noProps = PhysProps Nothing Nothing Nothing

data OptState = OptState
  { osMemo      :: Memo
  , osNextGroup  :: Int
  , osExplored   :: Set (GroupID, String)  -- (group, rule_name) already fired
  }

type OptM a = ReaderT OptEnv (StateT OptState (Except String)) a

runOpt :: OptEnv -> OptM a -> Either String a
runOpt env m =
  runExcept $ evalStateT (runReaderT m env)
    OptState { osMemo = IMap.empty, osNextGroup = 0, osExplored = Set.empty }

-- ── Cardinality Estimation ─────────────────────────────────────────

estimateCard :: LogicalPlan -> OptM Double
estimateCard = \case
  Scan { lpTable = t, lpPreds = ps } -> do
    catalog <- asks oeCatalog
    let base = maybe 1000 tsRowCount (Map.lookup t catalog)
    foldM (\rows p -> (* rows) <$> selectivity t p) base ps

  Filter { lpChild = c, lpPred = p } -> do
    childRows <- estimateCard c
    sel       <- selectivity "" p
    return (childRows * sel)

  Join { lpLeft = l, lpRight = r, lpJoinType = jt, lpJoinPred = p } -> do
    lRows <- estimateCard l
    rRows <- estimateCard r
    sel   <- selectivity "" p
    let cross = lRows * rRows * sel
    return $ case jt of
      Inner      -> cross
      LeftOuter  -> max cross lRows
      RightOuter -> max cross rRows
      FullOuter  -> max cross (lRows + rRows)
      Semi       -> lRows * min 1.0 sel
      AntiSemi   -> lRows * (1.0 - min 1.0 sel)

  Agg { lpChild = c, lpGroupBy = gby } -> do
    childRows <- estimateCard c
    if null gby
      then return 1.0
      else return (min childRows (childRows ** (fromIntegral (length gby) / 10.0)))

  Sort   { lpChild = c } -> estimateCard c
  Limit  { lpChild = c, lpN = n } -> min (fromIntegral n) <$> estimateCard c
  Project{ lpChild = c } -> estimateCard c
  Union  { lpLeft = l, lpRight = r, lpAll = a } -> do
    lr <- estimateCard l; rr <- estimateCard r
    return $ if a then lr + rr else max lr rr * 0.9
  Window { lpChild = c } -> estimateCard c

selectivity :: String -> Pred -> OptM Double
selectivity tbl = \case
  PTrue              -> return 1.0
  PFalse             -> return 0.0
  PAnd ps            -> product <$> mapM (selectivity tbl) ps
  POr  ps            -> do sels <- mapM (selectivity tbl) ps
                           return $ 1 - product (map (1-) sels)
  PNot p             -> (1-) <$> selectivity tbl p
  PComp Eq _ _       -> return 0.05    -- default: 1/ndv heuristic
  PComp op _ _ | op `elem` [Lt,Le,Gt,Ge]
                     -> return 0.333
  _                  -> return 0.1

-- ── Transformation Rules (Cascades-style) ─────────────────────────

data TransformRule = TransformRule
  { trName    :: String
  , trPattern :: LogicalPlan -> Maybe LogicalPlan
  }

commuteJoin :: TransformRule
commuteJoin = TransformRule "CommJoin" $ \case
  Join l r jt p -> Just (Join r l (flipJoin jt) (flipPred p))
  _             -> Nothing

flipJoin :: JoinType -> JoinType
flipJoin LeftOuter  = RightOuter
flipJoin RightOuter = LeftOuter
flipJoin j          = j

flipPred :: Pred -> Pred
flipPred (PComp op l r) = PComp (flipComp op) r l
flipPred p = p

flipComp :: CompOp -> CompOp
flipComp Lt = Gt; flipComp Le = Ge; flipComp Gt = Lt; flipComp Ge = Le
flipComp op = op

associateJoin :: TransformRule
associateJoin = TransformRule "AssocJoin" $ \case
  Join (Join a b it1 p1) c it2 p2
    | it1 == Inner && it2 == Inner ->
        Just (Join a (Join b c Inner p2) Inner p1)
  _ -> Nothing

pushFilterIntoJoin :: TransformRule
pushFilterIntoJoin = TransformRule "PushPredJoin" $ \case
  Filter (Join l r jt p) fp
    | refsOnly (tablesOf l) fp ->
        Just (Join (Filter l fp) r jt p)
    | refsOnly (tablesOf r) fp ->
        Just (Join l (Filter r fp) jt p)
  _ -> Nothing

refsOnly :: Set String -> Pred -> Bool
refsOnly _ PTrue  = True
refsOnly _ PFalse = True
refsOnly tables (PComp _ (ECol c) _) = Set.member (tableOf c) tables
refsOnly _ _ = False

tableOf :: String -> String
tableOf s = case break (=='.') s of
  (t, '.':_) -> t
  _           -> s

tablesOf :: LogicalPlan -> Set String
tablesOf = \case
  Scan { lpAlias = a } -> Set.singleton a
  Filter { lpChild = c } -> tablesOf c
  Join { lpLeft = l, lpRight = r } -> tablesOf l `Set.union` tablesOf r
  Project { lpChild = c } -> tablesOf c
  _ -> Set.empty

defaultRules :: [TransformRule]
defaultRules = [commuteJoin, associateJoin, pushFilterIntoJoin]

-- ── Cost Model ─────────────────────────────────────────────────────

seqScanCost :: Double -> Double
seqScanCost pages = pages * 1.0   -- 1 cost unit per page

randomIOCost :: Double -> Double
randomIOCost tuples = tuples * 4.0

hashBuildCost :: Double -> Double
hashBuildCost rows = rows * 3.0

hashProbeCost :: Double -> Double
hashProbeCost rows = rows * 1.1

mergeSortCost :: Double -> Double
mergeSortCost rows = rows * log (rows + 1) * 0.01

costPlan :: PhysicalPlan -> OptM Cost
costPlan = \case
  SeqScan   { ppCost = c }  -> return c
  IndexScan { ppCost = c }  -> return c
  HashJoin  { ppLeft = l, ppRight = r } -> do
    lc <- costPlan l; rc <- costPlan r
    lr <- totalRows l; rr <- totalRows r
    return $ lc + rc + hashBuildCost lr + hashProbeCost rr
  MergeJoin { ppLeft = l, ppRight = r } -> do
    lc <- costPlan l; rc <- costPlan r
    lr <- totalRows l; rr <- totalRows r
    return $ lc + rc + mergeSortCost lr + mergeSortCost rr + lr + rr
  Sort_ { ppChild = c, ppCost = _ } -> do
    cc <- costPlan c; cr <- totalRows c
    return $ cc + mergeSortCost cr
  HashAgg { ppChild = c } -> do
    cc <- costPlan c; cr <- totalRows c
    return $ cc + hashBuildCost cr
  _ -> return 0.0

totalRows :: PhysicalPlan -> OptM Double
totalRows _ = return 1000.0  -- would traverse plan tree in real impl

-- ── Main Optimization Entry Point ─────────────────────────────────

optimize :: Catalog -> LogicalPlan -> Either String PhysicalPlan
optimize catalog lp =
  let env = OptEnv catalog defaultRules noProps
  in runOpt env (optimizePlan lp)

optimizePlan :: LogicalPlan -> OptM PhysicalPlan
optimizePlan lp = do
  card   <- estimateCard lp
  alts   <- generatePhysical lp card
  costs  <- mapM (\p -> (,p) <$> costPlan p) alts
  case costs of
    [] -> throwError "no physical plan generated"
    _  -> return . snd $ minimumBy (comparing fst) costs

generatePhysical :: LogicalPlan -> Double -> OptM [PhysicalPlan]
generatePhysical lp card = case lp of
  Scan { lpTable = t, lpPreds = ps } -> do
    catalog <- asks oeCatalog
    let pages = maybe 100 tsPageCount (Map.lookup t catalog)
    let seqC  = seqScanCost (fromIntegral pages)
    let seq_  = SeqScan t ps seqC
    -- Index scan hypothetical (real impl checks catalog for indexes)
    let idx_  = IndexScan t (t <> "_pk") [] (seqC * 0.1)
    return [seq_, idx_]

  Filter { lpChild = c, lpPred = p } -> do
    inner <- optimizePlan c
    return [inner]     -- filter pushed into scan in real impl

  Join { lpLeft = l, lpRight = r, lpJoinPred = jp } -> do
    lp_  <- optimizePlan l
    rp_  <- optimizePlan r
    lc   <- estimateCard l
    rc   <- estimateCard r
    let hj = HashJoin lp_ rp_ jp 0.0
        nj = NestedLoopJoin lp_ rp_ jp 0.0
        -- MergeJoin requires sorted inputs
        mj = MergeJoin lp_ rp_ jp [] [] 0.0
    return [hj, nj, mj]

  Agg { lpChild = c, lpGroupBy = gby, lpAggs = ags } -> do
    inner <- optimizePlan c
    return [ HashAgg inner gby ags 0.0
           , SortAgg inner gby ags 0.0 ]

  Sort { lpChild = c, lpOrderBy = keys } -> do
    inner <- optimizePlan c
    return [ Sort_ inner keys 0.0 ]

  _ -> do
    inner <- optimizePlan (lpChild_ lp)
    return [inner]

lpChild_ :: LogicalPlan -> LogicalPlan
lpChild_ (Project c _) = c
lpChild_ (Limit   c _) = c
lpChild_ (Window  c _) = c
lpChild_ lp = lp
