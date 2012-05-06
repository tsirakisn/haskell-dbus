{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

-- Copyright (C) 2010-2012 John Millikin <jmillikin@gmail.com>
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

module DBusTests.Signature (test_Signature) where

import           Test.Chell
import           Test.Chell.QuickCheck
import           Test.QuickCheck hiding ((.&.), property)

import           Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as Char8
import qualified Data.Text as T

import           DBus

import           DBusTests.Util

test_Signature :: Suite
test_Signature = suite "Signature"
	[ test_BuildSignature
	, test_ParseSignature
	, test_ParseInvalid
	, test_FormatSignature
	, test_IsAtom
	, test_ShowType
	]

test_BuildSignature :: Suite
test_BuildSignature = property "signature" prop where
	prop = forAll gen_SignatureTypes check
	check types = case signature types of
		Nothing -> False
		Just sig -> signatureTypes sig == types

test_ParseSignature :: Suite
test_ParseSignature = property "parseSignature" prop where
	prop = forAll gen_SignatureBytes check
	check (bytes, types) = case parseSignature bytes of
		Nothing -> False
		Just sig -> signatureTypes sig == types

test_ParseInvalid :: Suite
test_ParseInvalid = assertions "parse-invalid" $ do
	-- struct code
	$expect (nothing (parseSignature "r"))
	
	-- empty struct
	$expect (nothing (parseSignature "()"))
	
	-- dict code
	$expect (nothing (parseSignature "e"))
	
	-- non-atomic dict key
	$expect (nothing (parseSignature "a{vy}"))
	
	-- unix fd (intentionally not supported in haskell-dbus)
	$expect (nothing (parseSignature "h"))
	
	-- at most 255 characters
	$expect (just (parseSignature (Char8.replicate 254 'y')))
	$expect (just (parseSignature (Char8.replicate 255 'y')))
	$expect (nothing (parseSignature (Char8.replicate 256 'y')))
	
	-- length also enforced by 'signature'
	$expect (just (signature (replicate 255 TypeWord8)))
	$expect (nothing (signature (replicate 256 TypeWord8)))

test_FormatSignature :: Suite
test_FormatSignature = property "formatSignature" prop where
	prop = forAll gen_SignatureBytes check
	check (bytes, _) = let
		Just sig = parseSignature bytes
		in T.unpack (signatureText sig) == Char8.unpack bytes

test_IsAtom :: Suite
test_IsAtom = assertions "IsAtom" $ do
	let Just sig = signature []
	assertAtom TypeSignature sig

test_ShowType :: Suite
test_ShowType = assertions "show-type" $ do
	$expect (equal "Bool" (show TypeBoolean))
	$expect (equal "Bool" (show TypeBoolean))
	$expect (equal "Word8" (show TypeWord8))
	$expect (equal "Word16" (show TypeWord16))
	$expect (equal "Word32" (show TypeWord32))
	$expect (equal "Word64" (show TypeWord64))
	$expect (equal "Int16" (show TypeInt16))
	$expect (equal "Int32" (show TypeInt32))
	$expect (equal "Int64" (show TypeInt64))
	$expect (equal "Double" (show TypeDouble))
	$expect (equal "String" (show TypeString))
	$expect (equal "Signature" (show TypeSignature))
	$expect (equal "ObjectPath" (show TypeObjectPath))
	$expect (equal "Variant" (show TypeVariant))
	$expect (equal "[Word8]" (show (TypeArray TypeWord8)))
	$expect (equal "Map Word8 (Map Word8 Word8)" (show (TypeDictionary TypeWord8 (TypeDictionary TypeWord8 TypeWord8))))
	$expect (equal "(Word8, Word16)" (show (TypeStructure [TypeWord8, TypeWord16])))

gen_SignatureTypes :: Gen [Type]
gen_SignatureTypes = do
	(_, ts) <- gen_SignatureBytes
	return ts

gen_SignatureBytes :: Gen (ByteString, [Type])
gen_SignatureBytes = gen where
	anyType = oneof [atom, container]
	atom = elements
		[ ("b", TypeBoolean)
		, ("y", TypeWord8)
		, ("q", TypeWord16)
		, ("u", TypeWord32)
		, ("t", TypeWord64)
		, ("n", TypeInt16)
		, ("i", TypeInt32)
		, ("x", TypeInt64)
		, ("d", TypeDouble)
		, ("s", TypeString)
		, ("o", TypeObjectPath)
		, ("g", TypeSignature)
		]
	container = oneof
		[ return ("v", TypeVariant)
		, array
		, dict
		, struct
		]
	array = do
		(tCode, tEnum) <- anyType
		return ('a':tCode, TypeArray tEnum)
	dict = do
		(kCode, kEnum) <- atom
		(vCode, vEnum) <- anyType
		return (concat ["a{", kCode, vCode, "}"], TypeDictionary kEnum vEnum)
	struct = do
		ts <- listOf1 (halfSized anyType)
		let (codes, enums) = unzip ts
		return ("(" ++ concat codes ++ ")", TypeStructure enums)
	gen = do
		types <- listOf anyType
		let (codes, enums) = unzip types
		let chars = concat codes
		if length chars > 255
			then halfSized gen
			else return (Char8.pack chars, enums)

instance Arbitrary Signature where
	arbitrary = do
		ts <- gen_SignatureTypes
		let Just sig = signature ts
		return sig