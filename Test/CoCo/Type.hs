{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}

-- |
-- Module      : Test.CoCo.Type
-- Copyright   : (c) 2017 Michael Walker
-- License     : MIT
-- Maintainer  : Michael Walker <mike@barrucadu.co.uk>
-- Stability   : experimental
-- Portability : AllowAmbiguousTypes, FlexibleInstances, GADTs, KindSignatures, MagicHash, MultiParamTypeClasses, ScopedTypeVariables, TypeApplications, TypeOperators
--
-- A reimplementation of Data.Typeable and Data.Dynamic, but twisted
-- to my own malign purposes. This is basically all necessary because
-- the constructor for
-- @<http://hackage.haskell.org/package/base/docs/Data-Dynamic.html#t:Dynamic Data.Dynamic.Dynamic>@
-- isn't exposed. On the other hand, if it was exposed it would be
-- trivial to violate its invariant and write unsafeCoerce, swings and
-- roundabouts...
--
-- This is not good code. Do not come here to learn, unless you need
-- to solve the same problem. Here be dragons.
module Test.CoCo.Type
  ( -- * Dynamic
    Dynamic
  , toDyn
  , fromDyn
  , anyFromDyn
  , dynTypeRep
  , dynApp
  -- ** Type-safe coercions
  , coerceDyn
  , unwrapMonadicDyn
  -- ** Unsafe operations
  , unsafeToDyn
  , unsafeFromDyn
  , unsafeWrapMonadicDyn

  -- * Typeable
  , HasTypeRep
  , TypeRep
  , typeRep
  , typeOf
  , rawTypeRep
  -- ** Type-safe casting
  , (:~:)(..)
  , cast
  , eqT
  , gcast
  , coerceTypeRep
  -- ** Function types
  , funTys
  , funResultTy
  , typeArity
  -- ** Miscellaneous
  , unmonad
  , stateTypeRep
  , monadTyCon
  , monadTypeRep
  -- ** Unsafe operations
  , unsafeFromRawTypeRep
  ) where

import Data.Function (on)
import Data.Maybe (isJust)
import Data.Proxy (Proxy(..))
import Data.Typeable ((:~:)(..))
import qualified Data.Typeable as T
import GHC.Base (Any)
import Unsafe.Coerce (unsafeCoerce)

-------------------------------------------------------------------------------
-- Dynamic

-- | A dynamically-typed value, with state type @s@ and monad type
-- @m@.
data Dynamic (s :: *) (m :: * -> *) where
  Dynamic :: Any -> TypeRep s m -> Dynamic s m

instance Show (Dynamic s m) where
  show d = "Dynamic <" ++ show (dynTypeRep d) ++ ">"

-- | This only compares types.
instance Eq (Dynamic s m) where
  (==) = (==) `on` dynTypeRep

-- | This only compares types.
instance Ord (Dynamic s m) where
  compare = compare `on` dynTypeRep

-- | Convert a static value into a dynamic one.
toDyn :: HasTypeRep s m a => a -> Dynamic s m
toDyn a = Dynamic (unsafeCoerce a) (typeOf a)

-- | Try to convert a dynamic value back into a static one.
fromDyn :: HasTypeRep s m a => Dynamic s m -> Maybe a
fromDyn (Dynamic x ty) = case unsafeCoerce x of
  r | typeOf r == ty -> Just r
    | otherwise -> Nothing

-- | Throw away type information and get the 'Any' from a 'Dynamic'.
anyFromDyn :: Dynamic s m -> Any
anyFromDyn (Dynamic x _) = x

-- | Get the type of a dynamic value.
dynTypeRep :: Dynamic s m -> TypeRep s m
dynTypeRep (Dynamic _ ty) = ty

-- | Apply a dynamic function to a dynamic value, if the types match.
dynApp :: Dynamic s m -> Dynamic s m -> Maybe (Dynamic s m)
dynApp (Dynamic f t1) (Dynamic x t2) = case t1 `funResultTy` t2 of
  Just t3 -> Just (Dynamic ((unsafeCoerce f) x) t3)
  Nothing -> Nothing


-------------------------------------------------------------------------------
-- Type-safe coercions

-- | Change the state and monad type parameters of a dynamic value, if
-- the contained 'TypeRep' does not reference them.
coerceDyn :: Dynamic s1 m1 -> Maybe (Dynamic s2 m2)
coerceDyn (Dynamic x ty) = Dynamic x <$> coerceTypeRep ty

-- | Take a dynamic value containing a monadic value, and turn it into
-- a monadic value containing a dynamic value.
unwrapMonadicDyn :: Functor m => Dynamic s m -> Maybe (m (Dynamic s m))
unwrapMonadicDyn (Dynamic a ty) = case unmonad ty of
  Just innerTy -> Just $ (`Dynamic` innerTy) <$> unsafeCoerce a
  Nothing -> Nothing


-------------------------------------------------------------------------------
-- Unsafe operations

-- | Convert a static value into a dynamic one, using a regular normal
-- Typeable 'T.TypeRep'. This is safe if 'HasTypeRep' would assign
-- that 'T.TypeRep', and so is unsafe if the monad or state cases
-- apply.
unsafeToDyn :: T.TypeRep -> a -> Dynamic s m
unsafeToDyn ty a = Dynamic (unsafeCoerce a) (TypeRep ty)

-- | Convert a dynamic value into a static one. This is safe if
-- 'HasTypeRep' would assign the same 'T.TypeRep', and so is unsafe if
-- the monad or state cases apply.
unsafeFromDyn :: T.Typeable a => Dynamic s m -> Maybe a
unsafeFromDyn (Dynamic x ty) = case unsafeCoerce x of
  r | unsafeFromRawTypeRep (T.typeOf r) == ty -> Just r
    | otherwise -> Nothing

-- | Wrap a monadic value, given its type.
unsafeWrapMonadicDyn :: Functor m => TypeRep s m -> m (Dynamic s m) -> Dynamic s m
unsafeWrapMonadicDyn ty mdyn = Dynamic (unsafeCoerce $ fmap anyFromDyn mdyn) ty


-------------------------------------------------------------------------------
-- Typeable

-- | Typeable, but which can represent a non-Typeable state and monad
-- type.
class HasTypeRep (s :: *) (m :: * -> *) (a :: *) where
  typeRep# :: proxy a -> TypeRep s m

instance {-# OVERLAPPABLE #-} T.Typeable a => HasTypeRep s m a where
  typeRep# proxy = TypeRep (T.typeRep proxy)

instance {-# OVERLAPPABLE #-} HasTypeRep s m a => HasTypeRep s m (m a) where
  typeRep# _ =
    let ty = (typeRep# :: proxy a -> TypeRep s m) Proxy
    in monadTypeRep (rawTypeRep ty)

instance (HasTypeRep s m a, HasTypeRep s m b) => HasTypeRep s m (a -> b) where
  typeRep# _ = TypeRep $
    let tyA = (typeRep# :: proxy a -> TypeRep s m) Proxy
        tyB = (typeRep# :: proxy b -> TypeRep s m) Proxy
    in T.mkFunTy (rawTypeRep tyA) (rawTypeRep tyB)

instance {-# INCOHERENT #-} HasTypeRep s m s where
  typeRep# _ = stateTypeRep

-- | A concrete representation of a type of some expression, with a
-- state type @s@ and monad type @m@.
newtype TypeRep (s :: *) (m :: * -> *) = TypeRep T.TypeRep
  deriving (Eq, Ord)

instance Show (TypeRep s m) where
  show = show . rawTypeRep

-- | Get the underlying 'T.Typeable' 'T.TypeRep' from a 'TypeRep'.
rawTypeRep :: TypeRep s m -> T.TypeRep
rawTypeRep (TypeRep ty) = ty

-- | Takes a value of type @a@ with state @s@ in some monad @m@, and
-- returns a concrete representation of that type.
typeRep :: forall s m a proxy. HasTypeRep s m a => proxy a -> TypeRep s m
typeRep = typeRep#

-- | Get the type of a value.
typeOf :: forall s m a. HasTypeRep s m a => a -> TypeRep s m
typeOf _ = typeRep @s @m @a Proxy


-------------------------------------------------------------------------------
-- Type-safe casting

-- | The type-safe cast operation.
cast :: forall s m a b. (HasTypeRep s m a, HasTypeRep s m b) => a -> Maybe b
cast x = fmap (\Refl -> x) (eqT @s @m @a @b)

-- | Extract a witness of equality of two types
eqT :: forall s m a b. (HasTypeRep s m a, HasTypeRep s m b) => Maybe (a :~: b)
eqT = if typeRep @s @m @a Proxy == typeRep @s @m @b Proxy
      then Just $ unsafeCoerce Refl
      else Nothing

-- | Cast through a type constructor.
gcast :: forall s m a b c. (HasTypeRep s m a, HasTypeRep s m b) => c a -> Maybe (c b)
gcast x = fmap (\Refl -> x) (eqT @s @m @a @b)

-- | Change the state and monad type parameters of a 'TypeRep', if it
-- does not reference them.
coerceTypeRep :: TypeRep s1 m1 -> Maybe (TypeRep s2 m2)
coerceTypeRep (TypeRep ty)
    | check ty  = Just (TypeRep ty)
    | otherwise = Nothing
  where
    check raw_ty
      | stateTypeRep == TypeRep raw_ty    = False
      | isJust (unmonad $ TypeRep raw_ty) = False
      | otherwise = all check . snd $ T.splitTyConApp raw_ty


-------------------------------------------------------------------------------
-- Function types

-- | The types of a function's argument and result. Returns @Nothing@
-- if applied to any type other than a function type.
funTys :: TypeRep s m -> Maybe (TypeRep s m, TypeRep s m)
funTys ty = case T.splitTyConApp . rawTypeRep $ ty of
    (con, [argTy, resultTy]) | con == funTyCon -> Just (TypeRep argTy, TypeRep resultTy)
    _ -> Nothing
  where
    funTyCon = T.typeRepTyCon (T.typeRep (Proxy :: Proxy (() -> ())))

-- | Applies a type to a given function type, if the types match.
funResultTy :: TypeRep s m -> TypeRep s m -> Maybe (TypeRep s m)
funResultTy t1 t2 = TypeRep <$> rawTypeRep t1 `T.funResultTy` rawTypeRep t2

-- | The arity of a type. Non-function types have an arity of 0.
typeArity :: TypeRep s m -> Int
typeArity = go . rawTypeRep where
  go ty = case T.splitTyConApp ty of
    (con, [_, resultType]) | con == funTyCon -> 1 + go resultType
    _ -> 0

  funTyCon = T.typeRepTyCon (T.typeRep (Proxy :: Proxy (() -> ())))


-------------------------------------------------------------------------------
-- Miscellaneous

-- | Remove the monad type constructor from a type, if it has it.
unmonad :: TypeRep s m -> Maybe (TypeRep s m)
unmonad = go . rawTypeRep where
  go ty = case T.splitTyConApp ty of
    (con, [innerType]) | con == monadTyCon -> Just (TypeRep innerType)
    _ -> Nothing

-- | The 'TypeRep' of the state variable.
stateTypeRep :: TypeRep s m
stateTypeRep = TypeRep $ T.mkTyConApp (T.mkTyCon3 "" "" ":state:") []

-- | The 'T.Typeable' 'T.TyCon' of the monad variable.
monadTyCon :: T.TyCon
monadTyCon = T.mkTyCon3 "" "" ":monad:"

-- | The 'TypeRep' of a monadic value.
monadTypeRep :: T.TypeRep -> TypeRep s m
monadTypeRep ty = TypeRep $ T.mkTyConApp monadTyCon [ty]


-------------------------------------------------------------------------------
-- Unsafe operations

-- | Turn a 'T.TypeRep' into a 'TypeRep'. This is This is safe if
-- 'HasTypeRep' would assign that 'T.TypeRep', and so is unsafe if the
-- monad or state cases apply.
unsafeFromRawTypeRep :: T.TypeRep -> TypeRep s m
unsafeFromRawTypeRep = TypeRep