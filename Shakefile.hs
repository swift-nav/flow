#!/usr/bin/env stack
{- stack
    runghc
      --package shakers
 -}
 

{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}

import Development.Shakers

-- | Main entry point.
--
main :: IO ()
main = shakeMain $ do
  let pats =
        [ "stack.yaml"
        , "Shakefile.hs"
        , "main//*.hs"
        , "src//*.hs"
        ]
      pats' = delete "stack.yaml" pats

  -- | Haskell rules.
  --
  hsRules "." pats'

  -- | Cabal rules.
  --
  cabalRules "." "wolf.cabal"

  -- | Stack rules.
  --
  stackRules "." pats

  -- | Default things to run.
  --
  want [ "build-error", "lint" ]
