{-# LANGUAGE BangPatterns #-}

-- TODO: Add some comments describing how this implementation works.

-- | A reimplementation of Data.WordMap that seems to be 1.4-4x faster.

module Data.WordMap.Internal where

import Control.DeepSeq
import Control.Applicative hiding (empty)

import Data.Monoid
import qualified Data.Foldable (Foldable(..))
import Data.Traversable

import Data.Word (Word)
import Data.Bits (xor)

import Prelude hiding (foldr, foldl, lookup, null, map, min, max)

type Key = Word

data WordMap a = NonEmpty {-# UNPACK #-} !Key a !(Node a) | Empty deriving (Eq)
data Node a = Bin {-# UNPACK #-} !Key a !(Node a) !(Node a) | Tip deriving (Eq, Show)

instance Show a => Show (WordMap a) where
    show m = "fromList " ++ show (toList m)

instance Functor WordMap where
    fmap _ Empty = Empty
    fmap f (NonEmpty min minV node) = NonEmpty min (f minV) (fmap f node)

instance Functor Node where
    fmap _ Tip = Tip
    fmap f (Bin k v l r) = Bin k (f v) (fmap f l) (fmap f r)

instance Data.Foldable.Foldable WordMap where
    foldMap f = start
      where
        start Empty = mempty
        start (NonEmpty _ minV root) = f minV `mappend` goL root
        
        goL Tip = mempty
        goL (Bin _ maxV l r) = goL l `mappend` goR r `mappend` f maxV
        
        goR Tip = mempty
        goR (Bin _ minV l r) = f minV `mappend` goL l `mappend` goR r
    
    foldr = foldr
    foldr' = foldr'
    foldl = foldl
    foldl' = foldl'

instance Traversable WordMap where
    traverse f = start
      where
        start Empty = pure Empty
        start (NonEmpty min minV node) = NonEmpty min <$> f minV <*> goL node
        
        goL Tip = pure Tip
        goL (Bin max maxV l r) = (\l' r' v' -> Bin max v' l' r') <$> goL l <*> goR r <*> f maxV
        
        goR Tip = pure Tip
        goR (Bin min minV l r) = Bin min <$> f minV <*> goL l <*> goR r

instance Monoid (WordMap a) where
    mempty = empty
    mappend = union

instance NFData a => NFData (WordMap a) where
    rnf Empty = ()
    rnf (NonEmpty _ v n) = rnf v `seq` rnf n

instance NFData a => NFData (Node a) where
    rnf Tip = ()
    rnf (Bin _ v l r) = rnf v `seq` rnf l `seq` rnf r

-- | /O(min(n,W))/. Find the value at a key.
-- Calls 'error' when the element can not be found.
--
-- > fromList [(5,'a'), (3,'b')] ! 1    Error: element not in the map
-- > fromList [(5,'a'), (3,'b')] ! 5 == 'a'
(!) :: WordMap a -> Key -> a
(!) m k = findWithDefault (error $ "WordMap.!: key " ++ show k ++ " is not an element of the map") k m

-- | Same as 'difference'.
(\\) :: WordMap a -> WordMap b -> WordMap a
(\\) = difference

-- | /O(1)/. Is the map empty?
null :: WordMap a -> Bool
null Empty = True
null _ = False

-- | /O(n)/. Number of elements in the map.
size :: WordMap a -> Int
size Empty = 0
size (NonEmpty _ _ node) = sizeNode node where
    sizeNode Tip = 1
    sizeNode (Bin _ _ l r) = sizeNode l + sizeNode r

-- | /O(1)/. Find the smallest and largest key in the map.
bounds :: WordMap a -> Maybe (Key, Key)
bounds Empty = Nothing
bounds (NonEmpty min _ Tip) = Just (min, min)
bounds (NonEmpty min _ (Bin max _ _ _)) = Just (min, max)

-- TODO: Is there a good way to unify the 'lookup'-like functions?

-- | /O(min(n,W))/. Is the key a member of the map?
member :: Key -> WordMap a -> Bool
member k = k `seq` start
  where
    start Empty = False
    start (NonEmpty min _ node)
        | k < min = False
        | k == min = True
        | otherwise = goL (xor min k) node
    
    goL !_ Tip = False
    goL !xorCache (Bin max _ l r)
        | k < max = if xorCache < xorCacheMax
                    then goL xorCache l
                    else goR xorCacheMax r
        | k > max = False
        | otherwise = True
      where xorCacheMax = xor k max
    
    goR !_ Tip = False
    goR !xorCache (Bin min _ l r)
        | k > min = if xorCache < xorCacheMin
                    then goR xorCache r
                    else goL xorCacheMin l
        | k < min = False
        | otherwise = True
      where xorCacheMin = xor min k

-- | /O(min(n,W))/. Is the key not a member of the map?
notMember :: Key -> WordMap a -> Bool
notMember k = k `seq` start
  where
    start Empty = True
    start (NonEmpty min _ node)
        | k < min = True
        | k == min = False
        | otherwise = goL (xor min k) node
    
    goL !_ Tip = True
    goL !xorCache (Bin max _ l r)
        | k < max = if xorCache < xorCacheMax
                    then goL xorCache l
                    else goR xorCacheMax r
        | k > max = True
        | otherwise = False
      where xorCacheMax = xor k max
    
    goR !_ Tip = True
    goR !xorCache (Bin min _ l r)
        | k > min = if xorCache < xorCacheMin
                    then goR xorCache r
                    else goL xorCacheMin l
        | k < min = True
        | otherwise = False
      where xorCacheMin = xor min k

-- | /O(min(n,W))/. Lookup the value at a key in the map.
lookup :: Key -> WordMap a -> Maybe a
lookup k = k `seq` start
  where
    start Empty = Nothing
    start (NonEmpty min minV node)
        | k < min = Nothing
        | k == min = Just minV
        | otherwise = goL (xor min k) node
    
    goL !_ Tip = Nothing
    goL !xorCache (Bin max maxV l r)
        | k < max = if xorCache < xorCacheMax
                    then goL xorCache l
                    else goR xorCacheMax r
        | k > max = Nothing
        | otherwise = Just maxV
      where xorCacheMax = xor k max
    
    goR !_ Tip = Nothing
    goR !xorCache (Bin min minV l r)
        | k > min = if xorCache < xorCacheMin
                    then goR xorCache r
                    else goL xorCacheMin l
        | k < min = Nothing
        | otherwise = Just minV
      where xorCacheMin = xor min k

-- | /O(min(n,W))/. The expression @findWithDefault def k map@ returns
-- the value at key @k@ or returns @def@ when the key is not an element
-- of the map. 
findWithDefault :: a -> Key -> WordMap a -> a
findWithDefault def k = k `seq` start
  where
    start Empty = def
    start (NonEmpty min minV node)
        | k < min = def
        | k == min = minV
        | otherwise = goL (xor min k) node
    
    goL !_ Tip = def
    goL !xorCache (Bin max maxV l r)
        | k < max = if xorCache < xorCacheMax
                    then goL xorCache l
                    else goR xorCacheMax r
        | k > max = def
        | otherwise = maxV
      where xorCacheMax = xor k max
    
    goR !_ Tip = def
    goR !xorCache (Bin min minV l r)
        | k > min = if xorCache < xorCacheMin
                    then goR xorCache r
                    else goL xorCacheMin l
        | k < min = def
        | otherwise = minV
      where  xorCacheMin = xor min k

-- | /O(log n)/. Find largest key smaller than the given one and return the
-- corresponding (key, value) pair.
--
-- > lookupLT 3 (fromList [(3,'a'), (5,'b')]) == Nothing
-- > lookupLT 4 (fromList [(3,'a'), (5,'b')]) == Just (3, 'a')
lookupLT :: Key -> WordMap a -> Maybe (Key, a)
lookupLT k = k `seq` start
  where
    start Empty = Nothing
    start (NonEmpty min minV node)
        | min >= k = Nothing
        | otherwise = Just (goL (xor min k) min minV node)
    
    goL !_ min minV Tip = (min, minV)
    goL !xorCache min minV (Bin max maxV l r)
        | max < k = (max, maxV)
        | xorCache < xorCacheMax = goL xorCache min minV l
        | otherwise = goR xorCacheMax r min minV l
      where
        xorCacheMax = xor k max
    
    goR !_ Tip fMin fMinV fallback = getMax fMin fMinV fallback
    goR !xorCache (Bin min minV l r) fMin fMinV fallback
        | min >= k = getMax fMin fMinV fallback
        | xorCache < xorCacheMin = goR xorCache r min minV l
        | otherwise = goL xorCacheMin min minV l
      where
        xorCacheMin = xor min k
    
    getMax min minV Tip = (min, minV)
    getMax _   _   (Bin max maxV _ _) = (max, maxV)

-- | /O(log n)/. Find largest key smaller or equal to the given one and return
-- the corresponding (key, value) pair.
--
-- > lookupLE 2 (fromList [(3,'a'), (5,'b')]) == Nothing
-- > lookupLE 4 (fromList [(3,'a'), (5,'b')]) == Just (3, 'a')
-- > lookupLE 5 (fromList [(3,'a'), (5,'b')]) == Just (5, 'b')
lookupLE :: Key -> WordMap a -> Maybe (Key, a)
lookupLE k = k `seq` start
  where
    start Empty = Nothing
    start (NonEmpty min minV node)
        | min > k = Nothing
        | otherwise = Just (goL (xor min k) min minV node)
    
    goL !_ min minV Tip = (min, minV)
    goL !xorCache min minV (Bin max maxV l r)
        | max <= k = (max, maxV)
        | xorCache < xorCacheMax = goL xorCache min minV l
        | otherwise = goR xorCacheMax r min minV l
      where
        xorCacheMax = xor k max
    
    goR !_ Tip fMin fMinV fallback = getMax fMin fMinV fallback
    goR !xorCache (Bin min minV l r) fMin fMinV fallback
        | min > k = getMax fMin fMinV fallback
        | xorCache < xorCacheMin = goR xorCache r min minV l
        | otherwise = goL xorCacheMin min minV l
      where
        xorCacheMin = xor min k
    
    getMax min minV Tip = (min, minV)
    getMax _   _   (Bin max maxV _ _) = (max, maxV)

-- | /O(log n)/. Find smallest key greater than the given one and return the
-- corresponding (key, value) pair.
--
-- > lookupGT 4 (fromList [(3,'a'), (5,'b')]) == Just (5, 'b')
-- > lookupGT 5 (fromList [(3,'a'), (5,'b')]) == Nothing
lookupGT :: Key -> WordMap a -> Maybe (Key, a)
lookupGT k = k `seq` start
  where
    start Empty = Nothing
    start (NonEmpty min minV Tip)
        | min <= k = Nothing
        | otherwise = Just (min, minV)
    start (NonEmpty min minV (Bin max maxV l r))
        | max <= k = Nothing
        | otherwise = Just (goR (xor k max) max maxV (Bin min minV l r))
    
    goL !_ Tip fMax fMaxV fallback = getMin fMax fMaxV fallback
    goL !xorCache (Bin max maxV l r) fMax fMaxV fallback
        | max <= k = getMin fMax fMaxV fallback
        | xorCache < xorCacheMax = goL xorCache l max maxV r
        | otherwise = goR xorCacheMax max maxV r
      where
        xorCacheMax = xor k max
    
    goR !_ max maxV Tip = (max, maxV)
    goR !xorCache max maxV (Bin min minV l r)
        | min > k = (min, minV)
        | xorCache < xorCacheMin = goR xorCache max maxV r
        | otherwise = goL xorCacheMin l max maxV r
      where
        xorCacheMin = xor min k
    
    getMin max maxV Tip = (max, maxV)
    getMin _   _   (Bin min minV _ _) = (min, minV)

-- | /O(log n)/. Find smallest key greater or equal to the given one and return
-- the corresponding (key, value) pair.
--
-- > lookupGE 3 (fromList [(3,'a'), (5,'b')]) == Just (3, 'a')
-- > lookupGE 4 (fromList [(3,'a'), (5,'b')]) == Just (5, 'b')
-- > lookupGE 6 (fromList [(3,'a'), (5,'b')]) == Nothing
lookupGE :: Key -> WordMap a -> Maybe (Key, a)
lookupGE k = k `seq` start
  where
    start Empty = Nothing
    start (NonEmpty min minV Tip)
        | min < k = Nothing
        | otherwise = Just (min, minV)
    start (NonEmpty min minV (Bin max maxV l r))
        | max < k = Nothing
        | otherwise = Just (goR (xor k max) max maxV (Bin min minV l r))
    
    goL !_ Tip fMax fMaxV fallback = getMin fMax fMaxV fallback
    goL !xorCache (Bin max maxV l r) fMax fMaxV fallback
        | max < k = getMin fMax fMaxV fallback
        | xorCache < xorCacheMax = goL xorCache l max maxV r
        | otherwise = goR xorCacheMax max maxV r
      where
        xorCacheMax = xor k max
    
    goR !_ max maxV Tip = (max, maxV)
    goR !xorCache max maxV (Bin min minV l r)
        | min >= k = (min, minV)
        | xorCache < xorCacheMin = goR xorCache max maxV r
        | otherwise = goL xorCacheMin l max maxV r
      where
        xorCacheMin = xor min k
    
    getMin max maxV Tip = (max, maxV)
    getMin _   _   (Bin min minV _ _) = (min, minV)

-- | /O(1)/. The empty map.
empty :: WordMap a
empty = Empty

-- | /O(1)/. A map of one element.
singleton :: Key -> a -> WordMap a
singleton k v = NonEmpty k v Tip

-- | /O(min(n,W))/. Insert a new key\/value pair in the map.
-- If the key is already present in the map, the associated value
-- is replaced with the supplied value. 
insert :: Key -> a -> WordMap a -> WordMap a
insert k v = k `seq` start
  where
    start Empty = NonEmpty k v Tip
    start (NonEmpty min minV root)
        | k > min = NonEmpty min minV (goL (xor min k) min root)
        | k < min = NonEmpty k v (endL (xor min k) min minV root)
        | otherwise = NonEmpty k v root
    
    goL !_        _    Tip = Bin k v Tip Tip
    goL !xorCache min (Bin max maxV l r)
        | k < max = if xorCache < xorCacheMax
                    then Bin max maxV (goL xorCache min l) r
                    else Bin max maxV l (goR xorCacheMax max r)
        | k > max = if xor min max < xorCacheMax
                    then Bin k v (Bin max maxV l r) Tip
                    else Bin k v l (endR xorCacheMax max maxV r)
        | otherwise = Bin max v l r
      where xorCacheMax = xor k max

    goR !_        _    Tip = Bin k v Tip Tip
    goR !xorCache max (Bin min minV l r)
        | k > min = if xorCache < xorCacheMin
                    then Bin min minV l (goR xorCache max r)
                    else Bin min minV (goL xorCacheMin min l) r
        | k < min = if xor min max < xorCacheMin
                    then Bin k v Tip (Bin min minV l r)
                    else Bin k v (endL xorCacheMin min minV l) r
        | otherwise = Bin min v l r
      where xorCacheMin = xor min k
    
    endL !xorCache min minV = go
      where
        go Tip = Bin min minV Tip Tip
        go (Bin max maxV l r)
            | xor min max < xorCache = Bin max maxV Tip (Bin min minV l r)
            | otherwise = Bin max maxV (go l) r

    endR !xorCache max maxV = go
      where
        go Tip = Bin max maxV Tip Tip
        go (Bin min minV l r)
            | xor min max < xorCache = Bin min minV (Bin max maxV l r) Tip
            | otherwise = Bin min minV l (go r)

-- | /O(min(n,W))/. Insert with a combining function.
-- @'insertWith' f key value mp@
-- will insert the pair (key, value) into @mp@ if key does
-- not exist in the map. If the key does exist, the function will
-- insert @f new_value old_value@.
--
-- > insertWith (++) 5 "xxx" (fromList [(5,"a"), (3,"b")]) == fromList [(3, "b"), (5, "xxxa")]
-- > insertWith (++) 7 "xxx" (fromList [(5,"a"), (3,"b")]) == fromList [(3, "b"), (5, "a"), (7, "xxx")]
-- > insertWith (++) 5 "xxx" empty                         == singleton 5 "xxx"
insertWith :: (a -> a -> a) -> Key -> a -> WordMap a -> WordMap a
insertWith combine k v = k `seq` start
  where
    start Empty = NonEmpty k v Tip
    start (NonEmpty min minV root)
        | k > min = NonEmpty min minV (goL (xor min k) min root)
        | k < min = NonEmpty k v (endL (xor min k) min minV root)
        | otherwise = NonEmpty k (combine v minV) root
    
    goL !_        _    Tip = Bin k v Tip Tip
    goL !xorCache min (Bin max maxV l r)
        | k < max = if xorCache < xorCacheMax
                    then Bin max maxV (goL xorCache min l) r
                    else Bin max maxV l (goR xorCacheMax max r)
        | k > max = if xor min max < xorCacheMax
                    then Bin k v (Bin max maxV l r) Tip
                    else Bin k v l (endR xorCacheMax max maxV r)
        | otherwise = Bin max (combine v maxV) l r
      where xorCacheMax = xor k max

    goR !_        _    Tip = Bin k v Tip Tip
    goR !xorCache max (Bin min minV l r)
        | k > min = if xorCache < xorCacheMin
                    then Bin min minV l (goR xorCache max r)
                    else Bin min minV (goL xorCacheMin min l) r
        | k < min = if xor min max < xorCacheMin
                    then Bin k v Tip (Bin min minV l r)
                    else Bin k v (endL xorCacheMin min minV l) r
        | otherwise = Bin min (combine v minV) l r
      where xorCacheMin = xor min k
    
    endL !xorCache min minV = finishL
      where
        finishL Tip = Bin min minV Tip Tip
        finishL (Bin max maxV l r)
            | xor min max < xorCache = Bin max maxV Tip (Bin min minV l r)
            | otherwise = Bin max maxV (finishL l) r

    endR !xorCache max maxV = finishR
      where
        finishR Tip = Bin max maxV Tip Tip
        finishR (Bin min minV l r)
            | xor min max < xorCache = Bin min minV (Bin max maxV l r) Tip
            | otherwise = Bin min minV l (finishR r)

-- | /O(min(n,W))/. Insert with a combining function.
-- @'insertWithKey' f key value mp@
-- will insert the pair (key, value) into @mp@ if key does
-- not exist in the map. If the key does exist, the function will
-- insert @f key new_value old_value@.
--
-- > let f key new_value old_value = (show key) ++ ":" ++ new_value ++ "|" ++ old_value
-- > insertWithKey f 5 "xxx" (fromList [(5,"a"), (3,"b")]) == fromList [(3, "b"), (5, "5:xxx|a")]
-- > insertWithKey f 7 "xxx" (fromList [(5,"a"), (3,"b")]) == fromList [(3, "b"), (5, "a"), (7, "xxx")]
-- > insertWithKey f 5 "xxx" empty                         == singleton 5 "xxx"
insertWithKey :: (Key -> a -> a -> a) -> Key -> a -> WordMap a -> WordMap a
insertWithKey f k = insertWith (f k) k

-- | /O(min(n,W))/. The expression (@'insertLookupWithKey' f k x map@)
-- is a pair where the first element is equal to (@'lookup' k map@)
-- and the second element equal to (@'insertWithKey' f k x map@).
--
-- > let f key new_value old_value = (show key) ++ ":" ++ new_value ++ "|" ++ old_value
-- > insertLookupWithKey f 5 "xxx" (fromList [(5,"a"), (3,"b")]) == (Just "a", fromList [(3, "b"), (5, "5:xxx|a")])
-- > insertLookupWithKey f 7 "xxx" (fromList [(5,"a"), (3,"b")]) == (Nothing,  fromList [(3, "b"), (5, "a"), (7, "xxx")])
-- > insertLookupWithKey f 5 "xxx" empty                         == (Nothing,  singleton 5 "xxx")
--
-- This is how to define @insertLookup@ using @insertLookupWithKey@:
--
-- > let insertLookup kx x t = insertLookupWithKey (\_ a _ -> a) kx x t
-- > insertLookup 5 "x" (fromList [(5,"a"), (3,"b")]) == (Just "a", fromList [(3, "b"), (5, "x")])
-- > insertLookup 7 "x" (fromList [(5,"a"), (3,"b")]) == (Nothing,  fromList [(3, "b"), (5, "a"), (7, "x")])
insertLookupWithKey :: (Key -> a -> a -> a) -> Key -> a -> WordMap a -> (Maybe a, WordMap a)
insertLookupWithKey combine k v = k `seq` start
  where
    start Empty = (Nothing, NonEmpty k v Tip)
    start (NonEmpty min minV root)
        | k > min = let (mv, root') = goL (xor min k) min root
                    in  (mv, NonEmpty min minV root')
        | k < min = (Nothing, NonEmpty k v (endL (xor min k) min minV root))
        | otherwise = (Just minV, NonEmpty k (combine k v minV) root)
    
    goL !_        _    Tip = (Nothing, Bin k v Tip Tip)
    goL !xorCache min (Bin max maxV l r)
        | k < max = if xorCache < xorCacheMax
                    then let (mv, l') = goL xorCache min l
                         in  (mv, Bin max maxV l' r)
                    else let (mv, r') = goR xorCacheMax max r
                         in  (mv, Bin max maxV l r')
        | k > max = if xor min max < xorCacheMax
                    then (Nothing, Bin k v (Bin max maxV l r) Tip)
                    else (Nothing, Bin k v l (endR xorCacheMax max maxV r))
        | otherwise = (Just maxV, Bin max (combine k v maxV) l r)
      where xorCacheMax = xor k max

    goR !_        _    Tip = (Nothing, Bin k v Tip Tip)
    goR !xorCache max (Bin min minV l r)
        | k > min = if xorCache < xorCacheMin
                    then let (mv, r') = goR xorCache max r
                         in  (mv, Bin min minV l r')
                    else let (mv, l') = goL xorCacheMin min l
                         in  (mv, Bin min minV l' r)
        | k < min = if xor min max < xorCacheMin
                    then (Nothing, Bin k v Tip (Bin min minV l r))
                    else (Nothing, Bin k v (endL xorCacheMin min minV l) r)
        | otherwise = (Just minV, Bin min (combine k v minV) l r)
      where xorCacheMin = xor min k
    
    endL !xorCache min minV = finishL
      where
        finishL Tip = Bin min minV Tip Tip
        finishL (Bin max maxV l r)
            | xor min max < xorCache = Bin max maxV Tip (Bin min minV l r)
            | otherwise = Bin max maxV (finishL l) r

    endR !xorCache max maxV = finishR
      where
        finishR Tip = Bin max maxV Tip Tip
        finishR (Bin min minV l r)
            | xor min max < xorCache = Bin min minV (Bin max maxV l r) Tip
            | otherwise = Bin min minV l (finishR r)

-- | /O(min(n,W))/. Delete a key and its value from the map.
-- When the key is not a member of the map, the original map is returned.
delete :: Key -> WordMap a -> WordMap a
delete k = k `seq` start
  where
    start Empty = Empty
    start m@(NonEmpty min _ Tip)
        | k == min = Empty
        | otherwise = m
    start m@(NonEmpty min minV root@(Bin max maxV l r))
        | k < min = m
        | k == min = let DR min' minV' root' = goDeleteMin max maxV l r in NonEmpty min' minV' root'
        | otherwise = NonEmpty min minV (goL (xor min k) min root)
    
    goL !_        _      Tip = Tip
    goL !xorCache min n@(Bin max maxV l r)
        | k < max = if xorCache < xorCacheMax
                    then Bin max maxV (goL xorCache min l) r
                    else Bin max maxV l (goR xorCacheMax max r)
        | k > max = n
        | otherwise = case r of
            Tip -> l
            Bin minI minVI lI rI -> let DR max' maxV' r' = goDeleteMax minI minVI lI rI
                                    in  Bin max' maxV' l r'
      where xorCacheMax = xor k max
    
    goR !_        _      Tip = Tip
    goR !xorCache max n@(Bin min minV l r)
        | k > min = if xorCache < xorCacheMin
                    then Bin min minV l (goR xorCache max r)
                    else Bin min minV (goL xorCacheMin min l) r
        | k < min = n
        | otherwise = case l of
            Tip -> r
            Bin maxI maxVI lI rI -> let DR min' minV' l' = goDeleteMin maxI maxVI lI rI
                                    in  Bin min' minV' l' r
      where xorCacheMin = xor min k
    
    goDeleteMin max maxV l r = case l of
        Tip -> case r of
            Tip -> DR max maxV r
            Bin min minV l' r' -> DR min minV (Bin max maxV l' r')
        Bin maxI maxVI lI rI -> let DR min minV l' = goDeleteMin maxI maxVI lI rI
                                in  DR min minV (Bin max maxV l' r)
    
    goDeleteMax min minV l r = case r of
        Tip -> case l of
            Tip -> DR min minV l
            Bin max maxV l' r' -> DR max maxV (Bin min minV l' r')
        Bin minI minVI lI rI -> let DR max maxV r' = goDeleteMax minI minVI lI rI
                                in  DR max maxV (Bin min minV l r')

-- TODO: Does a strict pair work? My guess is not, as GHC was already
-- unboxing the tuple, but it would be simpler to use one of those.
-- | Without this specialized type (I was just using a tuple), GHC's
-- CPR correctly unboxed the tuple, but it couldn't unbox the returned
-- Key, leading to lots of inefficiency (3x slower than stock Data.WordMap)
data DeleteResult a = DR {-# UNPACK #-} !Key a !(Node a)

-- | /O(min(n,W))/. Adjust a value at a specific key. When the key is not
-- a member of the map, the original map is returned.
--
-- > adjust ("new " ++) 5 (fromList [(5,"a"), (3,"b")]) == fromList [(3, "b"), (5, "new a")]
-- > adjust ("new " ++) 7 (fromList [(5,"a"), (3,"b")]) == fromList [(3, "b"), (5, "a")]
-- > adjust ("new " ++) 7 empty                         == empty
adjust :: (a -> a) -> Key -> WordMap a -> WordMap a
adjust f k = k `seq` start
  where
    start Empty = Empty
    start m@(NonEmpty min minV node)
        | k > min = NonEmpty min minV (goL (xor min k) min node)
        | k < min = m
        | otherwise = NonEmpty min (f minV) node
    
    goL !_        _      Tip = Tip
    goL !xorCache min n@(Bin max maxV l r)
        | k < max = if xorCache < xorCacheMax
                    then Bin max maxV (goL xorCache min l) r
                    else Bin max maxV l (goR xorCacheMax max r)
        | k > max = n
        | otherwise = Bin max (f maxV) l r
      where xorCacheMax = xor k max
    
    goR !_        _      Tip = Tip
    goR !xorCache max n@(Bin min minV l r)
        | k > min = if xorCache < xorCacheMin
                    then Bin min minV l (goR xorCache max r)
                    else Bin min minV (goL xorCacheMin min l) r
        | k < min = n
        | otherwise = Bin min (f minV) l r
      where xorCacheMin = xor min k

-- | /O(min(n,W))/. Adjust a value at a specific key. When the key is not
-- a member of the map, the original map is returned.
--
-- > let f key x = (show key) ++ ":new " ++ x
-- > adjustWithKey f 5 (fromList [(5,"a"), (3,"b")]) == fromList [(3, "b"), (5, "5:new a")]
-- > adjustWithKey f 7 (fromList [(5,"a"), (3,"b")]) == fromList [(3, "b"), (5, "a")]
-- > adjustWithKey f 7 empty                         == empty
adjustWithKey :: (Key -> a -> a) -> Key -> WordMap a -> WordMap a
adjustWithKey f k = adjust (f k) k

-- | /O(min(n,W))/. The expression (@'update' f k map@) updates the value @x@
-- at @k@ (if it is in the map). If (@f x@) is 'Nothing', the element is
-- deleted. If it is (@'Just' y@), the key @k@ is bound to the new value @y@.
--
-- > let f x = if x == "a" then Just "new a" else Nothing
-- > update f 5 (fromList [(5,"a"), (3,"b")]) == fromList [(3, "b"), (5, "new a")]
-- > update f 7 (fromList [(5,"a"), (3,"b")]) == fromList [(3, "b"), (5, "a")]
-- > update f 3 (fromList [(5,"a"), (3,"b")]) == singleton 5 "a"
update :: (a -> Maybe a) -> Key -> WordMap a -> WordMap a
update f k = k `seq` start
  where
    start Empty = Empty
    start m@(NonEmpty min minV Tip)
        | k == min = case f minV of
            Nothing -> Empty
            Just minV' -> NonEmpty min minV' Tip
        | otherwise = m
    start m@(NonEmpty min minV root@(Bin max maxV l r))
        | k < min = m
        | k == min = case f minV of
            Nothing -> let DR min' minV' root' = goDeleteMin max maxV l r
                       in NonEmpty min' minV' root'
            Just minV' -> NonEmpty min minV' root
        | otherwise = NonEmpty min minV (goL (xor min k) min root)
    
    goL !_        _      Tip = Tip
    goL !xorCache min n@(Bin max maxV l r)
        | k < max = if xorCache < xorCacheMax
                    then Bin max maxV (goL xorCache min l) r
                    else Bin max maxV l (goR xorCacheMax max r)
        | k > max = n
        | otherwise = case f maxV of
            Nothing -> case r of
                Tip -> l
                Bin minI minVI lI rI -> let DR max' maxV' r' = goDeleteMax minI minVI lI rI
                                        in  Bin max' maxV' l r'
            Just maxV' -> Bin max maxV' l r
      where xorCacheMax = xor k max
    
    goR !_        _      Tip = Tip
    goR !xorCache max n@(Bin min minV l r)
        | k > min = if xorCache < xorCacheMin
                    then Bin min minV l (goR xorCache max r)
                    else Bin min minV (goL xorCacheMin min l) r
        | k < min = n
        | otherwise = case f minV of
            Nothing -> case l of
                Tip -> r
                Bin maxI maxVI lI rI -> let DR min' minV' l' = goDeleteMin maxI maxVI lI rI
                                        in  Bin min' minV' l' r
            Just minV' -> Bin min minV' l r
      where xorCacheMin = xor min k
    
    goDeleteMin max maxV l r = case l of
        Tip -> case r of
            Tip -> DR max maxV r
            Bin min minV l' r' -> DR min minV (Bin max maxV l' r')
        Bin maxI maxVI lI rI -> let DR min minV l' = goDeleteMin maxI maxVI lI rI
                                in  DR min minV (Bin max maxV l' r)
    
    goDeleteMax min minV l r = case r of
        Tip -> case l of
            Tip -> DR min minV l
            Bin max maxV l' r' -> DR max maxV (Bin min minV l' r')
        Bin minI minVI lI rI -> let DR max maxV r' = goDeleteMax minI minVI lI rI
                                in  DR max maxV (Bin min minV l r')

-- | /O(min(n,W))/. The expression (@'updateWithKey' f k map@) updates the value @x@
-- at @k@ (if it is in the map). If (@f k x@) is 'Nothing', the element is
-- deleted. If it is (@'Just' y@), the key @k@ is bound to the new value @y@.
--
-- > let f k x = if x == "a" then Just ((show k) ++ ":new a") else Nothing
-- > updateWithKey f 5 (fromList [(5,"a"), (3,"b")]) == fromList [(3, "b"), (5, "5:new a")]
-- > updateWithKey f 7 (fromList [(5,"a"), (3,"b")]) == fromList [(3, "b"), (5, "a")]
-- > updateWithKey f 3 (fromList [(5,"a"), (3,"b")]) == singleton 5 "a"
updateWithKey :: (Key -> a -> Maybe a) -> Key -> WordMap a -> WordMap a
updateWithKey f k = update (f k) k

-- | /O(min(n,W))/. Lookup and update.
-- The function returns original value, if it is updated.
-- This is different behavior than 'Data.Map.updateLookupWithKey'.
-- Returns the original key value if the map entry is deleted.
--
-- > let f k x = if x == "a" then Just ((show k) ++ ":new a") else Nothing
-- > updateLookupWithKey f 5 (fromList [(5,"a"), (3,"b")]) == (Just "a", fromList [(3, "b"), (5, "5:new a")])
-- > updateLookupWithKey f 7 (fromList [(5,"a"), (3,"b")]) == (Nothing,  fromList [(3, "b"), (5, "a")])
-- > updateLookupWithKey f 3 (fromList [(5,"a"), (3,"b")]) == (Just "b", singleton 5 "a")
updateLookupWithKey :: (Key -> a -> Maybe a) -> Key -> WordMap a -> (Maybe a, WordMap a)
updateLookupWithKey f k = k `seq` start
  where
    start Empty = (Nothing, Empty)
    start m@(NonEmpty min minV Tip)
        | k == min = case f min minV of
            Nothing -> (Just minV, Empty)
            Just minV' -> (Just minV, NonEmpty min minV' Tip)
        | otherwise = (Nothing, m)
    start m@(NonEmpty min minV root@(Bin max maxV l r))
        | k < min = (Nothing, m)
        | k == min = case f min minV of
            Nothing -> let DR min' minV' root' = goDeleteMin max maxV l r
                       in (Just minV, NonEmpty min' minV' root')
            Just minV' -> (Just minV, NonEmpty min minV' root)
        | otherwise = let (mv, root') = goL (xor min k) min root
                      in  (mv, NonEmpty min minV root')
    
    goL !_        _      Tip = (Nothing, Tip)
    goL !xorCache min n@(Bin max maxV l r)
        | k < max = if xorCache < xorCacheMax
                    then let (mv, l') = goL xorCache min l
                         in  (mv, Bin max maxV l' r)
                    else let (mv, r') = goR xorCacheMax max r
                         in  (mv, Bin max maxV l r')
        | k > max = (Nothing, n)
        | otherwise = case f max maxV of
            Nothing -> case r of
                Tip -> (Just maxV, l)
                Bin minI minVI lI rI -> let DR max' maxV' r' = goDeleteMax minI minVI lI rI
                                        in (Just maxV, Bin max' maxV' l r')
            Just maxV' -> (Just maxV, Bin max maxV' l r)
      where xorCacheMax = xor k max
    
    goR !_        _      Tip = (Nothing, Tip)
    goR !xorCache max n@(Bin min minV l r)
        | k > min = if xorCache < xorCacheMin
                    then let (mv, r') = goR xorCache max r
                         in  (mv, Bin min minV l r')
                    else let (mv, l') = goL xorCacheMin min l
                         in  (mv, Bin min minV l' r)
        | k < min = (Nothing, n)
        | otherwise = case f min minV of
            Nothing -> case l of
                Tip -> (Just minV, r)
                Bin maxI maxVI lI rI -> let DR min' minV' l' = goDeleteMin maxI maxVI lI rI
                                        in (Just minV, Bin min' minV' l' r)
            Just minV' -> (Just minV, Bin min minV' l r)
      where xorCacheMin = xor min k
    
    goDeleteMin max maxV l r = case l of
        Tip -> case r of
            Tip -> DR max maxV r
            Bin min minV l' r' -> DR min minV (Bin max maxV l' r')
        Bin maxI maxVI lI rI -> let DR min minV l' = goDeleteMin maxI maxVI lI rI
                                in  DR min minV (Bin max maxV l' r)
    
    goDeleteMax min minV l r = case r of
        Tip -> case l of
            Tip -> DR min minV l
            Bin max maxV l' r' -> DR max maxV (Bin min minV l' r')
        Bin minI minVI lI rI -> let DR max maxV r' = goDeleteMax minI minVI lI rI
                                in  DR max maxV (Bin min minV l r')

-- | /O(min(n,W))/. The expression (@'alter' f k map@) alters the value @x@ at @k@, or absence thereof.
-- 'alter' can be used to insert, delete, or update a value in an 'IntMap'.
-- In short : @'lookup' k ('alter' f k m) = f ('lookup' k m)@.
alter :: (Maybe a -> Maybe a) -> Key -> WordMap a -> WordMap a
alter f k m | member k m = update (f . Just) k m
            | otherwise = case f Nothing of
                Just x -> insert k x m
                Nothing -> m

-- | /O(n+m)/. The (left-biased) union of two maps.
-- It prefers the first map when duplicate keys are encountered,
-- i.e. (@'union' == 'unionWith' 'const'@).
--
-- > union (fromList [(5, "a"), (3, "b")]) (fromList [(5, "A"), (7, "C")]) == fromList [(3, "b"), (5, "a"), (7, "C")]
union :: WordMap a -> WordMap a -> WordMap a
union = unionWith const

-- | /O(n+m)/. The union with a combining function.
--
-- > unionWith (++) (fromList [(5, "a"), (3, "b")]) (fromList [(5, "A"), (7, "C")]) == fromList [(3, "b"), (5, "aA"), (7, "C")]
unionWith :: (a -> a -> a) -> WordMap a -> WordMap a -> WordMap a
unionWith f = unionWithKey (const f)

-- TODO: Actually implement union properly.

-- | /O(n+m)/. The union with a combining function.
--
-- > let f key left_value right_value = (show key) ++ ":" ++ left_value ++ "|" ++ right_value
-- > unionWithKey f (fromList [(5, "a"), (3, "b")]) (fromList [(5, "A"), (7, "C")]) == fromList [(3, "b"), (5, "5:a|A"), (7, "C")]
unionWithKey :: (Key -> a -> a -> a) -> WordMap a -> WordMap a -> WordMap a
unionWithKey combine = start
  where
    start Empty m2 = m2
    start m1 Empty = m1
    start (NonEmpty min1 minV1 root1) (NonEmpty min2 minV2 root2)
        | min1 < min2 = NonEmpty min1 minV1 (goL2 minV2 min1 root1 min2 root2)
        | min1 > min2 = NonEmpty min2 minV2 (goL1 minV1 min1 root1 min2 root2)
        | otherwise = NonEmpty min1 (combine min1 minV1 minV2) (goLFused min1 root1 root2) -- we choose min1 arbitrarily, as min1 == min2
    
    -- TODO: Should I bind 'minV1' in a closure? It never changes.
    -- TODO: Should I cache @xor min1 min2@?
    goL1 minV1 min1 Tip !_   Tip = Bin min1 minV1 Tip Tip
    goL1 minV1 min1 Tip min2 n2  = goInsertL1 min1 minV1 (xor min1 min2) min2 n2
    goL1 minV1 min1 n1  min2 Tip = endL (xor min1 min2) min1 minV1 n1 -- FIXME: Is this right?
    goL1 minV1 min1 n1@(Bin max1 maxV1 l1 r1) min2 n2@(Bin max2 maxV2 l2 r2) = case compareMSB (xor min1 max1) (xor min2 max2) of
         LT | xor min2 max2 `ltMSB` xor min1 min2 -> disjoint -- we choose min1 and min2 arbitrarily - we just need something from tree 1 and something from tree 2
            | xor min2 min1 < xor min1 max2 -> Bin max2 maxV2 (goL1 minV1 min1 n1 min2 l2) r2 -- we choose min1 arbitrarily - we just need something from tree 1
            | max1 > max2 -> Bin max1 maxV1 l2 (goR2 maxV2 max1 (Bin min1 minV1 l1 r1) max2 r2)
            | max1 < max2 -> Bin max2 maxV2 l2 (goR1 maxV1 max1 (Bin min1 minV1 l1 r1) max2 r2)
            | otherwise -> Bin max1 (combine max1 maxV1 maxV2) l2 (goRFused max1 (Bin min1 minV1 l1 r1) r2) -- we choose max1 arbitrarily, as max1 == max2
         EQ | max2 < min1 -> disjoint
            | max1 > max2 -> Bin max1 maxV1 (goL1 minV1 min1 l1 min2 l2) (goR2 maxV2 max1 r1 max2 r2)
            | max1 < max2 -> Bin max2 maxV2 (goL1 minV1 min1 l1 min2 l2) (goR1 maxV1 max1 r1 max2 r2)
            | otherwise -> Bin max1 (combine max1 maxV1 maxV2) (goL1 minV1 min1 l1 min2 l2) (goRFused max1 r1 r2) -- we choose max1 arbitrarily, as max1 == max2
         GT | xor min1 max1 `ltMSB` xor min1 min2 -> disjoint -- we choose min1 and min2 arbitrarily - we just need something from tree 1 and something from tree 2
            | otherwise -> Bin max1 maxV1 (goL1 minV1 min1 l1 min2 n2) r1
       where
         disjoint = Bin max1 maxV1 n2 (Bin min1 minV1 l1 r1)
    
    -- TODO: Should I bind 'minV2' in a closure? It never changes.
    -- TODO: Should I cache @xor min1 min2@?
    goL2 minV2 !_   Tip min2 Tip = Bin min2 minV2 Tip Tip
    goL2 minV2 min1 Tip min2 n2  = endL (xor min1 min2) min2 minV2 n2 -- FIXME: Is this right?
    goL2 minV2 min1 n1  min2 Tip = goInsertL2 min2 minV2 (xor min1 min2) min1 n1
    goL2 minV2 min1 n1@(Bin max1 maxV1 l1 r1) min2 n2@(Bin max2 maxV2 l2 r2) = case compareMSB (xor min1 max1) (xor min2 max2) of
         LT | xor min2 max2 `ltMSB` xor min1 min2 -> disjoint -- we choose min1 and min2 arbitrarily - we just need something from tree 1 and something from tree 2
            | otherwise -> Bin max2 maxV2 (goL2 minV2 min1 n1 min2 l2) r2
         EQ | max1 < min2 -> disjoint
            | max1 > max2 -> Bin max1 maxV1 (goL2 minV2 min1 l1 min2 l2) (goR2 maxV2 max1 r1 max2 r2)
            | max1 < max2 -> Bin max2 maxV2 (goL2 minV2 min1 l1 min2 l2) (goR1 maxV1 max1 r1 max2 r2)
            | otherwise -> Bin max1 (combine max1 maxV1 maxV2) (goL2 minV2 min1 l1 min2 l2) (goRFused max1 r1 r2) -- we choose max1 arbitrarily, as max1 == max2
         GT | xor min1 max1 `ltMSB` xor min1 min2 -> disjoint -- we choose min1 and min2 arbitrarily - we just need something from tree 1 and something from tree 2
            | xor min1 min2 < xor min2 max1 -> Bin max1 maxV1 (goL2 minV2 min1 l1 min2 n2) r1 -- we choose min2 arbitrarily - we just need something from tree 2
            | max1 > max2 -> Bin max1 maxV1 l1 (goR2 maxV2 max1 r1 max2 (Bin min2 minV2 l2 r2))
            | max1 < max2 -> Bin max2 maxV2 l1 (goR1 maxV1 max1 r1 max2 (Bin min2 minV2 l2 r2))
            | otherwise -> Bin max1 (combine max1 maxV1 maxV2) l1 (goRFused max1 r1 (Bin min2 minV2 l2 r2)) -- we choose max1 arbitrarily, as max1 == max2
       where
         disjoint = Bin max2 maxV2 n1 (Bin min2 minV2 l2 r2)
    
    -- TODO: Should I bind 'min' in a closure? It never changes.
    -- TODO: Should I use an xor cache here?
    -- 'goLFused' is called instead of 'goL' if the minimums of the two trees are the same
    -- Note that because of this property, the trees cannot be disjoint, so we can skip most of the checks in 'goL'
    goLFused !_ Tip n2 = n2
    goLFused !_ n1 Tip = n1
    goLFused min n1@(Bin max1 maxV1 l1 r1) n2@(Bin max2 maxV2 l2 r2) = case compareMSB (xor min max1) (xor min max2) of
        LT -> Bin max2 maxV2 (goLFused min n1 l2) r2
        EQ | max1 > max2 -> Bin max1 maxV1 (goLFused min l1 l2) (goR2 maxV2 max1 r1 max2 r2)
           | max1 < max2 -> Bin max2 maxV2 (goLFused min l1 l2) (goR1 maxV1 max1 r1 max2 r2)
           | otherwise -> Bin max1 (combine max1 maxV1 maxV2) (goLFused min l1 l2) (goRFused max1 r1 r2) -- we choose max1 arbitrarily, as max1 == max2
        GT -> Bin max1 maxV1 (goLFused min l1 n2) r1
    
    -- TODO: Should I bind 'maxV1' in a closure? It never changes.
    -- TODO: Should I cache @xor max1 max2@?
    goR1 maxV1 max1 Tip !_   Tip = Bin max1 maxV1 Tip Tip
    goR1 maxV1 max1 Tip max2 n2  = goInsertR1 max1 maxV1 (xor max1 max2) max2 n2
    goR1 maxV1 max1 n1  max2 Tip = endR (xor max1 max2) max1 maxV1 n1 -- FIXME: Is this right?
    goR1 maxV1 max1 n1@(Bin min1 minV1 l1 r1) max2 n2@(Bin min2 minV2 l2 r2) = case compareMSB (xor min1 max1) (xor min2 max2) of
         LT | xor min2 max2 `ltMSB` xor max1 max2 -> disjoint -- we choose max1 and max2 arbitrarily - we just need something from tree 1 and something from tree 2
            | xor min2 max1 > xor max1 max2 -> Bin min2 minV2 l2 (goR1 maxV1 max1 n1 max2 r2) -- we choose max1 arbitrarily - we just need something from tree 1
            | min1 < min2 -> Bin min1 minV1 (goL2 minV2 min1 (Bin max1 maxV1 l1 r1) min2 l2) r2
            | min1 > min2 -> Bin min2 minV2 (goL1 minV1 min1 (Bin max1 maxV1 l1 r1) min2 l2) r2
            | otherwise -> Bin min1 (combine min1 minV1 minV2) (goLFused min1 (Bin max1 maxV1 l1 r1) l2) r2 -- we choose min1 arbitrarily, as min1 == min2
         EQ | max1 < min2 -> disjoint
            | min1 < min2 -> Bin min1 minV1 (goL2 minV2 min1 l1 min2 l2) (goR1 maxV1 max1 r1 max2 r2)
            | min1 > min2 -> Bin min2 minV2 (goL1 minV1 min1 l1 min2 l2) (goR1 maxV1 max1 r1 max2 r2)
            | otherwise -> Bin min1 (combine min1 minV1 minV2) (goLFused min1 l1 l2) (goR1 maxV1 max1 r1 max2 r2) -- we choose min1 arbitrarily, as min1 == min2
         GT | xor min1 max1 `ltMSB` xor max1 max2 -> disjoint -- we choose max1 and max2 arbitrarily - we just need something from tree 1 and something from tree 2
            | otherwise -> Bin min1 minV1 l1 (goR1 maxV1 max1 r1 max2 n2)
       where
         disjoint = Bin min1 minV1 (Bin max1 maxV1 l1 r1) n2
    
    -- TODO: Should I bind 'minV2' in a closure? It never changes.
    -- TODO: Should I cache @xor min1 min2@?
    goR2 maxV2 !_   Tip max2   Tip = Bin max2 maxV2 Tip Tip
    goR2 maxV2 max1 Tip max2 n2  = endR (xor max1 max2) max2 maxV2 n2 -- FIXME: Is this right?
    goR2 maxV2 max1 n1  max2 Tip = goInsertR2 max2 maxV2 (xor max1 max2) max1 n1
    goR2 maxV2 max1 n1@(Bin min1 minV1 l1 r1) max2 n2@(Bin min2 minV2 l2 r2) = case compareMSB (xor min1 max1) (xor min2 max2) of
         LT | xor min2 max2 `ltMSB` xor max1 max2 -> disjoint -- we choose max1 and max2 arbitrarily - we just need something from tree 1 and something from tree 2
            | otherwise -> Bin min2 minV2 l2 (goR2 maxV2 max1 n1 max2 r2)
         EQ | max2 < min1 -> disjoint
            | min1 < min2 -> Bin min1 minV1 (goL2 minV2 min1 l1 min2 l2) (goR2 maxV2 max1 r1 max2 r2)
            | min1 > min2 -> Bin min2 minV2 (goL1 minV1 min1 l1 min2 l2) (goR2 maxV2 max1 r1 max2 r2)
            | otherwise -> Bin min1 (combine min1 minV1 minV2) (goLFused min1 l1 l2) (goR2 maxV2 max1 r1 max2 r2) -- we choose min1 arbitrarily, as min1 == min2
         GT | xor min1 max1 `ltMSB` xor max1 max2 -> disjoint -- we choose max1 and max2 arbitrarily - we just need something from tree 1 and something from tree 2
            | xor min1 max2 > xor max2 max1 -> Bin min1 minV1 l1 (goR2 maxV2 max1 r1 max2 n2) -- we choose max2 arbitrarily - we just need something from tree 2
            | min1 < min2 -> Bin min1 minV1 (goL2 minV2 min1 l1 min2 (Bin max2 maxV2 l2 r2)) r1
            | min1 > min2 -> Bin min2 minV2 (goL1 minV1 min1 l1 min2 (Bin max2 maxV2 l2 r2)) r1
            | otherwise -> Bin min1 (combine min1 minV1 minV2) (goLFused min1 l1 (Bin max2 maxV2 l2 r2)) r1 -- we choose min1 arbitrarily, as min1 == min2
       where
         disjoint = Bin min2 minV2 (Bin max2 maxV2 l2 r2) n1
    
    -- TODO: Should I bind 'max' in a closure? It never changes.
    -- TODO: Should I use an xor cache here?
    -- 'goRFused' is called instead of 'goR' if the minimums of the two trees are the same
    -- Note that because of this property, the trees cannot be disjoint, so we can skip most of the checks in 'goR'
    goRFused !_ Tip n2 = n2
    goRFused !_ n1 Tip = n1
    goRFused max n1@(Bin min1 minV1 l1 r1) n2@(Bin min2 minV2 l2 r2) = case compareMSB (xor min1 max) (xor min2 max) of
        LT -> Bin min2 minV2 l2 (goRFused max n1 r2)
        EQ | min1 < min2 -> Bin min1 minV1 (goL2 minV2 min1 l1 min2 l2) (goRFused max r1 r2)
           | min1 > min2 -> Bin min2 minV2 (goL1 minV1 min1 l1 min2 l2) (goRFused max r1 r2)
           | otherwise -> Bin min1 (combine min1 minV1 minV2) (goLFused min1 l1 l2) (goRFused max r1 r2) -- we choose min1 arbitrarily, as min1 == min2
        GT -> Bin min1 minV1 l1 (goRFused max r1 n2)
    
    goInsertL1 k v !_        _    Tip = Bin k v Tip Tip
    goInsertL1 k v !xorCache min (Bin max maxV l r)
        | k < max = if xorCache < xorCacheMax
                    then Bin max maxV (goInsertL1 k v xorCache min l) r
                    else Bin max maxV l (goInsertR1 k v xorCacheMax max r)
        | k > max = if xor min max < xorCacheMax
                    then Bin k v (Bin max maxV l r) Tip
                    else Bin k v l (endR xorCacheMax max maxV r)
        | otherwise = Bin max (combine k v maxV) l r
      where xorCacheMax = xor k max

    goInsertR1 k v !_        _    Tip = Bin k v Tip Tip
    goInsertR1 k v !xorCache max (Bin min minV l r)
        | k > min = if xorCache < xorCacheMin
                    then Bin min minV l (goInsertR1 k v xorCache max r)
                    else Bin min minV (goInsertL1 k v xorCacheMin min l) r
        | k < min = if xor min max < xorCacheMin
                    then Bin k v Tip (Bin min minV l r)
                    else Bin k v (endL xorCacheMin min minV l) r
        | otherwise = Bin min (combine k v minV) l r
      where xorCacheMin = xor min k
    
    goInsertL2 k v !_        _    Tip = Bin k v Tip Tip
    goInsertL2 k v !xorCache min (Bin max maxV l r)
        | k < max = if xorCache < xorCacheMax
                    then Bin max maxV (goInsertL2 k v xorCache min l) r
                    else Bin max maxV l (goInsertR2 k v xorCacheMax max r)
        | k > max = if xor min max < xorCacheMax
                    then Bin k v (Bin max maxV l r) Tip
                    else Bin k v l (endR xorCacheMax max maxV r)
        | otherwise = Bin max (combine k maxV v) l r
      where xorCacheMax = xor k max

    goInsertR2 k v !_        _    Tip = Bin k v Tip Tip
    goInsertR2 k v !xorCache max (Bin min minV l r)
        | k > min = if xorCache < xorCacheMin
                    then Bin min minV l (goInsertR2 k v xorCache max r)
                    else Bin min minV (goInsertL2 k v xorCacheMin min l) r
        | k < min = if xor min max < xorCacheMin
                    then Bin k v Tip (Bin min minV l r)
                    else Bin k v (endL xorCacheMin min minV l) r
        | otherwise = Bin min (combine k minV v) l r
      where xorCacheMin = xor min k
    
    endL !xorCache min minV = finishL
      where
        finishL Tip = Bin min minV Tip Tip
        finishL (Bin max maxV l r)
            | xor min max < xorCache = Bin max maxV Tip (Bin min minV l r)
            | otherwise = Bin max maxV (finishL l) r

    endR !xorCache max maxV = finishR
      where
        finishR Tip = Bin max maxV Tip Tip
        finishR (Bin min minV l r)
            | xor min max < xorCache = Bin min minV (Bin max maxV l r) Tip
            | otherwise = Bin min minV l (finishR r)

-- | The union of a list of maps.
--
-- > unions [(fromList [(5, "a"), (3, "b")]), (fromList [(5, "A"), (7, "C")]), (fromList [(5, "A3"), (3, "B3")])]
-- >     == fromList [(3, "b"), (5, "a"), (7, "C")]
-- > unions [(fromList [(5, "A3"), (3, "B3")]), (fromList [(5, "A"), (7, "C")]), (fromList [(5, "a"), (3, "b")])]
-- >     == fromList [(3, "B3"), (5, "A3"), (7, "C")]
unions :: [WordMap a] -> WordMap a
unions = Data.Foldable.foldl' union empty

-- | The union of a list of maps, with a combining operation.
--
-- > unionsWith (++) [(fromList [(5, "a"), (3, "b")]), (fromList [(5, "A"), (7, "C")]), (fromList [(5, "A3"), (3, "B3")])]
-- >     == fromList [(3, "bB3"), (5, "aAA3"), (7, "C")]
unionsWith :: (a -> a -> a) -> [WordMap a] -> WordMap a
unionsWith f = Data.Foldable.foldl' (unionWith f) empty

-- | /O(n+m)/. Difference between two maps (based on keys).
--
-- > difference (fromList [(5, "a"), (3, "b")]) (fromList [(5, "A"), (7, "C")]) == singleton 3 "b"
difference :: WordMap a -> WordMap b -> WordMap a
difference m1 m2 = foldrWithKey' (\k _ -> delete k) m1 m2

-- | /O(n+m)/. Difference with a combining function.
--
-- > let f al ar = if al == "b" then Just (al ++ ":" ++ ar) else Nothing
-- > differenceWith f (fromList [(5, "a"), (3, "b")]) (fromList [(5, "A"), (3, "B"), (7, "C")])
-- >     == singleton 3 "b:B"
differenceWith :: (a -> b -> Maybe a) -> WordMap a -> WordMap b -> WordMap a
differenceWith f = differenceWithKey (const f)

-- | /O(n+m)/. Difference with a combining function. When two equal keys are
-- encountered, the combining function is applied to the key and both values.
-- If it returns 'Nothing', the element is discarded (proper set difference).
-- If it returns (@'Just' y@), the element is updated with a new value @y@.
--
-- > let f k al ar = if al == "b" then Just ((show k) ++ ":" ++ al ++ "|" ++ ar) else Nothing
-- > differenceWithKey f (fromList [(5, "a"), (3, "b")]) (fromList [(5, "A"), (3, "B"), (10, "C")])
-- >     == singleton 3 "3:b|B"
differenceWithKey :: (Key -> a -> b -> Maybe a) -> WordMap a -> WordMap b -> WordMap a
differenceWithKey f m1 m2 = foldrWithKey' (\k b m -> update (\a -> f k a b) k m) m1 m2

-- | /O(n+m)/. The (left-biased) intersection of two maps (based on keys).
--
-- > intersection (fromList [(5, "a"), (3, "b")]) (fromList [(5, "A"), (7, "C")]) == singleton 5 "a"
intersection :: WordMap a -> WordMap b -> WordMap a
intersection = intersectionWith const

-- | /O(n+m)/. The intersection with a combining function.
--
-- > intersectionWith (++) (fromList [(5, "a"), (3, "b")]) (fromList [(5, "A"), (7, "C")]) == singleton 5 "aA"
intersectionWith :: (a -> b -> c) -> WordMap a -> WordMap b -> WordMap c
intersectionWith f = intersectionWithKey (const f)

-- TODO: Actually implement intersection properly.

-- | /O(n+m)/. The intersection with a combining function.
--
-- > let f k al ar = (show k) ++ ":" ++ al ++ "|" ++ ar
-- > intersectionWithKey f (fromList [(5, "a"), (3, "b")]) (fromList [(5, "A"), (7, "C")]) == singleton 5 "5:a|A"
intersectionWithKey :: (Key -> a -> b -> c) -> WordMap a -> WordMap b -> WordMap c
intersectionWithKey combine = start
  where
    start Empty !_ = Empty
    start !_ Empty = Empty
    start (NonEmpty min1 minV1 root1) (NonEmpty min2 minV2 root2)
        | min1 < min2 = goL2 minV2 min1 root1 min2 root2
        | min1 > min2 = goL1 minV1 min1 root1 min2 root2
        | otherwise = NonEmpty min1 (combine min1 minV1 minV2) (goLFused min1 root1 root2) -- we choose min1 arbitrarily, as min1 == min2
    
    -- TODO: This scheme might produce lots of unnecessary flipBounds calls. This should be rectified.
    
    goL1 _     !_   !_  !_   Tip = Empty
    goL1 minV1 min1 Tip min2 n2  = goLookupL1 min1 minV1 (xor min1 min2) n2
    goL1 _ min1 (Bin _ _ _ _) _ (Bin max2 _ _ _) | min1 > max2 = Empty
    goL1 minV1 min1 n1@(Bin max1 maxV1 l1 r1) min2 n2@(Bin max2 maxV2 l2 r2) = case compareMSB (xor min1 max1) (xor min2 max2) of
        LT | xor min2 min1 < xor min1 max2 -> goL1 minV1 min1 n1 min2 l2 -- min1 is arbitrary here - we just need something from tree 1
           | max1 > max2 -> flipBounds $ goR2 maxV2 max1 (Bin min1 minV1 l1 r1) max2 r2
           | max1 < max2 -> flipBounds $ goR1 maxV1 max1 (Bin min1 minV1 l1 r1) max2 r2
           | otherwise -> flipBounds $ NonEmpty max1 (combine max1 maxV1 maxV2) (goRFused max1 (Bin min1 minV1 l1 r1) r2)
        EQ | max1 > max2 -> binL (goL1 minV1 min1 l1 min2 l2) (goR2 maxV2 max1 r1 max2 r2)
           | max1 < max2 -> binL (goL1 minV1 min1 l1 min2 l2) (goR1 maxV1 max1 r1 max2 r2)
           | otherwise -> case goL1 minV1 min1 l1 min2 l2 of
                Empty -> flipBounds (NonEmpty max1 (combine max1 maxV1 maxV2) (goRFused max1 r1 r2))
                NonEmpty min' minV' l' -> NonEmpty min' minV' (Bin max1 (combine max1 maxV1 maxV2) l' (goRFused max1 r1 r2))
        GT -> goL1 minV1 min1 l1 min2 n2
    
    goL2 _     !_   Tip !_   !_  = Empty
    goL2 minV2 min1 n1  min2 Tip = goLookupL2 min2 minV2 (xor min1 min2) n1
    goL2 _ _ (Bin max1 _ _ _) min2 (Bin _ _ _ _) | min2 > max1 = Empty
    goL2 minV2 min1 n1@(Bin max1 maxV1 l1 r1) min2 n2@(Bin max2 maxV2 l2 r2) = case compareMSB (xor min1 max1) (xor min2 max2) of
        LT -> goL2 minV2 min1 n1 min2 l2
        EQ | max1 > max2 -> binL (goL2 minV2 min1 l1 min2 l2) (goR2 maxV2 max1 r1 max2 r2)
           | max1 < max2 -> binL (goL2 minV2 min1 l1 min2 l2) (goR1 maxV1 max1 r1 max2 r2)
           | otherwise -> case goL2 minV2 min1 l1 min2 l2 of
                Empty -> flipBounds (NonEmpty max1 (combine max1 maxV1 maxV2) (goRFused max1 r1 r2))
                NonEmpty min' minV' l' -> NonEmpty min' minV' (Bin max1 (combine max1 maxV1 maxV2) l' (goRFused max1 r1 r2))
        GT | xor min1 min2 < xor min2 max1 -> goL2 minV2 min1 l1 min2 n2 -- min2 is arbitrary here - we just need something from tree 2
           | max1 > max2 -> flipBounds $ goR2 maxV2 max1 r1 max2 (Bin min2 minV2 l2 r2)
           | max1 < max2 -> flipBounds $ goR1 maxV1 max1 r1 max2 (Bin min2 minV2 l2 r2)
           | otherwise -> flipBounds $ NonEmpty max1 (combine max1 maxV1 maxV2) (goRFused max1 r1 (Bin min2 minV2 l2 r2))
    
    goLFused min = loop
      where
        loop Tip !_ = Tip
        loop !_ Tip = Tip
        loop n1@(Bin max1 maxV1 l1 r1) n2@(Bin max2 maxV2 l2 r2) = case compareMSB (xor min max1) (xor min max2) of
            LT -> loop n1 l2
            EQ | max1 > max2 -> case goR2 maxV2 max1 r1 max2 r2 of
                    Empty -> loop l1 l2
                    NonEmpty max' maxV' r' -> Bin max' maxV' (loop l1 l2) r'
               | max1 < max2 -> case goR1 maxV1 max1 r1 max2 r2 of
                    Empty -> loop l1 l2
                    NonEmpty max' maxV' r' -> Bin max' maxV' (loop l1 l2) r'
               | otherwise -> Bin max1 (combine max1 maxV1 maxV2) (loop l1 l2) (goRFused max1 r1 r2) -- we choose max1 arbitrarily, as max1 == max2
            GT -> loop l1 n2
    
    goR1 _     !_   !_  !_   Tip = Empty
    goR1 maxV1 max1 Tip max2 n2  = goLookupR1 max1 maxV1 (xor max1 max2) n2
    goR1 _ max1 (Bin _ _ _ _) _ (Bin min2 _ _ _) | min2 > max1 = Empty
    goR1 maxV1 max1 n1@(Bin min1 minV1 l1 r1) max2 n2@(Bin min2 minV2 l2 r2) = case compareMSB (xor min1 max1) (xor min2 max2) of
        LT | xor min2 max1 > xor max1 max2 -> goR1 maxV1 max1 n1 max2 r2 -- max1 is arbitrary here - we just need something from tree 1
           | min1 < min2 -> flipBounds $ goL2 minV2 min1 (Bin max1 maxV1 l1 r1) min2 l2
           | min1 > min2 -> flipBounds $ goL1 minV1 min1 (Bin max1 maxV1 l1 r1) min2 l2
           | otherwise -> flipBounds $ NonEmpty min1 (combine min1 minV1 minV2) (goLFused min1 (Bin max1 maxV1 l1 r1) l2)
        EQ | min1 < min2 -> binR (goL2 minV2 min1 l1 min2 l2) (goR1 maxV1 max1 r1 max2 r2)
           | min1 > min2 -> binR (goL1 minV1 min1 l1 min2 l2) (goR1 maxV1 max1 r1 max2 r2)
           | otherwise -> case goR1 maxV1 max1 r1 max2 r2 of
                Empty -> flipBounds (NonEmpty min1 (combine min1 minV1 minV2) (goLFused min1 l1 l2))
                NonEmpty max' maxV' r' -> NonEmpty max' maxV' (Bin min1 (combine min1 minV1 minV2) (goLFused min1 l1 l2) r')
        GT -> goR1 maxV1 max1 r1 max2 n2
    
    goR2 _     !_   Tip !_   !_  = Empty
    goR2 maxV2 max1 n1  max2 Tip = goLookupR2 max2 maxV2 (xor max1 max2) n1
    goR2 _ _ (Bin min1 _ _ _) max2 (Bin _ _ _ _) | min1 > max2 = Empty
    goR2 maxV2 max1 n1@(Bin min1 minV1 l1 r1) max2 n2@(Bin min2 minV2 l2 r2) = case compareMSB (xor min1 max1) (xor min2 max2) of
        LT -> goR2 maxV2 max1 n1 max2 r2
        EQ | min1 < min2 -> binR (goL2 minV2 min1 l1 min2 l2) (goR2 maxV2 max1 r1 max2 r2)
           | min1 > min2 -> binR (goL1 minV1 min1 l1 min2 l2) (goR2 maxV2 max1 r1 max2 r2)
           | otherwise -> case goR2 maxV2 max1 r1 max2 r2 of
                Empty -> flipBounds (NonEmpty min1 (combine min1 minV1 minV2) (goLFused min1 l1 l2))
                NonEmpty max' maxV' r' -> NonEmpty max' maxV' (Bin min1 (combine min1 minV1 minV2) (goLFused min1 l1 l2) r')
        GT | xor min1 max2 > xor max2 max1 -> goR2 maxV2 max1 r1 max2 n2 -- max2 is arbitrary here - we just need something from tree 2
           | min1 < min2 -> flipBounds $ goL2 minV2 min1 l1 min2 (Bin max2 maxV2 l2 r2)
           | min1 > min2 -> flipBounds $ goL1 minV1 min1 l1 min2 (Bin max2 maxV2 l2 r2)
           | otherwise -> flipBounds $ NonEmpty min1 (combine min1 minV1 minV2) (goLFused min1 l1 (Bin max2 maxV2 l2 r2))
    
    goRFused max = loop
      where
        loop Tip !_ = Tip
        loop !_ Tip = Tip
        loop n1@(Bin min1 minV1 l1 r1) n2@(Bin min2 minV2 l2 r2) = case compareMSB (xor min1 max) (xor min2 max) of
            LT -> loop n1 r2
            EQ | min1 < min2 -> case goL2 minV2 min1 l1 min2 l2 of
                    Empty -> loop r1 r2
                    NonEmpty min' minV' l' -> Bin min' minV' l' (loop r1 r2)
               | min1 > min2 -> case goL1 minV1 min1 l1 min2 l2 of
                    Empty -> loop r1 r2
                    NonEmpty min' minV' l' -> Bin min' minV' l' (loop r1 r2)
               | otherwise -> Bin min1 (combine min1 minV1 minV2) (goLFused min1 l1 l2) (loop r1 r2) -- we choose max1 arbitrarily, as max1 == max2
            GT -> loop r1 n2
    
    goLookupL1 !_ _ !_ Tip = Empty
    goLookupL1 k v !xorCache (Bin max maxV l r)
        | k < max = if xorCache < xorCacheMax
                    then goLookupL1 k v xorCache l
                    else goLookupR1 k v xorCacheMax r
        | k > max = Empty
        | otherwise = NonEmpty k (combine k v maxV) Tip
      where xorCacheMax = xor k max
    
    goLookupR1 !_ _ !_ Tip = Empty
    goLookupR1 k v !xorCache (Bin min minV l r)
        | k > min = if xorCache < xorCacheMin
                    then goLookupR1 k v xorCache r
                    else goLookupL1 k v xorCacheMin l
        | k < min = Empty
        | otherwise = NonEmpty k (combine k v minV) Tip
      where xorCacheMin = xor min k
    
    goLookupL2 !_ _ !_ Tip = Empty
    goLookupL2 k v !xorCache (Bin max maxV l r)
        | k < max = if xorCache < xorCacheMax
                    then goLookupL2 k v xorCache l
                    else goLookupR2 k v xorCacheMax r
        | k > max = Empty
        | otherwise = NonEmpty k (combine k maxV v) Tip
      where xorCacheMax = xor k max
    
    goLookupR2 !_ _ !_ Tip = Empty
    goLookupR2 k v !xorCache (Bin min minV l r)
        | k > min = if xorCache < xorCacheMin
                    then goLookupR2 k v xorCache r
                    else goLookupL2 k v xorCacheMin l
        | k < min = Empty
        | otherwise = NonEmpty k (combine k minV v) Tip
      where xorCacheMin = xor min k

-- | /O(n)/. Map a function over all values in the map.
--
-- > map (++ "x") (fromList [(5,"a"), (3,"b")]) == fromList [(3, "bx"), (5, "ax")]
map :: (a -> b) -> WordMap a -> WordMap b
map = fmap

-- | /O(n)/. Map a function over all values in the map.
--
-- > let f key x = (show key) ++ ":" ++ x
-- > mapWithKey f (fromList [(5,"a"), (3,"b")]) == fromList [(3, "3:b"), (5, "5:a")]
mapWithKey :: (Key -> a -> b) -> WordMap a -> WordMap b
mapWithKey f = start
  where
    start Empty = Empty
    start (NonEmpty min minV root) = NonEmpty min (f min minV) (go root)
    
    go Tip = Tip
    go (Bin k v l r) = Bin k (f k v) (go l) (go r)


-- | /O(n)/.
-- @'traverseWithKey' f s == 'fromList' <$> 'traverse' (\(k, v) -> (,) k <$> f k v) ('toList' m)@
-- That is, behaves exactly like a regular 'traverse' except that the traversing
-- function also has access to the key associated with a value.
--
-- > traverseWithKey (\k v -> if odd k then Just (succ v) else Nothing) (fromList [(1, 'a'), (5, 'e')]) == Just (fromList [(1, 'b'), (5, 'f')])
-- > traverseWithKey (\k v -> if odd k then Just (succ v) else Nothing) (fromList [(2, 'c')])           == Nothing
traverseWithKey :: Applicative f => (Key -> a -> f b) -> WordMap a -> f (WordMap b)
traverseWithKey f = start
  where
    start  Empty = pure Empty
    start (NonEmpty min minV root) = NonEmpty min <$> f min minV <*> goL root
    
    goL  Tip = pure Tip
    goL (Bin max maxV l r) = (\l' r' maxV' -> Bin max maxV' l' r') <$> goL l <*> goR r <*> f max maxV
    
    goR  Tip = pure Tip
    goR (Bin min minV l r) = Bin min <$> f min minV <*> goL l <*> goR r

-- | /O(n)/. The function @'mapAccum'@ threads an accumulating
-- argument through the map in ascending order of keys.
--
-- > let f a b = (a ++ b, b ++ "X")
-- > mapAccum f "Everything: " (fromList [(5,"a"), (3,"b")]) == ("Everything: ba", fromList [(3, "bX"), (5, "aX")])
mapAccum :: (a -> b -> (a, c)) -> a -> WordMap b -> (a, WordMap c)
mapAccum f = mapAccumWithKey (\a _ x -> f a x)

-- | /O(n)/. The function @'mapAccumWithKey'@ threads an accumulating
-- argument through the map in ascending order of keys.
--
-- > let f a k b = (a ++ " " ++ (show k) ++ "-" ++ b, b ++ "X")
-- > mapAccumWithKey f "Everything:" (fromList [(5,"a"), (3,"b")]) == ("Everything: 3-b 5-a", fromList [(3, "bX"), (5, "aX")])
mapAccumWithKey :: (a -> Key -> b -> (a, c)) -> a -> WordMap b -> (a, WordMap c)
mapAccumWithKey f = start
  where
    start a  Empty = (a, Empty)
    start a (NonEmpty min minV root) =
        let (a',  minV') = f a min minV
            (a'', root') = goL root a'
        in  (a'', NonEmpty min minV' root')
    
    goL  Tip a = (a, Tip)
    goL (Bin max maxV l r) a =
        let (a',   l') = goL l a
            (a'',  r') = goR r a'
            (a''', maxV') = f a'' max maxV
        in  (a''', Bin max maxV' l' r')
    
    goR  Tip a = (a, Tip)
    goR (Bin min minV l r) a =
        let (a',   minV') = f a min minV
            (a'',   l') = goL l a'
            (a''',  r') = goR r a''
        in  (a''', Bin min minV' l' r')

-- | /O(n)/. The function @'mapAccumRWithKey'@ threads an accumulating
-- argument through the map in descending order of keys.
mapAccumRWithKey :: (a -> Key -> b -> (a, c)) -> a -> WordMap b -> (a, WordMap c)
mapAccumRWithKey f = start
  where
    start a Empty = (a, Empty)
    start a (NonEmpty min minV root) = 
        let (a',  root') = goL root a
            (a'', minV') = f a' min minV
        in  (a'', NonEmpty min minV' root')
    
    goL  Tip a = (a, Tip)
    goL (Bin max maxV l r) a =
        let (a',   maxV') = f a max maxV
            (a'',  r') = goR r a'
            (a''', l') = goL l a''
        in  (a''', Bin max maxV' l' r')
    
    goR  Tip a = (a, Tip)
    goR (Bin min minV l r) a =
        let (a',   r') = goR r a
            (a'',  l') = goL l a'
            (a''', minV') = f a'' min minV
        in  (a''', Bin min minV' l' r')

-- | /O(n*min(n,W))/.
-- @'mapKeys' f s@ is the map obtained by applying @f@ to each key of @s@.
--
-- The size of the result may be smaller if @f@ maps two or more distinct
-- keys to the same new key.  In this case the value at the greatest of the
-- original keys is retained.
--
-- > mapKeys (+ 1) (fromList [(5,"a"), (3,"b")])                        == fromList [(4, "b"), (6, "a")]
-- > mapKeys (\ _ -> 1) (fromList [(1,"b"), (2,"a"), (3,"d"), (4,"c")]) == singleton 1 "c"
-- > mapKeys (\ _ -> 3) (fromList [(1,"b"), (2,"a"), (3,"d"), (4,"c")]) == singleton 3 "c"
mapKeys :: (Key -> Key) -> WordMap a -> WordMap a
mapKeys f = foldlWithKey' (\m k a -> insert (f k) a m) empty

-- | /O(n*min(n,W))/.
-- @'mapKeysWith' c f s@ is the map obtained by applying @f@ to each key of @s@.
--
-- The size of the result may be smaller if @f@ maps two or more distinct
-- keys to the same new key.  In this case the associated values will be
-- combined using @c@.
--
-- > mapKeysWith (++) (\ _ -> 1) (fromList [(1,"b"), (2,"a"), (3,"d"), (4,"c")]) == singleton 1 "cdab"
-- > mapKeysWith (++) (\ _ -> 3) (fromList [(1,"b"), (2,"a"), (3,"d"), (4,"c")]) == singleton 3 "cdab"
mapKeysWith :: (a -> a -> a) -> (Key -> Key) -> WordMap a -> WordMap a
mapKeysWith combine f = foldlWithKey' (\m k a -> insertWith combine (f k) a m) empty

-- | /O(n*min(n,W))/.
-- @'mapKeysMonotonic' f s == 'mapKeys' f s@, but works only when @f@
-- is strictly monotonic.
-- That is, for any values @x@ and @y@, if @x@ < @y@ then @f x@ < @f y@.
-- /The precondition is not checked./
-- Semi-formally, we have:
--
-- > and [x < y ==> f x < f y | x <- ls, y <- ls]
-- >                     ==> mapKeysMonotonic f s == mapKeys f s
-- >     where ls = keys s
--
-- This means that @f@ maps distinct original keys to distinct resulting keys.
-- This function has slightly better performance than 'mapKeys'.
--
-- > mapKeysMonotonic (\ k -> k * 2) (fromList [(5,"a"), (3,"b")]) == fromList [(6, "b"), (10, "a")]
mapKeysMonotonic :: (Key -> Key) -> WordMap a -> WordMap a
mapKeysMonotonic = mapKeys

-- | /O(n)/. Fold the values in the map using the given right-associative
-- binary operator, such that @'foldr' f z == 'Prelude.foldr' f z . 'elems'@.
--
-- For example,
--
-- > elems map = foldr (:) [] map
--
-- > let f a len = len + (length a)
-- > foldr f 0 (fromList [(5,"a"), (3,"bbb")]) == 4
foldr :: (a -> b -> b) -> b -> WordMap a -> b
foldr f z = start
  where
    start Empty = z
    start (NonEmpty _ minV root) = f minV (goL root z)
    
    goL Tip acc = acc
    goL (Bin _ maxV l r) acc = goL l (goR r (f maxV acc))
    
    goR Tip acc = acc
    goR (Bin _ minV l r) acc = f minV (goL l (goR r acc))

-- | /O(n)/. Fold the values in the map using the given left-associative
-- binary operator, such that @'foldl' f z == 'Prelude.foldl' f z . 'elems'@.
--
-- For example,
--
-- > elems = reverse . foldl (flip (:)) []
--
-- > let f len a = len + (length a)
-- > foldl f 0 (fromList [(5,"a"), (3,"bbb")]) == 4
foldl :: (a -> b -> a) -> a -> WordMap b -> a
foldl f z = start
  where
    start Empty = z
    start (NonEmpty _ minV root) = goL (f z minV) root
    
    goL acc Tip = acc
    goL acc (Bin _ maxV l r) = f (goR (goL acc l) r) maxV
    
    goR acc Tip = acc
    goR acc (Bin _ minV l r) = goR (goL (f acc minV) l) r

-- | /O(n)/. Fold the keys and values in the map using the given right-associative
-- binary operator, such that
-- @'foldrWithKey' f z == 'Prelude.foldr' ('uncurry' f) z . 'toAscList'@.
--
-- For example,
--
-- > keys map = foldrWithKey (\k x ks -> k:ks) [] map
--
-- > let f k a result = result ++ "(" ++ (show k) ++ ":" ++ a ++ ")"
-- > foldrWithKey f "Map: " (fromList [(5,"a"), (3,"b")]) == "Map: (5:a)(3:b)"
foldrWithKey :: (Key -> a -> b -> b) -> b -> WordMap a -> b
foldrWithKey f z = start
  where
    start Empty = z
    start (NonEmpty min minV root) = f min minV (goL root z)
    
    goL Tip acc = acc
    goL (Bin max maxV l r) acc = goL l (goR r (f max maxV acc))
    
    goR Tip acc = acc
    goR (Bin min minV l r) acc = f min minV (goL l (goR r acc))

-- | /O(n)/. Fold the keys and values in the map using the given left-associative
-- binary operator, such that
-- @'foldlWithKey' f z == 'Prelude.foldl' (\\z' (kx, x) -> f z' kx x) z . 'toAscList'@.
--
-- For example,
--
-- > keys = reverse . foldlWithKey (\ks k x -> k:ks) []
--
-- > let f result k a = result ++ "(" ++ (show k) ++ ":" ++ a ++ ")"
-- > foldlWithKey f "Map: " (fromList [(5,"a"), (3,"b")]) == "Map: (3:b)(5:a)"
foldlWithKey :: (a -> Key -> b -> a) -> a -> WordMap b -> a
foldlWithKey f z = start
  where
    start Empty = z
    start (NonEmpty min minV root) = goL (f z min minV) root
    
    goL acc Tip = acc
    goL acc (Bin max maxV l r) = f (goR (goL acc l) r) max maxV
    
    goR acc Tip = acc
    goR acc (Bin min minV l r) = goR (goL (f acc min minV) l) r

-- | /O(n)/. Fold the keys and values in the map using the given monoid, such that
--
-- @'foldMapWithKey' f = 'Prelude.fold' . 'mapWithKey' f@
--
-- This can be an asymptotically faster than 'foldrWithKey' or 'foldlWithKey' for some monoids.
foldMapWithKey :: Monoid m => (Key -> a -> m) -> WordMap a -> m
foldMapWithKey f = start
  where
    start Empty = mempty
    start (NonEmpty min minV root) = f min minV `mappend` goL root
    
    goL Tip = mempty
    goL (Bin max maxV l r) = goL l `mappend` goR r `mappend` f max maxV
    
    goR Tip = mempty
    goR (Bin min minV l r) = f min minV `mappend` goL l `mappend` goR r

-- | /O(n)/. A strict version of 'foldr'. Each application of the operator is
-- evaluated before using the result in the next application. This
-- function is strict in the starting value.
foldr' :: (a -> b -> b) -> b -> WordMap a -> b
foldr' f z = start
  where
    start Empty = z
    start (NonEmpty _ minV root) = f minV $! goL root $! z
    
    goL Tip acc = acc
    goL (Bin _ maxV l r) acc = goL l $! goR r $! f maxV $! acc
    
    goR Tip acc = acc
    goR (Bin _ minV l r) acc = f minV $! goL l $! goR r $! acc

-- | /O(n)/. A strict version of 'foldl'. Each application of the operator is
-- evaluated before using the result in the next application. This
-- function is strict in the starting value.
foldl' :: (a -> b -> a) -> a -> WordMap b -> a
foldl' f z = start
  where
    start Empty = z
    start (NonEmpty _ minV root) = s goL (s f z minV) root
    
    goL acc Tip = acc
    goL acc (Bin _ maxV l r) = s f (s goR (s goL acc l) r) maxV
    
    goR acc Tip = acc
    goR acc (Bin _ minV l r) = s goR (s goL (s f acc minV) l) r
    
    s = ($!)

-- | /O(n)/. A strict version of 'foldrWithKey'. Each application of the operator is
-- evaluated before using the result in the next application. This
-- function is strict in the starting value.
foldrWithKey' :: (Key -> a -> b -> b) -> b -> WordMap a -> b
foldrWithKey' f z = start
  where
    start Empty = z
    start (NonEmpty min minV root) = f min minV $! goL root $! z
    
    goL Tip acc = acc
    goL (Bin max maxV l r) acc = goL l $! goR r $! f max maxV $! acc
    
    goR Tip acc = acc
    goR (Bin min minV l r) acc = f min minV $! goL l $! goR r $! acc

-- | /O(n)/. A strict version of 'foldlWithKey'. Each application of the operator is
-- evaluated before using the result in the next application. This
-- function is strict in the starting value.
foldlWithKey' :: (a -> Key -> b -> a) -> a -> WordMap b -> a
foldlWithKey' f z = start
  where
    start Empty = z
    start (NonEmpty min minV root) = s goL (s f z min minV) root
    
    goL acc Tip = acc
    goL acc (Bin max maxV l r) = s f (s goR (s goL acc l) r) max maxV
    
    goR acc Tip = acc
    goR acc (Bin min minV l r) = s goR (s goL (s f acc min minV) l) r
    
    s = ($!)

-- | /O(n)/. Convert the map to a list of key\/value pairs.
toList :: WordMap a -> [(Key, a)]
toList = start
  where
    start  Empty = []
    start (NonEmpty min minV node) = (min, minV) : goL node []
    
    goL Tip rest = rest
    goL (Bin max maxV l r) rest = goL l $ goR r $ (max, maxV) : rest
    
    goR Tip rest = rest
    goR (Bin min minV l r) rest = (min, minV) : (goL l $ goR r $ rest)

-- | /O(n*min(n,W))/. Create a map from a list of key\/value pairs.
fromList :: [(Key, a)] -> WordMap a
fromList = Data.Foldable.foldr (uncurry insert) empty

-- | /O(n)/. Filter all values that satisfy some predicate.
--
-- > filter (> "a") (fromList [(5,"a"), (3,"b")]) == singleton 3 "b"
-- > filter (> "x") (fromList [(5,"a"), (3,"b")]) == empty
-- > filter (< "a") (fromList [(5,"a"), (3,"b")]) == empty
filter :: (a -> Bool) -> WordMap a -> WordMap a
filter p = filterWithKey (const p)

-- | /O(n)/. Filter all keys\/values that satisfy some predicate.
--
-- > filterWithKey (\k _ -> k > 4) (fromList [(5,"a"), (3,"b")]) == singleton 5 "a"
filterWithKey :: (Key -> a -> Bool) -> WordMap a -> WordMap a
filterWithKey p = start
  where
    start Empty = Empty
    start (NonEmpty min minV root)
        | p min minV = NonEmpty min minV (goL root)
        | otherwise = goDeleteL root
    
    goL Tip = Tip
    goL (Bin max maxV l r)
        | p max maxV = Bin max maxV (goL l) (goR r)
        | otherwise = case goDeleteR r of
            Empty -> goL l
            NonEmpty max' maxV' r' -> Bin max' maxV' (goL l) r'
    
    goR Tip = Tip
    goR (Bin min minV l r)
        | p min minV = Bin min minV (goL l) (goR r)
        | otherwise = case goDeleteL l of
            Empty -> goR r
            NonEmpty min' minV' l' -> Bin min' minV' l' (goR r)
    
    goDeleteL Tip = Empty
    goDeleteL (Bin max maxV l r)
        | p max maxV = case goDeleteL l of
            Empty -> case goR r of
                Tip -> NonEmpty max maxV Tip
                Bin minI minVI lI rI -> NonEmpty minI minVI (Bin max maxV lI rI)
            NonEmpty min minV l' -> NonEmpty min minV (Bin max maxV l' (goR r))
        | otherwise = binL (goDeleteL l) (goDeleteR r)
    
    goDeleteR Tip = Empty
    goDeleteR (Bin min minV l r)
        | p min minV = case goDeleteR r of
            Empty -> case goL l of
                Tip -> NonEmpty min minV Tip
                Bin maxI maxVI lI rI -> NonEmpty maxI maxVI (Bin min minV lI rI)
            NonEmpty max maxV r' -> NonEmpty max maxV (Bin min minV (goL l) r')
        | otherwise = binR (goDeleteL l) (goDeleteR r)

-- | /O(n)/. Partition the map according to some predicate. The first
-- map contains all elements that satisfy the predicate, the second all
-- elements that fail the predicate. See also 'split'.
--
-- > partition (> "a") (fromList [(5,"a"), (3,"b")]) == (singleton 3 "b", singleton 5 "a")
-- > partition (< "x") (fromList [(5,"a"), (3,"b")]) == (fromList [(3, "b"), (5, "a")], empty)
-- > partition (> "x") (fromList [(5,"a"), (3,"b")]) == (empty, fromList [(3, "b"), (5, "a")])
partition :: (a -> Bool) -> WordMap a -> (WordMap a, WordMap a)
partition p = partitionWithKey (const p)

-- | /O(n)/. Partition the map according to some predicate. The first
-- map contains all elements that satisfy the predicate, the second all
-- elements that fail the predicate. See also 'split'.
--
-- > partitionWithKey (\ k _ -> k > 3) (fromList [(5,"a"), (3,"b")]) == (singleton 5 "a", singleton 3 "b")
-- > partitionWithKey (\ k _ -> k < 7) (fromList [(5,"a"), (3,"b")]) == (fromList [(3, "b"), (5, "a")], empty)
-- > partitionWithKey (\ k _ -> k > 7) (fromList [(5,"a"), (3,"b")]) == (empty, fromList [(3, "b"), (5, "a")])
partitionWithKey :: (Key -> a -> Bool) -> WordMap a -> (WordMap a, WordMap a)
partitionWithKey p = start
  where
    start Empty = (Empty, Empty)
    start (NonEmpty min minV root)
        | p min minV = let SP t f = goTrueL root
                       in (NonEmpty min minV t, f)
        | otherwise  = let SP t f = goFalseL root
                       in (t, NonEmpty min minV f)
    
    goTrueL Tip = SP Tip Empty
    goTrueL (Bin max maxV l r)
        | p max maxV = let SP tl fl = goTrueL l
                           SP tr fr = goTrueR r
                       in SP (Bin max maxV tl tr) (binL fl fr)
        | otherwise = let SP tl fl = goTrueL l
                          SP tr fr = goFalseR r
                          t = case tr of
                            Empty -> tl
                            NonEmpty max' maxV' r' -> Bin max' maxV' tl r'
                          f = case fl of
                            Empty -> flipBounds $ NonEmpty max maxV fr
                            NonEmpty min' minV' l' -> NonEmpty min' minV' (Bin max maxV l' fr)
                      in SP t f
    
    goTrueR Tip = SP Tip Empty
    goTrueR (Bin min minV l r)
        | p min minV = let SP tl fl = goTrueL l
                           SP tr fr = goTrueR r
                       in SP (Bin min minV tl tr) (binR fl fr)
        | otherwise = let SP tl fl = goFalseL l
                          SP tr fr = goTrueR r
                          t = case tl of
                            Empty -> tr
                            NonEmpty min' minV' l' -> Bin min' minV' l' tr
                          f = case fr of
                            Empty -> flipBounds $ NonEmpty min minV fl
                            NonEmpty max' maxV' r' -> NonEmpty max' maxV' (Bin min minV fl r')
                      in SP t f
    
    goFalseL Tip = SP Empty Tip
    goFalseL (Bin max maxV l r)
        | p max maxV = let SP tl fl = goFalseL l
                           SP tr fr = goTrueR r
                           t = case tl of
                             Empty -> flipBounds $ NonEmpty max maxV tr
                             NonEmpty min' minV' l' -> NonEmpty min' minV' (Bin max maxV l' tr)
                           f = case fr of
                             Empty -> fl
                             NonEmpty max' maxV' r' -> Bin max' maxV' fl r'
                       in SP t f
        | otherwise = let SP tl fl = goFalseL l
                          SP tr fr = goFalseR r
                      in SP (binL tl tr) (Bin max maxV fl fr)
    
    goFalseR Tip = SP Empty Tip
    goFalseR (Bin min minV l r)
        | p min minV = let SP tl fl = goTrueL l
                           SP tr fr = goFalseR r
                           t = case tr of
                             Empty -> flipBounds $ NonEmpty min minV tl
                             NonEmpty max' maxV' r' -> NonEmpty max' maxV' (Bin min minV tl r')
                           f = case fl of
                             Empty -> fr
                             NonEmpty min' minV' l' -> Bin min' minV' l' fr
                       in SP t f
        | otherwise = let SP tl fl = goFalseL l
                          SP tr fr = goFalseR r
                      in SP (binR tl tr) (Bin min minV fl fr)

data SP a b = SP !a !b

-- | /O(n)/. Map values and collect the 'Just' results.
--
-- > let f x = if x == "a" then Just "new a" else Nothing
-- > mapMaybe f (fromList [(5,"a"), (3,"b")]) == singleton 5 "new a"
mapMaybe :: (a -> Maybe b) -> WordMap a -> WordMap b
mapMaybe f = mapMaybeWithKey (const f)

-- | /O(n)/. Map keys\/values and collect the 'Just' results.
--
-- > let f k _ = if k < 5 then Just ("key : " ++ (show k)) else Nothing
-- > mapMaybeWithKey f (fromList [(5,"a"), (3,"b")]) == singleton 3 "key : 3"
mapMaybeWithKey :: (Key -> a -> Maybe b) -> WordMap a -> WordMap b
mapMaybeWithKey f = start
  where
    start Empty = Empty
    start (NonEmpty min minV root) = case f min minV of
        Just minV' -> NonEmpty min minV' (goL root)
        Nothing -> goDeleteL root
    
    goL Tip = Tip
    goL (Bin max maxV l r) = case f max maxV of
        Just maxV' -> Bin max maxV' (goL l) (goR r)
        Nothing -> case goDeleteR r of
            Empty -> goL l
            NonEmpty max' maxV' r' -> Bin max' maxV' (goL l) r'
    
    goR Tip = Tip
    goR (Bin min minV l r) = case f min minV of
        Just minV' -> Bin min minV' (goL l) (goR r)
        Nothing -> case goDeleteL l of
            Empty -> goR r
            NonEmpty min' minV' l' -> Bin min' minV' l' (goR r)
    
    goDeleteL Tip = Empty
    goDeleteL (Bin max maxV l r) = case f max maxV of
        Just maxV' -> case goDeleteL l of
            Empty -> case goR r of
                Tip -> NonEmpty max maxV' Tip
                Bin minI minVI lI rI -> NonEmpty minI minVI (Bin max maxV' lI rI)
            NonEmpty min minV l' -> NonEmpty min minV (Bin max maxV' l' (goR r))
        Nothing -> binL (goDeleteL l) (goDeleteR r)
    
    goDeleteR Tip = Empty
    goDeleteR (Bin min minV l r) = case f min minV of
        Just minV' -> case goDeleteR r of
            Empty -> case goL l of
                Tip -> NonEmpty min minV' Tip
                Bin maxI maxVI lI rI -> NonEmpty maxI maxVI (Bin min minV' lI rI)
            NonEmpty max maxV r' -> NonEmpty max maxV (Bin min minV' (goL l) r')
        Nothing -> binR (goDeleteL l) (goDeleteR r)

-- | /O(n)/. Map values and separate the 'Left' and 'Right' results.
--
-- > let f a = if a < "c" then Left a else Right a
-- > mapEither f (fromList [(5,"a"), (3,"b"), (1,"x"), (7,"z")])
-- >     == (fromList [(3,"b"), (5,"a")], fromList [(1,"x"), (7,"z")])
-- >
-- > mapEither (\ a -> Right a) (fromList [(5,"a"), (3,"b"), (1,"x"), (7,"z")])
-- >     == (empty, fromList [(5,"a"), (3,"b"), (1,"x"), (7,"z")])
mapEither :: (a -> Either b c) -> WordMap a -> (WordMap b, WordMap c)
mapEither f = mapEitherWithKey (const f)

-- | /O(n)/. Map keys\/values and separate the 'Left' and 'Right' results.
--
-- > let f k a = if k < 5 then Left (k * 2) else Right (a ++ a)
-- > mapEitherWithKey f (fromList [(5,"a"), (3,"b"), (1,"x"), (7,"z")])
-- >     == (fromList [(1,2), (3,6)], fromList [(5,"aa"), (7,"zz")])
-- >
-- > mapEitherWithKey (\_ a -> Right a) (fromList [(5,"a"), (3,"b"), (1,"x"), (7,"z")])
-- >     == (empty, fromList [(1,"x"), (3,"b"), (5,"a"), (7,"z")])
mapEitherWithKey :: (Key -> a -> Either b c) -> WordMap a -> (WordMap b, WordMap c)
mapEitherWithKey func = start
  where
    start Empty = (Empty, Empty)
    start (NonEmpty min minV root) = case func min minV of
        Left v  -> let SP t f = goTrueL root
                   in (NonEmpty min v t, f)
        Right v -> let SP t f = goFalseL root
                   in (t, NonEmpty min v f)
    
    goTrueL Tip = SP Tip Empty
    goTrueL (Bin max maxV l r) = case func max maxV of
        Left v  -> let SP tl fl = goTrueL l
                       SP tr fr = goTrueR r
                   in SP (Bin max v tl tr) (binL fl fr)
        Right v -> let SP tl fl = goTrueL l
                       SP tr fr = goFalseR r
                       t = case tr of
                            Empty -> tl
                            NonEmpty max' maxV' r' -> Bin max' maxV' tl r'
                       f = case fl of
                            Empty -> flipBounds $ NonEmpty max v fr
                            NonEmpty min' minV' l' -> NonEmpty min' minV' (Bin max v l' fr)
                   in SP t f
    
    goTrueR Tip = SP Tip Empty
    goTrueR (Bin min minV l r) = case func min minV of
        Left v  -> let SP tl fl = goTrueL l
                       SP tr fr = goTrueR r
                   in SP (Bin min v tl tr) (binR fl fr)
        Right v -> let SP tl fl = goFalseL l
                       SP tr fr = goTrueR r
                       t = case tl of
                            Empty -> tr
                            NonEmpty min' minV' l' -> Bin min' minV' l' tr
                       f = case fr of
                            Empty -> flipBounds $ NonEmpty min v fl
                            NonEmpty max' maxV' r' -> NonEmpty max' maxV' (Bin min v fl r')
                   in SP t f
    
    goFalseL Tip = SP Empty Tip
    goFalseL (Bin max maxV l r) = case func max maxV of
        Left v  -> let SP tl fl = goFalseL l
                       SP tr fr = goTrueR r
                       t = case tl of
                            Empty -> flipBounds $ NonEmpty max v tr
                            NonEmpty min' minV' l' -> NonEmpty min' minV' (Bin max v l' tr)
                       f = case fr of
                            Empty -> fl
                            NonEmpty max' maxV' r' -> Bin max' maxV' fl r'
                   in SP t f
        Right v -> let SP tl fl = goFalseL l
                       SP tr fr = goFalseR r
                   in SP (binL tl tr) (Bin max v fl fr)
    
    goFalseR Tip = SP Empty Tip
    goFalseR (Bin min minV l r) = case func min minV of
        Left v  -> let SP tl fl = goTrueL l
                       SP tr fr = goFalseR r
                       t = case tr of
                            Empty -> flipBounds $ NonEmpty min v tl
                            NonEmpty max' maxV' r' -> NonEmpty max' maxV' (Bin min v tl r')
                       f = case fl of
                            Empty -> fr
                            NonEmpty min' minV' l' -> Bin min' minV' l' fr
                   in SP t f
        Right v -> let SP tl fl = goFalseL l
                       SP tr fr = goFalseR r
                   in SP (binR tl tr) (Bin min v fl fr)

split :: Key -> WordMap a -> (WordMap a, WordMap a)
split k m = case splitLookup k m of
    (lt, _, gt) -> (lt, gt)

splitLookup :: Key -> WordMap a -> (WordMap a, Maybe a, WordMap a)
splitLookup k = k `seq` start
  where
    start Empty = (Empty, Nothing, Empty)
    start m@(NonEmpty min minV root)
        | k > min = case root of
            Tip -> (m, Nothing, Empty)
            Bin max maxV l r | k < max -> let (DR glb glbV lt, eq, DR lub lubV gt) = go (xor min k) min minV (xor k max) max maxV l r
                                          in (flipBounds (NonEmpty glb glbV lt), eq, NonEmpty lub lubV gt)
                             | k > max -> (m, Nothing, Empty)
                             | otherwise -> let DR max' maxV' root' = goDeleteMax min minV l r
                                            in (flipBounds (NonEmpty max' maxV' root'), Just maxV, Empty)
                                
        | k < min = (Empty, Nothing, m)
        | otherwise = case root of
            Tip -> (Empty, Just minV, Empty)
            Bin max maxV l r -> let DR min' minV' root' = goDeleteMin max maxV l r
                                in (Empty, Just minV, NonEmpty min' minV' root')
    
    go xorCacheMin min minV xorCacheMax max maxV l r
        | xorCacheMin < xorCacheMax = case l of
            Tip -> (DR min minV Tip, Nothing, flipBoundsDR (DR max maxV r))
            Bin maxI maxVI lI rI
                | k < maxI -> let (lt, eq, DR minI minVI gt) = go xorCacheMin min minV (xor k maxI) maxI maxVI lI rI
                              in (lt, eq, DR minI minVI (Bin max maxV gt r))
                | k > maxI -> (flipBoundsDR (DR min minV l), Nothing, flipBoundsDR (DR max maxV r))
                | otherwise -> (goDeleteMax min minV lI rI, Just maxVI, flipBoundsDR (DR max maxV r))
        | otherwise = case r of
            Tip -> (flipBoundsDR (DR min minV l), Nothing, DR max maxV Tip)
            Bin minI minVI lI rI
                | k > minI -> let (DR maxI maxVI lt, eq, gt) = go (xor minI k) minI minVI xorCacheMax max maxV lI rI
                              in (DR maxI maxVI (Bin min minV l lt), eq, gt)
                | k < minI -> (flipBoundsDR (DR min minV l), Nothing, flipBoundsDR (DR max maxV r))
                | otherwise -> (flipBoundsDR (DR min minV l), Just minVI, goDeleteMin max maxV lI rI)
    
    goDeleteMin max maxV l r = case l of
        Tip -> case r of
            Tip -> DR max maxV r
            Bin min minV l' r' -> DR min minV (Bin max maxV l' r')
        Bin maxI maxVI lI rI -> let DR min minV l' = goDeleteMin maxI maxVI lI rI
                                in  DR min minV (Bin max maxV l' r)
    
    goDeleteMax min minV l r = case r of
        Tip -> case l of
            Tip -> DR min minV l
            Bin max maxV l' r' -> DR max maxV (Bin min minV l' r')
        Bin minI minVI lI rI -> let DR max maxV r' = goDeleteMax minI minVI lI rI
                                in  DR max maxV (Bin min minV l r')

-- | /O(1)/. The minimal key of the map.
findMin :: WordMap a -> (Key, a)
findMin Empty = error "findMin: empty map has no minimal element"
findMin (NonEmpty min minV _) = (min, minV)

-- | /O(1)/. The maximal key of the map.
findMax :: WordMap a -> (Key, a)
findMax Empty = error "findMin: empty map has no minimal element"
findMax (NonEmpty min minV root) = case root of
    Tip -> (min, minV)
    Bin max maxV _ _ -> (max, maxV)

-- | /O(min(n,W))/. Delete the minimal key. Returns an empty map if the map is empty.
--
-- Note that this is a change of behaviour for consistency with 'Data.Map.Map' &#8211;
-- versions prior to 0.5 threw an error if the 'IntMap' was already empty.
deleteMin :: WordMap a -> WordMap a
deleteMin Empty = Empty
deleteMin m = delete (fst (findMin m)) m

-- | /O(min(n,W))/. Delete the maximal key. Returns an empty map if the map is empty.
--
-- Note that this is a change of behaviour for consistency with 'Data.Map.Map' &#8211;
-- versions prior to 0.5 threw an error if the 'IntMap' was already empty.
deleteMax :: WordMap a -> WordMap a
deleteMax Empty = Empty
deleteMax m = delete (fst (findMax m)) m

-- | /O(min(n,W))/. Delete and find the minimal element.
deleteFindMin :: WordMap a -> ((Key, a), WordMap a)
deleteFindMin m = let (k, a) = findMin m
                  in ((k, a), delete k m)

-- | /O(min(n,W))/. Delete and find the maximal element.
deleteFindMax :: WordMap a -> ((Key, a), WordMap a)
deleteFindMax m = let (k, a) = findMax m
                  in ((k, a), delete k m)

-- | /O(min(n,W))/. Update the value at the minimal key.
--
-- > updateMin (\ a -> Just ("X" ++ a)) (fromList [(5,"a"), (3,"b")]) == fromList [(3, "Xb"), (5, "a")]
-- > updateMin (\ _ -> Nothing)         (fromList [(5,"a"), (3,"b")]) == singleton 5 "a"
updateMin :: (a -> Maybe a) -> WordMap a -> WordMap a
updateMin _ Empty = Empty
updateMin f m = update f (fst (findMin m)) m

-- | /O(min(n,W))/. Update the value at the maximal key.
--
-- > updateMax (\ a -> Just ("X" ++ a)) (fromList [(5,"a"), (3,"b")]) == fromList [(3, "b"), (5, "Xa")]
-- > updateMax (\ _ -> Nothing)         (fromList [(5,"a"), (3,"b")]) == singleton 3 "b"
updateMax :: (a -> Maybe a) -> WordMap a -> WordMap a
updateMax _ Empty = Empty
updateMax f m = update f (fst (findMax m)) m

-- | /O(min(n,W))/. Update the value at the minimal key.
--
-- > updateMinWithKey (\ k a -> Just ((show k) ++ ":" ++ a)) (fromList [(5,"a"), (3,"b")]) == fromList [(3,"3:b"), (5,"a")]
-- > updateMinWithKey (\ _ _ -> Nothing)                     (fromList [(5,"a"), (3,"b")]) == singleton 5 "a"
updateMinWithKey :: (Key -> a -> Maybe a) -> WordMap a -> WordMap a
updateMinWithKey _ Empty = Empty
updateMinWithKey f m = updateWithKey f (fst (findMin m)) m

-- | /O(min(n,W))/. Update the value at the maximal key.
--
-- > updateMaxWithKey (\ k a -> Just ((show k) ++ ":" ++ a)) (fromList [(5,"a"), (3,"b")]) == fromList [(3,"b"), (5,"5:a")]
-- > updateMaxWithKey (\ _ _ -> Nothing)                     (fromList [(5,"a"), (3,"b")]) == singleton 3 "b"
updateMaxWithKey :: (Key -> a -> Maybe a) -> WordMap a -> WordMap a
updateMaxWithKey _ Empty = Empty
updateMaxWithKey f m = updateWithKey f (fst (findMax m)) m

-- | /O(min(n,W))/. Retrieves the minimal key of the map, and the map
-- stripped of that element, or 'Nothing' if passed an empty map.
minView :: WordMap a -> Maybe (a, WordMap a)
minView Empty = Nothing
minView m = let (k, a) = findMin m
            in Just (a, delete k m)

-- | /O(min(n,W))/. Retrieves the maximal key of the map, and the map
-- stripped of that element, or 'Nothing' if passed an empty map.
maxView :: WordMap a -> Maybe (a, WordMap a)
maxView Empty = Nothing
maxView m = let (k, a) = findMax m
            in Just (a, delete k m)

-- | /O(min(n,W))/. Retrieves the minimal (key,value) pair of the map, and
-- the map stripped of that element, or 'Nothing' if passed an empty map.
--
-- > minViewWithKey (fromList [(5,"a"), (3,"b")]) == Just ((3,"b"), singleton 5 "a")
-- > minViewWithKey empty == Nothing
minViewWithKey :: WordMap a -> Maybe ((Key, a), WordMap a)
minViewWithKey Empty = Nothing
minViewWithKey m = let (k, a) = findMin m
                   in Just ((k, a), delete k m)

-- | /O(min(n,W))/. Retrieves the maximal (key,value) pair of the map, and
-- the map stripped of that element, or 'Nothing' if passed an empty map.
--
-- > maxViewWithKey (fromList [(5,"a"), (3,"b")]) == Just ((5,"a"), singleton 3 "b")
-- > maxViewWithKey empty == Nothing
maxViewWithKey :: WordMap a -> Maybe ((Key, a), WordMap a)
maxViewWithKey Empty = Nothing
maxViewWithKey m = let (k, a) = findMax m
                   in Just ((k, a), delete k m)

----------------------------

-- | Show the tree that implements the map.
showTree :: Show a => WordMap a -> String
showTree = unlines . aux where
    aux Empty = []
    aux (NonEmpty min minV node) = (show min ++ " " ++ show minV) : auxNode False node
    auxNode _ Tip = ["+-."]
    auxNode lined (Bin bound val l r) = ["+--" ++ show bound ++ " " ++ show val, prefix : "  |"] ++ fmap indent (auxNode True l) ++ [prefix : "  |"] ++ fmap indent (auxNode False r)
      where
        prefix = if lined then '|' else ' '
        indent line = prefix : "  " ++ line

valid :: WordMap a -> Bool
valid = start
  where
    start Empty = True
    start (NonEmpty min _ root) = allKeys (> min) root && goL min root
    
    goL _    Tip = True
    goL min (Bin max _ l r) =
           allKeys (< max) l
        && allKeys (< max) r
        && allKeys (\k -> xor min k < xor k max) l
        && allKeys (\k -> xor min k > xor k max) r
        && goL min l
        && goR max r
    
    goR _    Tip = True
    goR max (Bin min _ l r) =
           allKeys (> min) l
        && allKeys (> min) r
        && allKeys (\k -> xor min k < xor k max) l
        && allKeys (\k -> xor min k > xor k max) r
        && goL min l
        && goR max r
    
    allKeys _ Tip = True
    allKeys p (Bin b _ l r) = p b && allKeys p l && allKeys p r

-- | /O(1)/. Returns whether the most significant bit of its first
-- argument is less significant than the most significant bit of its
-- second argument.
{-# INLINE ltMSB #-}
ltMSB :: Word -> Word -> Bool
ltMSB x y = x < y && x < xor x y

{-# INLINE compareMSB #-}
compareMSB :: Word -> Word -> Ordering
compareMSB x y = case compare x y of
    LT | x < xor x y -> LT
    GT | y < xor x y -> GT
    _ -> EQ

{-# INLINE binL #-}
binL :: WordMap a -> WordMap a -> WordMap a
binL Empty r = flipBounds r
binL l Empty = l
binL (NonEmpty min minV l) (NonEmpty max maxV r) = NonEmpty min minV (Bin max maxV l r)

{-# INLINE binR #-}
binR :: WordMap a -> WordMap a -> WordMap a
binR Empty r = r
binR l Empty = flipBounds l
binR (NonEmpty min minV l) (NonEmpty max maxV r) = NonEmpty max maxV (Bin min minV l r)

{-# INLINE flipBounds #-}
flipBounds :: WordMap a -> WordMap a
flipBounds Empty = Empty
flipBounds n@(NonEmpty _ _ Tip) = n
flipBounds (NonEmpty b1 v1 (Bin b2 v2 l r)) = NonEmpty b2 v2 (Bin b1 v1 l r)

{-# INLINE flipBoundsDR #-}
flipBoundsDR :: DeleteResult a -> DeleteResult a
flipBoundsDR n@(DR _ _ Tip) = n
flipBoundsDR (DR b1 v1 (Bin b2 v2 l r)) = DR b2 v2 (Bin b1 v1 l r)
