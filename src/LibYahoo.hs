{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE BangPatterns #-}

module LibYahoo
  ( getYahooDataSafe
  , YahooException(..)
  ) where

import Control.Exception as E
import Control.Lens
import Control.Monad.Except
import qualified Data.ByteString.Lazy as B
       (ByteString, drop, pack, take)
import qualified Data.ByteString.Lazy.Char8 as C
import Data.Int
import Data.Time.Clock
import Data.Typeable
import Network.HTTP.Client
import Network.HTTP.Client.TLS
import Network.HTTP.Simple hiding (httpLbs)
import qualified Network.Wreq as W
       (responseBody, responseStatus, statusCode)
import qualified Network.Wreq.Session as S
import Text.Regex.PCRE

crumbleLink :: String -> String
crumbleLink ticker =
  "https://finance.yahoo.com/quote/" ++ ticker ++ "/history?p=" ++ ticker

yahooDataLink :: String -> String -> String
yahooDataLink ticker crumb =
  "https://query1.finance.yahoo.com/v7/finance/download/" ++ ticker ++
  "?period1=1201686274&period2=1504364674&interval=1d&events=history&crumb=" ++
  crumb

crumblePattern :: String
crumblePattern = "CrumbStore\":{\"crumb\":\"(.*?)\"}" :: String

getCrumble :: B.ByteString -> B.ByteString
getCrumble crumbText = do
  let test = crumbText =~ crumblePattern :: (Int, Int)
   -- let shift = 22 :: Int64
   -- let crumb = DBL.take (fromIntegral (snd test) - (shift + 2) ) (DBL.drop (fromIntegral (fst test) + shift) crumbText)
  B.take
    (fromIntegral (snd test) - 24)
    (B.drop (fromIntegral (fst test) + 22) crumbText)

getYahooData :: String -> IO B.ByteString
getYahooData ticker =
  S.withSession $ \sess
   -- get session related data
   -> do
    r <- S.get sess (crumbleLink "KO")
    let rb = r ^. W.responseBody
    let crb = getCrumble rb
   -- get time series
    r2 <- S.get sess (yahooDataLink ticker (C.unpack crb))
    let r2b = r2 ^. W.responseBody
    return r2b

------------------------------------------------------------------------------------------------------
data YahooException
  = YStatusCodeException
  | YCookieCrumbleException
  deriving (Typeable)

instance Show YahooException where
  show YStatusCodeException = "Yadata data fetch exception!"
  show YCookieCrumbleException = "Yadata cookie crumble exception!"

instance Exception YahooException

getYahooDataSafe :: String -> IO String
getYahooDataSafe ticker = do
  manager <- newManager $ managerSetProxy noProxy tlsManagerSettings
  setGlobalManager manager
  cookieRequest <- parseRequest (crumbleLink "KO")
  crumb <-
    E.try (httpLbs cookieRequest manager) :: IO (Either YahooException (Response C.ByteString))
  case crumb of
    Left e -> return $ show YCookieCrumbleException
    Right crb -> do
      now <- getCurrentTime
      let (jar1, _) = updateCookieJar crb cookieRequest now (createCookieJar [])
      let body = crb ^. W.responseBody
      dataRequest <- parseRequest (yahooDataLink ticker (C.unpack $ getCrumble body))
      now2 <- getCurrentTime
      let (dataReq, jar2) = insertCookiesIntoRequest dataRequest jar1 now2
      result <-
        E.try (httpLbs dataReq manager) :: IO (Either YahooException (Response C.ByteString))
      case result of
        Left e -> return $ show YStatusCodeException
        Right d -> do
          let body2 = d ^. W.responseBody
          return $ C.unpack body2
