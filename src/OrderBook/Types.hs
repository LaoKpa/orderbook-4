{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeOperators #-}
module OrderBook.Types
( OrderBook(..)
, BuySide(..), buySide, bestBid
, SellSide(..), sellSide, bestAsk
, isEmpty
, SomeBook
, mkSomeBook
, fromSomeBook
, Order(..)
, SomeOrder
, AnyBook(..)
, mkSomeOrder
, fromOrder
, midPrice
)
where

import MyPrelude
import qualified Money
--import Data.Vector hiding (null, concat)
import qualified Data.Vector  as Vec
import Text.Printf
--import qualified Text.Show.Pretty   as P
import qualified Control.Category   as Cat


-- ETH/BTC . BTC/USD
--------------------
-- USD -> BTC -> ETH
-- ETH -> BTC -> USD

-- BuySide  ETH BTC . BuySide  BTC USD    (Buy  BTC for USD -> Buy  ETH for BTC)
-- SellSide BTC USD . SellSide ETH BTC    (Sell ETH for BTC -> Sell BTC for USD)

instance Cat.Category Order where
   id = Order (fromRational pseudoInf) Cat.id
      where pseudoInf = fromIntegral (maxBound :: Int64) % 1
   o1 . o2 = Order (fromRational minQty) (oPrice o1 Cat.. oPrice o2)
      where minQty = min (toRational $ oQuantity o1) (toRational $ oQuantity o2)

-- | The result of composing two orders, plus the remainder
composeRem :: Order b c
           -> Order a b
           -> (Order a c, Maybe (Either (Order b c) (Order a b)))
composeRem bc ab =
   fromDiff $ toRational (oQuantity bc) - toRational (oQuantity ab)
   where
   price = oPrice bc Cat.. oPrice ab
   fromDiff diff
      | diff == 0 = (Order (oQuantity ab) price, Nothing)
      | diff >  0 = (Order (oQuantity ab) price, Just . Left $
                     Order (fromRational diff) (oPrice bc))
      | diff <  0 = (Order (fromRational . toRational $ oQuantity bc) price, Just . Right $
                     Order (fromRational $ abs diff) (oPrice ab))


-- | Buyers want to convert "quote" to "base"
newtype BuySide (venue :: Symbol) (base :: Symbol) (quote :: Symbol)
   = BuySide { buySide :: Vector (Order base quote) }
      deriving (Eq, Generic, Show)

bestBid :: OrderBook venue base quote -> Maybe (Order base quote)
bestBid = (Vec.!? 0) . buySide . obBids

-- | Sellers want to convert "base" to "quote"
newtype SellSide (venue :: Symbol) (base :: Symbol) (quote :: Symbol)
   = SellSide { sellSide :: Vector (Order base quote) }
      deriving (Eq, Generic, Show)

bestAsk :: OrderBook venue base quote -> Maybe (Order base quote)
bestAsk = (Vec.!? 0) . sellSide . obAsks

class OrderbookSide a where
    isEmpty :: a -> Bool
instance OrderbookSide (BuySide venue base quote) where   
    isEmpty = null . buySide
instance OrderbookSide (SellSide venue base quote) where   
    isEmpty = null . sellSide


data OrderBook (venue :: Symbol) (base :: Symbol) (quote :: Symbol) = OrderBook
   { obBids  :: BuySide venue base quote
   , obAsks  :: SellSide venue base quote
   } deriving (Eq, Generic)

instance NFData (BuySide venue base quote)
instance NFData (SellSide venue base quote)
instance NFData (OrderBook venue base quote)

data SomeBook (venue :: Symbol) = SomeBook
   { sbBids  :: Vector SomeOrder
   , sbAsks  :: Vector SomeOrder
   }

mkSomeBook
   :: Vector SomeOrder  -- ^ Buy orders (bids)
   -> Vector SomeOrder  -- ^ Sell orders (asks)
   -> Either String (SomeBook venue)
mkSomeBook bids = Right . SomeBook bids

fromSomeBook
   :: (KnownSymbol venue, KnownSymbol base, KnownSymbol quote)
   => SomeBook venue
   -> OrderBook venue base quote
fromSomeBook SomeBook{..} =
   OrderBook (BuySide $ map fromSomeOrder sbBids)
             (SellSide $ map fromSomeOrder sbAsks)


data Order (base :: Symbol) (quote :: Symbol) = Order
   { oQuantity :: Money.Dense base
   , oPrice    :: Money.ExchangeRate base quote
   } deriving (Eq, Generic)

data SomeOrder = SomeOrder
   { soQuantity :: Rational
   , soPrice    :: Rational
   } deriving (Eq, Generic, Show)

-- | Create a 'SomeOrder' only if price > 0 and neither 'notANumber' nor 'infinity'
mkSomeOrder :: Rational    -- ^ Quantity
            -> Rational    -- ^ Price
            -> Maybe SomeOrder
mkSomeOrder qty price =
   SomeOrder <$> fmap toRational (Money.dense qty)
             <*> fmap Money.fromExchangeRate (Money.exchangeRate price)

fromOrder
   :: Order base quote
   -> SomeOrder
fromOrder Order{..} =
   SomeOrder (toRational oQuantity)
             (Money.fromExchangeRate oPrice)

fromSomeOrder
   :: (KnownSymbol base, KnownSymbol quote)
   => SomeOrder
   -> Order base quote
fromSomeOrder so@SomeOrder{..} = -- We know SomeOrder contains valid Dense/ExchangeRate
   let throwBug = error $ "SomeOrder: invalid qty/price: " ++ show so in
   Order (fromMaybe throwBug $ Money.dense soQuantity)
         (fromMaybe throwBug $ Money.exchangeRate soPrice)

instance Ord (Order base quote) where
   o1 <= o2 = oPrice o1 <= oPrice o2

instance NFData (Order base quote)

data AnyBook venue = forall base quote.
   ( KnownSymbol venue
   , KnownSymbol base
   , KnownSymbol quote )
     => AnyBook (OrderBook venue base quote)

-- | Order book mid price (Nothing in case there are no bids and/or asks).
--   Will fail horribly if bestBidPrice+bestAskPrice equals zero
--   (which would comprise an invalid order book (containing a negative price)).
midPrice :: forall venue base quote.
            (KnownSymbol base, KnownSymbol quote)
         => OrderBook venue base quote
         -> Maybe (Money.ExchangeRate base quote)
midPrice ob@OrderBook{..} =
   let rationalPrice = Money.fromExchangeRate . oPrice
       unsafeConv r = fromMaybe (error $ "Bad midPrice: " <> show (r,bestBid ob,bestAsk ob))
                                (Money.exchangeRate r)
   in do
      bb <- bestBid ob
      ba <- bestAsk ob
      return . unsafeConv $ ( rationalPrice bb
                            + rationalPrice ba ) / 2

showOrder :: forall base quote.
             (KnownSymbol base, KnownSymbol quote)
          => String
          -> Order base quote
          -> String
showOrder name Order{..} =
   let
      template = "[%s: %.4f %s @ %.4f %s/%s]"
      baseS = symbolVal (Proxy :: Proxy base)
      quoteS = symbolVal (Proxy :: Proxy quote)
      doublePrice :: Double
      doublePrice = realToFrac . Money.fromExchangeRate $ oPrice
      doubleQty :: Double
      doubleQty = realToFrac oQuantity
   in printf template name doubleQty baseS doublePrice quoteS baseS

instance (KnownSymbol base, KnownSymbol quote) => Show (Order base quote) where
   show = showOrder "Order"

instance (KnownSymbol venue, KnownSymbol base, KnownSymbol quote) =>
            Show (OrderBook venue base quote) where
   show ob@OrderBook{..} =
      let
         template = "<Order book: %s %s, mid price: %s, orders: %s>"
         venue = symbolVal (Proxy :: Proxy venue)
         currPair = symbolVal (Proxy :: Proxy base) <> "/" <> symbolVal (Proxy :: Proxy quote)
         midPriceF :: Maybe Double
         midPriceF = realToFrac . Money.fromExchangeRate <$> midPrice ob
         sortDesc = sortBy (flip compare)
         askIndent = ("\n\t" <> replicate 40 ' ')
         bidIndent = "\n\t"
         midPriceStr :: String
         midPriceStr = case midPriceF of
                        Nothing -> "<no bids/asks>"
                        Just price -> printf "%.4f" price
         orders =    askIndent <> intercalate askIndent (showOrder "SELL" <$> sortDesc (Vec.toList $ sellSide obAsks))
                  <> bidIndent <> intercalate bidIndent (Vec.toList $ fmap (showOrder "BUY ") $ buySide obBids)
      in printf template venue currPair midPriceStr orders

instance Show (AnyBook venue) where
   show (AnyBook ob) = show ob

instance NFData (AnyBook venue) where
   rnf (AnyBook ob) = rnf ob

instance (KnownSymbol venue, KnownSymbol base, KnownSymbol quote) =>
            Print (OrderBook venue base quote) where
   putStr ob = putStr (toS $ show ob :: Text)
   putStrLn l = putStr l >> putStr ("\n" :: Text)

