module Malfunction.Print where

import Malfunction.AST
import Text.Printf
-- Bafflingly there is no type-class for pretty-printable-stuff
-- in `Text.Printf` -- so we'll use the definition in agda.
import Agda.Utils.Pretty

instance Pretty Mod where
  pretty = text . showMod

showMod :: Mod -> String
showMod (MMod bs ts) = printf "(module %s (export %s))"
  (unwords . map showBinding $ bs)
  (unwords . map showTerm $ ts)

instance Pretty Term where
  pretty = text . showTerm

showTerm :: Term -> String
showTerm tt = case tt of
  Mvar i              -> showIdent i
  Mlambda is t        -> printf "(lambda (%s) %s)" (unwords (map showIdent is)) (showTerm t)
  Mapply t ts         -> printf "(apply %s %s)" (showTerm t) (unwords . map showTerm $ ts)
  Mlet bs t           -> printf "(let %s %s)" (unwords (map showBinding bs)) (showTerm t)
  Mint ic             -> printf "%s" (showIntConst ic)
  Mstring s           -> printf "%s" (show s)
  Mglobal li          -> printf "(global %s)" (showLongident li)
  Mswitch t cexps     -> printf "(switch %s %s)" (showTerm t) (unwords (map showCaseExpression cexps))
 -- Integers
  Mintop1 op tp t0    -> printf "(%s %s)" (showUnaryIntOp op) (showTypedTerm tp t0)
  Mintop2 op tp t0 t1 -> printf "(%s %s %s)" (showBinaryIntOp op) (showTypedTerm tp t0) (showTypedTerm tp t1)
  Mconvert tp0 tp1 t0 -> printf "(convert.%s.%s %s)" (showIntType tp0) (showIntType tp1) (showTerm t0)
  -- Vectors
  Mvecnew tp t0 t1    -> printf "(makevec %s %s)"  (showTerm t0) (showTerm t1)
  Mvecget tp t0 t1    -> printf "(load %s %s)"     (showTerm t0) (showTerm t1)
  Mvecset tp t0 t1 t2 -> printf "(store %s %s %s)" (showTerm t0) (showTerm t1) (showTerm t2)
  Mveclen tp t0       -> printf "(length %s)"      (showTerm t0)
  -- Blocks
  Mblock i ts         -> printf "(block (tag %s) %s)" (show i) (unwords (map showTerm ts))
  Mfield i t0         -> printf "(field %s %s)" (show i) (showTerm t0)

instance Pretty Binding where
  pretty = text . showBinding

showBinding :: Binding -> String
showBinding b = case b of
  Unnamed t    -> printf "(_ %s)" (showTerm t)
  Named i t    -> printf "(%s %s)" (showIdent i) (showTerm t)
  Recursive bs -> printf "(rec %s)" (unwords (map showIdentTerm bs))
  where
    showIdentTerm :: (Ident, Term) -> String
    showIdentTerm (i, t) = printf "(%s %s)" (showIdent i) (showTerm t)

instance Pretty IntConst where
  pretty = text . showIntConst

showIntConst :: IntConst -> String
showIntConst ic = case ic of
  CInt    i -> show i
  CInt32  i -> show i
  CInt64  i -> show i
  CBigint i -> show i

-- Problematic:
-- instance Pretty Longident where
--   pretty = text . showLongident

showLongident :: Longident -> String
showLongident = unwords . map showIdent

-- Ditto problematic:
-- instance Pretty Ident where
--   pretty = text . showIdent

showIdent :: Ident -> String
showIdent = ('$':)

-- Ditto problematic:
-- instance Pretty ([Case], Term) where
--   pretty = text . showCaseExpression

showCaseExpression :: ([Case], Term) -> String
showCaseExpression (cs, t) = printf "(%s %s)" (unwords (map showCase cs)) (showTerm t)

instance Pretty Case where
  pretty = text . showCase

-- I don't think it's possible to create `_` and `n` as mentioned in the spec
-- using the AST define in the original implementation of malfunction.
showCase :: Case -> String
showCase c = case c of
  Deftag          -> "(tag _)"
  Tag n           -> printf "(tag %s)" (show n)
  CaseAnyInt      -> "_"
  CaseInt n       -> show n
  Intrange (i, j) -> printf "(%s %s)" (show i) (show j)

instance Pretty UnaryIntOp where
  pretty = text . showUnaryIntOp

showUnaryIntOp :: UnaryIntOp -> String
showUnaryIntOp op = case op of
  Neg -> "?"
  Not -> "?"

instance Pretty BinaryIntOp where
  pretty = text . showBinaryIntOp

showBinaryIntOp :: BinaryIntOp -> String
showBinaryIntOp op = case op of
  Add -> "+"
  Sub -> "-"
  Mul -> "*"
  Div -> "/"
  Mo  -> "%"
  And -> "&"
  Or  -> "|"
  Xor -> "^"
  Lsl -> "<<"
  Lsr -> ">>"
  Asr  -> "a>>"
  Lt  -> "<"
  Gt  -> ">"
  Lte -> "<="
  Gte -> ">="
  Eq  -> "=="

-- Problematic:

showTypedTerm :: IntType -> Term -> String
showTypedTerm tp t = case tp of
  TInt -> showTerm t
  _    -> printf "%s.%s" (showTerm t) (showIntType tp)

instance Pretty IntType where
  pretty = text . showIntType

showIntType :: IntType -> String
showIntType tp = case tp of
  TInt    -> "int"
  TInt32  -> "int32"
  TInt64  -> "int64"
  TBigint -> "bigint"
