{-# Language TypeFamilies, FlexibleInstances #-}
module Csound.Typed.Types.Prim(
    Sig(..), D(..), Tab(..), unTab, Str(..), Spec(..), Wspec(..), 
    BoolSig(..), BoolD(..), Unit(..), unit, Val(..), hideGE, SigOrD,

    -- ** Tables
    preTab, TabSize(..), TabArgs(..), updateTabSize,
    fromPreTab, getPreTabUnsafe, skipNorm, forceNorm,
    nsamp, ftlen, ftchnls, ftsr, ftcps,

    -- ** constructors
    double, int, text, 
    
    -- ** constants
    idur, getSampleRate, getControlRate, getBlockSize, getZeroDbfs,

    -- ** converters
    ar, kr, ir, sig,

    -- ** lifters
    on0, on1, on2, on3,

    -- ** numeric funs
    quot', rem', div', mod', ceil', floor', round', int', frac',
   
    -- ** logic funs
    when1, whens, untilDo, whileDo, boolSig
) where

import Control.Applicative hiding ((<*))
import Control.Monad
import Control.Monad.Trans.Class
import Data.Monoid
import qualified Data.IntMap as IM

import Data.Default
import Data.Boolean

import Csound.Dynamic hiding (double, int, str, when1, whens, ifBegin, ifEnd, elseBegin, untilBegin, untilEnd, untilDo)
import qualified Csound.Dynamic as D(double, int, str, ifBegin, ifEnd, elseBegin, untilBegin, untilEnd)
import Csound.Typed.GlobalState

-- | Signals
newtype Sig  = Sig  { unSig :: GE E }

-- | Constant numbers
newtype D    = D    { unD   :: GE E }

-- | Strings
newtype Str  = Str  { unStr :: GE E }

-- | Spectrum. It's @fsig@ in the Csound.
newtype Spec  = Spec  { unSpec  :: GE E }

-- | Another type for spectrum. It's @wsig@ in the Csound.
newtype Wspec = Wspec { unWspec :: GE E }

-- Booleans

-- | A signal of booleans.
newtype BoolSig = BoolSig { unBoolSig :: GE E }

-- | A constant boolean value.
newtype BoolD   = BoolD   { unBoolD   :: GE E }

type instance BooleanOf Sig  = BoolSig

type instance BooleanOf D    = BoolD
type instance BooleanOf Str  = BoolD
type instance BooleanOf Tab  = BoolD
type instance BooleanOf Spec = BoolD

-- Procedures

-- | Csound's empty tuple.
newtype Unit = Unit { unUnit :: GE () } 

-- | Constructs Csound's empty tuple.
unit :: Unit
unit = Unit $ return ()

instance Monoid Unit where
    mempty = Unit (return ())
    mappend a b = Unit $ (unUnit a) >> (unUnit b)

instance Default Unit where
    def = unit

-- tables

-- | Tables (or arrays)
data Tab  
    = Tab (GE E)
    | TabPre PreTab

preTab :: TabSize -> Int -> TabArgs -> Tab
preTab size gen args = TabPre $ PreTab size gen args

data PreTab = PreTab
    { preTabSize    :: TabSize
    , preTabGen     :: Int
    , preTabArgs    :: TabArgs }

-- Table size.
data TabSize 
    -- Size is fixed by the user.
    = SizePlain Int
    -- Size is relative to the renderer settings.
    | SizeDegree 
    { hasGuardPoint :: Bool
    , sizeDegree    :: Int      -- is the power of two
    }

instance Default TabSize where
    def = SizeDegree
        { hasGuardPoint = False
        , sizeDegree = 0 }
    
-- Table arguments can be
data TabArgs 
    -- absolute
    = ArgsPlain [Double]
    -- or relative to the table size (used for tables that implement interpolation)
    | ArgsRelative [Double]
    -- GEN 16 uses unusual interpolation scheme, so we need a special case
    | ArgsGen16 [Double]
    | FileAccess String [Double]

renderTab :: PreTab -> GE E
renderTab a = saveGen =<< fromPreTab a 

getPreTabUnsafe :: String -> Tab -> PreTab
getPreTabUnsafe msg x = case x of
    TabPre a    -> a
    _           -> error msg

fromPreTab :: PreTab -> GE Gen
fromPreTab a = withOptions $ \opt -> go (defTabFi opt) a
    where
        go :: TabFi -> PreTab -> Gen
        go tabFi tab = Gen size (preTabGen tab) args file
            where size = defineTabSize (getTabSizeBase tabFi tab) (preTabSize tab)
                  (args, file) = defineTabArgs size (preTabArgs tab)

getTabSizeBase :: TabFi -> PreTab -> Int
getTabSizeBase tf tab = IM.findWithDefault (tabFiBase tf) (preTabGen tab) (tabFiGens tf)

defineTabSize :: Int -> TabSize -> Int
defineTabSize base x = case x of
       SizePlain n -> n
       SizeDegree guardPoint degree ->          
                byGuardPoint guardPoint $
                byDegree base degree
    where byGuardPoint guardPoint 
            | guardPoint = (+ 1)
            | otherwise  = id
            
          byDegree zero n = 2 ^ max 0 (zero + n) 

defineTabArgs :: Int -> TabArgs -> ([Double], Maybe String)
defineTabArgs size args = case args of
    ArgsPlain as -> (as, Nothing)
    ArgsRelative as -> (fromRelative size as, Nothing)
    ArgsGen16 as -> (formRelativeGen16 size as, Nothing)
    FileAccess filename as -> (as, Just filename)
    where fromRelative n as = substEvens (mkRelative n $ getEvens as) as
          getEvens xs = case xs of
            [] -> []
            _:[] -> []
            _:b:as -> b : getEvens as
            
          substEvens evens xs = case (evens, xs) of
            ([], as) -> as
            (_, []) -> []
            (e:es, a:_:as) -> a : e : substEvens es as
            _ -> error "table argument list should contain even number of elements"
            
          mkRelative n as = fmap ((fromIntegral :: (Int -> Double)) . round . (s * )) as
            where s = fromIntegral n / sum as
          
          -- special case. subst relatives for Gen16
          formRelativeGen16 n as = substGen16 (mkRelative n $ getGen16 as) as

          getGen16 xs = case xs of
            _:durN:_:rest    -> durN : getGen16 rest
            _                -> []

          substGen16 durs xs = case (durs, xs) of 
            ([], as) -> as
            (_, [])  -> []
            (d:ds, valN:_:typeN:rest)   -> valN : d : typeN : substGen16 ds rest
            (_, _)   -> xs

-- | Skips normalization (sets table size to negative value)
skipNorm :: Tab -> Tab
skipNorm x = case x of
    Tab _ -> error "you can skip normalization only for primitive tables (made with gen-routines)"
    TabPre a -> TabPre $ a{ preTabGen = negate $ abs $ preTabGen a }

-- | Force normalization (sets table size to positive value).
-- Might be useful to restore normalization for table 'Csound.Tab.doubles'.
forceNorm :: Tab -> Tab
forceNorm x = case x of
    Tab _ -> error "you can force normalization only for primitive tables (made with gen-routines)"
    TabPre a -> TabPre $ a{ preTabGen = abs $ preTabGen a }

----------------------------------------------------------------------------
-- change table size

updateTabSize :: (TabSize -> TabSize) -> Tab -> Tab
updateTabSize phi x = case x of
    Tab _ -> error "you can change size only for primitive tables (made with gen-routines)"
    TabPre a -> TabPre $ a{ preTabSize = phi $ preTabSize a }

-------------------------------------------------------------------------------
-- constructors

-- | Constructs a number.
double :: Double -> D
double = fromE . D.double

-- | Constructs an integer.
int :: Int -> D
int = fromE . D.int

-- | Constructs a string.
text :: String -> Str
text = fromE . D.str

-------------------------------------------------------------------------------
-- constants

-- | Querries a total duration of the note. It's equivallent to Csound's @p3@ field.
idur :: D 
idur = fromE $ pn 3

getSampleRate :: D
getSampleRate = fromE $ readOnlyVar (VarVerbatim Ir "sr")

getControlRate :: D
getControlRate = fromE $ readOnlyVar (VarVerbatim Ir "kr")

getBlockSize :: D
getBlockSize = fromE $ readOnlyVar (VarVerbatim Ir "ksmps")

getZeroDbfs :: D
getZeroDbfs = fromE $ readOnlyVar (VarVerbatim Ir "0dbfs")

-------------------------------------------------------------------------------
-- converters

-- | Sets a rate of the signal to audio rate.
ar :: Sig -> Sig
ar = on1 $ setRate Ar

-- | Sets a rate of the signal to control rate.
kr :: Sig -> Sig
kr = on1 $ setRate Kr

-- | Converts a signal to the number (initial value of the signal).
ir :: Sig -> D
ir = on1 $ setRate Ir

-- | Makes a constant signal from the number.
sig :: D -> Sig
sig = on1 $ setRate Kr

-------------------------------------------------------------------------------
-- single wrapper

-- | Contains all Csound values.
class Val a where
    fromGE  :: GE E -> a
    toGE    :: a -> GE E

    fromE   :: E -> a
    fromE = fromGE . return

hideGE :: Val a => GE a -> a
hideGE = fromGE . join . fmap toGE

instance Val Sig    where { fromGE = Sig    ; toGE = unSig  }
instance Val D      where { fromGE = D      ; toGE = unD    }
instance Val Str    where { fromGE = Str    ; toGE = unStr  }
instance Val Spec   where { fromGE = Spec   ; toGE = unSpec }
instance Val Wspec  where { fromGE = Wspec  ; toGE = unWspec}

instance Val Tab where 
    fromGE = Tab 
    toGE = unTab

unTab :: Tab -> GE E
unTab x = case x of
        Tab a -> a
        TabPre a -> renderTab a

instance Val BoolSig where { fromGE = BoolSig ; toGE = unBoolSig }
instance Val BoolD   where { fromGE = BoolD   ; toGE = unBoolD   }

class Val a => SigOrD a where

instance SigOrD Sig where
instance SigOrD D   where

on0 :: Val a => E -> a
on0 = fromE

on1 :: (Val a, Val b) => (E -> E) -> (a -> b)
on1 f a = fromGE $ fmap f $ toGE a

on2 :: (Val a, Val b, Val c) => (E -> E -> E) -> (a -> b -> c)
on2 f a b = fromGE $ liftA2 f (toGE a) (toGE b)

on3 :: (Val a, Val b, Val c, Val d) => (E -> E -> E -> E) -> (a -> b -> c -> d)
on3 f a b c = fromGE $ liftA3 f (toGE a) (toGE b) (toGE c)

-------------------------------------------------------------------------------
-- defaults

instance Default Sig    where def = 0
instance Default D      where def = 0
instance Default Tab    where def = fromE 0
instance Default Str    where def = text ""
instance Default Spec   where def = fromE 0 

-------------------------------------------------------------------------------
-- monoid

instance Monoid Sig     where { mempty = on0 mempty     ; mappend = on2 mappend }
instance Monoid D       where { mempty = on0 mempty     ; mappend = on2 mappend }

-------------------------------------------------------------------------------
-- numeric

instance Num Sig where 
    { (+) = on2 (+); (*) = on2 (*); negate = on1 negate; (-) = on2 (\a b -> a - b)   
    ; fromInteger = on0 . fromInteger; abs = on1 abs; signum = on1 signum }

instance Num D where 
    { (+) = on2 (+); (*) = on2 (*); negate = on1 negate; (-) = on2 (\a b -> a - b)   
    ; fromInteger = on0 . fromInteger; abs = on1 abs; signum = on1 signum }

instance Fractional Sig  where { (/) = on2 (/);    fromRational = on0 . fromRational }
instance Fractional D    where { (/) = on2 (/);    fromRational = on0 . fromRational }

instance Floating Sig where
    { pi = on0 pi;  exp = on1 exp;  sqrt = on1 sqrt; log = on1 log;  logBase = on2 logBase; (**) = on2 (**)
    ;  sin = on1 sin;  tan = on1 tan;  cos = on1 cos; sinh = on1 sinh; tanh = on1 tanh; cosh = on1 cosh
    ; asin = on1 asin; atan = on1 atan;  acos = on1 acos ; asinh = on1 asinh; acosh = on1 acosh; atanh = on1 atanh }

instance Floating D where
    { pi = on0 pi;  exp = on1 exp;  sqrt = on1 sqrt; log = on1 log;  logBase = on2 logBase; (**) = on2 (**)
    ;  sin = on1 sin;  tan = on1 tan;  cos = on1 cos; sinh = on1 sinh; tanh = on1 tanh; cosh = on1 cosh
    ; asin = on1 asin; atan = on1 atan;  acos = on1 acos ; asinh = on1 asinh; acosh = on1 acosh; atanh = on1 atanh }

ceil', floor', frac', int', round' :: SigOrD a => a -> a
quot', rem', div', mod' :: SigOrD a => a -> a -> a

ceil' = on1 ceilE;    floor' = on1 floorE;  frac' = on1 fracE;  int' = on1 intE;    round' = on1 roundE
quot' = on2 quot; rem' = on2 rem;   div' = on2 div;   mod' = on2 mod

-------------------------------------------------------------------------------
-- logic

instance Boolean BoolSig  where { true = on0 true;  false = on0 false;  notB = on1 notB;  (&&*) = on2 (&&*);  (||*) = on2 (||*) }
instance Boolean BoolD    where { true = on0 true;  false = on0 false;  notB = on1 notB;  (&&*) = on2 (&&*);  (||*) = on2 (||*) }

instance IfB Sig  where ifB = on3 ifB
instance IfB D    where ifB = on3 ifB
instance IfB Tab  where ifB = on3 ifB
instance IfB Str  where ifB = on3 ifB
instance IfB Spec where ifB = on3 ifB

instance EqB Sig  where { (==*) = on2 (==*);    (/=*) = on2 (/=*) }
instance EqB D    where { (==*) = on2 (==*);    (/=*) = on2 (/=*) }

instance OrdB Sig where { (<*)  = on2 (<*) ;    (>*)  = on2 (>*);     (<=*) = on2 (<=*);    (>=*) = on2 (>=*) }
instance OrdB D   where { (<*)  = on2 (<*) ;    (>*)  = on2 (>*);     (<=*) = on2 (<=*);    (>=*) = on2 (>=*) }

-- | Invokes the given procedure if the boolean signal is true.
when1 :: BoolSig -> SE () -> SE ()
when1 p body = do
    ifBegin p
    body
    ifEnd

-- | The chain of @when1@s. Tests all the conditions in sequence
-- if everything is false it invokes the procedure given in the second argument.
whens :: [(BoolSig, SE ())] -> SE () -> SE ()
whens bodies el = case bodies of
    []   -> el
    a:as -> do
        ifBegin (fst a)
        snd a
        elseIfs as
        elseBegin 
        el
        foldl1 (>>) $ replicate (1 + length bodies) ifEnd
    where elseIfs = mapM_ (\(p, body) -> elseBegin >> ifBegin p >> body)

ifBegin :: BoolSig -> SE ()
ifBegin a = fromDep_ $ D.ifBegin =<< lift (toGE a)

ifEnd :: SE ()
ifEnd = fromDep_ D.ifEnd

elseBegin :: SE ()
elseBegin = fromDep_ D.elseBegin

-- elseIfBegin :: BoolSig -> SE ()
-- elseIfBegin a = fromDep_ $ D.elseIfBegin =<< lift (toGE a)

untilDo :: BoolSig -> SE () -> SE ()
untilDo p body = do
    untilBegin p
    body
    untilEnd

whileDo :: BoolSig -> SE () -> SE ()
whileDo p = untilDo (notB p) 

untilBegin :: BoolSig -> SE ()
untilBegin a = fromDep_ $ D.untilBegin =<< lift (toGE a)

untilEnd :: SE ()
untilEnd = fromDep_ D.untilEnd

-- | Creates a constant boolean signal.
boolSig :: BoolD -> BoolSig
boolSig = fromGE . toGE


----------------------------------------------

-- | nsamp — Returns the number of samples loaded into a stored function table number.
--
-- > nsamp(x) (init-rate args only)
--
-- csound doc: <http://www.csounds.com/manual/html/nsamp.html>
nsamp :: Tab -> D
nsamp = on1 $ opr1 "nsamp"

-- | Returns a length of the table.
ftlen :: Tab -> D
ftlen = on1 $ opr1 "ftlen"

-- | Returns the number of channels for a table that stores wav files
ftchnls :: Tab -> D
ftchnls = on1 $ opr1 "ftchnls"

-- | Returns the sample rate for a table that stores wav files
ftsr :: Tab -> D
ftsr = on1 $ opr1 "ftsr"

-- | Returns the base frequency for a table that stores wav files
ftcps :: Tab -> D
ftcps = on1 $ opr1 "ftcps"

