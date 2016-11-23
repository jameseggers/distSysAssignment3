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
leaveChatroom :: Text, leftChatroom :: Text } deriving (Show)

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
  ret <- case (messageType (fromJust parsedMessage)) of
    "JOIN_CHATROOM" -> handleJoinChatroom sock parsedMessage channel 1
    -- "CHAT" -> handleChat sock parsedMessage channel
  runServer (sock,addr) channel

listenForMessagesFromOthers :: Socket -> Chan Message -> Int -> Maybe Message -> IO ()
listenForMessagesFromOthers sock channel chatroomRef message = do
  receivedMessage <- readChan channel
  if (roomRef receivedMessage) == chatroomRef
    then dealWithChannelMessage sock channel receivedMessage
    else (send sock "")
  listenForMessagesFromOthers sock channel chatroomRef message

dealWithChannelMessage :: Socket -> Chan Message -> Message -> IO Int
dealWithChannelMessage sock channel receivedMessage = do
  let reply = case (messageType receivedMessage) of
                "JOINED_CHATROOM" -> ("JOINED_CHATROOM:"++(unpack (joinedChatRoom receivedMessage))++"\nSERVER_IP:#{server_ip}\nPORT:0\nROOM_REF:1\nJOIN_ID:#{user_reference}\n")
  send sock reply

-- handleChat :: Socket -> Maybe Message -> Chan Message -> IO ()
-- handleChat sock message channel

handleJoinChatroom :: Socket -> Maybe Message -> Chan Message -> Int -> IO (Maybe Message)
handleJoinChatroom _ Nothing _ _ = return Nothing
handleJoinChatroom sock message channel 4 = do
  newChannel <- dupChan channel
  let justMessage = fromJust message
  let roomReference = hash $ unpack $ (chatroomToJoin justMessage)
  forkIO (listenForMessagesFromOthers sock newChannel roomReference message)
  let reply = Message { messageType = "JOINED_CHATROOM", clientIp = "123", port = 4342, clientName = "james",
joinedChatRoom = (joinedChatRoom justMessage), roomRef = roomReference, joinId = 1 }
  writeChan channel reply
  return message

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

parseMessage :: Text -> Maybe Message
parseMessage message
  | Data.List.isPrefixOf "JOIN_CHATROOM" stringMessage = Just Message { messageType = "JOIN_CHATROOM", chatroomToJoin = message }
  | Data.List.isPrefixOf "LEAVE_CHATROOM" stringMessage = Just Message { messageType = "LEAVE_CHATROOM" }
  | Data.List.isPrefixOf "CHAT" stringMessage = Just Message { messageType = "CHAT"}
  | otherwise = Nothing
  where stringMessage = unpack message
