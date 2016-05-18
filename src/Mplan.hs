module Mplan( fromParseTree
            , fromString
            , Name
            , BinaryOp
            , RelExpr(..)
            , ScalarExpr(..)) where

import qualified Parser as P
import Parser(Name)



data OrderSpec = Asc | Desc deriving (Eq,Show)

data BinaryOp =
  Gt | Lt | Leq | Geq {- rel -}
  | Eq | Neq {- comp -}
  | LogAnd | LogOr {- logical -}
  | Sub | Add | Div | Mul | Mod | BitAnd | BitOr  {- arith -}
  deriving (Eq, Show)

data ScalarExpr =
  {- a Ref can be a column or a previously bound name for an intermediate -}
  Ref Name
  | Lit { littype :: String,  litvalue :: String }
  | Binop { binop :: BinaryOp, left :: ScalarExpr, right :: ScalarExpr  }
  deriving (Eq, Show)

data RelExpr =
  Table { tablename :: Name,  tablecolumns :: [(Name, Maybe Name)]  }
  | Project { child :: RelExpr, projectout :: [(ScalarExpr, Maybe Name)], order ::[(Name, OrderSpec)] }
    {- Select invariants:
     -single child node
     -predicate is a single scalar expression
  -}
  | Select { child :: RelExpr, selectpredicate :: ScalarExpr  }
  {- Group invariants:
     - single child node
     - multiple output value columns with potential expressions (non-empty)
     - multiple group key value columns (non-empty)
  -}
  | Group {  child :: RelExpr, groupvalues :: [(Name, Maybe Name)], groupkeys :: [(Name, Maybe Name)]  }
  {- Semijoin invariants:
     - binary relop
     - condition may be complex (most are quality, but some aren't)
  -}
  | SemiJoin { lchild :: RelExpr, rchild :: RelExpr, condition :: ScalarExpr  }
  | TopN
  | Cross
  | Join
  | AntiJoin
  | LeftOuter
  deriving (Eq,Show)


-- thsis  way to insert extra consistency checks
check :: a -> (a -> Bool) -> String -> Either String a
check val cond msg = if cond val then Right val else Left msg

solve :: P.Rel -> Either String RelExpr

{- Leaf -> Table invariants /checks:
  -tablecolumns must not be empty.
  -table columns may themselves be aliased within table.
  -some of the names involve using schema (not for now)
   for concrete resolution to things like partsupp.%partsupp_fk1
-}
solve P.Leaf { P.source, P.columns } =
  do pcols <- sequence $ map split columns
     pcols <- check pcols ( /= []) "list of table columns must not be empty"
     return $ Table { tablename = source, tablecolumns = pcols}
  where
    split P.Expr { P.expr = P.Ref { P.rname }
                 , P.alias } = Right (rname, alias)
    split _ = Left "a Leaf should only have reference expressions"

solve P.Node { P.relop } = Left $ "converting " ++ relop ++ " to Mplan is not implemented "

fromParseTree :: P.Rel -> Either String RelExpr
fromParseTree = solve

fromString :: String -> Either String RelExpr
fromString s = P.fromString s >>= fromParseTree

