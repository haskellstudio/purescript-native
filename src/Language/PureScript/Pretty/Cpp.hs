-----------------------------------------------------------------------------
--
-- Module      :  Language.PureScript.Pretty.Cpp
-- Copyright   :  (c) 2013-15 Phil Freeman, Andy Arvanitis, and other contributors
-- License     :  MIT
--
-- Maintainer  :  Andy Arvanitis
-- Stability   :  experimental
-- Portability :
--
-- |
-- Pretty printer for the C++11 AST
--
-----------------------------------------------------------------------------

{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE CPP #-}

module Language.PureScript.Pretty.Cpp (
    dotsTo,
    linebreak,
    prettyPrintCpp,
    stripScope
) where

import Data.Char
import Data.List
import Data.Maybe (fromMaybe)

#if __GLASGOW_HASKELL__ < 710
import Control.Applicative
#endif
import Control.Arrow ((<+>))
import Control.Monad.State
import Control.PatternArrows
import qualified Control.Arrow as A

import Language.PureScript.CodeGen.Cpp.AST
import Language.PureScript.CodeGen.Cpp.Types
import Language.PureScript.Comments
import Language.PureScript.Pretty.Common

import Numeric

-- import Debug.Trace

literals :: Pattern PrinterState Cpp String
literals = mkPattern' match
  where
  match :: Cpp -> StateT PrinterState Maybe String
  match CppNoOp = return []
  match CppEndOfHeader = return []
  match (CppNumericLiteral n) = return $ either show show n
  match (CppStringLiteral s) = return $ string s ++ "s"
  match (CppCharLiteral c) = return $ show c
  match (CppBooleanLiteral True) = return "true"
  match (CppBooleanLiteral False) = return "false"
  match (CppArrayLiteral xs) = fmap concat $ sequence
    [ return "any::vector"
    , return "{ "
    , fmap (intercalate ", ") $ forM xs prettyPrintCpp'
    , return " }"
    ]
  match (CppObjectLiteral []) = return "nullptr"
  match (CppObjectLiteral ps) = fmap concat $ sequence
    [ return $ "any::map{\n"
    , withIndent $ do
        cpps <- forM ps $ \(key, value) -> do
                            val <- prettyPrintCpp' value
                            return $ "{ " ++ show key ++ "s, " ++ val ++ " }"
        indentString <- currentIndent
        return $ intercalate ", \n" $ map (indentString ++) cpps
    , return "\n"
    , currentIndent
    , return "}"
    ]
  match (CppFunction name args rty qs ret) =
    let qs' = delete CppTemplSpec qs in
    fmap concat $ sequence
    [ do
      indentString <- currentIndent
      return $ maybe [] ((++ "\n" ++ indentString) . runQualifier) (find (== CppTemplSpec) qs)
    , return . concatMap (++ " ") . filter (not . null) $ runQualifier <$> qs'
    , return $ if CppConstructor `elem` qs || CppDestructor `elem` qs
                 then []
                 else "auto "
    , return name
    , return $ parens (intercalate ", " $ argstr <$> args)
    , if CppConstructor `elem` qs && (not . null) args
        then let cpps = ": " ++ intercalate ", " (
                                  ("data{" ++ show name ++ "_h}") :
                                  ((\(a, _) -> a ++ parens a) <$> args)
                                ) in
          if length args > 2
            then do
              indentString <- withIndent currentIndent
              return ('\n' : indentString ++ cpps)
            else return (' ' : cpps)
        else return []
    , let rty' | Just r' <- rty, everythingOnTypes (||) (== AutoType) r' = Nothing
               | otherwise = rty
      in return (maybe "" ((" -> " ++) . runType) rty')
    , return $ if CppDefault `elem` qs then " = default" else []
    , return $ if CppDelete `elem` qs then " = delete" else []
    , if ret == CppNoOp
        then return ";"
        else do
          cpps <- prettyPrintCpp' ret
          return $ ' ' : cpps
    ]
  match (CppBlock sts) = fmap concat $ sequence
    [ return "{\n"
    , withIndent $ prettyStatements sts
    , return $ if null sts then "" else "\n"
    , currentIndent
    , return "}"
    ]
  match (CppNamespace _ []) = return []
  match (CppNamespace (':':':':name) sts) = fmap concat $ sequence $
    [ return "\n"
    , currentIndent
    , return $ "namespace " ++ (dotsTo '_' name) ++ " {\n"
    , withIndent $ prettyStatements sts
    , return "\n"
    , currentIndent
    , return "}"
    ]
  match (CppNamespace name sts) = fmap concat $ sequence $
    [ return "\n"
    , currentIndent
    , return $ "namespace " ++ (dotsTo '_' name) ++ " {\n"
    , withIndent $ prettyStatements sts'
    , return "\n"
    , currentIndent
    , return "}"
    ]
    ++ let (cpp', cpps') = fromNested nested' in
       map match cpp'
    ++ if null cpps' then [] else [match (CppNamespace name (filter isUseNamespace sts ++ cpps'))]
    where
    (sts', nested') = break isNestedNamespace sts
    fromNested :: [Cpp] -> ([Cpp], [Cpp])
    fromNested [] = ([],[])
    fromNested cpps@((CppNamespace nm _):_) = ([foldl1 combineNamespaces namespaces], others)
      where
      (namespaces, others) = span inSameNamespace cpps
      inSameNamespace :: Cpp -> Bool
      inSameNamespace (CppNamespace nm' _) | nm' == nm = True
      inSameNamespace _ = False
    fromNested _ = error "Not a nested namespace"
    combineNamespaces :: Cpp -> Cpp -> Cpp
    combineNamespaces (CppNamespace nm ss) (CppNamespace nm' ss')
      | nm == nm' = CppNamespace nm (ss ++ filter (not . isUseNamespace) ss')
    combineNamespaces _ _ = error "Cannot fold cpps"
    isUseNamespace :: Cpp -> Bool
    isUseNamespace (CppUseNamespace{}) = True
    isUseNamespace _ = False

  match (CppSequence []) = return []
  match (CppSequence cpps) = fmap concat $ sequence
    [ return "\n"
    , prettyStatements cpps
    ]
  match (CppInclude path name) =
    let fullpath
          | null path = last . words . dotsTo ' ' $ name
          | otherwise = (dotsTo '/' path) ++ '/' : (last . words . dotsTo ' ' $ name) in
    fmap concat $ sequence
    [ return $ "#include \"" ++ fullpath ++ ".hh\""
    ]
  match (CppUseNamespace name) = fmap concat $ sequence
    [ return $ "using namespace " ++ (dotsTo '_' name) ++ ";"
    ]
  match (CppTypeAlias (newName, newTyps) typ spec) =
    let typ' = runType typ
        (tmps, name') = if null newTyps
                          then ([], typ')
                          else ([return (templDecl newTyps), return "\n", currentIndent], typ')
    in fmap concat $ sequence $
    tmps ++
    [ return $ "using " ++ newName ++ " = " ++ if null spec then name' else spec ++ angles name'
    , return ";"
    ]
  match (CppCast typ val) = return $
    case val of
      CppNumericLiteral {} -> vstr
      CppStringLiteral {}  -> vstr
      CppBooleanLiteral {} -> vstr
      _ -> val' ++ ".cast" ++ angles (runType typ) ++ parens []
    where
    vstr = prettyPrintCpp1 val
    val' | '(' `elem` vstr || '[' `elem` vstr = parens vstr
         | otherwise = vstr

  match (CppVar ident) = return ident
  match (CppApp v [CppNoOp]) = return (prettyPrintCpp1 v)
  match (CppVariableIntroduction (ident, typ) qs value) =
    let qs' = delete CppTemplSpec qs in
    fmap concat $ sequence
    [ do
      indentString <- currentIndent
      return $ maybe [] ((++ "\n" ++ indentString) . runQualifier) (find (== CppTemplSpec) qs)
    , return . concatMap (++ " ") . filter (not . null) $ runQualifier <$> qs'
    , return $ if CppMutable `notElem` qs then "const " else ""
    , return (maybe "any" runType typ ++ " ")
    , return ident
    , maybe (return "") (fmap (" = " ++) . prettyPrintCpp') value
    , return ";"
    ]
  match (CppAssignment target value) = fmap concat $ sequence
    [ prettyPrintCpp' target
    , return " = "
    , prettyPrintCpp' value
    , return ";"
    ]
  match (CppWhile cond sts) = fmap concat $ sequence
    [ return "while ("
    , prettyPrintCpp' cond
    , return ") "
    , prettyPrintCpp' sts
    ]
  match (CppFor ident start end sts) = fmap concat $ sequence
    [ return $ "for (auto " ++ ident ++ " = "
    , prettyPrintCpp' start
    , return $ "; " ++ ident ++ " < "
    , prettyPrintCpp' end
    , return $ "; " ++ ident ++ "++) "
    , prettyPrintCpp' sts
    ]
  match (CppIfElse cond thens elses) = fmap concat $ sequence
    [ return "if ("
    , prettyPrintCpp' cond
    , return ") "
    , prettyPrintCpp' thens
    , maybe (return "") (fmap (" else " ++) . prettyPrintCpp') elses
    ]
  match (CppReturn (CppBlock (cpp:cpps))) = fmap concat $ sequence
    [   do s <- prettyPrintCpp' cpp
           return $ dropWhile isSpace s
      , return $ if null cpps then "" else "\n"
      , prettyStatements cpps
    ]
  match (CppReturn value) = fmap concat $ sequence
    [ return "return "
    , prettyPrintCpp' value
    , return ";"
    ]
  match (CppThrow value) = fmap concat $ sequence
    [ return "throw "
    , prettyPrintCpp' value
    , return ";"
    ]
  match (CppBreak lbl) = return $ "goto " ++ lbl ++ ";"
  match (CppContinue lbl) = return $ "goto " ++ lbl ++ ";"
  match (CppLabel lbl cpp) = fmap concat $ sequence
    [ return $ lbl ++ ": "
    , prettyPrintCpp' cpp
    ]
  match (CppComment [] cpp) = match cpp
  match (CppComment com cpp) = fmap concat $ sequence $
    [ return "\n"
    , currentIndent
    , return "/**\n"
    ] ++
    map asLine (concatMap commentLines com) ++
    [ currentIndent
    , return " */\n"
    , currentIndent
    , prettyPrintCpp' cpp
    ]
    where
    commentLines :: Comment -> [String]
    commentLines (LineComment s) = [s]
    commentLines (BlockComment s) = lines s

    asLine :: String -> StateT PrinterState Maybe String
    asLine s = do
      i <- currentIndent
      return $ i ++ " * " ++ removeComments s ++ "\n"

    removeComments :: String -> String
    removeComments ('*' : '/' : s) = removeComments s
    removeComments (c : s) = c : removeComments s

    removeComments [] = []
  match (CppRaw cpp) = return cpp
  match _ = mzero

string :: String -> String
string s = '"' : concatMap encodeChar s ++ "\""
  where
  encodeChar :: Char -> String
  encodeChar '\b' = "\\b"
  encodeChar '\t' = "\\t"
  encodeChar '\n' = "\\n"
  encodeChar '\v' = "\\v"
  encodeChar '\f' = "\\f"
  encodeChar '\r' = "\\r"
  encodeChar '"'  = "\\\""
  encodeChar '\\' = "\\\\"
  encodeChar c | fromEnum c > 0xFFF = "\\u" ++ showHex (fromEnum c) ""
  encodeChar c | fromEnum c > 0xFF = "\\u0" ++ showHex (fromEnum c) ""
  encodeChar c = [c]

conditional :: Pattern PrinterState Cpp ((Cpp, Cpp), Cpp)
conditional = mkPattern match
  where
  match (CppConditional cond th el) = Just ((th, el), cond)
  match _ = Nothing

accessor :: Pattern PrinterState Cpp (String, Cpp)
accessor = mkPattern match
  where
  match (CppAccessor prop val) = Just (prettyPrintCpp1 prop, val)
  match _ = Nothing

indexer :: Pattern PrinterState Cpp (String, Cpp)
indexer = mkPattern' match
  where
  match (CppIndexer index val) = (,) <$> prettyPrintCpp' index <*> pure val
  match _ = mzero

lam :: Pattern PrinterState Cpp ((String, [(String, Maybe Type)], Maybe Type), Cpp)
lam = mkPattern match
  where
  match (CppLambda caps args rty ret) =
    -- let rty' | Just r' <- rty, everythingOnTypes (||) (== AutoType) r' = Nothing
    --          | otherwise = rty
    -- in
    Just ((concatMap runCaptureType caps, args, rty), ret)
  match _ = Nothing

app :: Pattern PrinterState Cpp (String, Cpp)
app = mkPattern' match
  where
  match (CppApp _ [CppNoOp]) = mzero
  match (CppApp val args) = do
    cpps <- mapM prettyPrintCpp' args
    return (intercalate ", " cpps, val)
  match _ = mzero

unary' :: CppUnaryOp -> (Cpp -> String) -> Operator PrinterState Cpp String
unary' op mkStr = Wrap match (++)
  where
  match :: Pattern PrinterState Cpp (String, Cpp)
  match = mkPattern match'
    where
    match' (CppUnary op' val) | op' == op = Just (mkStr val, val)
    match' _ = Nothing

unary :: CppUnaryOp -> String -> Operator PrinterState Cpp String
unary op str = unary' op (const str)

negateOperator :: Operator PrinterState Cpp String
negateOperator = unary' CppNegate (\v -> if isNegate v then "- " else "-")
  where
  isNegate (CppUnary CppNegate _) = True
  isNegate _ = False

binary :: BinaryOp -> String -> Operator PrinterState Cpp String
binary op str = AssocL match (\v1 v2 -> v1 ++ str ++ v2)
  where
  match :: Pattern PrinterState Cpp (Cpp, Cpp)
  match = mkPattern match'
    where
    match' (CppBinary op' v1 v2) | op' == op = Just (v1, v2)
    match' _ = Nothing

prettyStatements :: [Cpp] -> StateT PrinterState Maybe String
prettyStatements sts = do
  cpps <- forM (filter (/=CppNoOp) sts) prettyPrintCpp'
  indentString <- currentIndent
  return $ intercalate "\n" $ map (indentString ++) cpps

-- |
-- Generate a pretty-printed string representing a C++11 expression
--
prettyPrintCpp1 :: Cpp -> String
prettyPrintCpp1 = fromMaybe (error "Incomplete pattern") . flip evalStateT (PrinterState 0) . prettyPrintCpp'

-- |
-- Generate a pretty-printed string representing a collection of C++11 expressions at the same indentation level
--
prettyPrintCpp :: [Cpp] -> String
prettyPrintCpp = fromMaybe (error "Incomplete pattern") . flip evalStateT (PrinterState 0) . prettyStatements

-- |
-- Generate an indented, pretty-printed string representing a C++11 expression
--
prettyPrintCpp' :: Cpp -> StateT PrinterState Maybe String
prettyPrintCpp' = A.runKleisli $ runPattern matchValue
  where
  matchValue :: Pattern PrinterState Cpp String
  matchValue = buildPrettyPrinter operators (literals <+> fmap parens matchValue)
  operators :: OperatorTable PrinterState Cpp String
  operators =
    OperatorTable [ [ Wrap accessor $ \prop val -> val ++ "::" ++ prop ]
                  , [ Wrap indexer $ \index val -> val ++ "[" ++ index ++ "]" ]
                  , [ Wrap app $ \args val -> val ++ parens args ]
                  , [ unary CppNew "new " ]
                  , [ Wrap lam $ \(caps, args, rty) ret -> '[' : caps ++ "]"
                        ++ let args' = argstr <$> args in
                           parens (intercalate ", " args')
                        ++ maybe "" ((" -> " ++) . runType) rty
                        ++ " "
                        ++ ret ]
                  , [ unary     CppNot                "!"
                    , unary     CppBitwiseNot         "~"
                    , unary     CppPositive           "+"
                    , negateOperator ]
                  , [ binary    Multiply             " * "
                    , binary    Divide               " / "
                    , binary    Modulus              " % "
                    , binary    Dot                  "." ]
                  , [ binary    Add                  " + "
                    , binary    Subtract             " - " ]
                  , [ binary    ShiftLeft            " << "
                    , binary    ShiftRight           " >> " ]
                  , [ binary    LessThan             " < "
                    , binary    LessThanOrEqual      " <= "
                    , binary    GreaterThan          " > "
                    , binary    GreaterThanOrEqual   " >= "
                    , binary    Equal                " == "
                    , binary    NotEqual             " != " ]
                  , [ binary    BitwiseAnd           " & " ]
                  , [ binary    BitwiseXor           " ^ " ]
                  , [ binary    BitwiseOr            " | " ]
                  , [ binary    And                  " && " ]
                  , [ binary    Or                   " || " ]
                  , [ Wrap conditional $ \(th, el) cond -> cond ++ " ? " ++ prettyPrintCpp1 th ++ " : " ++ prettyPrintCpp1 el ]
                    ]

dotsTo :: Char -> String -> String
dotsTo chr' = map (\c -> if c == '.' then chr' else c)

argstr :: (String, Maybe Type) -> String
argstr (name, Nothing) = argStr name AutoType
argstr ("__unused", Just typ@AnyType) = argRefStr [] typ
argstr (name, Just typ@AnyType) = argRefStr name typ
argstr (name, Just typ) = argStr name typ

argStr :: String -> Type -> String
argStr name typ = argTypStr typ ++ if null name then [] else " " ++ name

-- argParamStr :: String -> Type -> String
-- argParamStr name typ = "param" ++ angles (runType typ) ++ if null name then [] else " " ++ name

argRefStr :: String -> Type -> String
argRefStr name typ = argTypStr typ ++ "&" ++ if null name then [] else " " ++ name

argTypStr :: Type -> String
argTypStr typ = "const " ++ runType typ

templDecl :: [TemplateInfo] -> String
templDecl ps = "template " ++ angles (intercalate ", " (go <$> ps))
  where
  go :: TemplateInfo -> String
  go (name, 0) = "typename " ++ name
  go (name, n) = "typename" ++ parens (intercalate "," $ replicate n "typename") ++ ' ' : name

isNestedNamespace :: Cpp -> Bool
isNestedNamespace (CppNamespace (':':':':_) _) = True
isNestedNamespace _ = False

stripScope :: String -> String
stripScope = reverse . takeWhile (/=':') . reverse

angles :: String -> String
angles s = '<' : s ++ ">"

linebreak :: [Cpp]
linebreak = [CppRaw ""]
