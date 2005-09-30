{-# OPTIONS -cpp #-}

{-| This module contains the building blocks used to construct the lexer.
-}
module Syntax.Parser.LexActions
    ( -- * Main function
      lexToken
      -- * Lex actions
      -- ** General actions
    , token
    , withRange, withRange', withRange_
    , withLayout
    , begin, end, endWith
    , begin_, end_
      -- ** Specialized actions
    , keyword, symbol, identifier, operator, literal
      -- * Lex predicates
    , notFollowedBy, notEOF
    ) where

import Data.List (isPrefixOf)

#ifndef __HADDOCK__
import {-# SOURCE #-} Syntax.Parser.Lexer
#endif

import Syntax.Parser.Alex
import Syntax.Parser.Monad
import Syntax.Parser.Tokens
import Syntax.Position
import Syntax.Common

import Utils.List
import Utils.Tuple
import Utils.Unicode

{--------------------------------------------------------------------------
    Scan functions
 --------------------------------------------------------------------------}

-- | Called at the end of a file. Returns 'TokEOF'.
returnEOF :: AlexInput -> Parser Token
returnEOF inp =
    do  setLastPos $ lexPos inp
	setPrevToken "<EOF>"
	return TokEOF

-- | Set the current input and lex a new token (calls 'lexToken').
skipTo :: AlexInput -> Parser Token
skipTo inp = setLexInput inp >> lexToken

{-| Scan the input to find the next token. Calls
    'Syntax.Parser.Lexer.alexScan'.  This is the main lexing function where all
    the work happens.  The function 'Syntax.Parser.Lexer.lexer', used by the
    parser is the continuation version of this function.
-}
lexToken :: Parser Token
lexToken =
    do	inp <- getLexInput
	ls:_ <- getLexState
	case alexScan (foolAlex inp) ls of
	    AlexEOF			-> returnEOF inp
	    AlexError _			-> parseError "Lexical error"
	    AlexSkip inp' len		-> skipTo (newInput inp inp' len)
	    AlexToken inp' len action	-> action inp (newInput inp inp' len) len
		
-- | Use the input string from the previous input (with the appropriate
--   number of characters dropped) instead of the fake input string that
--   was given to Alex (with unicode characters removed).
newInput :: PreviousInput -> CurrentInput -> TokenLength -> CurrentInput
newInput inp inp' len =
    case drop (len - 1) (lexInput inp) of
	c:s'	-> inp' { lexInput    = s'
			, lexPrevChar = c
			}

-- | Alex can't handle unicode characters. To solve this we translate all
--   unicode identifiers to @z@ and all unicode operator characters to @+@.
--   It is important that there aren't any keywords containing @z@ or @+@.
foolAlex :: AlexInput -> AlexInput
foolAlex inp = inp { lexInput = map fool $ lexInput inp }
    where
	fool c
	    | isUnicodeId c = 'z'
	    | isUnicodeOp c = '+'
	    | otherwise	    = c

{--------------------------------------------------------------------------
    Lex actions
 --------------------------------------------------------------------------}

-- | The most general way of parsing a token.
token :: (String -> Parser tok) -> LexAction tok
token action inp inp' len =
    do  setLexInput inp'
	setPrevToken t
	setLastPos $ lexPos inp
	action t
    where
	t = take len $ lexInput inp

-- | Parse a token from a 'Range' and the lexed string.
withRange :: ((Range,String) -> tok) -> LexAction tok
withRange f = token $ \s ->
		do  r <- getParseRange
		    return $ f (r,s)

-- | Like 'withRange', but applies a function to the string.
withRange' :: (String -> a) -> ((Range,a) -> tok) -> LexAction tok
withRange' f t = withRange (t . (id -*- f))

-- | Return a token without looking at the lexed string.
withRange_ :: (Range -> r) -> LexAction r
withRange_ f = withRange (f . fst)


-- | Executed for layout keywords. Enters the 'Syntax.Parser.Lexer.layout'
--   state and performs the given action.
withLayout :: LexAction r -> LexAction r
withLayout a i1 i2 n =
    do	pushLexState layout
	a i1 i2 n


-- | Enter a new state without consuming any input.
begin :: LexState -> LexAction Token
begin code _ _ _ =
    do	pushLexState code
	lexToken


-- | Enter a new state throwing away the current lexeme.
begin_ :: LexState -> LexAction Token
begin_ code _ inp' _ =
    do	pushLexState code
	skipTo inp'


-- | Exit the current state throwing away the current lexeme.
end_ :: LexAction Token
end_ _ inp' _ =
    do	popLexState
	skipTo inp'


-- | Exit the current state and perform the given action.
endWith :: LexAction a -> LexAction a
endWith a inp inp' n =
    do	popLexState
	a inp inp' n


-- | Exit the current state without consuming any input
end :: LexAction Token
end _ _ _ =
    do	popLexState
	lexToken

-- | Parse a 'Keyword' token, triggers layout for 'layoutKeywords'.
keyword :: Keyword -> LexAction Token
keyword k = layout $ withRange_ (TokKeyword k)
    where
	layout | elem k layoutKeywords	= withLayout
	       | otherwise		= id


-- | Parse a 'Symbol' token.
symbol :: Symbol -> LexAction Token
symbol s = withRange_ (TokSymbol s)


-- | Parse a literal.
literal :: Read a => (Range -> a -> Literal) -> LexAction Token
literal lit = withRange' read (TokLiteral . uncurry lit)

-- | Parse an identifier. Identifiers can be qualified (see 'Name').
--   Example: @Foo.Bar.f@
identifier :: LexAction Token
identifier = qualified (either TokId TokQId)


-- | Parse an operator. Operators can be qualified (see 'Name').
--   Example: @Nat.Operations.+@
operator :: LexAction Token
operator = qualified (either TokOp TokQOp)


-- | Parse a possibly qualified name.
qualified :: (Either Name QName -> a) -> LexAction a
qualified tok =
    withRange $ \ (r,s) ->
	case wordsBy (=='.') s of
	    [x]	-> tok $ Left $ Name r x
	    xs	-> tok $ Right $ QName (init xs) $ Name r (last xs)


{--------------------------------------------------------------------------
    Predicates
 --------------------------------------------------------------------------}

-- | True when the given character is not the next character of the input string.
notFollowedBy :: Char -> LexPredicate
notFollowedBy c' _ _ _ inp =
    case lexInput inp of
	[]  -> True
	c:_ -> c /= c'

-- | True if we are not at the end of the file.
notEOF :: LexPredicate
notEOF _ _ _ inp = not $ null $ lexInput inp

