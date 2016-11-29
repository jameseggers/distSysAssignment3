{-# LANGUAGE OverloadedStrings #-}

module Main where

import Network.Socket
import Data.Text hiding (head, tail, splitOn, length)
import Data.List.Split
import Data.List
import Control.Concurrent
import Control.Concurrent.Chan
import Network.Info
import Data.Maybe
import System.IO.Unsafe  -- be careful!
import System.Random
import Data.Hashable

type Msg = String

data Message = Message { messageType :: Text, clientIp :: Text,
port :: Int, clientName :: Text, chatroomToJoin :: Text, joinedChatRoom :: Text,
roomRef :: Int, joinId :: Int, errorCode :: Int, errorDescription :: Text,
chatroomToLeave :: Text, leftChatroom :: Text, messageText :: Text } deriving (Show)

main :: IO ()
main = withSocketsDo $ do
  let numberOfActiveThreads = 0
  let maximumThreads = 25
  sock <- socket socketFamily socketType defaultProtocol
  setSocketOption sock ReuseAddr 1
  bind sock address
  listen sock 2
  channel <- newChan
  waitForConnection sock channel [] maximumThreads
  where socketType = Stream
        socketFamily = AF_INET
        address = SockAddrInet 4243 iNADDR_ANY

waitForConnection :: Socket -> Chan Message -> [Socket] -> Int -> IO ()
waitForConnection sock channel runningSockets maximumNumberOfThreads = do
  conn <- accept sock
  activeSockets <- numberOfActiveSockets runningSockets 0
  threadId <- forkIO (runServer conn channel)
  let runningSocketsWithNewSocket = addNewSocket conn runningSockets maximumNumberOfThreads
  if (activeSockets >= maximumNumberOfThreads)
    then (killThread threadId) >> sClose (fst conn)
    else return ()
  waitForConnection sock channel runningSocketsWithNewSocket maximumNumberOfThreads

numberOfActiveSockets :: [Socket] -> Int -> IO Int
numberOfActiveSockets [] runningSockets = return runningSockets
numberOfActiveSockets (sock:socks) runningSockets = do
  isSockWritable <- isWritable sock
  if isSockWritable == True
    then numberOfActiveSockets socks (runningSockets + 1)
    else numberOfActiveSockets socks runningSockets

addNewSocket :: (Socket, SockAddr) -> [Socket] -> Int -> [Socket]
addNewSocket (sock, _) sockets maxSockets
  | (length sockets) == maxSockets = sockets
  | otherwise = sockets ++ [sock]

runServer :: (Socket, SockAddr) -> Chan Message -> IO ()
runServer (sock, addr) channel = do
  message <- recv sock 4096
  putStrLn message
  let stripedMessage = strip $ pack message
  let parsedMessage = parseMessage stripedMessage
  handleMessageByType parsedMessage sock channel
  runServer (sock,addr) channel

handleMessageByType :: Maybe Message -> Socket -> Chan Message -> IO ()
handleMessageByType Nothing _ _ = return ()
handleMessageByType message sock channel = do
  let justMessage = fromJust message
  case (messageType justMessage) of
    "JOIN_CHATROOM" -> handleJoinChatroom sock message channel
    "LEAVE_CHATROOM" -> handleLeaveChatroom sock message channel
    "CHAT" -> handleChat sock message channel
    "LEGACY" -> send sock (unpack (messageText justMessage)) >> return ()
    "KILL" -> sClose sock >> return ()

listenForMessagesFromOthers :: Socket -> Chan Message -> Int -> Maybe Message -> IO ()
listenForMessagesFromOthers sock channel chatroomRef message = do
  receivedMessage <- readChan channel
  putStrLn (show (roomRef receivedMessage))
  putStrLn (show chatroomRef)
  if (roomRef receivedMessage) == chatroomRef
    then dealWithChannelMessage sock channel receivedMessage
    else return ()
  listenForMessagesFromOthers sock channel chatroomRef message

dealWithChannelMessage :: Socket -> Chan Message -> Message -> IO ()
dealWithChannelMessage sock channel receivedMessage = do
  threadId <- myThreadId
  case (messageType receivedMessage) of
    "JOINED_CHATROOM" -> do
      send sock (getJoinedRoomMessage receivedMessage)
      return ()
    "CHAT" -> do
      send sock (getChatResponseMessage receivedMessage)
      return ()
    "LEAVE_CHATROOM" -> do
      killThread threadId
      return ()
    otherwise -> do
      return ()

handleChat :: Socket -> Maybe Message -> Chan Message -> IO ()
handleChat _ Nothing _ = return ()
handleChat sock message channel = do
  newChannel <- dupChan channel
  writeChan channel (fromJust message)
  return ()

handleLeaveChatroom :: Socket -> Maybe Message -> Chan Message -> IO ()
handleLeaveChatroom _ Nothing _ = return ()
handleLeaveChatroom sock message channel = do
  let justMessage = fromJust message
  let reply = Message { messageType = "CHAT", clientIp = "0", port = 0, clientName = (clientName justMessage),
leftChatroom = (chatroomToJoin justMessage), roomRef = (roomRef justMessage), joinId = (joinId justMessage), messageText = (clientName justMessage) `append` " has left this chatroom." }
  send sock (getLeftRoomMessage reply) >> writeChan channel reply

handleJoinChatroom :: Socket -> Maybe Message -> Chan Message -> IO ()
handleJoinChatroom _ Nothing _ = return ()
handleJoinChatroom sock message channel = do
  newChannel <- dupChan channel
  let justMessage = fromJust message
  let roomReference = hash $ unpack $ (chatroomToJoin justMessage)
  let joinId =  hash $ unpack $ (chatroomToJoin justMessage) `append` (clientName justMessage)
  forkIO (listenForMessagesFromOthers sock newChannel roomReference message)
  let reply = Message { messageType = "CHAT", clientIp = "0", port = 0, clientName = (clientName justMessage),
joinedChatRoom = (chatroomToJoin justMessage), roomRef = roomReference, joinId = joinId, messageText = (clientName justMessage) `append` " has joined this chatroom." }
  send sock (getJoinedRoomMessage reply) >> writeChan channel reply
  return ()

getJoinedRoomMessage :: Message -> String
getJoinedRoomMessage receivedMessage = ("JOINED_CHATROOM: "++(unpack (joinedChatRoom receivedMessage))++"\nSERVER_IP:45.55.165.67\nPORT:4243\nROOM_REF: "++(show $ roomRef receivedMessage)++"\nJOIN_ID: "++(show $ joinId receivedMessage)++"\n")

getLeftRoomMessage :: Message -> String
getLeftRoomMessage receivedMessage = ("LEFT_CHATROOM: "++(show $ roomRef receivedMessage)++"\nJOIN_ID: "++(show $ joinId receivedMessage) ++ "\n")

getChatResponseMessage :: Message -> String
getChatResponseMessage message = ("CHAT: " ++ (show (roomRef message)) ++ "\nCLIENT_NAME: " ++ (unpack (clientName message)) ++ "\nMESSAGE: " ++ (unpack (messageText message)) ++ "\n\n")

parseMessage :: Text -> Maybe Message
parseMessage message
  | Data.List.isPrefixOf "JOIN_CHATROOM" stringMessage = Just Message { messageType = "JOIN_CHATROOM", chatroomToJoin = getValue (splitByLine !! 0) ":", clientIp = "0", port = 0, clientName = getValue (splitByLine !! 3) ":" }
  | Data.List.isPrefixOf "LEAVE_CHATROOM" stringMessage = Just Message { messageType = "LEAVE_CHATROOM", roomRef = readAsInt (getValue (splitByLine !! 0) ":"), joinId = readAsInt (getValue (splitByLine !! 1) ":"), clientName = getValue (splitByLine !! 2) ":" }
  | Data.List.isPrefixOf "CHAT" stringMessage = Just Message { messageType = "CHAT", roomRef = readAsInt (getValue (splitByLine !! 0) ":"), joinId = readAsInt (getValue (splitByLine !! 1) ":"), clientName = getValue (splitByLine !! 2) ":", messageText = getValue (splitByLine !! 3) ":"}
  | Data.List.isPrefixOf "DISCONNECT" stringMessage = Just Message { messageType = "DISCONNECT" }
  | Data.List.isPrefixOf "HELO" stringMessage = Just Message { messageType = "LEGACY", messageText = "HELO " `append` (getValue (splitByLine !! 0) " ") `append` "\nIP:45.55.165.67\nPort:4243\nStudentID:13330379\n"}
  | Data.List.isPrefixOf "KILL_SERVICE" stringMessage = Just Message { messageType = "KILL" }
  | otherwise = Nothing
  where stringMessage = unpack message
        splitByLine = splitOn "\\n" stringMessage
        -- splitByLine = Data.List.lines stringMessage
        -- messageValue = (splitOn ":" (unpack message)) !! 1

readAsInt :: Text -> Int
readAsInt string = read (unpack string) :: Int

getValue :: String -> String -> Text
getValue line delimiter = pack ((splitOn delimiter line) !! 1)
