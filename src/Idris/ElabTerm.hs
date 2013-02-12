{-# LANGUAGE PatternGuards #-}

module Idris.ElabTerm where

import Idris.AbsSyntax
import Idris.DSL
import Idris.Delaborate

import Core.Elaborate hiding (Tactic(..))
import Core.TT
import Core.Evaluate

import Control.Monad
import Control.Monad.State
import Data.List
import Debug.Trace

-- Data to pass to recursively called elaborators; e.g. for where blocks,
-- paramaterised declarations, etc.

data ElabInfo = EInfo { params :: [(Name, PTerm)],
                        inblock :: Ctxt [Name], -- names in the block, and their params
                        liftname :: Name -> Name,
                        namespace :: Maybe [String] }

toplevel = EInfo [] emptyContext id Nothing

type ElabD a = Elab' [PDecl] a

-- Using the elaborator, convert a term in raw syntax to a fully
-- elaborated, typechecked term.
--
-- If building a pattern match, we convert undeclared variables from
-- holes to pattern bindings.

-- Also find deferred names in the term and their types

build :: IState -> ElabInfo -> Bool -> Name -> PTerm -> 
         ElabD (Term, [(Name, Type)], [PDecl])
build ist info pattern fn tm 
    = do elab ist info pattern False fn tm
         ivs <- get_instances
         hs <- get_holes
         ptm <- get_term
         -- Resolve remaining type classes. Two passes - first to get the
         -- default Num instances, second to clean up the rest
         when (not pattern) $
              mapM_ (\n -> when (n `elem` hs) $ 
                             do focus n
                                try (resolveTC 7 fn ist)
                                    (movelast n)) ivs
         ivs <- get_instances
         hs <- get_holes
         when (not pattern) $
              mapM_ (\n -> when (n `elem` hs) $ 
                             do focus n
                                resolveTC 7 fn ist) ivs
         probs <- get_probs
         tm <- get_term
         case probs of
            [] -> return ()
            ((_,_,_,e):es) -> lift (Error e)
         is <- getAux
         tt <- get_term
         let (tm, ds) = runState (collectDeferred tt) []
         log <- getLog
         if (log /= "") then trace log $ return (tm, ds, is)
            else return (tm, ds, is)

-- Build a term autogenerated as a typeclass method definition
-- (Separate, so we don't go overboard resolving things that we don't
-- know about yet on the LHS of a pattern def)

buildTC :: IState -> ElabInfo -> Bool -> Bool -> Name -> PTerm -> 
         ElabD (Term, [(Name, Type)], [PDecl])
buildTC ist info pattern tcgen fn tm 
    = do elab ist info pattern tcgen fn tm
         probs <- get_probs
         tm <- get_term
         case probs of
            [] -> return ()
            ((_,_,_,e):es) -> lift (Error e)
         is <- getAux
         tt <- get_term
         let (tm, ds) = runState (collectDeferred tt) []
         log <- getLog
         if (log /= "") then trace log $ return (tm, ds, is)
            else return (tm, ds, is)

-- Returns the set of declarations we need to add to complete the definition
-- (most likely case blocks to elaborate)

elab :: IState -> ElabInfo -> Bool -> Bool -> Name -> PTerm -> 
        ElabD ()
elab ist info pattern tcgen fn tm 
    = do elabE (False, False) tm -- (in argument, guarded)
         when pattern -- convert remaining holes to pattern vars
              (do update_term orderPats
--                   tm <- get_term
                  mkPat)
  where
    isph arg = case getTm arg of
        Placeholder -> (True, priority arg)
        _ -> (False, priority arg)

    toElab ina arg = case getTm arg of
        Placeholder -> Nothing
        v -> Just (priority arg, elabE ina v)

    toElab' ina arg = case getTm arg of
        Placeholder -> Nothing
        v -> Just (elabE ina v)

    mkPat = do hs <- get_holes
               tm <- get_term
               case hs of
                  (h: hs) -> do patvar h; mkPat
                  [] -> return ()

    elabE ina t = {- do g <- goal
                 tm <- get_term
                 trace ("Elaborating " ++ show t ++ " : " ++ show g ++ "\n\tin " ++ show tm) 
                    $ -} elab' ina t

    local f = do e <- get_env
                 return (f `elem` map fst e)

    elab' ina PType           = do apply RType []; solve
    elab' ina (PConstant c)  = do apply (RConstant c) []; solve
    elab' ina (PQuote r)     = do fill r; solve
    elab' ina (PTrue fc)     = try (elab' ina (PRef fc unitCon))
                                   (elab' ina (PRef fc unitTy))
    elab' ina (PFalse fc)    = elab' ina (PRef fc falseTy)
    elab' ina (PResolveTC (FC "HACK" _)) -- for chasing parent classes
       = resolveTC 5 fn ist
    elab' ina (PResolveTC fc) 
        | True = do c <- unique_hole (MN 0 "class")
                    instanceArg c
        | otherwise = do g <- goal
                         try (resolveTC 2 fn ist)
                          (do c <- unique_hole (MN 0 "class")
                              instanceArg c)
    elab' ina (PRefl fc t)   = elab' ina (PApp fc (PRef fc eqCon) [pimp (MN 0 "a") Placeholder,
                                                           pimp (MN 0 "x") t])
    elab' ina (PEq fc l r)   = elab' ina (PApp fc (PRef fc eqTy) [pimp (MN 0 "a") Placeholder,
                                                          pimp (MN 0 "b") Placeholder,
                                                          pexp l, pexp r])
    elab' ina@(_, a) (PPair fc l r) 
        = do hnf_compute 
             g <- goal
             case g of
                TType _ -> elabE (True, a) (PApp fc (PRef fc pairTy)
                                            [pexp l,pexp r])
                _ -> elabE (True, a) (PApp fc (PRef fc pairCon)
                                            [pimp (MN 0 "A") Placeholder,
                                             pimp (MN 0 "B") Placeholder,
                                             pexp l, pexp r])
    elab' ina (PDPair fc l@(PRef _ n) t r)
            = case t of 
                Placeholder -> 
                   do hnf_compute
                      g <- goal
                      case g of
                         TType _ -> asType
                         _ -> asValue
                _ -> asType
         where asType = elab' ina (PApp fc (PRef fc sigmaTy)
                                        [pexp t,
                                         pexp (PLam n Placeholder r)])
               asValue = elab' ina (PApp fc (PRef fc existsCon)
                                         [pimp (MN 0 "a") t,
                                          pimp (MN 0 "P") Placeholder,
                                          pexp l, pexp r])
    elab' ina (PDPair fc l t r) = elab' ina (PApp fc (PRef fc existsCon)
                                            [pimp (MN 0 "a") t,
                                             pimp (MN 0 "P") Placeholder,
                                             pexp l, pexp r])
    elab' ina (PAlternative True as) 
        = do hnf_compute
             ty <- goal
             ctxt <- get_context
             let (tc, _) = unApply ty
             let as' = pruneByType tc ctxt as
--              case as' of
--                 [a] -> elab' ina a
--                 as -> lift $ tfail $ CantResolveAlts (map showHd as)
             tryAll (zip (map (elab' ina) as') (map showHd as'))
        where showHd (PApp _ h _) = show h
              showHd x = show x
    elab' ina (PAlternative False as) 
        = trySeq as
        where -- if none work, take the error from the first
              trySeq (x : xs) = let e1 = elab' ina x in
                                    try e1 (trySeq' e1 xs)
              trySeq' deferr [] = deferr
              trySeq' deferr (x : xs) = try (elab' ina x) (trySeq' deferr xs)
    elab' ina (PPatvar fc n) | pattern = patvar n
    elab' (ina, guarded) (PRef fc n) | pattern && not (inparamBlock n)
                         = do ctxt <- get_context
                              let iscon = isConName Nothing n ctxt
                              let defined = case lookupTy Nothing n ctxt of
                                                [] -> False
                                                _ -> True
                            -- this is to stop us resolve type classes recursively
                              -- trace (show (n, guarded)) $
                              if (tcname n && ina) then erun fc $ patvar n
                                else if (defined && not guarded)
                                        then do apply (Var n) []; solve
                                        else try (do apply (Var n) []; solve)
                                                 (patvar n)
      where inparamBlock n = case lookupCtxtName Nothing n (inblock info) of
                                [] -> False
                                _ -> True
    elab' ina f@(PInferRef fc n) = elab' ina (PApp fc f [])
    elab' ina (PRef fc n) = erun fc $ do apply (Var n) []; solve
    elab' ina@(_, a) (PLam n Placeholder sc)
          = do -- n' <- unique_hole n
               -- let sc' = mapPT (repN n n') sc
               ptm <- get_term
               g <- goal
               attack; intro (Just n); 
               -- trace ("------ intro " ++ show n ++ " ---- \n" ++ show ptm) 
               elabE (True, a) sc; solve
       where repN n n' (PRef fc x) | x == n' = PRef fc n'
             repN _ _ t = t
    elab' ina@(_, a) (PLam n ty sc)
          = do hsin <- get_holes
               ptmin <- get_term
               tyn <- unique_hole (MN 0 "lamty")
               claim tyn RType
               attack
               ptm <- get_term
               hs <- get_holes
               -- trace ("BEFORE:\n" ++ show hsin ++ "\n" ++ show ptmin ++
               --       "\nNOW:\n" ++ show hs ++ "\n" ++ show ptm) $ 
               introTy (Var tyn) (Just n)
               -- end_unify
               focus tyn
               ptm <- get_term
               hs <- get_holes
               elabE (True, a) ty
               elabE (True, a) sc
               solve
    elab' ina@(_,a) (PPi _ n Placeholder sc)
          = do attack; arg n (MN 0 "ty"); elabE (True, a) sc; solve
    elab' ina@(_,a) (PPi _ n ty sc) 
          = do attack; tyn <- unique_hole (MN 0 "ty")
               claim tyn RType
               n' <- case n of 
                        MN _ _ -> unique_hole n
                        _ -> return n
               forall n' (Var tyn)
               focus tyn
               elabE (True, a) ty
               elabE (True, a) sc
               solve
    elab' ina@(_,a) (PLet n ty val sc)
          = do attack;
               tyn <- unique_hole (MN 0 "letty")
               claim tyn RType
               valn <- unique_hole (MN 0 "letval")
               claim valn (Var tyn)
               letbind n (Var tyn) (Var valn)
               case ty of
                   Placeholder -> return ()
                   _ -> do focus tyn
                           elabE (True, a) ty
               focus valn
               elabE (True, a) val
               elabE (True, a) sc
               ptm <- get_term
               solve
    elab' ina tm@(PApp fc (PInferRef _ f) args) = do
         rty <- goal
         ds <- get_deferred
         ctxt <- get_context
         -- make a function type a -> b -> c -> ... -> rty for the
         -- new function name
         env <- get_env
         argTys <- claimArgTys env args
         fn <- unique_hole (MN 0 "inf_fn")
         let fty = fnTy argTys rty
--             trace (show (ptm, map fst argTys)) $ focus fn
            -- build and defer the function application
         attack; deferType (mkN f) fty (map fst argTys); solve
         -- elaborate the arguments, to unify their types. They all have to
         -- be explicit.
         mapM_ elabIArg (zip argTys args)
       where claimArgTys env [] = return []
             claimArgTys env (arg : xs) | Just n <- localVar env (getTm arg)
                                  = do nty <- get_type (Var n) 
                                       ans <- claimArgTys env xs
                                       return ((n, (False, forget nty)) : ans)
             claimArgTys env (_ : xs) 
                                  = do an <- unique_hole (MN 0 "inf_argTy")
                                       aval <- unique_hole (MN 0 "inf_arg")
                                       claim an RType
                                       claim aval (Var an)
                                       ans <- claimArgTys env xs
                                       return ((aval, (True, (Var an))) : ans)
             fnTy [] ret  = forget ret
             fnTy ((x, (_, xt)) : xs) ret = RBind x (Pi xt) (fnTy xs ret)

             localVar env (PRef _ x) 
                           = case lookup x env of
                                  Just _ -> Just x
                                  _ -> Nothing
             localVar env _ = Nothing

             elabIArg ((n, (True, ty)), def) = do focus n; elabE ina (getTm def) 
             elabIArg _ = return () -- already done, just a name
             
             mkN n@(NS _ _) = n
             mkN n = case namespace info of
                        Just xs@(_:_) -> NS n xs
                        _ -> n

    -- if f is local, just do a simple_app
    elab' (ina, g) tm@(PApp fc (PRef _ f) args') 
       = do let args = {- case lookupCtxt f (inblock info) of
                          Just ps -> (map (pexp . (PRef fc)) ps ++ args')
                          _ ->-} args'
--             newtm <- mkSpecialised ist fc f (map getTm args') tm
            env <- get_env
            if (f `elem` map fst env && length args' == 1)
               then -- simple app, as below
                    do simple_app (elabE (ina, g) (PRef fc f)) 
                                  (elabE (True, g) (getTm (head args')))
                       solve
               else 
                 do ivs <- get_instances
                    ps <- get_probs
                    -- HACK: we shouldn't resolve type classes if we're defining an instance
                    -- function or default definition.
                    let isinf = f == inferCon || tcname f
                    -- if f is a type class, we need to know its arguments so that
                    -- we can unify with them
                    case lookupCtxt Nothing f (idris_classes ist) of
                        [] -> return ()
                        _ -> mapM_ setInjective (map getTm args')
                    ctxt <- get_context
                    let guarded = isConName Nothing f ctxt
                    ns <- apply (Var f) (map isph args)
                    ptm <- get_term
                    g <- goal
                    let (ns', eargs) = unzip $ 
                             sortBy (\(_,x) (_,y) -> 
                                            compare (priority x) (priority y))
                                    (zip ns args)
                    elabArgs (ina || not isinf, guarded)
                           [] False ns' (map (\x -> (lazyarg x, getTm x)) eargs)
                    mkSpecialised ist fc f (map getTm args') tm
                    solve
                    ptm <- get_term
                    ivs' <- get_instances
                    ps' <- get_probs
            -- Attempt to resolve any type classes which have 'complete' types,
            -- i.e. no holes in them
                    when (not pattern || (ina && not tcgen && not guarded)) $
                        mapM_ (\n -> do focus n
                                        g <- goal
                                        env <- get_env
                                        hs <- get_holes
                                        if all (\n -> not (n `elem` hs)) (freeNames g)
                                        -- let insts = filter tcname $ map fst (ctxtAlist (tt_ctxt ist))
                                         then try (resolveTC 7 fn ist)
                                                  (movelast n)
                                         else movelast n) 
                              (ivs' \\ ivs)
      where tcArg (n, PConstraint _ _ Placeholder _) = True
            tcArg _ = False

            tacTm (PTactics _) = True
            tacTm (PProof _) = True
            tacTm _ = False

            setInjective (PRef _ n) = setinj n
            setInjective (PApp _ (PRef _ n) _) = setinj n
            setInjective _ = return ()

    elab' ina@(_, a) (PApp fc f [arg])
          = erun fc $ 
             do simple_app (elabE ina f) (elabE (True, a) (getTm arg))
                solve
    elab' ina Placeholder = do (h : hs) <- get_holes
                               movelast h
    elab' ina (PMetavar n) = let n' = mkN n in
                                 do attack; defer n'; solve
        where mkN n@(NS _ _) = n
              mkN n = case namespace info of
                        Just xs@(_:_) -> NS n xs
                        _ -> n
    elab' ina (PProof ts) = do compute; mapM_ (runTac True ist) ts
    elab' ina (PTactics ts) 
        | not pattern = do mapM_ (runTac False ist) ts
        | otherwise = elab' ina Placeholder
    elab' ina (PElabError e) = fail (pshow ist e)
    elab' ina@(_, a) c@(PCase fc scr opts)
        = do attack
             tyn <- unique_hole (MN 0 "scty")
             claim tyn RType
             valn <- unique_hole (MN 0 "scval")
             scvn <- unique_hole (MN 0 "scvar")
             claim valn (Var tyn)
             letbind scvn (Var tyn) (Var valn)
             focus valn
             elabE (True, a) scr
             args <- get_env
             cname <- unique_hole' True (mkCaseName fn)
             let cname' = mkN cname
             elab' ina (PMetavar cname')
             let newdef = PClauses fc [] cname' 
                             (caseBlock fc cname' (reverse args) opts)
             -- fail $ "Not implemented " ++ show c ++ "\n" ++ show args
             -- elaborate case
             updateAux (newdef : )
             solve
        where mkCaseName (NS n ns) = NS (mkCaseName n) ns
              mkCaseName (UN x) = UN (x ++ "_case")
              mkCaseName (MN i x) = MN i (x ++ "_case")
              mkN n@(NS _ _) = n
              mkN n = case namespace info of
                        Just xs@(_:_) -> NS n xs
                        _ -> n
    elab' ina x = fail $ "Something's gone wrong. Did you miss a semi-colon somewhere?"

    caseBlock :: FC -> Name -> [(Name, Binder Term)] -> 
                               [(PTerm, PTerm)] -> [PClause]
    caseBlock fc n env opts 
        = let args = map mkarg (map fst (init env)) in
              map (mkClause args) opts
       where -- mkarg (MN _ _) = Placeholder
             mkarg n = PRef fc n
             -- may be shadowed names in the new pattern - so replace the
             -- old ones with an _
             mkClause args (l, r) 
                   = let args' = map (shadowed (allNamesIn l)) args
                         lhs = PApp fc (PRef fc n)
                                 (map pexp args' ++ [pexp l]) in
                         PClause fc n lhs [] r []

             shadowed new (PRef _ n) | n `elem` new = Placeholder
             shadowed new t = t

    elabArgs ina failed retry [] _
--         | retry = let (ns, ts) = unzip (reverse failed) in
--                       elabArgs ina [] False ns ts
        | otherwise = return ()
    elabArgs ina failed r (n:ns) ((_, Placeholder) : args) 
        = elabArgs ina failed r ns args
    elabArgs ina failed r (n:ns) ((lazy, t) : args)
        | lazy && not pattern 
          = do elabArg n (PApp bi (PRef bi (UN "lazy"))
                               [pimp (UN "a") Placeholder,
                                pexp t]); 
        | otherwise = elabArg n t
      where elabArg n t 
                = do hs <- get_holes
                     tm <- get_term
                     failed' <- -- trace (show (n, t, hs, tm)) $ 
                                case n `elem` hs of
                                   True ->
--                                       if r
--                                          then try (do focus n; elabE ina t; return failed)
--                                                   (return ((n,(lazy, t)):failed))
                                         do focus n; elabE ina t; return failed
                                   False -> return failed
                     elabArgs ina failed r ns args

-- For every alternative, look at the function at the head. Automatically resolve
-- any nested alternatives where that function is also at the head

pruneAlt :: [PTerm] -> [PTerm]
pruneAlt xs = map prune xs
  where
    prune (PApp fc1 (PRef fc2 f) as) 
        = PApp fc1 (PRef fc2 f) (fmap (fmap (choose f)) as)
    prune t = t

    choose f (PAlternative a as)
        = let as' = fmap (choose f) as
              fs = filter (headIs f) as' in
              case fs of
                 [a] -> a
                 _ -> PAlternative a as'
    choose f (PApp fc f' as) = PApp fc (choose f f') (fmap (fmap (choose f)) as)
    choose f t = t

    headIs f (PApp _ (PRef _ f') _) = f == f'
    headIs f (PApp _ f' _) = headIs f f'
    headIs f _ = True -- keep if it's not an application

-- Rule out alternatives that don't return the same type as the head of the goal
-- (If there are none left as a result, do nothing)
pruneByType :: Term -> Context -> [PTerm] -> [PTerm]
pruneByType (P _ n _) c as 
-- if the goal type is polymorphic, keep e
   | [] <- lookupTy Nothing n c = as
   | otherwise 
       = let asV = filter (headIs True n) as 
             as' = filter (headIs False n) as in
             case as' of
               [] -> case asV of
                        [] -> as
                        _ -> asV
               _ -> as'
  where
    headIs var f (PApp _ (PRef _ f') _) = typeHead var f f'
    headIs var f (PApp _ f' _) = headIs var f f'
    headIs var f (PPi _ _ _ sc) = headIs var f sc
    headIs _ _ _ = True -- keep if it's not an application

    typeHead var f f' 
        = case lookupTy Nothing f' c of
                       [ty] -> case unApply (getRetTy ty) of
                                    (P _ ftyn _, _) -> ftyn == f
                                    (V _, _) -> var -- keep, variable
                                    _ -> False
                       _ -> False

pruneByType t _ as = as

trivial :: IState -> ElabD ()
trivial ist = try' (do elab ist toplevel False False (MN 0 "tac") 
                                    (PRefl (FC "prf" 0) Placeholder)
                       return ())
                   (do env <- get_env
                       g <- goal
                       tryAll env
                       return ()) True
      where
        tryAll []     = fail "No trivial solution"
        tryAll ((x, b):xs) 
           = do -- if type of x has any holes in it, move on
                hs <- get_holes
                g <- goal
                if all (\n -> not (n `elem` hs)) (freeNames (binderTy b))
                   then try' (elab ist toplevel False False
                                    (MN 0 "tac") (PRef (FC "prf" 0) x))
                             (tryAll xs) True
                   else tryAll xs

findInstances :: IState -> Term -> [Name]
findInstances ist t 
    | (P _ n _, _) <- unApply t 
        = case lookupCtxt Nothing n (idris_classes ist) of
            [CI _ _ _ _ ins] -> ins
            _ -> []
    | otherwise = []

resolveTC :: Int -> Name -> IState -> ElabD ()
resolveTC 0 fn ist = fail $ "Can't resolve type class"
resolveTC 1 fn ist = try' (trivial ist) (resolveTC 0 fn ist) True
resolveTC depth fn ist 
      = do hnf_compute
           g <- goal
           ptm <- get_term
           hs <- get_holes 
           if True -- all (\n -> not (n `elem` hs)) (freeNames g)
            then try' (trivial ist)
                (do t <- goal
                    let insts = findInstances ist t
                    let (tc, ttypes) = unApply t
                    scopeOnly <- needsDefault t tc ttypes
                    tm <- get_term
--                    traceWhen (depth > 6) ("GOAL: " ++ show t ++ "\nTERM: " ++ show tm) $
--                        (tryAll (map elabTC (map fst (ctxtAlist (tt_ctxt ist)))))
--                     if scopeOnly then fail "Can't resolve" else
                    let depth' = if scopeOnly then 2 else depth
                    blunderbuss t depth' insts) True
            else do try' (trivial ist)
                         (do g <- goal
                             fail $ "Can't resolve " ++ show g) True
--             tm <- get_term
--                     fail $ "Can't resolve yet in " ++ show tm
  where
    elabTC n | n /= fn && tcname n = (resolve n depth, show n)
             | otherwise = (fail "Can't resolve", show n)

    needsDefault t num@(P _ (NS (UN "Num") ["Builtins"]) _) [P Bound a _]
        = do focus a
             fill (RConstant IType) -- default Int
             solve
             return False
    needsDefault t f as
          | all boundVar as = return True -- fail $ "Can't resolve " ++ show t
    needsDefault t f a = return False -- trace (show t) $ return ()

    boundVar (P Bound _ _) = True
    boundVar _ = False

    blunderbuss t d [] = do -- c <- get_env
                            -- ps <- get_probs
                            lift $ tfail $ CantResolve t
    blunderbuss t d (n:ns) 
        | n /= fn && tcname n = try' (resolve n d)
                                     (blunderbuss t d ns) True
        | otherwise = blunderbuss t d ns

    resolve n depth
       | depth == 0 = fail $ "Can't resolve type class"
       | otherwise 
           = do t <- goal
                let (tc, ttypes) = unApply t
--                 if (all boundVar ttypes) then resolveTC (depth - 1) fn insts ist 
--                   else do
                   -- if there's a hole in the goal, don't even try
                let imps = case lookupCtxtName Nothing n (idris_implicits ist) of
                                [] -> []
                                [args] -> map isImp (snd args) -- won't be overloaded!
                ps <- get_probs
                args <- apply (Var n) imps
                ps' <- get_probs
                when (length ps < length ps') $ fail "Can't apply type class"
--                 traceWhen (all boundVar ttypes) ("Progress: " ++ show t ++ " with " ++ show n) $
                mapM_ (\ (_,n) -> do focus n
                                     t' <- goal
                                     let (tc', ttype) = unApply t'
                                     let depth' = if t == t' then depth - 1 else depth
                                     resolveTC depth' fn ist) 
                      (filter (\ (x, y) -> not x) (zip (map fst imps) args))
                -- if there's any arguments left, we've failed to resolve
                hs <- get_holes
                solve
       where isImp (PImp p _ _ _ _) = (True, p)
             isImp arg = (False, priority arg)

collectDeferred :: Term -> State [(Name, Type)] Term
collectDeferred (Bind n (GHole t) app) =
    do ds <- get
       when (not (n `elem` map fst ds)) $ put ((n, t) : ds)
       collectDeferred app
collectDeferred (Bind n b t) = do b' <- cdb b
                                  t' <- collectDeferred t
                                  return (Bind n b' t')
  where
    cdb (Let t v)   = liftM2 Let (collectDeferred t) (collectDeferred v)
    cdb (Guess t v) = liftM2 Guess (collectDeferred t) (collectDeferred v)
    cdb b           = do ty' <- collectDeferred (binderTy b)
                         return (b { binderTy = ty' })
collectDeferred (App f a) = liftM2 App (collectDeferred f) (collectDeferred a)
collectDeferred t = return t

-- Running tactics directly

runTac :: Bool -> IState -> PTactic -> ElabD ()
runTac autoSolve ist tac = do env <- get_env
                              runT (fmap (addImplBound ist (map fst env)) tac) 
  where
    runT (Intro []) = do g <- goal
                         attack; intro (bname g)
      where
        bname (Bind n _ _) = Just n
        bname _ = Nothing
    runT (Intro xs) = mapM_ (\x -> do attack; intro (Just x)) xs
    runT Intros = do g <- goal
                     attack; intro (bname g)
                     try' (runT Intros)
                          (return ()) True
      where
        bname (Bind n _ _) = Just n
        bname _ = Nothing
    runT (Exact tm) = do elab ist toplevel False False (MN 0 "tac") tm
                         when autoSolve solveAll
    runT (Refine fn [])   
        = do (fn', imps) <- case lookupCtxtName Nothing fn (idris_implicits ist) of
                                    [] -> do a <- envArgs fn
                                             return (fn, a)
                                    -- FIXME: resolve ambiguities
                                    [(n, args)] -> return $ (n, map isImp args)
             ns <- apply (Var fn') (map (\x -> (x, 0)) imps)
             when autoSolve solveAll
       where isImp (PImp _ _ _ _ _) = True
             isImp _ = False
             envArgs n = do e <- get_env
                            case lookup n e of
                               Just t -> return $ map (const False)
                                                      (getArgTys (binderTy t))
                               _ -> return []
    runT (Refine fn imps) = do ns <- apply (Var fn) (map (\x -> (x,0)) imps)
                               when autoSolve solveAll
    runT (Rewrite tm) -- to elaborate tm, let bind it, then rewrite by that
              = do attack; -- (h:_) <- get_holes
                   tyn <- unique_hole (MN 0 "rty")
                   -- start_unify h
                   claim tyn RType
                   valn <- unique_hole (MN 0 "rval")
                   claim valn (Var tyn)
                   letn <- unique_hole (MN 0 "rewrite_rule")
                   letbind letn (Var tyn) (Var valn)  
                   focus valn
                   elab ist toplevel False False (MN 0 "tac") tm
                   rewrite (Var letn)
                   when autoSolve solveAll
    runT (LetTac n tm)
              = do attack
                   tyn <- unique_hole (MN 0 "letty")
                   claim tyn RType
                   valn <- unique_hole (MN 0 "letval")
                   claim valn (Var tyn)
                   letn <- unique_hole n
                   letbind letn (Var tyn) (Var valn)
                   focus valn
                   elab ist toplevel False False (MN 0 "tac") tm
                   when autoSolve solveAll
    runT (LetTacTy n ty tm)
              = do attack
                   tyn <- unique_hole (MN 0 "letty")
                   claim tyn RType
                   valn <- unique_hole (MN 0 "letval")
                   claim valn (Var tyn)
                   letn <- unique_hole n
                   letbind letn (Var tyn) (Var valn)
                   focus tyn
                   elab ist toplevel False False (MN 0 "tac") ty
                   focus valn
                   elab ist toplevel False False (MN 0 "tac") tm
                   when autoSolve solveAll
    runT Compute = compute
    runT Trivial = do trivial ist; when autoSolve solveAll
    runT (Focus n) = focus n
    runT Solve = solve
    runT (Try l r) = do try' (runT l) (runT r) True
    runT (TSeq l r) = do runT l; runT r
    runT (ReflectTac tm) = do attack -- let x : Tactic = tm in ...
                              valn <- unique_hole (MN 0 "tacval")
                              claim valn (Var tacticTy)
                              tacn <- unique_hole (MN 0 "tacn")
                              letbind tacn (Var tacticTy) (Var valn)
                              focus valn
                              elab ist toplevel False False (MN 0 "tac") tm
                              (tm', ty') <- get_type_val (Var tacn)
                              ctxt <- get_context
                              env <- get_env
                              let tactic = normalise ctxt env tm'
                              runReflected tactic
--                               p <- get_term
--                               trace (show p ++ "\n\n") $ 
                              return ()
        where tacticTy = tacm "Tactic"
    runT (GoalType n tac) = do g <- goal
                               case unApply g of
                                    (P _ n' _, _) -> 
                                       if nsroot n' == UN n
                                          then runT tac
                                          else fail "Wrong goal type"
                                    _ -> fail "Wrong goal type"
    runT x = fail $ "Not implemented " ++ show x

    runReflected t = do t' <- reify t
                        runTac autoSolve ist t'
    tacm n = NS (UN n) ["Reflection", "Language"]

    reify :: Term -> ElabD PTactic
    reify (P _ n _) | n == tacm "Trivial" = return Trivial
    reify (P _ n _) | n == tacm "Solve" = return Solve
    reify f@(App _ _) 
          | (P _ f _, args) <- unApply f = reifyAp f args
    reify t = fail ("Unknown tactic " ++ show t)

    reifyAp t [l, r] | t == tacm "Try" = liftM2 Try (reify l) (reify r)
    reifyAp t [Constant (Str x)] 
                     | t == tacm "Refine" = return $ Refine (UN x) []
    reifyAp t [l, r] | t == tacm "Seq" = liftM2 TSeq (reify l) (reify r)
    reifyAp t [Constant (Str n), x] 
                     | t == tacm "GoalType" = liftM (GoalType n) (reify x)
    reifyAp f args = fail ("Unknown tactic " ++ show (f, args)) -- shouldn't happen

solveAll = try (do solve; solveAll) (return ())

-- If the function application is specialisable, make a new
-- top level function by normalising the application
-- and elaborating the new expression.

mkSpecialised :: IState -> FC -> Name -> [PTerm] -> PTerm -> ElabD PTerm
mkSpecialised i fc n args def
    = do let tm' = def
         case lookupCtxt Nothing n (idris_statics i) of
           [] -> return tm'
           [as] -> if (not (or as)) then return tm' else
                       mkSpecDecl i n (zip args as) tm'

mkSpecDecl :: IState -> Name -> [(PTerm, Bool)] -> PTerm -> ElabD PTerm
mkSpecDecl i n pargs tm'
    = do t <- goal
         g <- get_guess
         let (f, args) = unApply g
         let sargs = zip args (map snd pargs)
         let staticArgs = map fst (filter (\ (_,x) -> x) sargs)
         let ns = group (sort (concatMap staticFnNames staticArgs))
         let ntimes = map (\xs -> (head xs, length xs - 1)) ns
         if (not (null ns)) then
           do env <- get_env
              let g' = g -- specialise ctxt env ntimes g
              return tm'
--               trace (show t ++ "\n" ++
--                      show ntimes ++ "\n" ++ 
--                      show (delab i g) ++ "\n" ++ show (delab i g')) $ return tm' -- TODO
           else return tm'
  where
    ctxt = tt_ctxt i
    cg = idris_callgraph i

    staticFnNames tm | (P _ f _, as) <- unApply tm
        = if not (isFnName Nothing f ctxt) then [] 
             else case lookupCtxt Nothing f cg of
                    [ns] -> f : f : [] --(ns \\ [f])
                    [] -> [f,f]
                    _ -> []
    staticFnNames _ = []

