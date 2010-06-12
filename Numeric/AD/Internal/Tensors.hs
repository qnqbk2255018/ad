{-# LANGUAGE TypeOperators, TemplateHaskell, ScopedTypeVariables #-}
{-# OPTIONS_HADDOCK hide #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  Numeric.AD.Internal.Tensors
-- Copyright   :  (c) Edward Kmett 2010
-- License     :  BSD3
-- Maintainer  :  ekmett@gmail.com
-- Stability   :  experimental
-- Portability :  GHC only
--
-----------------------------------------------------------------------------

module Numeric.AD.Internal.Tensors
    ( Tensors(..)
    , headT
    , tailT
    , tensors
    , vtensors
    ) where

import Control.Applicative
import Data.Foldable
import Data.Traversable
import Data.Monoid
import Data.Typeable (Typeable1(..), Typeable(..), TyCon, mkTyCon, mkTyConApp, typeOfDefault)
import Numeric.AD.Internal.Comonad
import Numeric.AD.Internal.Stream

infixl 3 :-

-- Polymorphic recursion precludes 'Data' in its current form, as no Data1 class exists
-- Polymorphic recursion also breaks 'show' for 'Tensors'!
-- factor Show1 out of Lifted?
data Tensors f a = a :- Tensors f (f a)

instance Functor f => Functor (Tensors f) where
    fmap f (a :- as) = f a :- fmap (fmap f) as

instance Foldable f => Foldable (Tensors f) where
    foldMap f (a :- as) = f a `mappend` foldMap (foldMap f) as

instance Traversable f => Traversable (Tensors f) where
    traverse f (a :- as) = (:-) <$> f a <*> traverse (traverse f) as

-- | While we can not be a 'Comonad' without a 'fzip'-like operation, you can use the
-- comonad for @'Stream' f a@ to manipulate a structure comonadically that you can turn 
-- into 'Tensors'.
instance Functor f => Copointed (Tensors f) where
    extract (a :- _) = a

tailT :: Tensors f a -> Tensors f (f a)
tailT (_ :- as) = as
{-# INLINE tailT #-}

headT :: Tensors f a -> a
headT (a :- _) = a
{-# INLINE headT #-}

tensors :: Functor f => Stream f a -> Tensors f a
tensors (a :< as) = a :- distribute (tensors <$> as)
    where
        distribute :: Functor f => f (Tensors f a) -> Tensors f (f a)
        distribute x = (headT <$> x) :- distribute (tailT <$> x)

vtensors :: Stream Vector a -> Tensors Vector a
vtensors (a :< as) = a :- distribute (Vector.map tensors as)
    where
        distribute :: Vector (Tensors Vector a) -> Tensors Vector (Vector a)
        distribute x = (Vector.map headT x) :- distribute (Vector.map tailT x)

instance Typeable1 f => Typeable1 (Tensors f) where
    typeOf1 tfa = mkTyConApp tensorsTyCon [typeOf1 (undefined `asArgsType` tfa)]
        where asArgsType :: f a -> t f a -> f a
              asArgsType = const

instance (Typeable1 f, Typeable a) => Typeable (Tensors f a) where
    typeOf = typeOfDefault
    
tensorsTyCon :: TyCon
tensorsTyCon = mkTyCon "Numeric.AD.Internal.Tensors.Tensors"
{-# NOINLINE tensorsTyCon #-}
