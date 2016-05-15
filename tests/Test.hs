import Test.Tasty
{- import Test.Tasty.SmallCheck as SC
import Test.Tasty.QuickCheck as QC -}
import Test.Tasty.HUnit
import Parser(parse)
import Scanner(scan)
import Data.Either(isRight,partitionEithers)
import qualified Data.Text as T
import Configuration(defaultConfiguration)
import Text.Groom
import Debug.Trace

main :: IO ()
main = do x <- readFile "tests/monet_test_cases.txt"
          let file_cases = get_test_cases x
            in defaultMain $ testGroup "Tests" [unitTests, testGroup "FileTests" file_cases]

toTestCase :: (String, String) -> TestTree
toTestCase (a, b)  = testCase ("------\n" ++  a ++ "\n\n" ++ b ++"\n------\n") (
  let (ls, rs) = partitionEithers $ traceShowId $ scan b
      prs = parse rs
  in (traceShowId ls) == [] && isRight (traceShowId prs) @? (case prs of Left str -> str)
  )

get_test_cases :: String  -> [TestTree]
get_test_cases s = {- the first element after split is a "", because we start with a plan, so must do tail -}
  let raw_pairs =
        case (T.splitOn (T.pack "plan") (T.pack s)) of
          [] -> []
          _ : rest -> rest
      to_pairs [x,y] = (T.unpack . T.strip $ x, T.unpack . T.strip $ y)
  in map (toTestCase . to_pairs . (T.splitOn (T.pack ";"))) raw_pairs


unitTests = testGroup "Unit tests"
  [ -- testCase "List comparison (different length)" $
  --     [1, 2, 3] `compare` [1,2] @?= GT

  -- -- the following test does not hold
  -- , testCase "List comparison (same length)" $
  --     [1, 2, 3] `compare` [1,2,2] @?= LT
  ]
