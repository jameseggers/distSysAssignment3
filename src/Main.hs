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
chatroomToLeave :: Text, leftChatroom :: Text } deriving (Show)

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
  let stripedMessage = strip $ pack message
  let parsedMessage = parseMessage stripedMessage
  case (messageType (fromJust parsedMessage)) of
    "JOIN_CHATROOM" -> handleJoinChatroom sock parsedMessage channel 1
    "LEAVE_CHATROOM" -> handleLeaveChatroom sock parsedMessage channel 1
  runServer (sock,addr) channel

listenForMessagesFromOthers :: Socket -> Chan Message -> Int -> Maybe Message -> IO ()
listenForMessagesFromOthers sock channel chatroomRef message = do
  receivedMessage <- readChan channel
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
    "LEAVE_CHATROOM" -> do
      send sock ("LEFT_CHATROOM: "++(show $ roomRef receivedMessage)++"\nJOIN_ID: "++(show $ joinId receivedMessage))
      killThread threadId
      return ()

handleLeaveChatroom :: Socket -> Maybe Message -> Chan Message -> Int -> IO ()
handleLeaveChatroom _ Nothing _ _ = return ()
handleLeaveChatroom sock message channel 3 = writeChan channel (fromJust message)
handleLeaveChatroom sock message channel numMessagesReceived = do
  messageReceived <- recv sock 4096
  let messageValue = ((splitOn ":" messageReceived) !! 1)
  let newMessage = case numMessagesReceived of
                      1 -> Just actualMessage { clientIp = "0", port = 0 }
                      2 -> Just actualMessage { joinId = read messageValue :: Int }
                      3 -> Just actualMessage { clientName = pack messageValue }
  handleLeaveChatroom sock newMessage channel (numMessagesReceived + 1)
  where actualMessage = fromJust message

handleJoinChatroom :: Socket -> Maybe Message -> Chan Message -> Int -> IO ()
handleJoinChatroom _ Nothing _ _ = return ()
handleJoinChatroom sock message channel 4 = do
  newChannel <- dupChan channel
  let justMessage = fromJust message
  let roomReference = hash $ unpack $ (chatroomToJoin justMessage)
  let joinId =  hash $ unpack $ (chatroomToJoin justMessage) `append` (clientName justMessage)
  forkIO (listenForMessagesFromOthers sock newChannel roomReference message)
  let reply = Message { messageType = "JOINED_CHATROOM", clientIp = "123", port = 4342, clientName = "james",
joinedChatRoom = (joinedChatRoom justMessage), roomRef = roomReference, joinId = joinId }
  writeChan channel reply
  return ()

handleJoinChatroom sock message channel numMessagesReceived = do
  messageReceived <- recv sock 4096
  let messageValue = pack $ ((splitOn ":" messageReceived) !! 1)
  let newMessage = case numMessagesReceived of
                      1 -> Just actualMessage { clientIp = "0", joinedChatRoom = (chatroomToJoin actualMessage) }
                      2 -> Just actualMessage { port = 0 }
                      3 -> Just actualMessage { clientName = messageValue }
  handleJoinChatroom sock newMessage channel newNumMessagesReceived
  where newNumMessagesReceived = numMessagesReceived + 1
        actualMessage = fromJust message

getJoinedRoomMessage :: Message -> String
getJoinedRoomMessage receivedMessage = ("JOINED_CHATROOM: "++(unpack (joinedChatRoom receivedMessage))++"\nSERVER_IP:#{server_ip}\nPORT:0\nROOM_REF: "++(show $ roomRef receivedMessage)++"\nJOIN_ID: "++(show $ joinId receivedMessage)++"\n")

parseMessage :: Text -> Maybe Message
parseMessage message
  | Data.List.isPrefixOf "JOIN_CHATROOM" stringMessage = Just Message { messageType = "JOIN_CHATROOM", chatroomToJoin = (pack nameOfChatroom) }
  | Data.List.isPrefixOf "LEAVE_CHATROOM" stringMessage = Just Message { messageType = "LEAVE_CHATROOM", roomRef = read stringMessage :: Int }
  | Data.List.isPrefixOf "CHAT" stringMessage = Just Message { messageType = "CHAT"}
  | otherwise = Nothing
  where stringMessage = unpack message
        nameOfChatroom = (splitOn ":" (unpack message)) !! 1
