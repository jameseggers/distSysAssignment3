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
  putStrLn $ show (fromJust ret)
  -- runServer (sock,addr) channel

listenForMessagesFromOthers :: Socket -> Chan Message -> Maybe Message -> IO ()
listenForMessagesFromOthers sock channel message = do
  receivedMessage <- readChan channel
  if (messageType receivedMessage) == "lol omg"
    then putStrLn "hi"
    else putStrLn "bye"

-- handleChat :: Socket -> Maybe Message -> Chan Message -> IO ()
-- handleChat sock message channel

handleJoinChatroom :: Socket -> Maybe Message -> Chan Message -> Int -> IO (Maybe Message)
-- handleJoinChatroom _ Nothing _ _ = return Nothing
handleJoinChatroom sock message channel 4 = do
  newChannel <- dupChan channel
  forkIO (listenForMessagesFromOthers sock newChannel message)
  send sock (unpack "hi")--(show $ fromJust message)
  return message
handleJoinChatroom sock message channel numMessagesReceived = do
  messageReceived <- recv sock 4096
  let messageValue = pack $ (splitOn ":" messageReceived) !! 1
  let newMessage = case numMessagesReceived of
                      1 -> Just actualMessage { clientIp = "0" }
                      2 -> Just actualMessage { port = 0 }
                      3 -> Just actualMessage { clientName = messageValue }
  handleJoinChatroom sock newMessage channel newNumMessagesReceived
  where newNumMessagesReceived = numMessagesReceived + 1
        actualMessage = fromJust message

parseMessage :: Text -> Maybe Message
parseMessage message
  | Data.List.isPrefixOf "JOIN_CHATROOM" stringMessage = Just defaultMessage { messageType = "JOIN_CHATROOM" }
  | Data.List.isPrefixOf "LEAVE_CHATROOM" stringMessage = Just defaultMessage { messageType = "LEAVE_CHATROOM" }
  | Data.List.isPrefixOf "CHAT" stringMessage = Just defaultMessage { messageType = "CHAT"}
  | otherwise = Nothing
  where stringMessage = unpack message

respondToMessage :: SockAddr -> Text -> String
respondToMessage addr message
  | (Data.List.isPrefixOf "KILL_SERVICE" stringMessage) = "die"
  | (Data.List.isPrefixOf "HELO" stringMessage) = stringMessage++"\nIP:178.62.42.127\nPort:"++justPort++"\nStudentID:13330379\n"
  | (Data.List.isPrefixOf "JOIN_CHATROOM" stringMessage) = "join"
  | otherwise = ""
  where address = (show addr)
        splitedAddress = splitOn ":" address
        justPort = "4243"
        stringMessage = unpack message

defaultMessage :: Message
defaultMessage = Message { messageType = "default", clientIp = "default",
port = 0, clientName = "default", chatroomToJoin = "default", joinedChatRoom = "default",
roomRef = 0, joinId = 0, errorCode = 0, errorDescription = "default",
leaveChatroom = "default", leftChatroom = "default" }
