{-# LANGUAGE OverloadedStrings #-}

module Main where

import Network.Socket
import Data.Text hiding (head, tail, splitOn, length)
import Data.List.Split
import Data.List
import Control.Concurrent
import Network.Info

main :: IO ()
main = withSocketsDo $ do
  let numberOfActiveThreads = 0
  let maximumThreads = 25
  sock <- socket socketFamily socketType defaultProtocol
  setSocketOption sock ReuseAddr 1
  bind sock address
  listen sock 2
  waitForConnection sock [] maximumThreads
  where socketType = Stream
        socketFamily = AF_INET
        address = SockAddrInet 4243 iNADDR_ANY

waitForConnection :: Socket -> [Socket] -> Int -> IO ()
waitForConnection sock runningSockets maximumNumberOfThreads = do
  conn <- accept sock
  activeSockets <- numberOfActiveSockets runningSockets 0
  threadId <- forkIO (runServer conn)
  let runningSocketsWithNewSocket = addNewSocket conn runningSockets maximumNumberOfThreads
  if (activeSockets >= maximumNumberOfThreads)
    then (killThread threadId) >> sClose (fst conn)
    else return ()
  waitForConnection sock runningSocketsWithNewSocket maximumNumberOfThreads

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

runServer :: (Socket, SockAddr) -> IO ()
runServer (sock, addr) = do
  message <- recv sock 4096
  putStrLn message
  let stripedMessage = strip $ pack message
  ns <- getNetworkInterfaces
  let ipAddress = show $ ipv4 (head ns)
  let response = respondToMessage addr ipAddress stripedMessage
  if response /= "die" then send sock response else return 0
  if response == "die" then sClose sock else runServer (sock, addr)

respondToMessage :: SockAddr -> String -> Text -> String
respondToMessage addr ipAddress message
  | (Data.List.isPrefixOf "KILL_SERVICE" stringMessage) = "die"
  | (Data.List.isPrefixOf "HELO" stringMessage) = stringMessage++"\nIP:178.62.42.127\nPort:"++justPort++"\nStudentID:13330379\n"
  | otherwise = ""
  where address = (show addr)
        splitedAddress = splitOn ":" address
        justPort = "4243"
        stringMessage = unpack message
