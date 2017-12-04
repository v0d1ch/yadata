{-# LANGUAGE OverloadedStrings #-}

-- Time Series
-- #############

module LibTS
( 
    getDateTimeIntervalTS,
    isAWorkingDay,
    alignTS,
    alignTSIndex,
    backFillTS,
    alignAndBackfillTS,
    TS(..),
    createTSRaw,
    createTSEither,
    writeFileTS,
    readFileTS,
    combineTS,
    indexTS,
    dataTS,
    takeTS,
    meanTS,
    diffTS,
    movingAverageTS,
    XTS(..),
    createXTSRaw,
    writeFileXTS,
    readFileXTS,
    convertTS2XTS,
    combineXTSnTS,
    combineXTSnXTS,
    indexXTS,
    dataXTS,
    takeXTS,
    movingAverageXTS
) where

import Data.Time
import Data.Time.Calendar.WeekDate
import qualified Data.Map as Map
import Data.List
import Data.Maybe
import Data.Either
import Text.CSV
import Control.Arrow (second)
import Data.Char
import Data.String
import Data.Semigroup

import LibCSV
-- ###########################################################################

isAWorkingDay::UTCTime -> Bool
isAWorkingDay x = 
    let myWeekDay = (toWeekDate . utctDay) x
        (_, _, aWeekDay) = myWeekDay
    in aWeekDay < 6

-- https://two-wrongs.com/haskell-time-library-tutorial

getDateTimeInterval :: [UTCTime] -> [UTCTime]
getDateTimeInterval timeIndex =
    if (length timeIndex == 0) 
        then [] 
        else fmap (\x -> addUTCTime (24*60*60*( fromRational x)) mint) [0 .. interval]
               where
                   mint = minimum timeIndex
                   maxt = maximum timeIndex
                   interval = (toRational (diffUTCTime maxt mint)) / (60*60*24)


getDateTimeIntervalTS' :: Num a => [(UTCTime, a)] -> [UTCTime]
getDateTimeIntervalTS' tseries = 
    getDateTimeInterval dates
    where
        (dates, _) = unzip tseries


getDateTimeIntervalTS :: Num a => Either String [(UTCTime, a)] -> Either String [UTCTime]
getDateTimeIntervalTS tseries = do
    tseries' <- tseries
    return $ getDateTimeIntervalTS' tseries'


-- https://downloads.haskell.org/~ghc/6.12.2/docs/html/libraries/containers-0.3.0.0/Data-Map.html
alignTS' :: Num a => [UTCTime] -> [(UTCTime, a)] -> [(UTCTime, Maybe a)]
alignTS' [] [] = []
alignTS' [] ts = alignTS' ( filter isAWorkingDay $ getDateTimeIntervalTS' ts) ts 
alignTS' _ [] = []
alignTS' idx ts = zip idx' allValues
     where   tvMap = foldl (\mm (key, value) -> Map.insert key value mm) Map.empty ts
             idx' = sort idx
             allValues = fmap (\v -> Map.lookup v tvMap) idx'                          


alignTSIndex :: Num a => Either String [UTCTime] -> Either String [(UTCTime, a)] -> Either String [(UTCTime, Maybe a)]                    
alignTSIndex idx ts = do 
    ind <- idx
    dta <- ts
    return $ alignTS' ind dta


alignTS :: Num a => Either String [(UTCTime, a)] -> Either String [(UTCTime, Maybe a)]                    
alignTS ts = do 
    dta <- ts
    return $ alignTS' [] dta


backFillTS' :: Num a => [Maybe a] -> [Maybe a]
backFillTS' [] = []
backFillTS' (x:[]) = [x]
backFillTS' (x:y:[]) = if (isNothing y) then (x:x:[]) else  (x:y:[])
backFillTS' (x:y:rest) = if (isJust x && isNothing y) then backFillTS' (x:x:rest) else  (x:( backFillTS' (y:rest) ))


backFillTS :: Num a => Either String [(UTCTime, Maybe a)] -> Either String [(UTCTime, Maybe a)] 
backFillTS ts = do 
    ts' <- ts
    let (tsIndex, values) = unzip ts'
    return $ zip tsIndex (backFillTS' values)
    

alignAndBackfillTSIndex :: (Eq a, Num a) => [UTCTime] -> [(UTCTime, a)] -> Either String [(UTCTime, a)]
alignAndBackfillTSIndex index ts = do
    let (tsIndex, values) = unzip $ alignTS' index ts
    let valuesB = backFillTS' values
    let values' = if any (== Nothing) valuesB 
                      then reverse (backFillTS' $ reverse valuesB ) else valuesB
    if all (== Nothing) values' 
        then Left "No data!"
        else return $ zip tsIndex ( catMaybes values' )

alignAndBackfillTS :: (Eq a, Num a) => [(UTCTime, a)] -> Either String [(UTCTime, a)]
alignAndBackfillTS = alignAndBackfillTSIndex []


-- TS -------------------------------------------------------------------------------------------
-- **********************************************************************************************

data TS a = TS [UTCTime] [a]

createTSRaw :: (Eq a, Num a) => [UTCTime] -> [a] -> TS a
createTSRaw [] [] = TS [] []
createTSRaw times values = TS abtimes abvalues
    where 
        ab = alignAndBackfillTS (zip times values)
        (abtimes, abvalues) = if (isLeft ab || fmap length ab == Right 0) then ([], []) else unzip (concat $ rights [ab])

        
createTSEither :: (Eq a, Num a) => Either String [(UTCTime, a)]  -> TS a
createTSEither ts = TS abtimes abvalues
    where
        ts1 = if (isLeft ts || fmap length ts == Right 0) then [] else (concat $ rights [ts])
        ab = alignAndBackfillTS ts1 
        (abtimes, abvalues) = if (isLeft ab ||fmap length ab == Right 0) then ([], []) else unzip (concat $ rights [ab])


instance Show a => Show (TS a) where
    show (TS times values) = mconcat rows
      where rows = ["Date | Value\n"] ++ zipWith (\x y -> mconcat [show x," | ",show y,"\n"] ) times values


writeFileTS :: (Show a) => FilePath -> TS a -> IO ()
writeFileTS path (TS times values) =
    writeFile path tsString
    where
        -- formatTime defaultTimeLocale "%F %T (%Z)" x
        tsString = mconcat $ ["Date,Value\n"] ++ zipWith (\x y -> mconcat [show x,",",show y,"\n"] ) times values


readFileTS :: FilePath -> IO (TS Double)
readFileTS path = do
    let tstext = readFile path
    txt <- tstext
    let ptxt = parseCSV path txt
    let date =  either 
                (\_-> []) 
                (\x-> fmap (read2UTCTime "%Y-%m-%d %H:%M:%S %Z") x) 
                                          (getColumnInCSVEither ptxt "Date")
    let value = either 
                (\_-> []) 
                (\x-> fmap read2Double x) (getColumnInCSVEither ptxt "Value")
    return $ TS date value


combineTS :: (Eq a, Num a) => TS a -> TS a -> TS a
combineTS (TS [] []) ts2 = ts2
combineTS ts1 (TS [] []) = ts1
combineTS (TS t1 v1) (TS t2 v2) = TS tx vx
    where 
        tx = filter isAWorkingDay $ getDateTimeInterval $ mconcat [t1,t2]
        tvMap = foldl (\mm (key, value) -> Map.insert key value mm) Map.empty $ zip t1 v1
        tv2Map = foldl (\mm (key, value) -> Map.insert key value mm) tvMap $ zip t2 v2
        allValues = fmap (\v -> Map.lookup v tv2Map) tx 
        allValuesB = if any (==Nothing) allValues then backFillTS' allValues else allValues
        allValuesB' = if any (== Nothing) allValuesB then reverse (backFillTS' $ reverse allValuesB ) else allValuesB
        vx = if all (==Nothing) allValuesB' then [] else catMaybes allValuesB'


instance (Eq a, Num a) => Semigroup (TS a) where
   (<>) = combineTS


instance (Eq a, Num a) => Monoid (TS a) where
   mempty = TS [] []
   mappend = (<>)


-- Get the index
indexTS :: TS a -> [UTCTime]
indexTS ( TS ind _ ) = ind


-- Get the data
dataTS :: (Eq a, Num a) => TS a -> [a]
dataTS ( TS _ dta ) = dta


takeTS :: Num a => Int -> TS a -> TS a
takeTS 0 ts = ts
takeTS _ ts@(TS [] []) = ts
takeTS n (TS x y) = TS (take n x) (take n y)

-- Calculations -------------------------------------------------------------------------------------------

-- Mean
mean :: (Real a) => [a] -> Double
mean xs = total/count
    where total = (realToFrac . sum) xs
          count = (realToFrac . length) xs

meanTS :: (Real a) => TS a -> Maybe Double
meanTS (TS _ []) = Nothing
meanTS (TS _ values) = Just $ mean values

-- diff
diffTS :: Num a => TS a -> TS a
diffTS (TS [] []) = TS [] []
diffTS (TS times values) = TS times ((head diffValues):diffValues)
    where shiftValues = tail values
          diffValues = zipWith (\x y -> x - y) shiftValues values

-- Moving Average
movingAvg :: (Real a) => Int -> [a]  -> [Double]
movingAvg n []  = []
movingAvg n vals = if (length nextVals) == n
                   then (mean nextVals):(movingAvg n restVals)
                   else []
    where nextVals = take n vals
          restVals = tail vals

movingAverageTS :: (Real a) => TS a -> Int -> TS Double
movingAverageTS (TS [] []) _ = TS [] []
movingAverageTS (TS times values) n = TS times (padding ++ ma)
    where ma = movingAvg n values 
          padding = fmap realToFrac $ take (n-1) values

-- a <- readFileXTS "labas.csv"
-- ts <- priceTimeSeries "IBM"
-- let ts1 = fmap (take 20) ts
-- let tx = createTSEither ts1
-- print tx

-- XTS -------------------------------------------------------------------------------------------
-- **********************************************************************************************

type ColXTS a = [a]
type ColNameXTS = String
data XTS a = XTS [UTCTime] [ColXTS a] [ColNameXTS]

createXTSRaw :: (Eq a, Num a) => [UTCTime] -> [ColXTS a] -> [ColNameXTS] -> XTS a
createXTSRaw [] [] [] = XTS [] [] []
createXTSRaw times values colnames = XTS abtimes abvalues colnames
   where
      abtimes = filter isAWorkingDay $ getDateTimeInterval times
      abvalues = fmap (\x-> let ab = alignAndBackfillTSIndex abtimes (zip times x)
                                (_, xvalues) = 
                                      if (isLeft ab || fmap length ab == Right 0) 
                                      then ([], []) 
                                      else unzip (concat $ rights [ab])
                            in xvalues
                      ) values


readFileXTS :: FilePath -> IO (XTS Double)
readFileXTS path = do 
    let tstext = readFile path
    txt <- tstext
    let ptxt = parseCSV path txt
    case ptxt of
        Left _    -> return $ XTS [] [] []
        Right dta -> do
            -- -----------------------------------------------------------------------------------------
            -- Add aligning !!! Add aligning !!! Add aligning !!! Add aligning !!! Add aligning !!! ----
            -- -----------------------------------------------------------------------------------------
            let dates = either 
                        (\_ -> []) 
                        (\x -> fmap (read2UTCTime "%Y-%m-%d %H:%M:%S %Z") x ) $ getColumnInCSV dta "Date"
            let restD = (fmap . fmap ) read2Double $ transpose $ delColumnInCSV dta "Date"
            let colnames = if (length dta == 0) then [] else filter (/= "Date") $ head dta
            return $ XTS dates restD colnames


preparePrinting :: [String] -> String -> String
preparePrinting dta sep = foldl (\x y -> x ++ sep ++ y ) "" dta


instance Show a => Show (XTS a) where
    show (XTS [] [] []) = "\n"
    show (XTS times values colNames) = mconcat rows
      where rows = ["Date " ++ preparePrinting colNames " | " ++ "\n"] ++ 
                    zipWith (\x y -> mconcat [show x, preparePrinting y " | ", "\n"] ) 
                                        times ((fmap . fmap) show $ transpose values)


writeFileXTS :: (Show a) => FilePath -> XTS a -> IO ()
writeFileXTS path (XTS times values colNames) =
    writeFile path tsString
    where
        -- formatTime defaultTimeLocale "%F %T (%Z)" x
        tsString = mconcat $ ["Date" ++ preparePrinting colNames "," ++ "\n"] ++  
                    zipWith (\x y -> mconcat [show x, preparePrinting y ",", "\n"] ) 
                                        times ((fmap . fmap) show $ transpose values)


convertTS2XTS :: String -> TS a -> XTS a
convertTS2XTS colName (TS index value)  = XTS index [value] [colName]


combineXTSnTS :: (Eq a, Num a) => XTS a -> String -> TS a -> XTS a
combineXTSnTS (XTS [] [] []) colName ts = convertTS2XTS colName ts
combineXTSnTS xts _ (TS [] []) = xts
combineXTSnTS (XTS xindex xdata xcolNames) colName (TS index value) = fts
    where
        ats = alignAndBackfillTSIndex xindex (zip index value)
        fts = case ats of
                Left _    -> XTS xindex xdata xcolNames 
                Right ts  -> XTS xindex (xdata ++ [ snd $ unzip ts ]) (xcolNames ++ [colName])

-- To be done ...
combineXTSnXTS :: (Eq a, Num a) => XTS a -> XTS a -> XTS a 
combineXTSnXTS  (XTS xindex xdata xcolNames) (XTS yindex ydata ycolNames) = undefined


instance (Eq a, Num a) => Semigroup (XTS a) where
    (<>) = combineXTSnXTS


instance (Eq a, Num a) => Monoid (XTS a) where
    mempty = XTS [] [] []
    mappend = (<>)


-- Get the index
indexXTS :: XTS a -> [UTCTime]
indexXTS ( XTS ind _ _ ) = ind


-- Get the data
dataXTS :: Num a => XTS a -> ([ColXTS a], [String])
dataXTS ( XTS _ dta cnames  ) = (dta, cnames)


takeXTS :: Num a => Int -> XTS a -> XTS a
takeXTS 0 ts = ts
takeXTS _ ts@(XTS [] [] []) = ts
takeXTS n (XTS x y z) = XTS (take n x) (fmap (take n) y) z


movingAverageXTS :: (Real a) => Int -> XTS a ->  XTS Double
movingAverageXTS _ (XTS [] [] [])  = XTS [] [] []
movingAverageXTS n (XTS xindex xdata xcolNames) = XTS xindex result xcolNames
    where ma = (fmap (movingAvg n) xdata) 
          padding = (fmap . fmap) realToFrac $ fmap (take (n-1)) xdata
          result = transpose $ (transpose padding) ++ (transpose ma)
