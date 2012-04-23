{-# LANGUAGE CPP #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE IncoherentInstances #-}

-- Copyright (C) 2009-2012 John Millikin <jmillikin@gmail.com>
--
-- This program is free software: you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation, either version 3 of the License, or
-- any later version.
--
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.
--
-- You should have received a copy of the GNU General Public License
-- along with this program.  If not, see <http://www.gnu.org/licenses/>.

module DBus.Types where

import           Control.Monad (liftM, when, (>=>))
import           Data.ByteString (ByteString)
import qualified Data.ByteString
import qualified Data.ByteString.Char8
import qualified Data.ByteString.Lazy
import qualified Data.ByteString.Unsafe
import           Data.Int
import           Data.List (intercalate)
import qualified Data.Map
import           Data.Map (Map)
import qualified Data.String
import qualified Data.Text
import           Data.Text (Text)
import qualified Data.Text.Encoding
import qualified Data.Text.Lazy
import qualified Data.Vector
import           Data.Vector (Vector)
import           Data.Word
import qualified Foreign
import           System.IO.Unsafe (unsafePerformIO)

import qualified Text.ParserCombinators.Parsec as Parsec
import           Text.ParserCombinators.Parsec ((<|>), oneOf)

import           DBus.Util (void)

data Type
	= TypeBoolean
	| TypeWord8
	| TypeWord16
	| TypeWord32
	| TypeWord64
	| TypeInt16
	| TypeInt32
	| TypeInt64
	| TypeDouble
	| TypeString
	| TypeSignature
	| TypeObjectPath
	| TypeVariant
	| TypeArray Type
	| TypeDictionary Type Type
	| TypeStructure [Type]
	deriving (Eq, Ord)

instance Show Type where
	showsPrec d = showString . showType (d > 10)

showType :: Bool -> Type -> String
showType paren t = case t of
	TypeBoolean -> "Bool"
	TypeWord8 -> "Word8"
	TypeWord16 -> "Word16"
	TypeWord32 -> "Word32"
	TypeWord64 -> "Word64"
	TypeInt16 -> "Int16"
	TypeInt32 -> "Int32"
	TypeInt64 -> "Int64"
	TypeDouble -> "Double"
	TypeString -> "String"
	TypeSignature -> "Signature"
	TypeObjectPath -> "ObjectPath"
	TypeVariant -> "Variant"
	TypeArray t' -> concat ["[", show t', "]"]
	TypeDictionary kt vt -> showParen paren (
	                        showString "Map " .
	                        shows kt .
	                        showString " " .
	                        showsPrec 11 vt) ""
	TypeStructure ts -> concat
		["(", intercalate ", " (map show ts), ")"]

newtype Signature = Signature [Type]
	deriving (Eq, Ord)

signatureTypes :: Signature -> [Type]
signatureTypes (Signature types) = types

instance Show Signature where
	showsPrec d sig = showParen (d > 10) $
		showString "Signature " .
		shows (signatureText sig)

signatureText :: Signature -> Text
signatureText = Data.Text.Encoding.decodeUtf8
              . Data.ByteString.Char8.pack
              . concatMap typeCode
              . signatureTypes

typeCode :: Type -> String
typeCode TypeBoolean    = "b"
typeCode TypeWord8      = "y"
typeCode TypeWord16     = "q"
typeCode TypeWord32     = "u"
typeCode TypeWord64     = "t"
typeCode TypeInt16      = "n"
typeCode TypeInt32      = "i"
typeCode TypeInt64      = "x"
typeCode TypeDouble     = "d"
typeCode TypeString     = "s"
typeCode TypeSignature  = "g"
typeCode TypeObjectPath = "o"
typeCode TypeVariant    = "v"
typeCode (TypeArray t)  = 'a' : typeCode t
typeCode (TypeDictionary kt vt) = concat
	[ "a{", typeCode kt , typeCode vt, "}"]

typeCode (TypeStructure ts) = concat
	["(", concatMap typeCode ts, ")"]

instance Data.String.IsString Signature where
	fromString s = case parseSignature (Data.ByteString.Char8.pack s) of
		Nothing -> undefined
		Just sig -> sig

signature :: [Type] -> Maybe Signature
signature = check where
	check ts = if sumLen ts > 255
		then Nothing
		else Just (Signature ts)
	sumLen :: [Type] -> Int
	sumLen = sum . map len

	len (TypeArray t) = 1 + len t
	len (TypeDictionary kt vt) = 3 + len kt + len vt
	len (TypeStructure ts) = 2 + sumLen ts
	len _ = 1

signature_ :: [Type] -> Signature
signature_ = undefined

parseSignature :: ByteString -> Maybe Signature
parseSignature bytes =
	case Data.ByteString.length bytes of
		0 -> Just (Signature [])
		1 -> parseSigFast bytes
		len | len <= 255 -> parseSigFull bytes
		_ -> Nothing

parseSigFast :: ByteString -> Maybe Signature
parseSigFast bytes =
	let byte = Data.ByteString.head bytes in
	parseAtom byte
		(\t -> Just (Signature [t]))
		(case byte of
			0x76 -> Just (Signature [TypeVariant])
			_ -> Nothing)

parseAtom :: Word8 -> (Type -> a) -> a -> a
parseAtom byte yes no = case byte of
	0x62 -> yes TypeBoolean
	0x6E -> yes TypeInt16
	0x69 -> yes TypeInt32
	0x78 -> yes TypeInt64
	0x79 -> yes TypeWord8
	0x71 -> yes TypeWord16
	0x75 -> yes TypeWord32
	0x74 -> yes TypeWord64
	0x64 -> yes TypeDouble
	0x73 -> yes TypeString
	0x67 -> yes TypeSignature
	0x6F -> yes TypeObjectPath
	_ -> no

parseSigFull :: ByteString -> Maybe Signature
parseSigFull bytes = unsafePerformIO io where
	io = Data.ByteString.Unsafe.unsafeUseAsCStringLen bytes castBuf
	castBuf (ptr, len) = parseSigBuf (Foreign.castPtr ptr, len)
	parseSigBuf (buf, len) = mainLoop [] 0 where

		mainLoop acc ii | ii >= len = return (Just (Signature (reverse acc)))
		mainLoop acc ii = do
			c <- Foreign.peekElemOff buf ii
			let next t = mainLoop (t : acc) (ii + 1)
			parseAtom c next $ case c of
				0x76 -> next TypeVariant
				0x28 -> do -- '('
					mt <- structure (ii + 1)
					case mt of
						Just (ii', t) -> mainLoop (t : acc) ii'
						Nothing -> return Nothing
				0x61 -> do -- 'a'
					mt <- array (ii + 1)
					case mt of
						Just (ii', t) -> mainLoop (t : acc) ii'
						Nothing -> return Nothing
				_ -> return Nothing

		structure :: Int -> IO (Maybe (Int, Type))
		structure = loop [] where
			loop _ ii | ii >= len = return Nothing
			loop acc ii = do
				c <- Foreign.peekElemOff buf ii
				let next t = loop (t : acc) (ii + 1)
				parseAtom c next $ case c of
					0x76 -> next TypeVariant
					0x28 -> do -- '('
						mt <- structure (ii + 1)
						case mt of
							Just (ii', t) -> loop (t : acc) ii'
							Nothing -> return Nothing
					0x61 -> do -- 'a'
						mt <- array (ii + 1)
						case mt of
							Just (ii', t) -> loop (t : acc) ii'
							Nothing -> return Nothing
					-- ')'
					0x29 -> return $ case acc of
						[] -> Nothing
						_ -> Just $ (ii + 1, TypeStructure (reverse acc))
					_ -> return Nothing

		array :: Int -> IO (Maybe (Int, Type))
		array ii | ii >= len = return Nothing
		array ii = do
			c <- Foreign.peekElemOff buf ii
			let next t = return $ Just (ii + 1, TypeArray t)
			parseAtom c next $ case c of
				0x76 -> next TypeVariant
				0x7B -> dict (ii + 1) -- '{'
				0x28 -> do -- '('
					mt <- structure (ii + 1)
					case mt of
						Just (ii', t) -> return $ Just (ii', TypeArray t)
						Nothing -> return Nothing
				0x61 -> do -- 'a'
					mt <- array (ii + 1)
					case mt of
						Just (ii', t) -> return $ Just (ii', TypeArray t)
						Nothing -> return Nothing
				_ -> return Nothing

		dict :: Int -> IO (Maybe (Int, Type))
		dict ii | ii + 1 >= len = return Nothing
		dict ii = do
			c1 <- Foreign.peekElemOff buf ii
			c2 <- Foreign.peekElemOff buf (ii + 1)
			
			let next t = return (Just (ii + 2, t))
			mt2 <- parseAtom c2 next $ case c2 of
				0x76 -> next TypeVariant
				0x28 -> structure (ii + 2) -- '('
				0x61 -> array (ii + 2) -- 'a'
				_ -> return Nothing
			
			case mt2 of
				Nothing -> return Nothing
				Just (ii', t2) -> if ii' >= len
					then return Nothing
					else do
						c3 <- Foreign.peekElemOff buf ii'
						return $ do
							if c3 == 0x7D then Just () else Nothing
							t1 <- parseAtom c1 Just Nothing
							Just (ii' + 1, TypeDictionary t1 t2)

class IsVariant a where
	toVariant :: a -> Variant
	fromVariant :: Variant -> Maybe a

class IsVariant a => IsValue a where
	typeOf :: a -> Type
	toValue :: a -> Value
	fromValue :: Value -> Maybe a

class IsValue a => IsAtom a where
	toAtom :: a -> Atom
	fromAtom :: Atom -> Maybe a

-- | 'Variant's may contain any other built&#8208;in D&#8208;Bus value. Besides
-- representing native @VARIANT@ values, they allow type&#8208;safe storage and
-- deconstruction of heterogeneous collections.
newtype Variant = Variant Value
	deriving (Eq)

data Value
	= ValueAtom Atom
	| ValueVariant Variant
	| ValueBytes ByteString
	| ValueVector Type (Vector Value)
	| ValueMap Type Type (Map Atom Value)
	| ValueStructure [Value]
	deriving (Show)

data Atom
	= AtomBool Bool
	| AtomWord8 Word8
	| AtomWord16 Word16
	| AtomWord32 Word32
	| AtomWord64 Word64
	| AtomInt16 Int16
	| AtomInt32 Int32
	| AtomInt64 Int64
	| AtomDouble Double
	| AtomText Text
	| AtomSignature Signature
	| AtomObjectPath ObjectPath
	deriving (Show, Eq, Ord)

instance Eq Value where
	(==) (ValueBytes x) y = case y of
		ValueBytes y' -> x == y'
		ValueVector TypeWord8 y' -> x == vectorToBytes y'
		_ -> False
	
	(==) (ValueVector TypeWord8 x) y = case y of
		ValueBytes y' -> vectorToBytes x == y'
		ValueVector TypeWord8 y' -> x == y'
		_ -> False
	
	(==) (ValueAtom x) (ValueAtom y) = x == y
	(==) (ValueVariant x) (ValueVariant y) = x == y
	(==) (ValueVector tx x) (ValueVector ty y) = tx == ty && x == y
	(==) (ValueMap ktx vtx x) (ValueMap kty vty y) = ktx == kty && vtx == vty && x == y
	(==) (ValueStructure x) (ValueStructure y) = x == y
	(==) _ _ = False

showAtom :: Bool -> Atom -> String
showAtom _ (AtomBool x) = show x
showAtom _ (AtomWord8 x) = show x
showAtom _ (AtomWord16 x) = show x
showAtom _ (AtomWord32 x) = show x
showAtom _ (AtomWord64 x) = show x
showAtom _ (AtomInt16 x) = show x
showAtom _ (AtomInt32 x) = show x
showAtom _ (AtomInt64 x) = show x
showAtom _ (AtomDouble x) = show x
showAtom _ (AtomText x) = show x
showAtom p (AtomSignature x) = showsPrec (if p then 11 else 0) x ""
showAtom p (AtomObjectPath x) = showsPrec (if p then 11 else 0) x ""

showValue :: Bool -> Value -> String
showValue p (ValueAtom x) = showAtom p x
showValue p (ValueVariant x) = showsPrec (if p then 11 else 0) x ""
showValue _ (ValueBytes xs) = 'b' : show xs
showValue _ (ValueVector TypeWord8 xs) = 'b' : show (vectorToBytes xs)
showValue _ (ValueVector _ xs) = showThings "[" (showValue False) "]" (Data.Vector.toList xs)
showValue _ (ValueMap _ _ xs) = showThings "{" showPair "}" (Data.Map.toList xs) where
	showPair (k, v) = showAtom False k ++ ": " ++ showValue False v
showValue _ (ValueStructure xs) = showThings "(" (showValue False) ")" xs

showThings :: String -> (a -> String) -> String -> [a] -> String
showThings a s z xs = a ++ intercalate ", " (map s xs) ++ z

vectorToBytes :: Vector Value -> ByteString
vectorToBytes = Data.ByteString.pack
              . Data.Vector.toList
              . Data.Vector.map (\(ValueAtom (AtomWord8 x)) -> x)

instance Show Variant where
	showsPrec d (Variant x) = showParen (d > 10) $
		showString "Variant " .  showString (showValue True x)

-- | Every variant is strongly&#8208;typed; that is, the type of its contained
-- value is known at all times. This function retrieves that type, so that
-- the correct cast can be used to retrieve the value.
variantType :: Variant -> Type
variantType (Variant val) = valueType val

valueType :: Value -> Type
valueType (ValueAtom x) = atomType x
valueType (ValueVariant _) = TypeVariant
valueType (ValueVector t _) = TypeArray t
valueType (ValueBytes _) = TypeArray TypeWord8
valueType (ValueMap kt vt _) = TypeDictionary kt vt
valueType (ValueStructure vs) = TypeStructure (map valueType vs)

atomType :: Atom -> Type
atomType (AtomBool _) = TypeBoolean
atomType (AtomWord8 _) = TypeWord8
atomType (AtomWord16 _) = TypeWord16
atomType (AtomWord32 _) = TypeWord32
atomType (AtomWord64 _) = TypeWord64
atomType (AtomInt16 _) = TypeInt16
atomType (AtomInt32 _) = TypeInt32
atomType (AtomInt64 _) = TypeInt64
atomType (AtomDouble _) = TypeDouble
atomType (AtomText _) = TypeString
atomType (AtomSignature _) = TypeSignature
atomType (AtomObjectPath _) = TypeObjectPath

#define IS_ATOM(HsType, AtomCons, TypeCons) \
	instance IsAtom HsType where \
	{ toAtom = AtomCons \
	; fromAtom (AtomCons x) = Just x \
	; fromAtom _ = Nothing \
	}; \
	instance IsValue HsType where \
	{ typeOf _ = TypeCons \
	; toValue = ValueAtom . toAtom \
	; fromValue (ValueAtom x) = fromAtom x \
	; fromValue _ = Nothing \
	}; \
	instance IsVariant HsType where \
	{ toVariant = Variant . toValue \
	; fromVariant (Variant val) = fromValue val \
	}

IS_ATOM(Bool,       AtomBool,       TypeBoolean)
IS_ATOM(Word8,      AtomWord8,      TypeWord8)
IS_ATOM(Word16,     AtomWord16,     TypeWord16)
IS_ATOM(Word32,     AtomWord32,     TypeWord32)
IS_ATOM(Word64,     AtomWord64,     TypeWord64)
IS_ATOM(Int16,      AtomInt16,      TypeInt16)
IS_ATOM(Int32,      AtomInt32,      TypeInt32)
IS_ATOM(Int64,      AtomInt64,      TypeInt64)
IS_ATOM(Double,     AtomDouble,     TypeDouble)
IS_ATOM(Text,       AtomText,       TypeString)
IS_ATOM(Signature,  AtomSignature,  TypeSignature)
IS_ATOM(ObjectPath, AtomObjectPath, TypeObjectPath)

instance IsValue Variant where
	typeOf _ = TypeVariant
	toValue = ValueVariant
	fromValue (ValueVariant x) = Just x
	fromValue _ = Nothing

instance IsVariant Variant where
	toVariant = Variant . toValue
	fromVariant (Variant val) = fromValue val

instance IsAtom Data.Text.Lazy.Text where
	toAtom = toAtom . Data.Text.Lazy.toStrict
	fromAtom = fmap Data.Text.Lazy.fromStrict . fromAtom

instance IsValue Data.Text.Lazy.Text where
	typeOf _ = TypeString
	toValue = ValueAtom . toAtom
	fromValue (ValueAtom x) = fromAtom x
	fromValue _ = Nothing

instance IsVariant Data.Text.Lazy.Text where
	toVariant = Variant . toValue
	fromVariant (Variant val) = fromValue val

instance IsAtom String where
	toAtom = toAtom . Data.Text.pack
	fromAtom = fmap Data.Text.unpack . fromAtom

instance IsValue String where
	typeOf _ = TypeString
	toValue = ValueAtom . toAtom
	fromValue (ValueAtom x) = fromAtom x
	fromValue _ = Nothing

instance IsVariant String where
	toVariant = Variant . toValue
	fromVariant (Variant val) = fromValue val

instance IsValue a => IsValue (Vector a) where
	typeOf v = TypeArray (vectorItemType v)
	toValue v = ValueVector (vectorItemType v) (Data.Vector.map toValue v)
	fromValue (ValueVector _ v) = Data.Vector.mapM fromValue v
	fromValue _ = Nothing

vectorItemType :: IsValue a => Vector a -> Type
vectorItemType v = typeOf (undefined `asTypeOf` Data.Vector.head v)

instance IsValue a => IsVariant (Vector a) where
	toVariant = Variant . toValue
	fromVariant (Variant val) = fromValue val

instance IsValue a => IsValue [a] where
	typeOf v = TypeArray (typeOf (undefined `asTypeOf` head v))
	toValue = toValue . Data.Vector.fromList
	fromValue = fmap Data.Vector.toList . fromValue

instance IsValue a => IsVariant [a] where
	toVariant = toVariant . Data.Vector.fromList
	fromVariant = fmap Data.Vector.toList . fromVariant

instance IsValue ByteString where
	typeOf _ = TypeArray TypeWord8
	toValue = ValueBytes
	fromValue (ValueBytes bs) = Just bs
	fromValue (ValueVector TypeWord8 v) = Just (vectorToBytes v)
	fromValue _ = Nothing

instance IsVariant ByteString where
	toVariant = Variant . toValue
	fromVariant (Variant val) = fromValue val

instance IsValue Data.ByteString.Lazy.ByteString where
	typeOf _ = TypeArray TypeWord8
	toValue = toValue
	        . Data.ByteString.concat
	        . Data.ByteString.Lazy.toChunks
	fromValue = fmap (\bs -> Data.ByteString.Lazy.fromChunks [bs])
	          . fromValue

instance IsVariant Data.ByteString.Lazy.ByteString where
	toVariant = Variant . toValue
	fromVariant (Variant val) = fromValue val

instance (Ord k, IsAtom k, IsValue v) => IsValue (Map k v) where
	typeOf m = TypeDictionary kt vt where
		(kt, vt) = mapItemType m
	
	toValue m = ValueMap kt vt (bimap box m) where
		(kt, vt) = mapItemType m
		box k v = (toAtom k, toValue v)
	
	fromValue (ValueMap _ _ m) = bimapM unbox m where
		unbox k v = do
			k' <- fromAtom k
			v' <- fromValue v
			return (k', v')
	fromValue _ = Nothing

bimap :: Ord k' => (k -> v -> (k', v')) -> Map k v -> Map k' v'
bimap f = Data.Map.fromList . map (\(k, v) -> f k v) . Data.Map.toList

bimapM :: (Monad m, Ord k') => (k -> v -> m (k', v')) -> Map k v -> m (Map k' v')
bimapM f = liftM Data.Map.fromList . mapM (\(k, v) -> f k v) . Data.Map.toList

mapItemType :: (IsValue k, IsValue v) => Map k v -> (Type, Type)
mapItemType m = (typeOf k, typeOf v) where
	mapItem :: Map k v -> (k, v)
	mapItem _ = (undefined, undefined)
	(k, v) = mapItem m

instance (Ord k, IsAtom k, IsValue v) => IsVariant (Map k v) where
	toVariant = Variant . toValue
	fromVariant (Variant val) = fromValue val

instance (IsValue a1, IsValue a2) => IsValue (a1, a2) where
	typeOf ~(a1, a2) = TypeStructure [typeOf a1, typeOf a2]
	toValue (a1, a2) = ValueStructure [toValue a1, toValue a2]
	fromValue (ValueStructure [a1, a2]) = do
		a1' <- fromValue a1
		a2' <- fromValue a2
		return (a1', a2')
	fromValue _ = Nothing

instance (IsVariant a1, IsVariant a2) => IsVariant (a1, a2) where
	toVariant (a1, a2) = Variant (ValueStructure [varToVal a1, varToVal a2])
	fromVariant (Variant (ValueStructure [a1, a2])) = do
		a1' <- (fromVariant . Variant) a1
		a2' <- (fromVariant . Variant) a2
		return (a1', a2')
	fromVariant _ = Nothing

varToVal :: IsVariant a => a -> Value
varToVal a = case toVariant a of
	Variant val -> val

newtype ObjectPath = ObjectPath Text
	deriving (Eq, Ord, Show)

objectPathText :: ObjectPath -> Text
objectPathText (ObjectPath text) = text

objectPath :: Text -> Maybe ObjectPath
objectPath text = do
	runParser parseObjectPath text
	return (ObjectPath text)

objectPath_ :: Text -> ObjectPath
objectPath_ = tryParse "object path" objectPath

instance Data.String.IsString ObjectPath where
	fromString = objectPath_ . Data.Text.pack

parseObjectPath :: Parsec.Parser ()
parseObjectPath = root <|> object where
	root = Parsec.try $ do
		slash
		Parsec.eof
	
	object = do
		slash
		skipSepBy1 element slash
		Parsec.eof
	
	element = Parsec.skipMany1 (oneOf chars)
	
	slash = void (Parsec.char '/')
	chars = concat [ ['a'..'z']
	               , ['A'..'Z']
	               , ['0'..'9']
	               , "_"]

newtype InterfaceName = InterfaceName Text
	deriving (Eq, Ord, Show)

interfaceNameText :: InterfaceName -> Text
interfaceNameText (InterfaceName text) = text

interfaceName :: Text -> Maybe InterfaceName
interfaceName text = do
	when (Data.Text.length text > 255) Nothing
	runParser parseInterfaceName text
	return (InterfaceName text)

interfaceName_ :: Text -> InterfaceName
interfaceName_ = tryParse "interface name" interfaceName

instance Data.String.IsString InterfaceName where
	fromString = interfaceName_ . Data.Text.pack

instance IsVariant InterfaceName where
	toVariant = toVariant . interfaceNameText
	fromVariant = fromVariant >=> interfaceName

parseInterfaceName :: Parsec.Parser ()
parseInterfaceName = name >> Parsec.eof where
	alpha = ['a'..'z'] ++ ['A'..'Z'] ++ "_"
	alphanum = alpha ++ ['0'..'9']
	element = do
		void (oneOf alpha)
		Parsec.skipMany (oneOf alphanum)
	name = do
		element
		void (Parsec.char '.')
		skipSepBy1 element (Parsec.char '.')

newtype MemberName = MemberName Text
	deriving (Eq, Ord, Show)

memberNameText :: MemberName -> Text
memberNameText (MemberName text) = text

memberName :: Text -> Maybe MemberName
memberName text = do
	when (Data.Text.length text > 255) Nothing
	runParser parseMemberName text
	return (MemberName text)

memberName_ :: Text -> MemberName
memberName_ = tryParse "member name" memberName

instance Data.String.IsString MemberName where
	fromString = memberName_ . Data.Text.pack

instance IsVariant MemberName where
	toVariant = toVariant . memberNameText
	fromVariant = fromVariant >=> memberName

parseMemberName :: Parsec.Parser ()
parseMemberName = name >> Parsec.eof where
	alpha = ['a'..'z'] ++ ['A'..'Z'] ++ "_"
	alphanum = alpha ++ ['0'..'9']
	name = do
		void (oneOf alpha)
		Parsec.skipMany (oneOf alphanum)

newtype ErrorName = ErrorName Text
	deriving (Eq, Ord, Show)

errorNameText :: ErrorName -> Text
errorNameText (ErrorName text) = text

errorName :: Text -> Maybe ErrorName
errorName text = do
	when (Data.Text.length text > 255) Nothing
	runParser parseInterfaceName text
	return (ErrorName text)

errorName_ :: Text -> ErrorName
errorName_ = tryParse "error name" errorName

instance Data.String.IsString ErrorName where
	fromString = errorName_ . Data.Text.pack

instance IsVariant ErrorName where
	toVariant = toVariant . errorNameText
	fromVariant = fromVariant >=> errorName

newtype BusName = BusName Text
	deriving (Eq, Ord, Show)

busNameText :: BusName -> Text
busNameText (BusName text) = text

busName :: Text -> Maybe BusName
busName text = do
	when (Data.Text.length text > 255) Nothing
	runParser parseBusName text
	return (BusName text)

busName_ :: Text -> BusName
busName_ = tryParse "bus name" busName

instance Data.String.IsString BusName where
	fromString = busName_ . Data.Text.pack

instance IsVariant BusName where
	toVariant = toVariant . busNameText
	fromVariant = fromVariant >=> busName

parseBusName :: Parsec.Parser ()
parseBusName = name >> Parsec.eof where
	alpha = ['a'..'z'] ++ ['A'..'Z'] ++ "_-"
	alphanum = alpha ++ ['0'..'9']
	
	name = unique <|> wellKnown
	unique = do
		void (Parsec.char ':')
		elements alphanum
	
	wellKnown = elements alpha
	
	elements start = do
		element start
		Parsec.skipMany1 $ do
			void (Parsec.char '.')
			element start
	
	element start = do
		void (oneOf start)
		Parsec.skipMany (oneOf alphanum)

newtype Structure = Structure [Value]
	deriving (Eq)

instance Show Structure where
	show (Structure xs) = showValue True (ValueStructure xs)

instance IsVariant Structure where
	toVariant (Structure xs) = Variant (ValueStructure xs)
	fromVariant (Variant (ValueStructure xs)) = Just (Structure xs)
	fromVariant _ = Nothing

structureItems :: Structure -> [Variant]
structureItems (Structure xs) = map Variant xs

data Array
	= Array Type (Vector Value)
	| ArrayBytes ByteString

instance Show Array where
	show (Array t xs) = showValue True (ValueVector t xs)
	show (ArrayBytes xs) = showValue True (ValueBytes xs)

instance Eq Array where
	x == y = norm x == norm y where
		norm (Array TypeWord8 xs) = Left (vectorToBytes xs)
		norm (Array t xs) = Right (t, xs)
		norm (ArrayBytes xs) = Left xs

instance IsVariant Array where
	toVariant (Array t xs) = Variant (ValueVector t xs)
	toVariant (ArrayBytes bs) = Variant (ValueBytes bs)
	fromVariant (Variant (ValueVector t xs)) = Just (Array t xs)
	fromVariant (Variant (ValueBytes bs)) = Just (ArrayBytes bs)
	fromVariant _ = Nothing

arrayItems :: Array -> [Variant]
arrayItems (Array _ xs) = map Variant (Data.Vector.toList xs)
arrayItems (ArrayBytes bs) = map toVariant (Data.ByteString.unpack bs)

data Dictionary = Dictionary Type Type (Map Atom Value)
	deriving (Eq)

instance Show Dictionary where
	show (Dictionary kt vt xs) = showValue True (ValueMap kt vt xs)

instance IsVariant Dictionary where
	toVariant (Dictionary kt vt xs) = Variant (ValueMap kt vt xs)
	fromVariant (Variant (ValueMap kt vt xs)) = Just (Dictionary kt vt xs)
	fromVariant _ = Nothing

dictionaryItems :: Dictionary -> [(Variant, Variant)]
dictionaryItems (Dictionary _ _ xs) = do
	(k, v) <- Data.Map.toList xs
	return (Variant (ValueAtom k), Variant v)

instance (IsValue a1, IsValue a2, IsValue a3) => IsValue (a1, a2, a3) where
	typeOf ~(a1, a2, a3) = TypeStructure [typeOf a1, typeOf a2, typeOf a3]
	toValue (a1, a2, a3) = ValueStructure [toValue a1, toValue a2, toValue a3]
	fromValue (ValueStructure [a1, a2, a3]) = do
		a1' <- fromValue a1
		a2' <- fromValue a2
		a3' <- fromValue a3
		return (a1', a2', a3')
	fromValue _ = Nothing

instance (IsValue a1, IsValue a2, IsValue a3, IsValue a4) => IsValue (a1, a2, a3, a4) where
	typeOf ~(a1, a2, a3, a4) = TypeStructure [typeOf a1, typeOf a2, typeOf a3, typeOf a4]
	toValue (a1, a2, a3, a4) = ValueStructure [toValue a1, toValue a2, toValue a3, toValue a4]
	fromValue (ValueStructure [a1, a2, a3, a4]) = do
		a1' <- fromValue a1
		a2' <- fromValue a2
		a3' <- fromValue a3
		a4' <- fromValue a4
		return (a1', a2', a3', a4')
	fromValue _ = Nothing

instance (IsValue a1, IsValue a2, IsValue a3, IsValue a4, IsValue a5) => IsValue (a1, a2, a3, a4, a5) where
	typeOf ~(a1, a2, a3, a4, a5) = TypeStructure [typeOf a1, typeOf a2, typeOf a3, typeOf a4, typeOf a5]
	toValue (a1, a2, a3, a4, a5) = ValueStructure [toValue a1, toValue a2, toValue a3, toValue a4, toValue a5]
	fromValue (ValueStructure [a1, a2, a3, a4, a5]) = do
		a1' <- fromValue a1
		a2' <- fromValue a2
		a3' <- fromValue a3
		a4' <- fromValue a4
		a5' <- fromValue a5
		return (a1', a2', a3', a4', a5')
	fromValue _ = Nothing

instance (IsValue a1, IsValue a2, IsValue a3, IsValue a4, IsValue a5, IsValue a6) => IsValue (a1, a2, a3, a4, a5, a6) where
	typeOf ~(a1, a2, a3, a4, a5, a6) = TypeStructure [typeOf a1, typeOf a2, typeOf a3, typeOf a4, typeOf a5, typeOf a6]
	toValue (a1, a2, a3, a4, a5, a6) = ValueStructure [toValue a1, toValue a2, toValue a3, toValue a4, toValue a5, toValue a6]
	fromValue (ValueStructure [a1, a2, a3, a4, a5, a6]) = do
		a1' <- fromValue a1
		a2' <- fromValue a2
		a3' <- fromValue a3
		a4' <- fromValue a4
		a5' <- fromValue a5
		a6' <- fromValue a6
		return (a1', a2', a3', a4', a5', a6')
	fromValue _ = Nothing

instance (IsValue a1, IsValue a2, IsValue a3, IsValue a4, IsValue a5, IsValue a6, IsValue a7) => IsValue (a1, a2, a3, a4, a5, a6, a7) where
	typeOf ~(a1, a2, a3, a4, a5, a6, a7) = TypeStructure [typeOf a1, typeOf a2, typeOf a3, typeOf a4, typeOf a5, typeOf a6, typeOf a7]
	toValue (a1, a2, a3, a4, a5, a6, a7) = ValueStructure [toValue a1, toValue a2, toValue a3, toValue a4, toValue a5, toValue a6, toValue a7]
	fromValue (ValueStructure [a1, a2, a3, a4, a5, a6, a7]) = do
		a1' <- fromValue a1
		a2' <- fromValue a2
		a3' <- fromValue a3
		a4' <- fromValue a4
		a5' <- fromValue a5
		a6' <- fromValue a6
		a7' <- fromValue a7
		return (a1', a2', a3', a4', a5', a6', a7')
	fromValue _ = Nothing

instance (IsValue a1, IsValue a2, IsValue a3, IsValue a4, IsValue a5, IsValue a6, IsValue a7, IsValue a8) => IsValue (a1, a2, a3, a4, a5, a6, a7, a8) where
	typeOf ~(a1, a2, a3, a4, a5, a6, a7, a8) = TypeStructure [typeOf a1, typeOf a2, typeOf a3, typeOf a4, typeOf a5, typeOf a6, typeOf a7, typeOf a8]
	toValue (a1, a2, a3, a4, a5, a6, a7, a8) = ValueStructure [toValue a1, toValue a2, toValue a3, toValue a4, toValue a5, toValue a6, toValue a7, toValue a8]
	fromValue (ValueStructure [a1, a2, a3, a4, a5, a6, a7, a8]) = do
		a1' <- fromValue a1
		a2' <- fromValue a2
		a3' <- fromValue a3
		a4' <- fromValue a4
		a5' <- fromValue a5
		a6' <- fromValue a6
		a7' <- fromValue a7
		a8' <- fromValue a8
		return (a1', a2', a3', a4', a5', a6', a7', a8')
	fromValue _ = Nothing

instance (IsValue a1, IsValue a2, IsValue a3, IsValue a4, IsValue a5, IsValue a6, IsValue a7, IsValue a8, IsValue a9) => IsValue (a1, a2, a3, a4, a5, a6, a7, a8, a9) where
	typeOf ~(a1, a2, a3, a4, a5, a6, a7, a8, a9) = TypeStructure [typeOf a1, typeOf a2, typeOf a3, typeOf a4, typeOf a5, typeOf a6, typeOf a7, typeOf a8, typeOf a9]
	toValue (a1, a2, a3, a4, a5, a6, a7, a8, a9) = ValueStructure [toValue a1, toValue a2, toValue a3, toValue a4, toValue a5, toValue a6, toValue a7, toValue a8, toValue a9]
	fromValue (ValueStructure [a1, a2, a3, a4, a5, a6, a7, a8, a9]) = do
		a1' <- fromValue a1
		a2' <- fromValue a2
		a3' <- fromValue a3
		a4' <- fromValue a4
		a5' <- fromValue a5
		a6' <- fromValue a6
		a7' <- fromValue a7
		a8' <- fromValue a8
		a9' <- fromValue a9
		return (a1', a2', a3', a4', a5', a6', a7', a8', a9')
	fromValue _ = Nothing

instance (IsValue a1, IsValue a2, IsValue a3, IsValue a4, IsValue a5, IsValue a6, IsValue a7, IsValue a8, IsValue a9, IsValue a10) => IsValue (a1, a2, a3, a4, a5, a6, a7, a8, a9, a10) where
	typeOf ~(a1, a2, a3, a4, a5, a6, a7, a8, a9, a10) = TypeStructure [typeOf a1, typeOf a2, typeOf a3, typeOf a4, typeOf a5, typeOf a6, typeOf a7, typeOf a8, typeOf a9, typeOf a10]
	toValue (a1, a2, a3, a4, a5, a6, a7, a8, a9, a10) = ValueStructure [toValue a1, toValue a2, toValue a3, toValue a4, toValue a5, toValue a6, toValue a7, toValue a8, toValue a9, toValue a10]
	fromValue (ValueStructure [a1, a2, a3, a4, a5, a6, a7, a8, a9, a10]) = do
		a1' <- fromValue a1
		a2' <- fromValue a2
		a3' <- fromValue a3
		a4' <- fromValue a4
		a5' <- fromValue a5
		a6' <- fromValue a6
		a7' <- fromValue a7
		a8' <- fromValue a8
		a9' <- fromValue a9
		a10' <- fromValue a10
		return (a1', a2', a3', a4', a5', a6', a7', a8', a9', a10')
	fromValue _ = Nothing

instance (IsValue a1, IsValue a2, IsValue a3, IsValue a4, IsValue a5, IsValue a6, IsValue a7, IsValue a8, IsValue a9, IsValue a10, IsValue a11) => IsValue (a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11) where
	typeOf ~(a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11) = TypeStructure [typeOf a1, typeOf a2, typeOf a3, typeOf a4, typeOf a5, typeOf a6, typeOf a7, typeOf a8, typeOf a9, typeOf a10, typeOf a11]
	toValue (a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11) = ValueStructure [toValue a1, toValue a2, toValue a3, toValue a4, toValue a5, toValue a6, toValue a7, toValue a8, toValue a9, toValue a10, toValue a11]
	fromValue (ValueStructure [a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11]) = do
		a1' <- fromValue a1
		a2' <- fromValue a2
		a3' <- fromValue a3
		a4' <- fromValue a4
		a5' <- fromValue a5
		a6' <- fromValue a6
		a7' <- fromValue a7
		a8' <- fromValue a8
		a9' <- fromValue a9
		a10' <- fromValue a10
		a11' <- fromValue a11
		return (a1', a2', a3', a4', a5', a6', a7', a8', a9', a10', a11')
	fromValue _ = Nothing

instance (IsValue a1, IsValue a2, IsValue a3, IsValue a4, IsValue a5, IsValue a6, IsValue a7, IsValue a8, IsValue a9, IsValue a10, IsValue a11, IsValue a12) => IsValue (a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12) where
	typeOf ~(a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12) = TypeStructure [typeOf a1, typeOf a2, typeOf a3, typeOf a4, typeOf a5, typeOf a6, typeOf a7, typeOf a8, typeOf a9, typeOf a10, typeOf a11, typeOf a12]
	toValue (a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12) = ValueStructure [toValue a1, toValue a2, toValue a3, toValue a4, toValue a5, toValue a6, toValue a7, toValue a8, toValue a9, toValue a10, toValue a11, toValue a12]
	fromValue (ValueStructure [a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12]) = do
		a1' <- fromValue a1
		a2' <- fromValue a2
		a3' <- fromValue a3
		a4' <- fromValue a4
		a5' <- fromValue a5
		a6' <- fromValue a6
		a7' <- fromValue a7
		a8' <- fromValue a8
		a9' <- fromValue a9
		a10' <- fromValue a10
		a11' <- fromValue a11
		a12' <- fromValue a12
		return (a1', a2', a3', a4', a5', a6', a7', a8', a9', a10', a11', a12')
	fromValue _ = Nothing

instance (IsValue a1, IsValue a2, IsValue a3, IsValue a4, IsValue a5, IsValue a6, IsValue a7, IsValue a8, IsValue a9, IsValue a10, IsValue a11, IsValue a12, IsValue a13) => IsValue (a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13) where
	typeOf ~(a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13) = TypeStructure [typeOf a1, typeOf a2, typeOf a3, typeOf a4, typeOf a5, typeOf a6, typeOf a7, typeOf a8, typeOf a9, typeOf a10, typeOf a11, typeOf a12, typeOf a13]
	toValue (a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13) = ValueStructure [toValue a1, toValue a2, toValue a3, toValue a4, toValue a5, toValue a6, toValue a7, toValue a8, toValue a9, toValue a10, toValue a11, toValue a12, toValue a13]
	fromValue (ValueStructure [a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13]) = do
		a1' <- fromValue a1
		a2' <- fromValue a2
		a3' <- fromValue a3
		a4' <- fromValue a4
		a5' <- fromValue a5
		a6' <- fromValue a6
		a7' <- fromValue a7
		a8' <- fromValue a8
		a9' <- fromValue a9
		a10' <- fromValue a10
		a11' <- fromValue a11
		a12' <- fromValue a12
		a13' <- fromValue a13
		return (a1', a2', a3', a4', a5', a6', a7', a8', a9', a10', a11', a12', a13')
	fromValue _ = Nothing

instance (IsValue a1, IsValue a2, IsValue a3, IsValue a4, IsValue a5, IsValue a6, IsValue a7, IsValue a8, IsValue a9, IsValue a10, IsValue a11, IsValue a12, IsValue a13, IsValue a14) => IsValue (a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14) where
	typeOf ~(a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14) = TypeStructure [typeOf a1, typeOf a2, typeOf a3, typeOf a4, typeOf a5, typeOf a6, typeOf a7, typeOf a8, typeOf a9, typeOf a10, typeOf a11, typeOf a12, typeOf a13, typeOf a14]
	toValue (a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14) = ValueStructure [toValue a1, toValue a2, toValue a3, toValue a4, toValue a5, toValue a6, toValue a7, toValue a8, toValue a9, toValue a10, toValue a11, toValue a12, toValue a13, toValue a14]
	fromValue (ValueStructure [a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14]) = do
		a1' <- fromValue a1
		a2' <- fromValue a2
		a3' <- fromValue a3
		a4' <- fromValue a4
		a5' <- fromValue a5
		a6' <- fromValue a6
		a7' <- fromValue a7
		a8' <- fromValue a8
		a9' <- fromValue a9
		a10' <- fromValue a10
		a11' <- fromValue a11
		a12' <- fromValue a12
		a13' <- fromValue a13
		a14' <- fromValue a14
		return (a1', a2', a3', a4', a5', a6', a7', a8', a9', a10', a11', a12', a13', a14')
	fromValue _ = Nothing

instance (IsValue a1, IsValue a2, IsValue a3, IsValue a4, IsValue a5, IsValue a6, IsValue a7, IsValue a8, IsValue a9, IsValue a10, IsValue a11, IsValue a12, IsValue a13, IsValue a14, IsValue a15) => IsValue (a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15) where
	typeOf ~(a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15) = TypeStructure [typeOf a1, typeOf a2, typeOf a3, typeOf a4, typeOf a5, typeOf a6, typeOf a7, typeOf a8, typeOf a9, typeOf a10, typeOf a11, typeOf a12, typeOf a13, typeOf a14, typeOf a15]
	toValue (a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15) = ValueStructure [toValue a1, toValue a2, toValue a3, toValue a4, toValue a5, toValue a6, toValue a7, toValue a8, toValue a9, toValue a10, toValue a11, toValue a12, toValue a13, toValue a14, toValue a15]
	fromValue (ValueStructure [a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15]) = do
		a1' <- fromValue a1
		a2' <- fromValue a2
		a3' <- fromValue a3
		a4' <- fromValue a4
		a5' <- fromValue a5
		a6' <- fromValue a6
		a7' <- fromValue a7
		a8' <- fromValue a8
		a9' <- fromValue a9
		a10' <- fromValue a10
		a11' <- fromValue a11
		a12' <- fromValue a12
		a13' <- fromValue a13
		a14' <- fromValue a14
		a15' <- fromValue a15
		return (a1', a2', a3', a4', a5', a6', a7', a8', a9', a10', a11', a12', a13', a14', a15')
	fromValue _ = Nothing

instance (IsVariant a1, IsVariant a2, IsVariant a3) => IsVariant (a1, a2, a3) where
	toVariant (a1, a2, a3) = Variant (ValueStructure [varToVal a1, varToVal a2, varToVal a3])
	fromVariant (Variant (ValueStructure [a1, a2, a3])) = do
		a1' <- (fromVariant . Variant) a1
		a2' <- (fromVariant . Variant) a2
		a3' <- (fromVariant . Variant) a3
		return (a1', a2', a3')
	fromVariant _ = Nothing

instance (IsVariant a1, IsVariant a2, IsVariant a3, IsVariant a4) => IsVariant (a1, a2, a3, a4) where
	toVariant (a1, a2, a3, a4) = Variant (ValueStructure [varToVal a1, varToVal a2, varToVal a3, varToVal a4])
	fromVariant (Variant (ValueStructure [a1, a2, a3, a4])) = do
		a1' <- (fromVariant . Variant) a1
		a2' <- (fromVariant . Variant) a2
		a3' <- (fromVariant . Variant) a3
		a4' <- (fromVariant . Variant) a4
		return (a1', a2', a3', a4')
	fromVariant _ = Nothing

instance (IsVariant a1, IsVariant a2, IsVariant a3, IsVariant a4, IsVariant a5) => IsVariant (a1, a2, a3, a4, a5) where
	toVariant (a1, a2, a3, a4, a5) = Variant (ValueStructure [varToVal a1, varToVal a2, varToVal a3, varToVal a4, varToVal a5])
	fromVariant (Variant (ValueStructure [a1, a2, a3, a4, a5])) = do
		a1' <- (fromVariant . Variant) a1
		a2' <- (fromVariant . Variant) a2
		a3' <- (fromVariant . Variant) a3
		a4' <- (fromVariant . Variant) a4
		a5' <- (fromVariant . Variant) a5
		return (a1', a2', a3', a4', a5')
	fromVariant _ = Nothing

instance (IsVariant a1, IsVariant a2, IsVariant a3, IsVariant a4, IsVariant a5, IsVariant a6) => IsVariant (a1, a2, a3, a4, a5, a6) where
	toVariant (a1, a2, a3, a4, a5, a6) = Variant (ValueStructure [varToVal a1, varToVal a2, varToVal a3, varToVal a4, varToVal a5, varToVal a6])
	fromVariant (Variant (ValueStructure [a1, a2, a3, a4, a5, a6])) = do
		a1' <- (fromVariant . Variant) a1
		a2' <- (fromVariant . Variant) a2
		a3' <- (fromVariant . Variant) a3
		a4' <- (fromVariant . Variant) a4
		a5' <- (fromVariant . Variant) a5
		a6' <- (fromVariant . Variant) a6
		return (a1', a2', a3', a4', a5', a6')
	fromVariant _ = Nothing

instance (IsVariant a1, IsVariant a2, IsVariant a3, IsVariant a4, IsVariant a5, IsVariant a6, IsVariant a7) => IsVariant (a1, a2, a3, a4, a5, a6, a7) where
	toVariant (a1, a2, a3, a4, a5, a6, a7) = Variant (ValueStructure [varToVal a1, varToVal a2, varToVal a3, varToVal a4, varToVal a5, varToVal a6, varToVal a7])
	fromVariant (Variant (ValueStructure [a1, a2, a3, a4, a5, a6, a7])) = do
		a1' <- (fromVariant . Variant) a1
		a2' <- (fromVariant . Variant) a2
		a3' <- (fromVariant . Variant) a3
		a4' <- (fromVariant . Variant) a4
		a5' <- (fromVariant . Variant) a5
		a6' <- (fromVariant . Variant) a6
		a7' <- (fromVariant . Variant) a7
		return (a1', a2', a3', a4', a5', a6', a7')
	fromVariant _ = Nothing

instance (IsVariant a1, IsVariant a2, IsVariant a3, IsVariant a4, IsVariant a5, IsVariant a6, IsVariant a7, IsVariant a8) => IsVariant (a1, a2, a3, a4, a5, a6, a7, a8) where
	toVariant (a1, a2, a3, a4, a5, a6, a7, a8) = Variant (ValueStructure [varToVal a1, varToVal a2, varToVal a3, varToVal a4, varToVal a5, varToVal a6, varToVal a7, varToVal a8])
	fromVariant (Variant (ValueStructure [a1, a2, a3, a4, a5, a6, a7, a8])) = do
		a1' <- (fromVariant . Variant) a1
		a2' <- (fromVariant . Variant) a2
		a3' <- (fromVariant . Variant) a3
		a4' <- (fromVariant . Variant) a4
		a5' <- (fromVariant . Variant) a5
		a6' <- (fromVariant . Variant) a6
		a7' <- (fromVariant . Variant) a7
		a8' <- (fromVariant . Variant) a8
		return (a1', a2', a3', a4', a5', a6', a7', a8')
	fromVariant _ = Nothing

instance (IsVariant a1, IsVariant a2, IsVariant a3, IsVariant a4, IsVariant a5, IsVariant a6, IsVariant a7, IsVariant a8, IsVariant a9) => IsVariant (a1, a2, a3, a4, a5, a6, a7, a8, a9) where
	toVariant (a1, a2, a3, a4, a5, a6, a7, a8, a9) = Variant (ValueStructure [varToVal a1, varToVal a2, varToVal a3, varToVal a4, varToVal a5, varToVal a6, varToVal a7, varToVal a8, varToVal a9])
	fromVariant (Variant (ValueStructure [a1, a2, a3, a4, a5, a6, a7, a8, a9])) = do
		a1' <- (fromVariant . Variant) a1
		a2' <- (fromVariant . Variant) a2
		a3' <- (fromVariant . Variant) a3
		a4' <- (fromVariant . Variant) a4
		a5' <- (fromVariant . Variant) a5
		a6' <- (fromVariant . Variant) a6
		a7' <- (fromVariant . Variant) a7
		a8' <- (fromVariant . Variant) a8
		a9' <- (fromVariant . Variant) a9
		return (a1', a2', a3', a4', a5', a6', a7', a8', a9')
	fromVariant _ = Nothing

instance (IsVariant a1, IsVariant a2, IsVariant a3, IsVariant a4, IsVariant a5, IsVariant a6, IsVariant a7, IsVariant a8, IsVariant a9, IsVariant a10) => IsVariant (a1, a2, a3, a4, a5, a6, a7, a8, a9, a10) where
	toVariant (a1, a2, a3, a4, a5, a6, a7, a8, a9, a10) = Variant (ValueStructure [varToVal a1, varToVal a2, varToVal a3, varToVal a4, varToVal a5, varToVal a6, varToVal a7, varToVal a8, varToVal a9, varToVal a10])
	fromVariant (Variant (ValueStructure [a1, a2, a3, a4, a5, a6, a7, a8, a9, a10])) = do
		a1' <- (fromVariant . Variant) a1
		a2' <- (fromVariant . Variant) a2
		a3' <- (fromVariant . Variant) a3
		a4' <- (fromVariant . Variant) a4
		a5' <- (fromVariant . Variant) a5
		a6' <- (fromVariant . Variant) a6
		a7' <- (fromVariant . Variant) a7
		a8' <- (fromVariant . Variant) a8
		a9' <- (fromVariant . Variant) a9
		a10' <- (fromVariant . Variant) a10
		return (a1', a2', a3', a4', a5', a6', a7', a8', a9', a10')
	fromVariant _ = Nothing

instance (IsVariant a1, IsVariant a2, IsVariant a3, IsVariant a4, IsVariant a5, IsVariant a6, IsVariant a7, IsVariant a8, IsVariant a9, IsVariant a10, IsVariant a11) => IsVariant (a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11) where
	toVariant (a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11) = Variant (ValueStructure [varToVal a1, varToVal a2, varToVal a3, varToVal a4, varToVal a5, varToVal a6, varToVal a7, varToVal a8, varToVal a9, varToVal a10, varToVal a11])
	fromVariant (Variant (ValueStructure [a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11])) = do
		a1' <- (fromVariant . Variant) a1
		a2' <- (fromVariant . Variant) a2
		a3' <- (fromVariant . Variant) a3
		a4' <- (fromVariant . Variant) a4
		a5' <- (fromVariant . Variant) a5
		a6' <- (fromVariant . Variant) a6
		a7' <- (fromVariant . Variant) a7
		a8' <- (fromVariant . Variant) a8
		a9' <- (fromVariant . Variant) a9
		a10' <- (fromVariant . Variant) a10
		a11' <- (fromVariant . Variant) a11
		return (a1', a2', a3', a4', a5', a6', a7', a8', a9', a10', a11')
	fromVariant _ = Nothing

instance (IsVariant a1, IsVariant a2, IsVariant a3, IsVariant a4, IsVariant a5, IsVariant a6, IsVariant a7, IsVariant a8, IsVariant a9, IsVariant a10, IsVariant a11, IsVariant a12) => IsVariant (a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12) where
	toVariant (a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12) = Variant (ValueStructure [varToVal a1, varToVal a2, varToVal a3, varToVal a4, varToVal a5, varToVal a6, varToVal a7, varToVal a8, varToVal a9, varToVal a10, varToVal a11, varToVal a12])
	fromVariant (Variant (ValueStructure [a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12])) = do
		a1' <- (fromVariant . Variant) a1
		a2' <- (fromVariant . Variant) a2
		a3' <- (fromVariant . Variant) a3
		a4' <- (fromVariant . Variant) a4
		a5' <- (fromVariant . Variant) a5
		a6' <- (fromVariant . Variant) a6
		a7' <- (fromVariant . Variant) a7
		a8' <- (fromVariant . Variant) a8
		a9' <- (fromVariant . Variant) a9
		a10' <- (fromVariant . Variant) a10
		a11' <- (fromVariant . Variant) a11
		a12' <- (fromVariant . Variant) a12
		return (a1', a2', a3', a4', a5', a6', a7', a8', a9', a10', a11', a12')
	fromVariant _ = Nothing

instance (IsVariant a1, IsVariant a2, IsVariant a3, IsVariant a4, IsVariant a5, IsVariant a6, IsVariant a7, IsVariant a8, IsVariant a9, IsVariant a10, IsVariant a11, IsVariant a12, IsVariant a13) => IsVariant (a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13) where
	toVariant (a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13) = Variant (ValueStructure [varToVal a1, varToVal a2, varToVal a3, varToVal a4, varToVal a5, varToVal a6, varToVal a7, varToVal a8, varToVal a9, varToVal a10, varToVal a11, varToVal a12, varToVal a13])
	fromVariant (Variant (ValueStructure [a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13])) = do
		a1' <- (fromVariant . Variant) a1
		a2' <- (fromVariant . Variant) a2
		a3' <- (fromVariant . Variant) a3
		a4' <- (fromVariant . Variant) a4
		a5' <- (fromVariant . Variant) a5
		a6' <- (fromVariant . Variant) a6
		a7' <- (fromVariant . Variant) a7
		a8' <- (fromVariant . Variant) a8
		a9' <- (fromVariant . Variant) a9
		a10' <- (fromVariant . Variant) a10
		a11' <- (fromVariant . Variant) a11
		a12' <- (fromVariant . Variant) a12
		a13' <- (fromVariant . Variant) a13
		return (a1', a2', a3', a4', a5', a6', a7', a8', a9', a10', a11', a12', a13')
	fromVariant _ = Nothing

instance (IsVariant a1, IsVariant a2, IsVariant a3, IsVariant a4, IsVariant a5, IsVariant a6, IsVariant a7, IsVariant a8, IsVariant a9, IsVariant a10, IsVariant a11, IsVariant a12, IsVariant a13, IsVariant a14) => IsVariant (a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14) where
	toVariant (a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14) = Variant (ValueStructure [varToVal a1, varToVal a2, varToVal a3, varToVal a4, varToVal a5, varToVal a6, varToVal a7, varToVal a8, varToVal a9, varToVal a10, varToVal a11, varToVal a12, varToVal a13, varToVal a14])
	fromVariant (Variant (ValueStructure [a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14])) = do
		a1' <- (fromVariant . Variant) a1
		a2' <- (fromVariant . Variant) a2
		a3' <- (fromVariant . Variant) a3
		a4' <- (fromVariant . Variant) a4
		a5' <- (fromVariant . Variant) a5
		a6' <- (fromVariant . Variant) a6
		a7' <- (fromVariant . Variant) a7
		a8' <- (fromVariant . Variant) a8
		a9' <- (fromVariant . Variant) a9
		a10' <- (fromVariant . Variant) a10
		a11' <- (fromVariant . Variant) a11
		a12' <- (fromVariant . Variant) a12
		a13' <- (fromVariant . Variant) a13
		a14' <- (fromVariant . Variant) a14
		return (a1', a2', a3', a4', a5', a6', a7', a8', a9', a10', a11', a12', a13', a14')
	fromVariant _ = Nothing

instance (IsVariant a1, IsVariant a2, IsVariant a3, IsVariant a4, IsVariant a5, IsVariant a6, IsVariant a7, IsVariant a8, IsVariant a9, IsVariant a10, IsVariant a11, IsVariant a12, IsVariant a13, IsVariant a14, IsVariant a15) => IsVariant (a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15) where
	toVariant (a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15) = Variant (ValueStructure [varToVal a1, varToVal a2, varToVal a3, varToVal a4, varToVal a5, varToVal a6, varToVal a7, varToVal a8, varToVal a9, varToVal a10, varToVal a11, varToVal a12, varToVal a13, varToVal a14, varToVal a15])
	fromVariant (Variant (ValueStructure [a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15])) = do
		a1' <- (fromVariant . Variant) a1
		a2' <- (fromVariant . Variant) a2
		a3' <- (fromVariant . Variant) a3
		a4' <- (fromVariant . Variant) a4
		a5' <- (fromVariant . Variant) a5
		a6' <- (fromVariant . Variant) a6
		a7' <- (fromVariant . Variant) a7
		a8' <- (fromVariant . Variant) a8
		a9' <- (fromVariant . Variant) a9
		a10' <- (fromVariant . Variant) a10
		a11' <- (fromVariant . Variant) a11
		a12' <- (fromVariant . Variant) a12
		a13' <- (fromVariant . Variant) a13
		a14' <- (fromVariant . Variant) a14
		a15' <- (fromVariant . Variant) a15
		return (a1', a2', a3', a4', a5', a6', a7', a8', a9', a10', a11', a12', a13', a14', a15')
	fromVariant _ = Nothing

-- | A value used to uniquely identify a particular message within a session.
-- 'Serial's are 32&#8208;bit unsigned integers, and eventually wrap.
newtype Serial = Serial Word32
	deriving (Eq, Ord, Show)

instance IsVariant Serial where
	toVariant (Serial x) = toVariant x
	fromVariant = fmap Serial . fromVariant

serialValue :: Serial -> Word32
serialValue (Serial x) = x

skipSepBy1 :: Parsec.Parser a -> Parsec.Parser b -> Parsec.Parser ()
skipSepBy1 p sep = do
	void p
	Parsec.skipMany (sep >> p)

runParser :: Parsec.Parser a -> Text -> Maybe a
runParser parser text = case Parsec.parse parser "" (Data.Text.unpack text) of
	Left _ -> Nothing
	Right a -> Just a

tryParse :: String -> (Text -> Maybe a) -> Text -> a
tryParse label parse text = case parse text of
	Just x -> x
	Nothing -> error ("Invalid " ++ label ++ ": " ++ show text)