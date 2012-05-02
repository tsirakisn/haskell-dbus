{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveDataTypeable #-}

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

module DBus.Client
	(
	-- * Clients
	  Client
	, ClientError
	, ClientOptions
	, clientTransports
	, clientAuthenticators
	, defaultClientOptions
	, connect
	, connectWith
	, disconnect
	, call
	, emit
	
	-- * Listening for signals
	, MatchRule(..)
	, listen
	
	-- * Exporting objects
	, Method
	, Reply(..)
	, throwError
	, method
	, export
	) where

import           Control.Concurrent
import           Control.Exception (SomeException)
import qualified Control.Exception
import           Control.Monad (forever, forM_)
import           Data.IORef
import           Data.List (foldl')
import qualified Data.Map
import           Data.Map (Map)
import           Data.Maybe (catMaybes)
import           Data.Text (Text)
import qualified Data.Text
import           Data.Typeable (Typeable)
import qualified Data.Set

import           DBus
import           DBus.Client.Error
import qualified DBus.Constants
import           DBus.Constants ( errorFailed, errorUnknownMethod
                                , errorInvalidParameters)
import qualified DBus.Introspection
import qualified DBus.Socket
import           DBus.Util (void)

data Client = Client
	{ clientSocket :: DBus.Socket.Socket
	, clientPendingCalls :: IORef (Map Serial (MVar (Either MethodError MethodReturn)))
	, clientSignalHandlers :: IORef [Signal -> IO ()]
	, clientObjects :: MVar (Map ObjectPath ObjectInfo)
	, clientThreadID :: ThreadId
	}

data ClientOptions = ClientOptions
	{ clientTransports :: [DBus.Socket.Transport]
	, clientAuthenticators :: [DBus.Socket.Authenticator]
	
	-- if specified, forces connection attempts to abort after the given
	-- number of milliseconds.
	, clientTimeout :: Maybe Integer
	
	-- whether the client should attempt to reconnect, if it loses its
	-- connection to the server. any pending method calls will fail with
	-- an error saying the connection was lost.
	, clientReconnect :: Bool
	}

type Callback = (ReceivedMessage -> IO ())

data Reply
	= ReplyReturn [Variant]
	| ReplyError ErrorName [Variant]

data Method = Method InterfaceName MemberName Signature Signature ([Variant] -> IO Reply)

type ObjectInfo = Map InterfaceName InterfaceInfo
type InterfaceInfo = Map MemberName MemberInfo
data MemberInfo
	= MemberMethod Signature Signature Callback
	| MemberSignal Signature

attach :: DBus.Socket.Socket -> IO Client
attach sock = do
	pendingCalls <- newIORef Data.Map.empty
	signalHandlers <- newIORef []
	objects <- newMVar Data.Map.empty
	
	clientMVar <- newEmptyMVar
	threadID <- forkIO $ do
		client <- readMVar clientMVar
		mainLoop client
	
	let client = Client
		{ clientSocket = sock
		, clientPendingCalls = pendingCalls
		, clientSignalHandlers = signalHandlers
		, clientObjects = objects
		, clientThreadID = threadID
		}
	putMVar clientMVar client
	
	export client "/" [introspectRoot client]
	
	void (call_ client (MethodCall
		{ methodCallPath = "/org/freedesktop/DBus"
		, methodCallMember = "Hello"
		, methodCallInterface = Just "org.freedesktop.DBus"
		, methodCallSender = Nothing
		, methodCallDestination = Just "org.freedesktop.DBus"
		, methodCallFlags = Data.Set.empty
		, methodCallBody = []
		}))
	
	return client

connect :: Address -> IO (Either ClientError Client)
connect = connectWith defaultClientOptions

connectWith :: ClientOptions -> Address -> IO (Either ClientError Client)
connectWith opts addr = do
	ret <- DBus.Socket.openWith (DBus.Socket.defaultSocketOptions
		{ DBus.Socket.socketTransports = clientTransports opts
		, DBus.Socket.socketAuthenticators = clientAuthenticators opts
		}) addr
	case ret of
		Left err -> return (Left (ClientError (show err)))
		Right conn -> Right `fmap` attach conn

-- | TODO
defaultClientOptions :: ClientOptions
defaultClientOptions = ClientOptions
	{ clientTransports = DBus.Socket.socketTransports DBus.Socket.defaultSocketOptions
	, clientAuthenticators = DBus.Socket.socketAuthenticators DBus.Socket.defaultSocketOptions
	, clientTimeout = Nothing
	, clientReconnect = True
	}

-- | Stop a 'Client''s callback thread and close its underlying socket.
disconnect :: Client -> IO ()
disconnect client = do
	killThread (clientThreadID client)
	disconnect' client

disconnect' :: Client -> IO ()
disconnect' client = do
	pendingCalls <- atomicModifyIORef (clientPendingCalls client) (\p -> (Data.Map.empty, p))
	forM_ (Data.Map.toList pendingCalls) $ \(k, v) -> do
		let err = MethodError "org.haskell.hackage.dbus.ClientError" k Nothing Nothing [toVariant ("connection closed during call" :: String)]
		putMVar v (Left err)
	
	atomicModifyIORef (clientSignalHandlers client) (\_ -> ([], ()))
	modifyMVar_ (clientObjects client) (\_ -> return Data.Map.empty)
	let sock = clientSocket client
	DBus.Socket.close sock

mainLoop :: Client -> IO ()
mainLoop client = forever $ do
	let sock = clientSocket client
	
	received <- DBus.Socket.receive sock
	msg <- case received of
		Left err -> do
			disconnect' client
			clientError ("Received invalid message: " ++ show err)
		Right msg -> return msg
	
	dispatch client msg

dispatch :: Client -> ReceivedMessage -> IO ()
dispatch client received = void . forkIO $ do
	let onReply serial result = do
		pending <- atomicModifyIORef
			(clientPendingCalls client)
			(\p -> case Data.Map.lookup serial p of
				Nothing -> (p, Nothing)
				Just mvar -> (Data.Map.delete serial p, Just mvar))
		case pending of
			Just mvar -> putMVar mvar result
			Nothing -> return ()
	
	case received of
		(ReceivedMethodReturn _ msg) -> onReply (methodReturnSerial msg) (Right msg)
		(ReceivedMethodError _ msg) -> onReply (methodErrorSerial msg) (Left msg)
		(ReceivedSignal _ msg) -> do
			handlers <- readIORef (clientSignalHandlers client)
			mapM_ ($ msg) handlers
		(ReceivedMethodCall serial msg) -> do
			objects <- readMVar (clientObjects client)
			let sender = methodCallSender msg
			case findMethod objects msg of
				Just io -> io received
				Nothing -> send_ client
					(MethodError errorUnknownMethod serial Nothing sender [])
					(\_ -> return ())
		_ -> return ()

send_ :: Message msg => Client -> msg -> (Serial -> IO a) -> IO a
send_ client msg io = do
	result <- DBus.Socket.send (clientSocket client) msg io
	case result of
		Right serial -> return serial
		Left err -> clientError ("Error sending message: " ++ show err)

call :: Client -> MethodCall -> IO (Either MethodError MethodReturn)
call client msg = do
	mvar <- newEmptyMVar
	send_ client msg (\serial -> atomicModifyIORef
		(clientPendingCalls client)
		(\p -> (Data.Map.insert serial mvar p, ())))
	takeMVar mvar

call_ :: Client -> MethodCall -> IO MethodReturn
call_ client msg = do
	result <- call client msg
	case result of
		Left err -> clientError ("Call failed: " ++ Data.Text.unpack (methodErrorMessage err))
		Right ret -> return ret

emit :: Client -> Signal -> IO ()
emit client msg = send_ client msg (\_ -> return ())

data MatchRule = MatchRule
	{ matchSender      :: Maybe BusName
	, matchDestination :: Maybe BusName
	, matchPath        :: Maybe ObjectPath
	, matchInterface   :: Maybe InterfaceName
	, matchMember      :: Maybe MemberName
	}
	deriving (Show)

listen :: Client -> MatchRule -> (BusName -> Signal -> IO ()) -> IO ()
listen client rule io = do
	let handler msg = case signalSender msg of
		Just sender -> if checkMatchRule rule sender msg
			then io sender msg
			else return ()
		Nothing -> return ()
	
	atomicModifyIORef (clientSignalHandlers client) (\hs -> (handler : hs, ()))
	void (call_ client (MethodCall
		{ methodCallPath = DBus.Constants.dbusPath
		, methodCallMember = "AddMatch"
		, methodCallInterface = Just DBus.Constants.dbusInterface
		, methodCallSender = Nothing
		, methodCallDestination = Just DBus.Constants.dbusName
		, methodCallFlags = Data.Set.empty
		, methodCallBody = [toVariant (formatMatchRule rule)]
		}))

formatMatchRule :: MatchRule -> Text
formatMatchRule rule = Data.Text.intercalate "," predicates where
	predicates = catMaybes
		[ f "sender" matchSender busNameText
		, f "destination" matchDestination busNameText
		, f "path" matchPath objectPathText
		, f "interface" matchInterface interfaceNameText
		, f "member" matchMember memberNameText
		]
	
	f :: Text -> (MatchRule -> Maybe a) -> (a -> Text) -> Maybe Text
	f key get text = do
		val <- fmap text (get rule)
		return (Data.Text.concat [key, "='", val, "'"])

checkMatchRule :: MatchRule -> BusName -> Signal -> Bool
checkMatchRule rule sender msg = and
	[ maybe True (== sender) (matchSender rule)
	, maybe True (\x -> signalDestination msg == Just x) (matchDestination rule)
	, maybe True (== signalPath msg) (matchPath rule)
	, maybe True (== signalInterface msg) (matchInterface rule)
	, maybe True (== signalMember msg) (matchMember rule)
	]

data MethodExc = MethodExc ErrorName [Variant]
	deriving (Show, Eq, Typeable)

instance Control.Exception.Exception MethodExc

-- | Normally, any exceptions raised while executing a method will be
-- given the generic @\"org.freedesktop.DBus.Error.Failed\"@ name.
-- 'throwError' allows the programmer to specify an error name, and provide
-- additional information to the remote application. You may use this instead
-- of 'Control.Exception.throwIO' to abort a method call.
throwError :: ErrorName -> Text -> [Variant] -> IO a
throwError name message extra = Control.Exception.throwIO (MethodExc name (toVariant message : extra))

method :: InterfaceName -> MemberName -> Signature -> Signature -> ([Variant] -> IO Reply) -> Method
method iface name inSig outSig io = Method iface name inSig outSig
	(\vs -> Control.Exception.catch
		(Control.Exception.catch
			(io vs)
			(\(MethodExc name' vs') -> return (ReplyError name' vs')))
		(\exc -> return (ReplyError errorFailed
			[toVariant (Data.Text.pack (show (exc :: SomeException)))])))

export :: Client -> ObjectPath -> [Method] -> IO ()
export client path methods = modifyMVar_ (clientObjects client) addObject where
	addObject objs = return (Data.Map.insert path info objs)
	
	info = foldl' addMethod Data.Map.empty (defaultIntrospect : methods)
	addMethod m (Method iface name inSig outSig cb) = Data.Map.insertWith'
		Data.Map.union iface
		(Data.Map.fromList [(name, MemberMethod inSig outSig (wrapCB cb))]) m
	
	wrapCB cb (ReceivedMethodCall serial msg) = do
		reply <- cb (methodCallBody msg)
		let sender = methodCallSender msg
		case reply of
			ReplyReturn vs -> send_ client (MethodReturn serial Nothing sender vs) (\_ -> return ())
			ReplyError name vs -> send_ client (MethodError name serial Nothing sender vs) (\_ -> return ())
	wrapCB _ _ = return ()
	
	defaultIntrospect = methodIntrospect $ do
		objects <- readMVar (clientObjects client)
		let Just obj = Data.Map.lookup path objects
		return (introspect path obj)

findMethod :: Map ObjectPath ObjectInfo -> MethodCall -> Maybe Callback
findMethod objects msg = do
	ifaceName <- methodCallInterface msg
	obj <- Data.Map.lookup (methodCallPath msg) objects
	iface <- Data.Map.lookup ifaceName obj
	member <- Data.Map.lookup (methodCallMember msg) iface
	case member of
		MemberMethod _ _ io -> return io
		_ -> Nothing

introspectRoot :: Client -> Method
introspectRoot client = methodIntrospect $ do
	objects <- readMVar (clientObjects client)
	let paths = filter (/= "/") (Data.Map.keys objects)
	let iface = "org.freedesktop.DBus.Introspectable"
	let name = "Introspect"
	return (DBus.Introspection.Object "/"
		[DBus.Introspection.Interface iface
			[DBus.Introspection.Method name
				[]
				[DBus.Introspection.Parameter "" TypeString]]
			[] []]
		[DBus.Introspection.Object p [] [] | p <- paths])

methodIntrospect :: IO DBus.Introspection.Object -> Method
methodIntrospect get = method iface name "" "s" impl where
	iface = "org.freedesktop.DBus.Introspectable"
	name = "Introspect"
	impl [] = do
		obj <- get
		let Just xml = DBus.Introspection.toXML obj
		return (ReplyReturn [toVariant xml])
	impl _ = return (ReplyError errorInvalidParameters [])

introspect :: ObjectPath -> ObjectInfo -> DBus.Introspection.Object
introspect path obj = DBus.Introspection.Object path interfaces [] where
	interfaces = map introspectIface (Data.Map.toList obj)
	
	introspectIface (name, iface) = let
		members = Data.Map.toList iface
		methods = concatMap introspectMethod members
		signals = concatMap introspectSignal members
		in DBus.Introspection.Interface name methods signals []
	
	introspectMethod (name, (MemberMethod inSig outSig _)) =
		[DBus.Introspection.Method name
			(map introspectParam (signatureTypes inSig))
			(map introspectParam (signatureTypes outSig))]
	introspectMethod _ = []
	
	introspectSignal (name, (MemberSignal sig)) =
		[DBus.Introspection.Signal name
			(map introspectParam (signatureTypes sig))]
	introspectSignal _ = []
	
	introspectParam = DBus.Introspection.Parameter ""
