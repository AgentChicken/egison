{-# LANGUAGE TupleSections #-}

{- |
Module      : Language.Egison.Parser
Copyright   : Satoshi Egi
Licence     : MIT

This module provide Egison parser.
-}

module Language.Egison.Parser 
       (
       -- * Parse a string
         readTopExprs
       , readTopExpr
       , readExprs
       , readExpr
       , parseTopExprs
       , parseTopExpr
       , parseExprs
       , parseExpr
       -- * Parse a file
       , loadLibraryFile
       , loadFile
       ) where

import Prelude hiding (mapM)
import Control.Monad.Identity hiding (mapM)
import Control.Monad.Error hiding (mapM)
import Control.Monad.State hiding (mapM)
import Control.Applicative ((<$>), (<*>), (*>), (<*), pure)

import System.Directory (doesFileExist)

import qualified Data.Sequence as Sq
import Data.Either
import Data.Char (isLower, isUpper)
import qualified Data.Set as Set
import Data.Traversable (mapM)
import Data.Ratio

import Text.Parsec
import Text.Parsec.String
import qualified Text.Parsec.Token as P

import qualified Data.Text as T

import Language.Egison.Types
import Language.Egison.Desugar
import Paths_egison (getDataFileName)

readTopExprs :: String -> EgisonM [EgisonTopExpr]
readTopExprs = either throwError (mapM desugarTopExpr) . parseTopExprs

readTopExpr :: String -> EgisonM EgisonTopExpr
readTopExpr = either throwError desugarTopExpr . parseTopExpr

readExprs :: String -> EgisonM [EgisonExpr]
readExprs = liftEgisonM . runDesugarM . either throwError (mapM desugar) . parseExprs

readExpr :: String -> EgisonM EgisonExpr
readExpr = liftEgisonM . runDesugarM . either throwError desugar . parseExpr

parseTopExprs :: String -> Either EgisonError [EgisonTopExpr]
parseTopExprs = doParse $ do
  ret <- whiteSpace >> endBy topExpr whiteSpace
  eof
  return ret

parseTopExpr :: String -> Either EgisonError EgisonTopExpr
parseTopExpr = doParse $ do
  ret <- whiteSpace >> topExpr
  whiteSpace >> eof
  return ret

parseExprs :: String -> Either EgisonError [EgisonExpr]
parseExprs = doParse $ do
  ret <- whiteSpace >> endBy expr whiteSpace
  eof
  return ret

parseExpr :: String -> Either EgisonError EgisonExpr
parseExpr = doParse $ do
  ret <- whiteSpace >> expr
  whiteSpace >> eof
  return ret

-- |Load a libary file
loadLibraryFile :: FilePath -> EgisonM [EgisonTopExpr]
loadLibraryFile file = liftIO (getDataFileName file) >>= loadFile

-- |Load a file
loadFile :: FilePath -> EgisonM [EgisonTopExpr]
loadFile file = do
  doesExist <- liftIO $ doesFileExist file
  unless doesExist $ throwError $ strMsg ("file does not exist: " ++ file)
  input <- liftIO $ readFile file
  exprs <- readTopExprs $ shebang input
  concat <$> mapM  recursiveLoad exprs
 where
  recursiveLoad (Load file) = loadLibraryFile file
  recursiveLoad (LoadFile file) = loadFile file
  recursiveLoad expr = return [expr]
  shebang :: String -> String
  shebang ('#':'!':cs) = ';':'#':'!':cs
  shebang cs = cs

--
-- Parser
--

doParse :: Parser a -> String -> Either EgisonError a
doParse p input = either (throwError . fromParsecError) return $ parse p "egison" input
  where
    fromParsecError :: ParseError -> EgisonError
    fromParsecError = Parser . show

--
-- Expressions
--
topExpr :: Parser EgisonTopExpr
topExpr = try (Test <$> expr)
      <|> try (parens (defineExpr
                   <|> testExpr
                   <|> executeExpr
                   <|> loadFileExpr
                   <|> loadExpr))
      <?> "top-level expression"

defineExpr :: Parser EgisonTopExpr
defineExpr = keywordDefine >> Define <$> varName <*> expr

testExpr :: Parser EgisonTopExpr
testExpr = keywordTest >> Test <$> expr

executeExpr :: Parser EgisonTopExpr
executeExpr = keywordExecute >> Execute <$> expr

loadFileExpr :: Parser EgisonTopExpr
loadFileExpr = keywordLoadFile >> LoadFile <$> stringLiteral

loadExpr :: Parser EgisonTopExpr
loadExpr = keywordLoad >> Load <$> stringLiteral

exprs :: Parser [EgisonExpr]
exprs = endBy expr whiteSpace

expr :: Parser EgisonExpr
expr = do expr <- expr'
          option expr $ IndexedExpr expr <$> many1 (try $ char '_' >> expr')

expr' :: Parser EgisonExpr
expr' = (try constantExpr
             <|> try varExpr
             <|> inductiveDataExpr
             <|> try arrayExpr
             <|> try tupleExpr
             <|> try hashExpr
             <|> collectionExpr
             <|> parens (ifExpr
                         <|> lambdaExpr
                         <|> memoizedLambdaExpr
                         <|> memoizeExpr
                         <|> patternFunctionExpr
                         <|> letRecExpr
                         <|> letExpr
                         <|> doExpr
                         <|> ioExpr
                         <|> matchAllExpr
                         <|> matchExpr
                         <|> matchAllLambdaExpr
                         <|> matchLambdaExpr
                         <|> nextMatchAllExpr
                         <|> nextMatchExpr
                         <|> nextMatchAllLambdaExpr
                         <|> nextMatchLambdaExpr
                         <|> matcherExpr
                         <|> matcherBFSExpr
                         <|> matcherDFSExpr
                         <|> seqExpr
                         <|> applyExpr
                         <|> algebraicDataMatcherExpr
                         <|> generateArrayExpr
                         <|> arraySizeExpr
                         <|> arrayRefExpr)
             <?> "expression")

varExpr :: Parser EgisonExpr
varExpr = VarExpr <$> ident

inductiveDataExpr :: Parser EgisonExpr
inductiveDataExpr = angles $ InductiveDataExpr <$> upperName <*> sepEndBy expr whiteSpace

tupleExpr :: Parser EgisonExpr
tupleExpr = brackets $ TupleExpr <$> sepEndBy expr whiteSpace

collectionExpr :: Parser EgisonExpr
collectionExpr = braces $ CollectionExpr <$> sepEndBy innerExpr whiteSpace
 where
  innerExpr :: Parser InnerExpr
  innerExpr = (char '@' >> SubCollectionExpr <$> expr)
               <|> ElementExpr <$> expr

arrayExpr :: Parser EgisonExpr
arrayExpr = between lp rp $ ArrayExpr <$> sepEndBy expr whiteSpace
  where
    lp = P.lexeme lexer (string "[|")
    rp = P.lexeme lexer (string "|]")

hashExpr :: Parser EgisonExpr
hashExpr = between lp rp $ HashExpr <$> sepEndBy pairExpr whiteSpace
  where
    lp = P.lexeme lexer (string "{|")
    rp = P.lexeme lexer (string "|}")
    pairExpr :: Parser (EgisonExpr, EgisonExpr)
    pairExpr = brackets $ (,) <$> expr <*> expr

matchAllExpr :: Parser EgisonExpr
matchAllExpr = keywordMatchAll >> MatchAllExpr <$> expr <*> expr <*> matchClause

matchExpr :: Parser EgisonExpr
matchExpr = keywordMatch >> MatchExpr <$> expr <*> expr <*> matchClauses

matchAllLambdaExpr :: Parser EgisonExpr
matchAllLambdaExpr = keywordMatchAllLambda >> MatchAllLambdaExpr <$> expr <*> matchClause

matchLambdaExpr :: Parser EgisonExpr
matchLambdaExpr = keywordMatchLambda >> MatchLambdaExpr <$> expr <*> matchClauses

nextMatchAllExpr :: Parser EgisonExpr
nextMatchAllExpr = keywordNextMatchAll >> NextMatchAllExpr <$> expr <*> expr <*> matchClause

nextMatchExpr :: Parser EgisonExpr
nextMatchExpr = keywordNextMatch >> NextMatchExpr <$> expr <*> expr <*> matchClauses

nextMatchAllLambdaExpr :: Parser EgisonExpr
nextMatchAllLambdaExpr = keywordNextMatchAllLambda >> NextMatchAllLambdaExpr <$> expr <*> matchClause

nextMatchLambdaExpr :: Parser EgisonExpr
nextMatchLambdaExpr = keywordNextMatchLambda >> NextMatchLambdaExpr <$> expr <*> matchClauses

matchClauses :: Parser [MatchClause]
matchClauses = braces $ sepEndBy matchClause whiteSpace

matchClause :: Parser MatchClause
matchClause = brackets $ (,) <$> pattern <*> expr

matcherExpr :: Parser EgisonExpr
matcherExpr = keywordMatcher >> MatcherBFSExpr <$> ppMatchClauses

matcherBFSExpr :: Parser EgisonExpr
matcherBFSExpr = keywordMatcherBFS >> MatcherBFSExpr <$> ppMatchClauses

matcherDFSExpr :: Parser EgisonExpr
matcherDFSExpr = keywordMatcherDFS >> MatcherDFSExpr <$> ppMatchClauses

ppMatchClauses :: Parser MatcherInfo
ppMatchClauses = braces $ sepEndBy ppMatchClause whiteSpace

ppMatchClause :: Parser (PrimitivePatPattern, EgisonExpr, [(PrimitiveDataPattern, EgisonExpr)])
ppMatchClause = brackets $ (,,) <$> pppattern <*> expr <*> pdMatchClauses

pdMatchClauses :: Parser [(PrimitiveDataPattern, EgisonExpr)]
pdMatchClauses = braces $ sepEndBy pdMatchClause whiteSpace

pdMatchClause :: Parser (PrimitiveDataPattern, EgisonExpr)
pdMatchClause = brackets $ (,) <$> pdPattern <*> expr

pppattern :: Parser PrimitivePatPattern
pppattern = ppWildCard
                 <|> pppatVar
                 <|> ppValuePat
                 <|> ppInductivePat
                 <?> "primitive-pattren-pattern"
                       
ppWildCard :: Parser PrimitivePatPattern
ppWildCard = reservedOp "_" *> pure PPWildCard

pppatVar :: Parser PrimitivePatPattern
pppatVar = reservedOp "$" *> pure PPPatVar

ppValuePat :: Parser PrimitivePatPattern
ppValuePat = string ",$" >> PPValuePat <$> ident

ppInductivePat :: Parser PrimitivePatPattern
ppInductivePat = angles (PPInductivePat <$> lowerName <*> sepEndBy pppattern whiteSpace)

pdPattern :: Parser PrimitiveDataPattern
pdPattern = reservedOp "_" *> pure PDWildCard
                    <|> (char '$' >> PDPatVar <$> ident)
                    <|> braces ((PDConsPat <$> pdPattern <*> (char '@' *> pdPattern))
                            <|> (PDSnocPat <$> (char '@' *> pdPattern) <*> pdPattern) 
                            <|> pure PDEmptyPat)
                    <|> angles (PDInductivePat <$> upperName <*> sepEndBy pdPattern whiteSpace)
                    <|> PDConstantPat <$> constantExpr
                    <?> "primitive-data-pattern"

ifExpr :: Parser EgisonExpr
ifExpr = keywordIf >> IfExpr <$> expr <*> expr <*> expr

lambdaExpr :: Parser EgisonExpr
lambdaExpr = keywordLambda >> LambdaExpr <$> varNames <*> expr

memoizedLambdaExpr :: Parser EgisonExpr
memoizedLambdaExpr = keywordMemoizedLambda >> MemoizedLambdaExpr <$> varNames <*> expr

memoizeExpr :: Parser EgisonExpr
memoizeExpr = keywordMemoize >> MemoizeExpr <$> expr

patternFunctionExpr :: Parser EgisonExpr
patternFunctionExpr = keywordPatternFunction >> PatternFunctionExpr <$> varNames <*> pattern

letRecExpr :: Parser EgisonExpr
letRecExpr =  keywordLetRec >> LetRecExpr <$> bindings <*> expr

letExpr :: Parser EgisonExpr
letExpr = keywordLet >> LetExpr <$> bindings <*> expr

doExpr :: Parser EgisonExpr
doExpr = keywordDo >> DoExpr <$> statements <*> option (ApplyExpr (VarExpr "return") (TupleExpr [])) expr

statements :: Parser [BindingExpr]
statements = braces $ sepEndBy statement whiteSpace

statement :: Parser BindingExpr
statement = try binding <|> brackets (([],) <$> expr)

bindings :: Parser [BindingExpr]
bindings = braces $ sepEndBy binding whiteSpace

binding :: Parser BindingExpr
binding = brackets $ (,) <$> varNames <*> expr

varNames :: Parser [String]
varNames = return <$> varName
            <|> brackets (sepEndBy varName whiteSpace) 

varName :: Parser String
varName = char '$' >> ident

ioExpr :: Parser EgisonExpr
ioExpr = keywordIo >> IoExpr <$> expr

seqExpr :: Parser EgisonExpr
seqExpr = keywordSeq >> SeqExpr <$> expr <*> expr

applyExpr :: Parser EgisonExpr
applyExpr = (keywordApply >> ApplyExpr <$> expr <*> expr) 
             <|> applyExpr'

applyExpr' :: Parser EgisonExpr
applyExpr' = do
  func <- expr
  args <- args
  let vars = lefts args
  case vars of
    [] -> return . ApplyExpr func . TupleExpr $ rights args
    _ | all null vars ->
        let genVar = modify (1+) >> gets (VarExpr . ('#':) . show)
            args' = evalState (mapM (either (const genVar) return) args) 0
        in return . LambdaExpr (annonVars $ length vars) . ApplyExpr func $ TupleExpr args'
      | all (not . null) vars ->
        let ns = Set.fromList $ map read vars
            n = Set.size ns
        in if Set.findMin ns == 1 && Set.findMax ns == n
             then
               let args' = map (either (VarExpr . ('#':)) id) args
               in return . LambdaExpr (annonVars n) . ApplyExpr func $ TupleExpr args'
             else fail "invalid partial application"
      | otherwise -> fail "invalid partial application"
 where
  args = sepEndBy arg whiteSpace
  arg = try (Right <$> expr)
         <|> char '$' *> (Left <$> option "" index)
  index = (:) <$> satisfy (\c -> '1' <= c && c <= '9') <*> many digit
  annonVars n = take n $ map (('#':) . show) [1..]

algebraicDataMatcherExpr :: Parser EgisonExpr
algebraicDataMatcherExpr = keywordAlgebraicDataMatcher
                                >> braces (AlgebraicDataMatcherExpr <$> sepEndBy1 inductivePat' whiteSpace)
  where
    inductivePat' :: Parser (String, [EgisonExpr]) 
    inductivePat' = angles $ (,) <$> lowerName <*> sepEndBy expr whiteSpace

generateArrayExpr :: Parser EgisonExpr
generateArrayExpr = keywordGenerateArray >> GenerateArrayExpr <$> varNames <*> expr <*> expr

arraySizeExpr :: Parser EgisonExpr
arraySizeExpr = keywordArrayBounds >> ArrayBoundsExpr <$> expr

arrayRefExpr :: Parser EgisonExpr
arrayRefExpr = keywordArrayRef >> ArrayRefExpr <$> expr <*> expr

-- Patterns

pattern :: Parser EgisonPattern
pattern = do pattern <- pattern'
             option pattern $ IndexedPat pattern <$> many1 (try $ char '_' >> expr')

pattern' :: Parser EgisonPattern
pattern' = wildCard
            <|> patVar
            <|> varPat
            <|> valuePat
            <|> predPat
            <|> notPat
            <|> tuplePat
            <|> inductivePat
            <|> contPat
            <|> parens (andPat
                    <|> orPat
                    <|> applyPat
                    <|> loopPat
                    <|> letPat)

wildCard :: Parser EgisonPattern
wildCard = reservedOp "_" >> pure WildCard

patVar :: Parser EgisonPattern
patVar = P.lexeme lexer $ PatVar <$> varName

varPat :: Parser EgisonPattern
varPat = VarPat <$> ident

valuePat :: Parser EgisonPattern
valuePat = reservedOp "," >> ValuePat <$> expr

predPat :: Parser EgisonPattern
predPat = reservedOp "?" >> PredPat <$> expr

letPat :: Parser EgisonPattern
letPat = keywordLet >> LetPat <$> bindings <*> pattern

notPat :: Parser EgisonPattern
notPat = reservedOp "^" >> NotPat <$> pattern

tuplePat :: Parser EgisonPattern
tuplePat = brackets $ TuplePat <$> sepEndBy pattern whiteSpace

inductivePat :: Parser EgisonPattern
inductivePat = angles $ InductivePat <$> lowerName <*> sepEndBy pattern whiteSpace

contPat :: Parser EgisonPattern
contPat = reservedOp "..." >> pure ContPat

andPat :: Parser EgisonPattern
andPat = reservedOp "&" >> AndPat <$> sepEndBy pattern whiteSpace

orPat :: Parser EgisonPattern
orPat = reservedOp "|" >> OrPat <$> sepEndBy pattern whiteSpace

applyPat :: Parser EgisonPattern
applyPat = ApplyPat <$> expr <*> sepEndBy pattern whiteSpace 

loopPat :: Parser EgisonPattern
loopPat = keywordLoop >> LoopPat <$> varName <*> loopRange <*> pattern <*> option (NotPat WildCard) pattern

loopRange :: Parser LoopRange
loopRange = brackets (try (do s <- expr
                              e <- expr
                              ep <- option WildCard pattern
                              return (LoopRange s e ep))
                 <|> (do s <- expr
                         ep <- option WildCard pattern
                         return (LoopRange s (ApplyExpr (VarExpr "from") (ApplyExpr (VarExpr "-") (TupleExpr [s, (IntegerExpr 1)]))) ep)))

-- Constants

constantExpr :: Parser EgisonExpr
constantExpr =  charExpr
                 <|> stringExpr
                 <|> boolExpr
                 <|> try floatExpr
                 <|> try rationalExpr
                 <|> integerExpr
                 <|> (keywordSomething *> pure SomethingExpr)
                 <|> (keywordUndefined *> pure UndefinedExpr)
                 <?> "constant"

charExpr :: Parser EgisonExpr
charExpr = CharExpr <$> charLiteral

stringExpr :: Parser EgisonExpr
stringExpr = StringExpr . T.pack <$> stringLiteral

boolExpr :: Parser EgisonExpr
boolExpr = BoolExpr <$> boolLiteral

floatExpr :: Parser EgisonExpr
floatExpr = FloatExpr <$> floatLiteral

rationalExpr :: Parser EgisonExpr
rationalExpr = do
  m <- integerLiteral
  char '/'
  n <- naturalLiteral
  return $ RationalExpr (m % n)

integerExpr :: Parser EgisonExpr
integerExpr = IntegerExpr <$> integerLiteral

--
-- Tokens
--

egisonDef :: P.GenLanguageDef String () Identity
egisonDef = 
  P.LanguageDef { P.commentStart       = "#|"
                , P.commentEnd         = "|#"
                , P.commentLine        = ";"
                , P.identStart         = letter <|> symbol1
                , P.identLetter        = letter <|> digit <|> symbol2
                , P.opStart            = symbol1
                , P.opLetter           = symbol1
                , P.reservedNames      = reservedKeywords
                , P.reservedOpNames    = reservedOperators
                , P.nestedComments     = True
                , P.caseSensitive      = True }
 where
  symbol1 = oneOf "+-*/="
  symbol2 = symbol1 <|> oneOf "'!?."

lexer :: P.GenTokenParser String () Identity
lexer = P.makeTokenParser egisonDef

reservedKeywords :: [String]
reservedKeywords = 
  [ "define"
  , "test"
  , "execute"
  , "load-file"
  , "load"
  , "if"
  , "seq"
  , "apply"
  , "lambda"
  , "memoized-lambda"
  , "memoize"
  , "pattern-function"
  , "letrec"
  , "let"
  , "loop"
  , "match-all"
  , "match"
  , "match-all-lambda"
  , "match-lambda"
  , "matcher"
  , "matcher-bfs"
  , "matcher-dfs"
  , "do"
  , "io"
  , "algebraic-data-matcher"
  , "generate-array"
  , "array-bounds"
  , "array-ref"
  , "something"
  , "undefined"]
  
reservedOperators :: [String]
reservedOperators = 
  [ "$"
  , "_"
  , "&"
  , "|"
  , "^"
  , ","
  , "."
  , "@"
  , "..."]

reserved :: String -> Parser ()
reserved = P.reserved lexer

reservedOp :: String -> Parser ()
reservedOp = P.reservedOp lexer

keywordDefine               = reserved "define"
keywordTest                 = reserved "test"
keywordExecute              = reserved "execute"
keywordLoadFile             = reserved "load-file"
keywordLoad                 = reserved "load"
keywordIf                   = reserved "if"
keywordThen                 = reserved "then"
keywordElse                 = reserved "else"
keywordSeq                  = reserved "seq"
keywordApply                = reserved "apply"
keywordLambda               = reserved "lambda"
keywordMemoizedLambda       = reserved "memoized-lambda"
keywordMemoize             = reserved "memoize"
keywordPatternFunction      = reserved "pattern-function"
keywordLetRec               = reserved "letrec"
keywordLet                  = reserved "let"
keywordLoop                 = reserved "loop"
keywordMatchAll             = reserved "match-all"
keywordMatchAllLambda       = reserved "match-all-lambda"
keywordMatch                = reserved "match"
keywordMatchLambda          = reserved "match-lambda"
keywordNextMatchAll         = reserved "next-match-all"
keywordNextMatchAllLambda   = reserved "next-match-all-lambda"
keywordNextMatch            = reserved "next-match"
keywordNextMatchLambda      = reserved "next-match-lambda"
keywordMatcher              = reserved "matcher"
keywordMatcherBFS           = reserved "matcher-bfs"
keywordMatcherDFS           = reserved "matcher-dfs"
keywordDo                   = reserved "do"
keywordIo                   = reserved "io"
keywordSomething            = reserved "something"
keywordUndefined            = reserved "undefined"
keywordAlgebraicDataMatcher = reserved "algebraic-data-matcher"
keywordGenerateArray        = reserved "generate-array"
keywordArrayBounds          = reserved "array-bounds"
keywordArrayRef             = reserved "array-ref"

sign :: Num a => Parser (a -> a)
sign = (char '-' >> return negate)
   <|> (char '+' >> return id)
   <|> return id

naturalLiteral :: Parser Integer
naturalLiteral = P.natural lexer

integerLiteral :: Parser Integer
integerLiteral = sign <*> P.natural lexer

floatLiteral :: Parser Double
floatLiteral = sign <*> P.float lexer

stringLiteral :: Parser String
stringLiteral = P.stringLiteral lexer

charLiteral :: Parser Char
charLiteral = P.charLiteral lexer

boolLiteral :: Parser Bool
boolLiteral = P.lexeme lexer $ char '#' >> (char 't' *> pure True <|> char 'f' *> pure False)

whiteSpace :: Parser ()
whiteSpace = P.whiteSpace lexer

parens :: Parser a -> Parser a
parens = P.parens lexer

brackets :: Parser a -> Parser a
brackets = P.brackets lexer

braces :: Parser a -> Parser a
braces = P.braces lexer

angles :: Parser a -> Parser a
angles = P.angles lexer

colon :: Parser String
colon = P.colon lexer

comma :: Parser String
comma = P.comma lexer

dot :: Parser String
dot = P.dot lexer

ident :: Parser String
ident = P.identifier lexer
    <|> try ((:) <$> char '+' <*> ident)
    <|> try ((:) <$> char '-' <*> ident)
    <|> (P.lexeme lexer $ string "+")
    <|> (P.lexeme lexer $ string "-")

upperName :: Parser String
upperName = P.lexeme lexer $ (:) <$> upper <*> option "" ident
 where
  upper :: Parser Char 
  upper = satisfy isUpper

lowerName :: Parser String
lowerName = P.lexeme lexer $ (:) <$> lower <*> option "" ident
 where
  lower :: Parser Char 
  lower = satisfy isLower
