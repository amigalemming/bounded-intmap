{-# LANGUAGE BangPatterns #-}
module Main where

import Control.DeepSeq
import Control.Exception (evaluate)
import Criterion.Main
import Data.List (foldl')
import qualified Data.IntMap as M
import qualified Data.IntMap.Bounded as W
import Data.Maybe (fromMaybe)
import Prelude hiding (lookup)

main = do
    let denseM = M.fromAscList elems :: M.IntMap Int
        denseW = W.fromList elems :: W.IntMap Int
        sparseM = M.fromAscList sElems :: M.IntMap Int
        sparseW = W.fromList sElems :: W.IntMap Int
    evaluate $ rnf denseM
    evaluate $ rnf denseW
    evaluate $ rnf sparseM
    evaluate $ rnf sparseW
    evaluate $ rnf sElemsSearch
    defaultMain
        [ bgroup "present"
            [ bgroup "lookup"
                [ bench "IntMap"  $ whnf (\m -> foldl' (\n k -> fromMaybe n (M.lookup k m)) 0 keys) denseM
                , bench "WordMap" $ whnf (\m -> foldl' (\n k -> fromMaybe n (W.lookup k m)) 0 keys) denseW
                ]
            , bgroup "member"
                [ bench "IntMap"  $ whnf (\m -> foldl' (\n x -> if M.member x m then n + 1 else n) 0 keys) denseM
                , bench "WordMap" $ whnf (\m -> foldl' (\n x -> if W.member x m then n + 1 else n) 0 keys) denseW
                ]
            , bgroup "insert"
                [ bench "IntMap"  $ whnf (\m -> foldl' (\m (k, v) -> M.insert k v m) m elems) denseM
                , bench "WordMap" $ whnf (\m -> foldl' (\m (k, v) -> W.insert k v m) m elems) denseW
                ]
            , bgroup "delete"
                [ bench "IntMap"  $ whnf (\m -> foldl' (\m k -> M.delete k m) m keys) denseM
                , bench "WordMap" $ whnf (\m -> foldl' (\m k -> W.delete k m) m keys) denseW
                ]
{-            , bgroup "update"
                [ bench "IntMap"  $ whnf (\m -> foldl' (\m k -> M.update Just k m) m keys) denseM
                , bench "WordMap" $ whnf (\m -> foldl' (\m k -> W.update Just k m) m keys) denseW
                ]-}
            ]
        , bgroup "absent"
            [ bgroup "lookup"
                [ bench "IntMap"  $ whnf (\m -> foldl' (\n k -> fromMaybe n (M.lookup k m)) 0 sKeysSearch) sparseM
                , bench "WordMap" $ whnf (\m -> foldl' (\n k -> fromMaybe n (W.lookup k m)) 0 sKeysSearch) sparseW
                ]
            , bgroup "member"
                [ bench "IntMap"  $ whnf (\m -> foldl' (\n x -> if M.member x m then n + 1 else n) 0 sKeysSearch) sparseM
                , bench "WordMap" $ whnf (\m -> foldl' (\n x -> if W.member x m then n + 1 else n) 0 sKeysSearch) sparseW
                ]
            , bgroup "insert"
                [ bench "IntMap" $ whnf (\m -> foldl' (\m (k, v) -> M.insert k v m) m sElemsSearch) sparseM
                , bench "WordMap" $ whnf (\m -> foldl' (\m (k, v) -> W.insert k v m) m sElemsSearch) sparseW
                ]
            , bgroup "delete"
                [ bench "IntMap" $ whnf (\m -> foldl' (\m k -> M.delete k m) m sKeysSearch) sparseM
                , bench "WordMap" $ whnf (\m -> foldl' (\m k -> W.delete k m) m sKeysSearch) sparseW
                ]
{-            , bgroup "update"
                [ bench "IntMap"  $ whnf (\m -> foldl' (\m k -> M.update Just k m) m sKeysSearch) sparseM
                , bench "WordMap" $ whnf (\m -> foldl' (\m k -> W.update Just k m) m sKeysSearch) sparseW
                ]-}
            ]
        ]
  where
    elems = zip keys values
    keys = [1..2^12]
    values = [1..2^12]
    sElems = zip sKeys sValues
    sElemsSearch = zip sKeysSearch sValues
    sKeys = [1,3..2^12]
    sKeysSearch = [2,4..2^12]
    sValues = [1,3..2^12]
