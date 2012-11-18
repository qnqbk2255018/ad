{-# LANGUAGE Rank2Types, TypeFamilies, FlexibleContexts, UndecidableInstances, TemplateHaskell, DeriveDataTypeable, BangPatterns #-}
-- {-# OPTIONS_HADDOCK hide, prune #-}
-----------------------------------------------------------------------------
-- |
-- Module      : Numeric.AD.Internal.Dense
-- Copyright   : (c) Edward Kmett 2010
-- License     : BSD3
-- Maintainer  : ekmett@gmail.com
-- Stability   : experimental
-- Portability : GHC only
--
-- Dense Forward AD. Useful when the result involves the majority of the input
-- elements. Do not use for 'Numeric.AD.Mode.Mixed.hessian' and beyond, since
-- they only contain a small number of unique @n@th derivatives --
-- @(n + k - 1) `choose` k@ for functions of @k@ inputs rather than the
-- @k^n@ that would be generated by using 'Dense', not to mention the redundant
-- intermediate derivatives that would be
-- calculated over and over during that process!
--
-- Assumes all instances of 'f' have the same number of elements.
--
-- NB: We don't need the full power of 'Traversable' here, we could get
-- by with a notion of zippable that can plug in 0's for the missing
-- entries. This might allow for gradients where @f@ has exponentials like @((->) a)@
-----------------------------------------------------------------------------

module Numeric.AD.Internal.Dense
    ( Dense(..)
    , ds
    , ds'
    , vars
    , apply
    ) where

import Language.Haskell.TH
import Data.Typeable ()
import Data.Traversable (Traversable, mapAccumL)
import Data.Data ()
import Numeric.AD.Internal.Types
import Numeric.AD.Internal.Combinators
import Numeric.AD.Internal.Classes
import Numeric.AD.Internal.Identity

data Dense f a
    = Lift !a
    | Dense !a (f a)
    | Zero

instance Show a => Show (Dense f a) where
    showsPrec d (Lift a)    = showsPrec d a
    showsPrec d (Dense a _) = showsPrec d a
    showsPrec _ Zero        = showString "0"

ds :: f a -> AD (Dense f) a -> f a
ds _ (AD (Dense _ da)) = da
ds z _ = z
{-# INLINE ds #-}

ds' :: Num a => f a -> AD (Dense f) a -> (a, f a)
ds' _ (AD (Dense a da)) = (a, da)
ds' z (AD (Lift a)) = (a, z)
ds' z (AD Zero) = (0, z)
{-# INLINE ds' #-}

-- Bind variables and count inputs
vars :: (Traversable f, Num a) => f a -> f (AD (Dense f) a)
vars as = snd $ mapAccumL outer (0 :: Int) as
    where
        outer !i a = (i + 1, AD $ Dense a $ snd $ mapAccumL (inner i) 0 as)
        inner !i !j _ = (j + 1, if i == j then 1 else 0)
{-# INLINE vars #-}

apply :: (Traversable f, Num a) => (f (AD (Dense f) a) -> b) -> f a -> b
apply f as = f (vars as)
{-# INLINE apply #-}

instance Primal (Dense f) where
    primal Zero = 0
    primal (Lift a) = a
    primal (Dense a _) = a

instance (Traversable f, Lifted (Dense f)) => Mode (Dense f) where
    auto = Lift
    zero = Zero

    Zero <+> a = a
    a <+> Zero = a
    Lift a     <+> Lift b     = Lift (a + b)
    Lift a     <+> Dense b db = Dense (a + b) db
    Dense a da <+> Lift b     = Dense (a + b) da
    Dense a da <+> Dense b db = Dense (a + b) $ zipWithT (+) da db

    Zero <**> y      = auto (0 ** primal y)
    _    <**> Zero   = auto 1
    x    <**> Lift y = lift1 (**y) (\z -> (y *^ z ** Id (y-1))) x
    x    <**> y      = lift2_ (**) (\z xi yi -> (yi *! z /! xi, z *! log1 xi)) x y

    _ *^ Zero       = Zero
    a *^ Lift b     = Lift (a * b)
    a *^ Dense b db = Dense (a * b) $ fmap (a*) db
    Zero       ^* _ = Zero
    Lift a     ^* b = Lift (a * b)
    Dense a da ^* b = Dense (a * b) $ fmap (*b) da
    Zero       ^/ _ = Zero
    Lift a     ^/ b = Lift (a / b)
    Dense a da ^/ b = Dense (a / b) $ fmap (/b) da

instance (Traversable f, Lifted (Dense f)) => Jacobian (Dense f) where
    type D (Dense f) = Id
    unary f _         Zero        = Lift (f 0)
    unary f _         (Lift b)    = Lift (f b)
    unary f (Id dadb) (Dense b db) = Dense (f b) (fmap (dadb *) db)

    lift1 f _  Zero        = Lift (f 0)
    lift1 f _  (Lift b)    = Lift (f b)
    lift1 f df (Dense b db) = Dense (f b) (fmap (dadb *) db)
        where
            Id dadb = df (Id b)

    lift1_ f _  Zero         = Lift (f 0)
    lift1_ f _  (Lift b)     = Lift (f b)
    lift1_ f df (Dense b db) = Dense a (fmap (dadb *) db)
        where
            a = f b
            Id dadb = df (Id a) (Id b)

    binary f _          _        Zero         Zero         = Lift (f 0 0)
    binary f _          _        Zero         (Lift c)     = Lift (f 0 c)
    binary f _          _        (Lift b)     Zero         = Lift (f b 0)
    binary f _          _        (Lift b)     (Lift c)     = Lift (f b c)
    binary f _         (Id dadc) Zero         (Dense c dc) = Dense (f 0 c) $ fmap (* dadc) dc
    binary f _         (Id dadc) (Lift b)     (Dense c dc) = Dense (f b c) $ fmap (* dadc) dc
    binary f (Id dadb) _         (Dense b db) Zero         = Dense (f b 0) $ fmap (dadb *) db
    binary f (Id dadb) _         (Dense b db) (Lift c)     = Dense (f b c) $ fmap (dadb *) db
    binary f (Id dadb) (Id dadc) (Dense b db) (Dense c dc) = Dense (f b c) $ zipWithT productRule db dc
        where productRule dbi dci = dadb * dbi + dci * dadc

    lift2 f _  Zero         Zero         = Lift (f 0 0)
    lift2 f _  Zero         (Lift c)     = Lift (f 0 c)
    lift2 f _  (Lift b)     Zero         = Lift (f b 0)
    lift2 f _  (Lift b)     (Lift c)     = Lift (f b c)
    lift2 f df Zero         (Dense c dc) = Dense (f 0 c) $ fmap (*dadc) dc where dadc = runId (snd (df (Id 0) (Id c)))
    lift2 f df (Lift b)     (Dense c dc) = Dense (f b c) $ fmap (*dadc) dc where dadc = runId (snd (df (Id b) (Id c)))
    lift2 f df (Dense b db) Zero         = Dense (f b 0) $ fmap (dadb*) db where dadb = runId (fst (df (Id b) (Id 0)))
    lift2 f df (Dense b db) (Lift c)     = Dense (f b c) $ fmap (dadb*) db where dadb = runId (fst (df (Id b) (Id c)))
    lift2 f df (Dense b db) (Dense c dc) = Dense (f b c) da
        where
            (Id dadb, Id dadc) = df (Id b) (Id c)
            da = zipWithT productRule db dc
            productRule dbi dci = dadb * dbi + dci * dadc

    lift2_ f _  Zero     Zero     = Lift (f 0 0)
    lift2_ f _  Zero     (Lift c) = Lift (f 0 c)
    lift2_ f _  (Lift b) Zero     = Lift (f b 0)
    lift2_ f _  (Lift b) (Lift c) = Lift (f b c)
    lift2_ f df Zero     (Dense c dc)
        = Dense a $ fmap (*dadc) dc
        where
            a = f 0 c
            (_, Id dadc) = df (Id a) (Id 0) (Id c)
    lift2_ f df (Lift b) (Dense c dc)
        = Dense a $ fmap (*dadc) dc
        where
            a = f b c
            (_, Id dadc) = df (Id a) (Id b) (Id c)
    lift2_ f df (Dense b db) Zero
        = Dense a $ fmap (dadb*) db
        where
            a = f b 0
            (Id dadb, _) = df (Id a) (Id b) (Id 0)
    lift2_ f df (Dense b db) (Lift c)
        = Dense a $ fmap (dadb*) db
        where
            a = f b c
            (Id dadb, _) = df (Id a) (Id b) (Id c)
    lift2_ f df (Dense b db) (Dense c dc)
        = Dense a $ zipWithT productRule db dc
        where
            a = f b c
            (Id dadb, Id dadc) = df (Id a) (Id b) (Id c)
            productRule dbi dci = dadb * dbi + dci * dadc

let f = varT (mkName "f") in
    deriveLifted
        (classP ''Traversable [f]:)
        (conT ''Dense `appT` f)
