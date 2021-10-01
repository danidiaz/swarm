-----------------------------------------------------------------------------
-----------------------------------------------------------------------------
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeSynonymInstances #-}

-- |
-- Module      :  Swarm.Language.Parse
-- Copyright   :  Brent Yorgey
-- Maintainer  :  byorgey@gmail.com
--
-- SPDX-License-Identifier: BSD-3-Clause
--
-- Parser for the Swarm language.  Note, you probably don't want to
-- use this directly, unless there is a good reason to parse a term
-- without also type checking it; use
-- 'Swarm.Language.Pipeline.processTerm' instead, which parses,
-- typechecks, elaborates, and capability checks a term all at once.
module Swarm.Language.Parse (
  -- * Parsers
  Parser,
  parsePolytype,
  parseType,
  parseTerm,

  -- * Utility functions
  runParser,
  runParserTH,
  readTerm,
) where

import Control.Monad.Reader
import Data.Bifunctor
import Data.Char
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Void
import Witch

import Control.Monad.Combinators.Expr
import Text.Megaparsec hiding (runParser)
import Text.Megaparsec.Char
import qualified Text.Megaparsec.Char.Lexer as L

import Swarm.Language.Syntax
import Swarm.Language.Types

-- | When parsing a term using a quasiquoter (i.e. something in the
--   Swarm source code that will be parsed at compile time), we want
--   to allow antiquoting, i.e. writing something like $x to refer to
--   an existing Haskell variable.  But when parsing a term entered by
--   the user at the REPL, we do not want to allow this syntax.
data Antiquoting = AllowAntiquoting | DisallowAntiquoting
  deriving (Eq, Ord, Show)

type Parser = ReaderT Antiquoting (Parsec Void Text)

--------------------------------------------------
-- Lexer

-- | List of reserved words that cannot be used as variable names.
reservedWords :: [String]
reservedWords =
  [ "left"
  , "right"
  , "back"
  , "forward"
  , "north"
  , "south"
  , "east"
  , "west"
  , "down"
  , "wait"
  , "selfdestruct"
  , "move"
  , "turn"
  , "grab"
  , "place"
  , "give"
  , "make"
  , "build"
  , "run"
  , "getx"
  , "gety"
  , "scan"
  , "upload"
  , "blocked"
  , "random"
  , "say"
  , "view"
  , "appear"
  , "create"
  , "ishere"
  , "int"
  , "string"
  , "dir"
  , "bool"
  , "cmd"
  , "let"
  , "def"
  , "end"
  , "in"
  , "if"
  , "true"
  , "false"
  , "not"
  , "fst"
  , "snd"
  , "forall"
  , "try"
  , "raise"
  ]

-- | Skip spaces and comments.
sc :: Parser ()
sc =
  L.space
    space1
    (L.skipLineComment "//")
    (L.skipBlockComment "/*" "*/")

-- | In general, we follow the convention that every token parser
--   assumes no leading whitespace and consumes all trailing
--   whitespace.  Concretely, we achieve this by wrapping every token
--   parser using 'lexeme'.
lexeme :: Parser a -> Parser a
lexeme = L.lexeme sc

-- | A lexeme consisting of a literal string.
symbol :: Text -> Parser Text
symbol = L.symbol sc

-- | Parse a case-insensitive reserved word, making sure it is not a
--   prefix of a longer variable name, and allowing the parser to
--   backtrack if it fails.
reserved :: Text -> Parser ()
reserved w = (lexeme . try) $ string' w *> notFollowedBy (alphaNumChar <|> char '_')

-- | Parse an identifier, i.e. any non-reserved string containing
--   alphanumeric characters and underscores and not starting with a
--   number.
identifier :: Parser Text
identifier = (lexeme . try) (p >>= check) <?> "variable name"
 where
  p = (:) <$> (letterChar <|> char '_') <*> many (alphaNumChar <|> char '_')
  check x
    | map toLower x `elem` reservedWords =
      fail $ "reserved word " ++ x ++ " cannot be used as variable name"
    | otherwise = return (into @Text x)

-- | Parse a string literal (including escape sequences) in double quotes.
stringLiteral :: Parser Text
stringLiteral = into <$> lexeme (char '"' >> manyTill L.charLiteral (char '"'))

-- | Parse a positive integer literal token.  Note that negation is
--   handled as a separate operator.
integer :: Parser Integer
integer = lexeme L.decimal

braces :: Parser a -> Parser a
braces = between (symbol "{") (symbol "}")

parens :: Parser a -> Parser a
parens = between (symbol "(") (symbol ")")

--------------------------------------------------
-- Parser

-- | Parse a Swarm language polytype, which starts with an optional
--   quanitifation (@forall@ followed by one or more variables and a
--   period) followed by a type.  Note that anything accepted by
--   'parseType' is also accepted by 'parsePolytype'.
parsePolytype :: Parser Polytype
parsePolytype =
  Forall
    <$> (fromMaybe [] <$> optional (reserved "forall" *> some identifier <* symbol "."))
    <*> parseType

-- | Parse a Swarm language (mono)type.
parseType :: Parser Type
parseType = makeExprParser parseTypeAtom table
 where
  table =
    [ [InfixR ((:*:) <$ symbol "*")]
    , [InfixR ((:->:) <$ symbol "->")]
    ]

parseTypeAtom :: Parser Type
parseTypeAtom =
  TyUnit <$ symbol "()"
    <|> TyVar <$> identifier
    <|> TyInt <$ reserved "int"
    <|> TyString <$ reserved "string"
    <|> TyDir <$ reserved "dir"
    <|> TyBool <$ reserved "bool"
    <|> TyCmd <$> (reserved "cmd" *> parseTypeAtom)
    <|> parens parseType

parseDirection :: Parser Direction
parseDirection =
  Lft <$ reserved "left"
    <|> Rgt <$ reserved "right"
    <|> Back <$ reserved "back"
    <|> Fwd <$ reserved "forward"
    <|> North <$ reserved "north"
    <|> South <$ reserved "south"
    <|> East <$ reserved "east"
    <|> West <$ reserved "west"
    <|> Down <$ reserved "down"

-- XXX I wish there was a better way to do this that would warn us to
-- add a new case to the parser whenever we add a new constructor to
-- 'Const'.
parseConst :: Parser Const
parseConst =
  Wait <$ reserved "wait"
    <|> Selfdestruct <$ reserved "selfdestruct"
    <|> Return <$ reserved "return"
    <|> Move <$ reserved "move"
    <|> Turn <$ reserved "turn"
    <|> Grab <$ reserved "grab"
    <|> Place <$ reserved "place"
    <|> Give <$ reserved "give"
    <|> Install <$ reserved "install"
    <|> Make <$ reserved "make"
    <|> Build <$ reserved "build"
    <|> Run <$ reserved "run"
    <|> GetX <$ reserved "getx"
    <|> GetY <$ reserved "gety"
    <|> Blocked <$ reserved "blocked"
    <|> Scan <$ reserved "scan"
    <|> Upload <$ reserved "upload"
    <|> Random <$ reserved "random"
    <|> Say <$ reserved "say"
    <|> View <$ reserved "view"
    <|> Appear <$ reserved "appear"
    <|> Create <$ reserved "create"
    <|> Ishere <$ reserved "ishere"
    <|> If <$ reserved "if"
    <|> Not <$ reserved "not"
    <|> Fst <$ reserved "fst"
    <|> Snd <$ reserved "snd"
    <|> Try <$ reserved "try"
    <|> Raise <$ reserved "raise"

parseTermAtom :: Parser Term
parseTermAtom =
  TUnit <$ symbol "()"
    <|> TConst <$> parseConst
    <|> TVar <$> identifier
    <|> TDir <$> parseDirection
    <|> TInt <$> integer
    <|> TString <$> stringLiteral
    <|> TBool <$> ((True <$ reserved "true") <|> (False <$ reserved "false"))
    <|> TLam <$> (symbol "\\" *> identifier)
      <*> optional (symbol ":" *> parseType)
      <*> (symbol "." *> parseTerm)
    <|> TLet <$> (reserved "let" *> identifier)
      <*> optional (symbol ":" *> parsePolytype)
      <*> (symbol "=" *> parseTerm)
      <*> (reserved "in" *> parseTerm)
    <|> TDef <$> (reserved "def" *> identifier)
      <*> optional (symbol ":" *> parsePolytype)
      <*> (symbol "=" *> parseTerm <* reserved "end")
    <|> parens parseTerm
    <|> TConst Noop <$ try (symbol "{" *> symbol "}")
    <|> braces parseTerm
    <|> (ask >>= (guard . (== AllowAntiquoting)) >> parseAntiquotation)

parseAntiquotation :: Parser Term
parseAntiquotation =
  TAntiString <$> (lexeme . try) (symbol "$str:" *> identifier)
    <|> TAntiInt <$> (lexeme . try) (symbol "$int:" *> identifier)

-- | Parse a Swarm language term.
parseTerm :: Parser Term
parseTerm = sepEndBy1 parseStmt (symbol ";") >>= mkBindChain

mkBindChain :: [Stmt] -> Parser Term
mkBindChain stmts = case last stmts of
  Binder _ _ -> fail "Last command in a chain must not have a binder"
  BareTerm t -> return $ foldr mkBind t (init stmts)
 where
  mkBind (BareTerm t1) t2 = TBind Nothing t1 t2
  mkBind (Binder x t1) t2 = TBind (Just x) t1 t2

data Stmt
  = BareTerm Term
  | Binder Text Term
  deriving (Show)

parseStmt :: Parser Stmt
parseStmt =
  mkStmt <$> optional (try (identifier <* symbol "<-")) <*> parseExpr

mkStmt :: Maybe Text -> Term -> Stmt
mkStmt Nothing = BareTerm
mkStmt (Just x) = Binder x

-- | When semicolons are missing between definitions, for example:
--     def a = 1 end def b = 2 end def c = 3 end
--   The makeExprParser produces:
--     App (App (TDef a) (TDef b)) (TDef x)
--   This function fix that by converting the Apps into Binds, so that it results in:
--     Bind a (Bind b (Bind c))
fixDefMissingSemis :: Term -> Term
fixDefMissingSemis term =
  case nestedDefs term [] of
    [] -> term
    defs -> foldr1 (TBind Nothing) defs
 where
  nestedDefs term' acc = case term' of
    def@TDef {} -> def : acc
    TApp nestedTerm def@TDef {} -> nestedDefs nestedTerm (def : acc)
    -- Otherwise returns an empty list to keep the term unchanged
    _ -> []

parseExpr :: Parser Term
parseExpr = fixDefMissingSemis <$> makeExprParser parseTermAtom table
 where
  table =
    [ [InfixL (TApp <$ string "")]
    , [InfixR (mkOp (Arith Exp) <$ symbol "^")]
    , [Prefix (TApp (TConst Neg) <$ symbol "-")]
    ,
      [ InfixL (mkOp (Arith Mul) <$ symbol "*")
      , InfixL (mkOp (Arith Div) <$ symbol "/")
      ]
    ,
      [ InfixL (mkOp (Arith Add) <$ symbol "+")
      , InfixL (mkOp (Arith Sub) <$ symbol "-")
      ]
    , map
        (\(s, op) -> InfixN (mkOp (Cmp op) <$ symbol s))
        [ ("==", CmpEq)
        , ("/=", CmpNeq)
        , ("<=", CmpLeq)
        , (">=", CmpGeq)
        , ("<", CmpLt)
        , (">", CmpGt)
        ]
    , [InfixR (TPair <$ symbol ",")]
    ]

mkOp :: Const -> Term -> Term -> Term
mkOp c = TApp . TApp (TConst c)

--------------------------------------------------
-- Utilities

-- | Run a parser on some input text, returning either the result or a
--   pretty-printed parse error message.
runParser :: Parser a -> Text -> Either Text a
runParser p t = first (from . errorBundlePretty) (parse (runReaderT p DisallowAntiquoting) "" t)

-- | A utility for running a parser in an arbitrary 'MonadFail' (which
--   is going to be the TemplateHaskell 'Q' monad --- see
--   "Swarm.Language.Parse.QQ"), with a specified source position.
runParserTH :: (Monad m, MonadFail m) => (String, Int, Int) -> Parser a -> String -> m a
runParserTH (file, line, col) p s =
  case snd (runParser' (runReaderT (fully p) AllowAntiquoting) initState) of
    Left err -> fail $ errorBundlePretty err
    Right e -> return e
 where
  -- This is annoying --- megaparsec does not export its function to
  -- construct an initial parser state, so we can't just use that
  -- and then change the one field we need to be different (the
  -- pstateSourcePos). We have to copy-paste the whole thing.
  initState :: State Text Void
  initState =
    State
      { stateInput = from s
      , stateOffset = 0
      , statePosState =
          PosState
            { pstateInput = from s
            , pstateOffset = 0
            , pstateSourcePos = SourcePos file (mkPos line) (mkPos col)
            , pstateTabWidth = defaultTabWidth
            , pstateLinePrefix = ""
            }
      , stateParseErrors = []
      }

-- | Run a parser "fully", consuming leading whitespace and ensuring
--   that the parser extends all the way to eof.
fully :: Parser a -> Parser a
fully p = sc *> p <* eof

-- | Parse some input 'Text' completely as a 'Term', consuming leading
--   whitespace and ensuring the parsing extends all the way to the
--   end of the input 'Text'.  Returns either the resulting 'Term' or
--   a pretty-printed parse error message.
readTerm :: Text -> Either Text Term
readTerm = runParser (fully parseTerm)
