{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}

module Language.STLC3.Sample where

import Control.Applicative (Alternative (empty, (<|>)))
import Control.Monad.Fresh (FreshT (..), runFreshT)
import Control.Monad.Reader (MonadReader (ask, local), MonadTrans (..), ReaderT (runReaderT), runReader)
import Control.Monad.State (MonadState (get, put), StateT, modify)
import Control.Monad.Trans.Writer.Lazy (WriterT (runWriterT))
import Data.Bool (bool)
import Data.Functor ((<&>))
import qualified Data.List as List
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Maybe (fromMaybe)
import qualified Data.Text as Text
import Hedgehog (Gen, MonadGen (..))
import qualified Hedgehog.Gen as Gen
import Hedgehog.Internal.Gen (GenT)
import qualified Hedgehog.Internal.Gen as Gen
import qualified Hedgehog.Internal.Seed as Seed
import qualified Hedgehog.Internal.Tree as Tree
import qualified Language.STLC3 as STLC3

type GenM = ReaderT (Map STLC3.Type [STLC3.Term]) (FreshT Gen)

genTy :: forall m. MonadGen m => m STLC3.Type
genTy =
  Gen.recursive
    Gen.choice
    [ -- non-recursive generators
      pure STLC3.TyUnit,
      pure STLC3.TyBool
    ]
    [ -- recursive generators
      STLC3.TyFun <$> genTy <*> genTy
    ]

-- | Finalize generation by running the monad transformers for the environment
genWellTypedExp :: STLC3.Type -> Gen STLC3.Term
genWellTypedExp ty = runFreshT $ runReaderT (genWellTypedExp' ty) Map.empty

-- | Main recursive mechanism for genersating expressions for a given type.
genWellTypedExp' :: STLC3.Type -> GenM STLC3.Term
genWellTypedExp' ty =
  Gen.shrink shrinkExp $
    genWellTypedPath ty
      <|> Gen.recursive
        Gen.choice
        [ -- non-recursive generators
          genWellTypedExp'' ty
        ]
        [ -- recursive generators
          genWellTypedApp ty,
          genWellTypedExp' ty,
          genWellTypedExp''' ty
        ]

shrinkExp :: STLC3.Term -> [STLC3.Term]
shrinkExp (STLC3.TmApp f a) = fst . flip runReader STLC3.ids . runWriterT $ do
  f' <- STLC3.eval f
  case f' of
    STLC3.TmFun var _ b -> (: []) <$> (STLC3.subst var a b >>= STLC3.eval)
    _ -> pure []
shrinkExp _ = []

genWellTypedExp'' :: STLC3.Type -> GenM STLC3.Term
genWellTypedExp'' STLC3.TyUnit = pure STLC3.TmUnit
genWellTypedExp'' STLC3.TyBool = Gen.bool <&> bool STLC3.TmTrue STLC3.TmFalse
genWellTypedExp'' (STLC3.TyFun ty ty') = do
  var <- freshVar
  STLC3.TmFun var ty <$> local (insertVar var ty) (genWellTypedExp' ty')

freshVar :: GenM STLC3.Id
freshVar = lift . FreshT $ do
  i <- get
  modify succ
  pure (Text.pack $ 'x' : show i)

insertVar :: STLC3.Id -> STLC3.Type -> Map STLC3.Type [STLC3.Term] -> Map STLC3.Type [STLC3.Term]
insertVar x ty = Map.insertWith (<>) ty [STLC3.TmVar x] . fmap (List.filter (/= STLC3.TmVar x))

genWellTypedExp''' :: STLC3.Type -> GenM STLC3.Term
genWellTypedExp''' ty =
  let tmIf = do
        tm <- genWellTypedExp'' STLC3.TyBool
        tm' <- genWellTypedExp'' ty
        tm'' <- genWellTypedExp'' ty
        pure (STLC3.TmIf tm tm' tm'')
   in tmIf

genWellTypedApp :: STLC3.Type -> GenM STLC3.Term
genWellTypedApp ty = do
  tg <- genKnownTypeMaybe
  eg <- genWellTypedExp' tg
  let tf = STLC3.TyFun tg ty
  ef <- genWellTypedExp' tf
  pure (STLC3.TmApp ef eg)

-- | Try to look up a variable of the desired type from the environment.
-- This does not always succceed, throwing `empty` when unavailable.
genWellTypedPath :: STLC3.Type -> GenM STLC3.Term
genWellTypedPath ty = do
  paths <- ask
  case fromMaybe [] (Map.lookup ty paths) of
    [] -> empty
    es -> Gen.element es

-- | Generate either known types from the environment or new types.
genKnownTypeMaybe :: GenM STLC3.Type
genKnownTypeMaybe = do
  known <- ask
  if Map.null known
    then genTy
    else
      Gen.frequency
        [ (2, Gen.element $ Map.keys known),
          (1, genTy)
        ]

sample :: forall m a. Monad m => GenT m a -> StateT Seed.Seed m a
sample gen =
  let go :: StateT Seed.Seed m a
      go = do
        seed <- get
        let (seed', seed'') = Seed.split seed
        put seed''
        Tree.NodeT x _ <- lift . Tree.runTreeT . Gen.evalGenT 30 seed' $ gen
        maybe go pure x
   in go