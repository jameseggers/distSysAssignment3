{-# LANGUAGE OverloadedStrings #-}

module Main where

import Network.Socket
import Data.Text hiding (head, tail, splitOn, length, map)
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
chatroomToLeave :: Text, leftChatroom :: Text, messageText :: Text, selectedSocket :: Socket, socketAction :: Text } deriving (Show)

main :: IO ()
main = withSocketsDo $ do
  let numberOfActiveThreads = 0
  let maximumThreads = 25
  sock <- socket socketFamily socketType defaultProtocol
  setSocketOption sock ReuseAddr 1
  bind sock address
  listen sock 2
  channel <- newChan
  forkIO (messageFanout [([], -5086779233225239604)] channel)
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

messageFanout :: [([Socket], Int)] -> Chan Message -> IO ()
messageFanout socketsAndRoomRefs channel = do
  receivedMessage <- readChan channel
  findSocksToSendTo socketsAndRoomRefs receivedMessage
  putStrLn (unpack (messageType receivedMessage))
  let socketsAndRoomRefsWithNewRooms = addNewRoomsToList socketsAndRoomRefs receivedMessage
  let newSocksAndRoomRefs = updateSocksRefsList socketsAndRoomRefsWithNewRooms [] receivedMessage
  messageFanout newSocksAndRoomRefs channel

addNewRoomsToList :: [([Socket], Int)] -> Message -> [([Socket], Int)]
addNewRoomsToList socksAndRefs message
  | (ref `elem` justRefs) == True = socksAndRefs
  | otherwise = (([], ref) : socksAndRefs)
  where justRefs = map (snd) socksAndRefs
        ref = (roomRef message)

findSocksToSendTo :: [([Socket], Int)] -> Message -> IO ()
findSocksToSendTo [] _  = return ()
findSocksToSendTo (socksAndRef:rest) message = do
  if (roomRef message) == (snd socksAndRef) && (messageType message) == "CHAT"
    then putStrLn "het bab" >> sendToSocketsInRoom (fst socksAndRef) message
    else findSocksToSendTo rest message

sendToSocketsInRoom :: [Socket] -> Message -> IO ()
sendToSocketsInRoom [] _ = return ()
sendToSocketsInRoom (sock:sockets) message = do
  send sock (getChatResponseMessage message)
  sendToSocketsInRoom sockets message

updateSocksRefsList :: [([Socket], Int)] -> [([Socket], Int)] -> Message -> [([Socket], Int)]
updateSocksRefsList [] acc _ = acc
updateSocksRefsList (socksAndRef:rest) acc message =
  if (messageType message) == "SOCK_ACTION" && (snd socksAndRef) == (roomRef message)
    then updateSocksRefsList rest ( (  (preformSockAction (fst socksAndRef) message), (snd socksAndRef) ) : acc) message
    else updateSocksRefsList rest (socksAndRef:acc) message

preformSockAction :: [Socket] -> Message -> [Socket]
preformSockAction sockets message =
  case (socketAction message) of
    "ADD" -> (selectedSocket message) : sockets
    "REMOVE" -> removeSockFromList sockets [] (selectedSocket message)

removeSockFromList :: [Socket] -> [Socket] -> Socket -> [Socket]
removeSockFromList [] acc _ = acc
removeSockFromList (sock:sockets) acc selectedSocket
  | sock == selectedSocket = removeSockFromList sockets acc selectedSocket
  | otherwise = removeSockFromList sockets (sock:acc) selectedSocket

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
  let justMessage = fromJust message
  let roomReference = hash $ unpack $ (chatroomToJoin justMessage)
  let joinIdHash =  hash $ unpack $ (chatroomToJoin justMessage) `append` (clientName justMessage)
  -- forkIO (listenForMessagesFromOthers sock channel roomReference joinIdHash message)
  let reply = Message { messageType = "SOCK_ACTION", clientIp = "0", port = 0, clientName = (clientName justMessage),
joinedChatRoom = (chatroomToJoin justMessage), roomRef = roomReference, joinId = joinIdHash,
messageText = (clientName justMessage) `append` " has joined this chatroom.", selectedSocket = sock, socketAction = "ADD" }
  send sock (getJoinedRoomMessage reply)
  writeChan channel reply
  let chatReply = reply { messageType = "CHAT" }
  writeChan channel chatReply

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
