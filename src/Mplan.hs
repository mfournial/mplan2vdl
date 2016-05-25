module Mplan( fromParseTree
            , fromString
            , BinaryOp
            , RelExpr(..)
            , ScalarExpr(..)
            , GroupAgg(..)
            , MType(..)) where

import qualified Parser as P
import Name(Name(..))
import Data.Time.Calendar
import Control.DeepSeq(NFData)
import GHC.Generics (Generic)
import Text.Groom
import Data.Int
import Data.Monoid(mappend)
import Debug.Trace
import Control.Monad(foldM, mapM)
import Text.Printf (printf)

import System.Locale
import Data.Time.Format
import Data.Time.Calendar
import Data.Time


data MType =
  MTinyint
  | MInt
  | MBigInt
  | MSmallint
  | MDecimal Int Int
  | MSecInterval Int
  | MMonthInterval
  | MDate
  | MCharFix Int
  | MChar
  deriving (Eq, Show, Generic)
instance NFData MType

resolveTypeSpec :: P.TypeSpec -> Either String MType
resolveTypeSpec P.TypeSpec { P.tname, P.tparams } = f tname tparams
  where f "int" [] = Right MInt
        f "tinyint" [] = Right MTinyint
        f "smallint" [] = Right MSmallint
        f "bigint" [] = Right MBigInt
        f "date" []  = Right MDate
        f name _ = Left $  "unsupported typespec: " ++ name
        -- f ["decimal"] [a, b] = Right (MDecimal a b)
        -- f ["sec_interval"] [a] = Right (MSecInterval a)
        -- f ["month_interval"] []  = Right MMonthInterval

        -- f ["char"] [a] = Right (MCharFix a)
        -- f ["char"] [] = Right MChar


{- assumes date is formatted properly: todo. error handling for tis -}
resolveDateString :: String -> Int64
resolveDateString datestr =
  fromIntegral $ diffDays day zero
  where zero = (readTime System.Locale.defaultTimeLocale "%Y-%m-%d" "0000-01-01") :: Day
        day = (readTime System.Locale.defaultTimeLocale "%Y-%m-%d" datestr) :: Day

data OrderSpec = Asc | Desc deriving (Eq,Show, Generic)
instance NFData OrderSpec

data BinaryOp =
  Gt | Lt | Leq | Geq {- rel -}
  | Eq | Neq {- comp -}
  | LogAnd | LogOr {- logical -}
  | Sub | Add | Div | Mul | Mod | BitAnd | BitOr  {- arith -}
  deriving (Eq, Show, Generic)
instance NFData BinaryOp



resolveInfix :: String -> Either String BinaryOp
resolveInfix str =
  case str of
    "<" -> Right Lt
    ">" -> Right Gt
    "<=" -> Right Leq
    ">=" -> Right Geq
    "=" -> Right Eq
    "!=" -> Right Neq
    _ -> Left $ "unknown infix symbol: " ++ str


resolveBinopOpcode :: Name -> Either String BinaryOp
resolveBinopOpcode nm =
  case nm of
    Name ["sys", "sql_add"] -> Right Add
    Name ["sys", "sql_sub"] -> Right Sub
    Name ["sys", "sql_mul"] -> Right Mul
    Name ["sys", "sql_div"] -> Right Div
    _ -> Left $ "unsupported binary function: " ++ show nm

 {- they must be semantically for a single tuple (see aggregates otherwise) -}
data UnaryOp =
  Neg | Year
  deriving (Eq, Show, Generic)
instance NFData UnaryOp


resolveUnopOpcode :: Name -> Either String UnaryOp
resolveUnopOpcode nm =
  case nm of
    Name ["sys", "year"] -> Right Year
    Name ["sys", "sql_neg"] -> Right Neg
    _ -> Left $ "unsupported scalar function " ++ show nm

 {- a Ref can be a column or a previously bound name for an intermediate -}
data ScalarExpr =
  Ref Name
  | IntLiteral Int64 {- use the widest possible type to not lose info -}
  | Unary { unop:: UnaryOp, arg::ScalarExpr }
  | Binop { binop :: BinaryOp, left :: ScalarExpr, right :: ScalarExpr  }
  | Cast { mtype :: MType, arg::ScalarExpr }
  deriving (Eq, Show, Generic)
instance NFData ScalarExpr

data GroupAgg = Sum ScalarExpr | Avg ScalarExpr | Count
  deriving (Eq,Show,Generic)
instance NFData GroupAgg

solveGroupOutputs :: [P.Expr] -> Either String ([(Name, Maybe Name)], [(GroupAgg, Maybe Name)])

solveGroupOutputs exprs =
  do sifted <- sequence $ map ghelper exprs
     return $ foldl mappend ([],[]) sifted

{- sifts out key lists to the first meber,
 and aggregates to the second  -}
ghelper  :: P.Expr -> Either String ([(Name, Maybe Name)], [(GroupAgg, Maybe Name)])

ghelper P.Expr
  { P.expr = P.Ref {P.rname} {- output key -}
  , P.alias }
  = Right ([(rname, alias)], [])

ghelper P.Expr
  { P.expr = P.Call { P.fname
                    , P.args=[ P.Expr
                               { P.expr=singlearg,
                                 P.alias = _ -- ignoring this inner alias.
                                 }
                             ]
                    }
  , P.alias }
  = do inner <- sc singlearg
       case fname of
         Name ["sys", "sum"] -> return ([], [(Sum inner, alias)])
         Name ["sys", "avg"] -> return ([], [(Avg inner, alias)])
         _ -> Left $ "unknown unary aggregate " ++ show fname

ghelper  P.Expr
  { P.expr = P.Call { P.fname=Name ["sys", "count"]
                    , P.args=[] }
  , P.alias }
  = Right ([], [(Count, alias)] )


ghelper s_ = Left $
  "expression not supported as output of group_by: " ++ groom s_


data RelExpr =
  Table       { tablename :: Name
              , tablecolumns :: [(Name, Maybe Name)]
              }
  | Project   { child :: RelExpr
              , projectout :: [(ScalarExpr, Maybe Name)]
              , order ::[(Name, OrderSpec)]
              }
  | Select    { child :: RelExpr
              , predicate :: ScalarExpr
              }
  | GroupBy   { child :: RelExpr
              , inputkeys :: [Name]
              , outputkeys :: [(Name, Maybe Name)]
              , outputaggs :: [(GroupAgg, Maybe Name)]
              }
  | SemiJoin  { lchild :: RelExpr
              , rchild :: RelExpr
              , condition :: ScalarExpr
              }
  | TopN
  | Cross
  | Join
  | AntiJoin
  | LeftOuter
  deriving (Eq,Show, Generic)
instance NFData RelExpr

-- thsis  way to insert extra consistency checks
check :: a -> (a -> Bool) -> String -> Either String a
check val cond msg = if cond val then Right val else Left msg


{-helper function uesd in multiple operators that introduce output
columns -}
solveOutputs :: [P.Expr] -> Either String [(ScalarExpr, Maybe Name)]
solveOutputs explist = sequence $ map f explist
  where f P.Expr { P.expr, P.alias } =
          do scalar <- sc expr
             return (scalar, alias)


solve :: P.Rel -> Either String RelExpr

{- Leaf (aka Table) invariants /checks:
  -tablecolumns must not be empty.
  -table columns must only be references, not complex expressions nor literals.
  -table columns may themselves be aliased within table.
  -some of the names involve using schema (not for now)
   for concrete resolution to things like partsupp.%partsupp_fk1
-}
solve P.Leaf { P.source, P.columns } =
  do pcols <- sequence $ map split columns
     checkedcols <- check pcols ( /= []) "list of table columns must not be empty"
     return $ Table { tablename = source, tablecolumns = checkedcols}
  where
    split P.Expr { P.expr = P.Ref { P.rname }
                 , P.alias } = Right (rname, alias)
    split _ = Left "table outputs should only have reference expressions"


{- Project invariants
- single child node
- multiple output columns with potential aliasing (non empty)
- potentially empty order columns. no aliasing there.
(what relation do they have with output ones?)
-}

solve P.Node { P.relop = "project"
             , P.children = [ch] -- only one child rel allowed for project
             , P.arg_lists = out : rest -- not dealing with order by right now.
             } =
  do child <- solve ch
     projectout <- solveOutputs out
     order <- (case rest of
                 [] -> Right []
                 _ -> Left "not dealing with order-by clauses")
     return $ Project {child, projectout, order }


  {- Group invariants:
     - single child node
     - multiple output value columns with potential expressions (non-empty)
     - multiple group key value columns (non-empty)
  -}
solve P.Node { P.relop = "group by"
             , P.children = [ch] -- only one child rel allowed for group by
             , P.arg_lists =  igroupkeys : igroupvalues : []
             } =
  do child <- solve ch
     inputkeys <- sequence $ map extractKey igroupkeys
     (outputkeys, outputaggs) <- solveGroupOutputs igroupvalues
     return $ GroupBy {child, inputkeys, outputkeys, outputaggs}
       where extractKey P.Expr { P.expr = P.Ref { P.rname }
                               , P.alias = Nothing } = Right rname
             extractKey e_ =
               Left $ "unexpected alias in input group key: " ++ groom e_

 {- Select invariants:
 -single child node
 -predicate is a single scalar expression
 -}
solve P.Node { P.relop = "select"
             , P.children = [ch]
             , P.arg_lists = props : []
             } =
  do child <- solve ch
     predicate <- conjunction props
     return $ Select { child, predicate }


  {- Semijoin invariants:
     - binary relop
     - condition may be complex (most are quality, but some aren't)
  -}


solve s_ = Left $ " parse tree not valid or case not implemented:  " ++ groom s_



{- code to transform parser scalar sublanguage into Mplan scalar -}
sc :: P.ScalarExpr -> Either String ScalarExpr
sc P.Ref { P.rname  } = Right $ Ref rname

{- for now, we are ignoring the aliases within calls -}
sc P.Call { P.fname, P.args = [ P.Expr { P.expr = singlearg, P.alias = _ } ] } =
  do sub <- sc singlearg
     unop <- resolveUnopOpcode fname
     return $ Unary { unop, arg=sub }

sc P.Call { P.fname
          , P.args = [ P.Expr { P.expr = firstarg, P.alias = _ }
                     , P.Expr { P.expr = secondarg, P.alias = _ }
                     ]
          } =
  do left <- sc firstarg
     right <- sc secondarg
     binop <- resolveBinopOpcode fname
     return $ Binop { binop, left, right }

sc P.Cast { P.tspec
          , P.value = P.Expr { P.expr = parg, P.alias = _  }
          } =
  do mtype <- resolveTypeSpec tspec
     arg <- sc parg
     return $ Cast { mtype, arg }

sc P.Literal { P.tspec, P.stringRep } =
  do mtype <- resolveTypeSpec tspec
     ret <- case mtype of
       MDate -> Right $ resolveDateString stringRep
       _ -> do int <- ( let r = readIntLiteral stringRep in
                        case mtype of
                          MInt -> r
                          MTinyint -> r
                          MSmallint -> r
                          _ -> Left "need to add conversion to this literal" )
               return $ int
     return $ IntLiteral ret


sc P.Infix {P.infixop
           ,P.left
           ,P.right} =
  do l <- sc (P.expr left)
     r <- sc (P.expr right)
     binop <- resolveInfix infixop
     return $ Binop { binop, left=l, right=r }

sc (P.Nested exprs) = conjunction exprs

sc s_ = Left $ "cannot handle this scalar: " ++ groom s_


{- converts a list into ANDs -}
conjunction :: [P.Expr] -> Either String ScalarExpr
conjunction exprs =
  do solved <- mapM (sc . P.expr) exprs
     case solved of
       [] -> Left $ "conjunction list cannot be empty (should check at parse time)"
       [x] -> return x
       x : y : rest -> return $ foldl makeAnd (makeAnd x y) rest
       where makeAnd a b = Binop { binop=LogAnd, left=a, right=b }


readIntLiteral :: String -> Either String Int64
readIntLiteral str =
  case reads str :: [(Int64, String)] of
    [(num, [])] -> Right num
    ow -> Left $ printf "cannot parse %s as integer literal: %s" str $ show ow

fromParseTree :: P.Rel -> Either String RelExpr
fromParseTree = solve

fromString :: String -> Either String RelExpr
fromString mplanstring =
  do parsetree <- P.fromString mplanstring
     let mplan = fromParseTree parsetree
     let tr = case mplan of
                Left err -> "\n--Error at Mplan stage:\n" ++ err
                Right g -> "\n--Mplan output:\n" ++ groom g
     trace tr mplan
