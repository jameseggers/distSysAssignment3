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
import Data.Hashable

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
  newChannel <- dupChan channel
  activeSockets <- numberOfActiveSockets runningSockets 0
  threadId <- forkIO (runServer conn newChannel)
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

listenForMessagesFromOthers :: Socket -> Chan Message -> Int -> Int -> Maybe Message -> IO ()
listenForMessagesFromOthers sock channel chatroomRef joinIdHash message = do
  receivedMessage <- readChan channel
  putStrLn "---"
  putStrLn (show joinIdHash)
  putStrLn (show (joinId receivedMessage))
  putStrLn (show chatroomRef)
  putStrLn (show (roomRef receivedMessage))
  putStrLn (unpack (messageType receivedMessage))
  putStrLn (unpack (messageText receivedMessage))
  putStrLn "---"
  if (roomRef receivedMessage) == chatroomRef
    then case (messageType receivedMessage) of
          "CHAT" -> do
            send sock (getChatResponseMessage receivedMessage)
            listenForMessagesFromOthers sock channel chatroomRef joinIdHash message
          "LEAVE_CHATROOM" -> do
            if joinIdHash == (joinId receivedMessage)
              then return ()
              else listenForMessagesFromOthers sock channel chatroomRef joinIdHash message
          otherwise -> listenForMessagesFromOthers sock channel chatroomRef joinIdHash message
    else do
      --writeChan channel receivedMessage
      listenForMessagesFromOthers sock channel chatroomRef joinIdHash message

handleChat :: Socket -> Maybe Message -> Chan Message -> IO ()
handleChat _ Nothing _ = return ()
handleChat sock message channel = writeChan channel (fromJust message)

handleLeaveChatroom :: Socket -> Maybe Message -> Chan Message -> IO ()
handleLeaveChatroom _ Nothing _ = return ()
handleLeaveChatroom sock message channel = do
  let justMessage = fromJust message
  let reply = Message { messageType = "CHAT", clientIp = "0", port = 0, clientName = (clientName justMessage),
leftChatroom = (chatroomToJoin justMessage), roomRef = (roomRef justMessage), joinId = (joinId justMessage), messageText = (clientName justMessage) `append` " has left this chatroom." }
  send sock (getLeftRoomMessage reply)
  let leaveReply = reply { messageType = "LEAVE_CHATROOM"}
  writeChan channel reply
  writeChan channel leaveReply

handleJoinChatroom :: Socket -> Maybe Message -> Chan Message -> IO ()
handleJoinChatroom _ Nothing _ = return ()
handleJoinChatroom sock message channel = do
  loloo <- dupChan channel
  let justMessage = fromJust message
  let roomReference = hash $ unpack $ (chatroomToJoin justMessage)
  let joinIdHash =  hash $ unpack $ (chatroomToJoin justMessage) `append` (clientName justMessage)
  forkIO (listenForMessagesFromOthers sock loloo roomReference joinIdHash message)
  let reply = Message { messageType = "CHAT", clientIp = "0", port = 0, clientName = (clientName justMessage),
joinedChatRoom = (chatroomToJoin justMessage), roomRef = roomReference, joinId = joinIdHash,
messageText = (clientName justMessage) `append` " has joined this chatroom." }
  send sock (getJoinedRoomMessage reply)
  writeChan channel reply

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
        splitByLine = splitOn "\n" stringMessage

readAsInt :: Text -> Int
readAsInt string = read (unpack string) :: Int

getValue :: String -> String -> Text
getValue line delimiter = pack ((splitOn delimiter line) !! 1)
