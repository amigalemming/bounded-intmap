{-# LANGUAGE BangPatterns, ScopedTypeVariables #-}

module Data.WordMap.Merge.Lazy (
    -- ** Simple merge tactic types
      WhenMissing
    , WhenMatched

    -- ** General combining function
    , merge

    -- ** @WhenMatched@ tactics
    , zipWithMaybeMatched
    , zipWithMatched

    -- *** @WhenMissing@ tactics
    , dropMissing
    , preserveMissing
    , mapMissing
    , mapMaybeMissing
    , filterMissing

    , unionWithM
    , intersectionWithM
) where

import Data.WordMap.Base
import Data.WordMap.Merge.Base

import Data.Bits (xor)

import Prelude hiding (min, max)

mapMissing :: forall a b. (Key -> a -> b) -> WhenMissing a b
mapMissing f = WhenMissing (\k v -> Just (f k v)) go go start where
    start (WordMap Empty) = WordMap Empty
    start (WordMap (NonEmpty min minV root)) = WordMap (NonEmpty min (f min minV) (go root))

    go :: Node t a -> Node t b
    go Tip = Tip
    go (Bin k v l r) = Bin k (f k v) (go l) (go r)

mapMaybeMissing :: (Key -> a -> Maybe b) -> WhenMissing a b
mapMaybeMissing f = WhenMissing f goLKeep goRKeep start where
    start (WordMap Empty) = WordMap Empty
    start (WordMap (NonEmpty min minV root)) = case f min minV of
        Just minV' -> WordMap (NonEmpty min minV' (goLKeep root))
        Nothing -> WordMap (goL root)

    goLKeep Tip = Tip
    goLKeep (Bin max maxV l r) = case f max maxV of
        Just maxV' -> Bin max maxV' (goLKeep l) (goRKeep r)
        Nothing -> case goR r of
            Empty -> goLKeep l
            NonEmpty max' maxV' r' -> Bin max' maxV' (goLKeep l) r'

    goRKeep Tip = Tip
    goRKeep (Bin min minV l r) = case f min minV of
        Just minV' -> Bin min minV' (goLKeep l) (goRKeep r)
        Nothing -> case goL l of
            Empty -> goRKeep r
            NonEmpty min' minV' l' -> Bin min' minV' l' (goRKeep r)

    goL Tip = Empty
    goL (Bin max maxV l r) = case f max maxV of
        Just maxV' -> case goL l of
            Empty -> case goRKeep r of
                Tip -> NonEmpty max maxV' Tip
                Bin minI minVI lI rI -> NonEmpty minI minVI (Bin max maxV' lI rI)
            NonEmpty min minV l' -> NonEmpty min minV (Bin max maxV' l' (goRKeep r))
        Nothing -> binL (goL l) (goR r)

    goR Tip = Empty
    goR (Bin min minV l r) = case f min minV of
        Just minV' -> case goR r of
            Empty -> case goLKeep l of
                Tip -> NonEmpty min minV' Tip
                Bin maxI maxVI lI rI -> NonEmpty maxI maxVI (Bin min minV' lI rI)
            NonEmpty max maxV r' -> NonEmpty max maxV (Bin min minV' (goLKeep l) r')
        Nothing -> binR (goL l) (goR r)

filterMissing :: (Key -> a -> Bool) -> WhenMissing a a
filterMissing p = WhenMissing (\k v -> if p k v then Just v else Nothing) goLKeep goRKeep start where
    start (WordMap Empty) = WordMap Empty
    start (WordMap (NonEmpty min minV root))
        | p min minV = WordMap (NonEmpty min minV (goLKeep root))
        | otherwise = WordMap (goL root)

    goLKeep Tip = Tip
    goLKeep (Bin max maxV l r)
        | p max maxV = Bin max maxV (goLKeep l) (goRKeep r)
        | otherwise = case goR r of
            Empty -> goLKeep l
            NonEmpty max' maxV' r' -> Bin max' maxV' (goLKeep l) r'

    goRKeep Tip = Tip
    goRKeep (Bin min minV l r)
        | p min minV = Bin min minV (goLKeep l) (goRKeep r)
        | otherwise = case goL l of
            Empty -> goRKeep r
            NonEmpty min' minV' l' -> Bin min' minV' l' (goRKeep r)

    goL Tip = Empty
    goL (Bin max maxV l r)
        | p max maxV = case goL l of
            Empty -> case goRKeep r of
                Tip -> NonEmpty max maxV Tip
                Bin minI minVI lI rI -> NonEmpty minI minVI (Bin max maxV lI rI)
            NonEmpty min minV l' -> NonEmpty min minV (Bin max maxV l' (goRKeep r))
        | otherwise = binL (goL l) (goR r)

    goR Tip = Empty
    goR (Bin min minV l r)
        | p min minV = case goR r of
            Empty -> case goLKeep l of
                Tip -> NonEmpty min minV Tip
                Bin maxI maxVI lI rI -> NonEmpty maxI maxVI (Bin min minV lI rI)
            NonEmpty max maxV r' -> NonEmpty max maxV (Bin min minV (goLKeep l) r')
        | otherwise = binR (goL l) (goR r)

{-# INLINE zipWithMaybeMatched #-}
zipWithMaybeMatched :: (Key -> a -> b -> Maybe c) -> WhenMatched a b c
zipWithMaybeMatched = WhenMatched

{-# INLINE zipWithMatched #-}
zipWithMatched :: (Key -> a -> b -> c) -> WhenMatched a b c
zipWithMatched f = zipWithMaybeMatched (\k a b -> Just (f k a b))

unionWithM :: (Key -> a -> a -> a) -> WordMap a -> WordMap a -> WordMap a
unionWithM f = merge preserveMissing preserveMissing (zipWithMatched f)

intersectionWithM :: (Key -> a -> b -> c) -> WordMap a -> WordMap b -> WordMap c
intersectionWithM f = merge dropMissing dropMissing (zipWithMatched f)