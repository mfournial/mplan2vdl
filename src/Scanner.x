-- -*- haskell -*-
{
{-# OPTIONS_GHC -w #-}
module Scanner ( ScannedToken(..)
               , Token(..)
               , scan
               , formatTokenOrError
               ) where

import qualified Data.ByteString.Lazy as B
import qualified Data.ByteString.Lazy.Char8 as C

}

%wrapper "posn-bytestring"

----------------------------------- Tokens ------------------------------------

$alpha = [a-zA-Z]
$num = [0-9]
$rel = [\<\>\=\!]
$alnumrel = [$alpha $num $rel]
$name = [$alnumrel \_  \% ] -- bc sys.>= and sys.=, sys.%pk, sys.l_lineitem are all names
$withinquotes = [$name \-\ \#]

tokens :-
  ([$white \|])+ ; -- ignore vertical bars as well.
  \[  { \posn _ -> scannedToken posn LBrack }
  \]  { \posn _ -> scannedToken posn RBrack }
  \(  { \posn _ -> scannedToken posn LParen }
  \)  { \posn _ -> scannedToken posn RParen }
  \,   { \posn _ -> scannedToken posn Comma }
  \.   { \posn _ -> scannedToken posn Dot }
  \;   { \posn _ -> scannedToken posn Semi }
  \"$withinquotes* \" { \posn s -> scannedToken posn ( ValueLiteral s ) }
  $num+ {\posn s -> let { parsedInt = C.readInteger s}
                    in  case parsedInt of
                          Just (i, "") -> scannedToken posn ( NumberLiteral $! i)   {- used only for internal types -}
                          _ -> error "parsing int"
                    }
  "NOT NULL"  { \posn _ -> scannedToken posn (Word "NOT NULL") }
  "no nil"  { \posn _ -> scannedToken posn (Word "no nil") }
  "PRIMARY KEY" { \posn _ -> scannedToken posn (Word "PRIMARY KEY") }
  "FOREIGN KEY" {  \posn _ -> scannedToken posn (Word "FOREIGN KEY") }
  "CREATE TABLE" { \posn _ -> scannedToken  posn ( Word "CREATE TABLE") }
  "!=" { \posn _ -> scannedToken posn (Word "!=") } -- must do this before !
  $name+ { \posn s -> scannedToken posn ( Word s ) }


----------------------------- Representing tokens -----------------------------

{
-- | A token with position information.
data ScannedToken = ScannedToken { line :: Int
                                 , column :: Int
                                 , extractRawToken :: Token
                                 } deriving (Eq,Show)

-- | A token.
data Token =
             Word B.ByteString
           | ValueLiteral B.ByteString
           | NumberLiteral Integer
           | LCurly
           | RCurly
           | LBrack
           | RBrack
           | LParen
           | RParen
           | Dot
           | Comma
           | Semi
           deriving (Eq)

instance Show Token where
  show (Word s) = show s
  show (ValueLiteral s) = show s
  show (NumberLiteral n) = show n
  show LCurly = "{"
  show RCurly = "}"
  show LBrack = "["
  show RBrack = "]"
  show LParen = "("
  show RParen = ")"
  show Dot = "."
  show Semi = ";"
  show Comma = ","


{-  Smart constructor to create a 'ScannedToken' by extracting the line and
column numbers from an 'AlexPosn'. -}
scannedToken :: AlexPosn -> Token -> ScannedToken
scannedToken (AlexPn _ lineNo columnNo) tok = ScannedToken lineNo columnNo tok


---------------------------- Scanning entry point -----------------------------

scan :: B.ByteString -> [ScannedToken] -- [Either String ScannedToken]
scan = alexScanTokens

formatTokenOrError :: Either String ScannedToken -> Either String String
formatTokenOrError (Left err) = Left err
formatTokenOrError (Right tok) = Right $ unwords [ show $ line tok
                                                 , show $ extractRawToken tok
                                                 ]
}
