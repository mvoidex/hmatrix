{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE FlexibleContexts         #-}
{-# LANGUAGE FlexibleInstances        #-}
{-# LANGUAGE BangPatterns             #-}

-- |
-- Module      :  Data.Packed.Internal.Matrix
-- Copyright   :  (c) Alberto Ruiz 2007
-- License     :  BSD3
-- Maintainer  :  Alberto Ruiz
-- Stability   :  provisional
--
-- Internal matrix representation
--

module Data.Packed.Internal.Matrix(
    Matrix(..), rows, cols, cdat, fdat,
    MatrixOrder(..), orderOf,
    createMatrix, mat,
    cmat, fmat,
    toLists, flatten, reshape,
    Element(..),
    trans,
    fromRows, toRows, fromColumns, toColumns,
    matrixFromVector,
    subMatrix,
    liftMatrix, liftMatrix2,
    (@@>), atM',
    singleton,
    emptyM,
    size, shSize, conformVs, conformMs, conformVTo, conformMTo
) where

import Data.Packed.Internal.Common
import Data.Packed.Internal.Signatures
import Data.Packed.Internal.Vector

import Foreign.Marshal.Alloc(alloca, free)
import Foreign.Marshal.Array(newArray)
import Foreign.Ptr(Ptr, castPtr)
import Foreign.Storable(Storable, peekElemOff, pokeElemOff, poke, sizeOf)
import Data.Complex(Complex)
import Foreign.C.Types
import System.IO.Unsafe(unsafePerformIO)
import Control.DeepSeq

-----------------------------------------------------------------

{- Design considerations for the Matrix Type
   -----------------------------------------

- we must easily handle both row major and column major order,
  for bindings to LAPACK and GSL/C

- we'd like to simplify redundant matrix transposes:
   - Some of them arise from the order requirements of some functions
   - some functions (matrix product) admit transposed arguments

- maybe we don't really need this kind of simplification:
   - more complex code
   - some computational overhead
   - only appreciable gain in code with a lot of redundant transpositions
     and cheap matrix computations

- we could carry both the matrix and its (lazily computed) transpose.
  This may save some transpositions, but it is necessary to keep track of the
  data which is actually computed to be used by functions like the matrix product
  which admit both orders.

- but if we need the transposed data and it is not in the structure, we must make
  sure that we touch the same foreignptr that is used in the computation.

- a reasonable solution is using two constructors for a matrix. Transposition just
  "flips" the constructor. Actual data transposition is not done if followed by a
  matrix product or another transpose.

-}

data MatrixOrder = RowMajor | ColumnMajor deriving (Show,Eq)

transOrder RowMajor = ColumnMajor
transOrder ColumnMajor = RowMajor
{- | Matrix representation suitable for BLAS\/LAPACK computations.

The elements are stored in a continuous memory array.

-}

data Matrix t = Matrix { irows :: {-# UNPACK #-} !Int
                       , icols :: {-# UNPACK #-} !Int
                       , xdat :: {-# UNPACK #-} !(Vector t)
                       , order :: !MatrixOrder }
-- RowMajor: preferred by C, fdat may require a transposition
-- ColumnMajor: preferred by LAPACK, cdat may require a transposition

cdat = xdat
fdat = xdat

rows :: Matrix t -> Int
rows = irows

cols :: Matrix t -> Int
cols = icols

orderOf :: Matrix t -> MatrixOrder
orderOf = order


-- | Matrix transpose.
trans :: Matrix t -> Matrix t
trans Matrix {irows = r, icols = c, xdat = d, order = o } = Matrix { irows = c, icols = r, xdat = d, order = transOrder o}

cmat :: (Element t) => Matrix t -> Matrix t
cmat m@Matrix{order = RowMajor} = m
cmat Matrix {irows = r, icols = c, xdat = d, order = ColumnMajor } = Matrix { irows = r, icols = c, xdat = transdata r d c, order = RowMajor}

fmat :: (Element t) => Matrix t -> Matrix t
fmat m@Matrix{order = ColumnMajor} = m
fmat Matrix {irows = r, icols = c, xdat = d, order = RowMajor } = Matrix { irows = r, icols = c, xdat = transdata c d r, order = ColumnMajor}

-- C-Haskell matrix adapter
-- mat :: Adapt (CInt -> CInt -> Ptr t -> r) (Matrix t) r

mat :: (Storable t) => Matrix t -> (((CInt -> CInt -> Ptr t -> t1) -> t1) -> IO b) -> IO b
mat a f =
    unsafeWith (xdat a) $ \p -> do
        let m g = do
            g (fi (rows a)) (fi (cols a)) p
        f m

{- | Creates a vector by concatenation of rows. If the matrix is ColumnMajor, this operation requires a transpose.

>>> flatten (ident 3)
fromList [1.0,0.0,0.0,0.0,1.0,0.0,0.0,0.0,1.0]

-}
flatten :: Element t => Matrix t -> Vector t
flatten = xdat . cmat

{-
type Mt t s = Int -> Int -> Ptr t -> s

infixr 6 ::>
type t ::> s = Mt t s
-}

-- | the inverse of 'Data.Packed.Matrix.fromLists'
toLists :: (Element t) => Matrix t -> [[t]]
toLists m = splitEvery (cols m) . toList . flatten $ m

-- | Create a matrix from a list of vectors.
-- All vectors must have the same dimension,
-- or dimension 1, which is are automatically expanded.
fromRows :: Element t => [Vector t] -> Matrix t
fromRows [] = emptyM 0 0
fromRows vs = case compatdim (map dim vs) of
    Nothing -> error $ "fromRows expects vectors with equal sizes (or singletons), given: " ++ show (map dim vs)
    Just 0  -> emptyM r 0
    Just c  -> matrixFromVector RowMajor r c . vjoin . map (adapt c) $ vs
  where
    r = length vs
    adapt c v
        | c == 0 = fromList[]
        | dim v == c = v
        | otherwise = constantD (v@>0) c

-- | extracts the rows of a matrix as a list of vectors
toRows :: Element t => Matrix t -> [Vector t]
toRows m
    | c == 0    = replicate r (fromList[])
    | otherwise = toRows' 0
  where
    v = flatten m
    r = rows m
    c = cols m
    toRows' k | k == r*c  = []
              | otherwise = subVector k c v : toRows' (k+c)

-- | Creates a matrix from a list of vectors, as columns
fromColumns :: Element t => [Vector t] -> Matrix t
fromColumns m = trans . fromRows $ m

-- | Creates a list of vectors from the columns of a matrix
toColumns :: Element t => Matrix t -> [Vector t]
toColumns m = toRows . trans $ m

-- | Reads a matrix position.
(@@>) :: Storable t => Matrix t -> (Int,Int) -> t
infixl 9 @@>
m@Matrix {irows = r, icols = c} @@> (i,j)
    | safe      = if i<0 || i>=r || j<0 || j>=c
                    then error "matrix indexing out of range"
                    else atM' m i j
    | otherwise = atM' m i j
{-# INLINE (@@>) #-}

--  Unsafe matrix access without range checking
atM' Matrix {icols = c, xdat = v, order = RowMajor} i j = v `at'` (i*c+j)
atM' Matrix {irows = r, xdat = v, order = ColumnMajor} i j = v `at'` (j*r+i)
{-# INLINE atM' #-}

------------------------------------------------------------------

matrixFromVector o r c v
    | r * c == dim v = m
    | otherwise = error $ "can't reshape vector dim = "++ show (dim v)++" to matrix " ++ shSize m
  where
    m = Matrix { irows = r, icols = c, xdat = v, order = o }

-- allocates memory for a new matrix
createMatrix :: (Storable a) => MatrixOrder -> Int -> Int -> IO (Matrix a)
createMatrix ord r c = do
    p <- createVector (r*c)
    return (matrixFromVector ord r c p)

{- | Creates a matrix from a vector by grouping the elements in rows with the desired number of columns. (GNU-Octave groups by columns. To do it you can define @reshapeF r = trans . reshape r@
where r is the desired number of rows.)

>>> reshape 4 (fromList [1..12])
(3><4)
 [ 1.0,  2.0,  3.0,  4.0
 , 5.0,  6.0,  7.0,  8.0
 , 9.0, 10.0, 11.0, 12.0 ]

-}
reshape :: Storable t => Int -> Vector t -> Matrix t
reshape 0 v = matrixFromVector RowMajor 0 0 v
reshape c v = matrixFromVector RowMajor (dim v `div` c) c v

singleton x = reshape 1 (fromList [x])

-- | application of a vector function on the flattened matrix elements
liftMatrix :: (Storable a, Storable b) => (Vector a -> Vector b) -> Matrix a -> Matrix b
liftMatrix f Matrix { irows = r, icols = c, xdat = d, order = o } = matrixFromVector o r c (f d)

-- | application of a vector function on the flattened matrices elements
liftMatrix2 :: (Element t, Element a, Element b) => (Vector a -> Vector b -> Vector t) -> Matrix a -> Matrix b -> Matrix t
liftMatrix2 f m1 m2
    | not (compat m1 m2) = error "nonconformant matrices in liftMatrix2"
    | otherwise = case orderOf m1 of
        RowMajor    -> matrixFromVector RowMajor    (rows m1) (cols m1) (f (xdat m1) (flatten m2))
        ColumnMajor -> matrixFromVector ColumnMajor (rows m1) (cols m1) (f (xdat m1) ((xdat.fmat) m2))


compat :: Matrix a -> Matrix b -> Bool
compat m1 m2 = rows m1 == rows m2 && cols m1 == cols m2

------------------------------------------------------------------

{- | Supported matrix elements.

    This class provides optimized internal
    operations for selected element types.
    It provides unoptimised defaults for any 'Storable' type,
    so you can create instances simply as:

    >instance Element Foo
-}
class (Storable a) => Element a where
    subMatrixD :: (Int,Int) -- ^ (r0,c0) starting position 
               -> (Int,Int) -- ^ (rt,ct) dimensions of submatrix
               -> Matrix a -> Matrix a
    subMatrixD = subMatrix'
    transdata :: Int -> Vector a -> Int -> Vector a
    transdata = transdataP -- transdata'
    constantD  :: a -> Int -> Vector a
    constantD = constantP -- constant'
    extractR :: Matrix a -> CInt -> Vector CInt -> CInt -> Vector CInt -> Matrix a
    sortI    :: Ord a => Vector a -> Vector CInt
    sortV    :: Ord a => Vector a -> Vector a
    compareV :: Ord a => Vector a -> Vector a -> Vector CInt
    selectV  :: Vector CInt -> Vector a -> Vector a -> Vector a -> Vector a


instance Element Float where
    transdata  = transdataAux ctransF
    constantD  = constantAux cconstantF
    extractR   = extractAux c_extractF
    sortI      = sortIdxF
    sortV      = sortValF
    compareV   = compareF
    selectV    = selectF
    

instance Element Double where
    transdata  = transdataAux ctransR
    constantD  = constantAux cconstantR
    extractR   = extractAux c_extractD
    sortI      = sortIdxD
    sortV      = sortValD
    compareV   = compareD
    selectV    = selectD


instance Element (Complex Float) where
    transdata  = transdataAux ctransQ
    constantD  = constantAux cconstantQ
    extractR   = extractAux c_extractQ
    sortI      = undefined
    sortV      = undefined
    compareV   = undefined
    selectV    = selectQ


instance Element (Complex Double) where
    transdata  = transdataAux ctransC
    constantD  = constantAux cconstantC
    extractR   = extractAux c_extractC
    sortI      = undefined
    sortV      = undefined
    compareV   = undefined
    selectV    = selectC

    
instance Element (CInt) where
    transdata  = transdataAux ctransI
    constantD  = constantAux cconstantI
    extractR   = extractAux c_extractI
    sortI      = sortIdxI
    sortV      = sortValI
    compareV   = compareI
    selectV    = selectI


-------------------------------------------------------------------

transdataAux fun c1 d c2 =
    if noneed
        then d
        else unsafePerformIO $ do
            -- putStrLn "T"
            v <- createVector (dim d)
            unsafeWith d $ \pd ->
                unsafeWith v $ \pv ->
                    fun (fi r1) (fi c1) pd (fi r2) (fi c2) pv // check "transdataAux"
            return v
  where r1 = dim d `div` c1
        r2 = dim d `div` c2
        noneed = dim d == 0 || r1 == 1 || c1 == 1

transdataP :: Storable a => Int -> Vector a -> Int -> Vector a
transdataP c1 d c2 =
    if noneed
       then d
       else unsafePerformIO $ do
          v <- createVector (dim d)
          unsafeWith d $ \pd ->
              unsafeWith v $ \pv ->
                  ctransP (fi r1) (fi c1) (castPtr pd) (fi sz) (fi r2) (fi c2) (castPtr pv) (fi sz) // check "transdataP"
          return v
   where r1 = dim d `div` c1
         r2 = dim d `div` c2
         sz = sizeOf (d @> 0)
         noneed = dim d == 0 || r1 == 1 || c1 == 1

foreign import ccall unsafe "transF" ctransF :: TFMFM
foreign import ccall unsafe "transR" ctransR :: TMM
foreign import ccall unsafe "transQ" ctransQ :: TQMQM
foreign import ccall unsafe "transC" ctransC :: TCMCM
foreign import ccall unsafe "transI" ctransI :: CM CInt (CM CInt (IO CInt))
foreign import ccall unsafe "transP" ctransP :: CInt -> CInt -> Ptr () -> CInt -> CInt -> CInt -> Ptr () -> CInt -> IO CInt

----------------------------------------------------------------------

constantAux fun x n = unsafePerformIO $ do
    v <- createVector n
    px <- newArray [x]
    app1 (fun px) vec v "constantAux"
    free px
    return v

foreign import ccall unsafe "constantF" cconstantF :: Ptr Float -> TF

foreign import ccall unsafe "constantR" cconstantR :: Ptr Double -> TV

foreign import ccall unsafe "constantQ" cconstantQ :: Ptr (Complex Float) -> TQV

foreign import ccall unsafe "constantC" cconstantC :: Ptr (Complex Double) -> TCV

foreign import ccall unsafe "constantI" cconstantI :: Ptr CInt -> CV CInt (IO CInt)

constantP :: Storable a => a -> Int -> Vector a
constantP a n = unsafePerformIO $ do
    let sz = sizeOf a
    v <- createVector n
    unsafeWith v $ \p -> do
       alloca $ \k -> do
                      poke k a
                      cconstantP (castPtr k) (fi n) (castPtr p) (fi sz) // check "constantP"
    return v
foreign import ccall unsafe "constantP" cconstantP :: Ptr () -> CInt -> Ptr () -> CInt -> IO CInt

----------------------------------------------------------------------

-- | Extracts a submatrix from a matrix.
subMatrix :: Element a
          => (Int,Int) -- ^ (r0,c0) starting position 
          -> (Int,Int) -- ^ (rt,ct) dimensions of submatrix
          -> Matrix a -- ^ input matrix
          -> Matrix a -- ^ result
subMatrix (r0,c0) (rt,ct) m
    | 0 <= r0 && 0 <= rt && r0+rt <= (rows m) &&
      0 <= c0 && 0 <= ct && c0+ct <= (cols m) = subMatrixD (r0,c0) (rt,ct) m
    | otherwise = error $ "wrong subMatrix "++
                          show ((r0,c0),(rt,ct))++" of "++show(rows m)++"x"++ show (cols m)

subMatrix'' (r0,c0) (rt,ct) c v = unsafePerformIO $ do
    w <- createVector (rt*ct)
    unsafeWith v $ \p ->
        unsafeWith w $ \q -> do
            let go (-1) _ = return ()
                go !i (-1) = go (i-1) (ct-1)
                go !i !j = do x <- peekElemOff p ((i+r0)*c+j+c0)
                              pokeElemOff      q (i*ct+j) x
                              go i (j-1)
            go (rt-1) (ct-1)
    return w

subMatrix' (r0,c0) (rt,ct) (Matrix { icols = c, xdat = v, order = RowMajor}) = Matrix rt ct (subMatrix'' (r0,c0) (rt,ct) c v) RowMajor
subMatrix' (r0,c0) (rt,ct) m = trans $ subMatrix' (c0,r0) (ct,rt) (trans m)

--------------------------------------------------------------------------

maxZ xs = if minimum xs == 0 then 0 else maximum xs

conformMs ms = map (conformMTo (r,c)) ms
  where
    r = maxZ (map rows ms)
    c = maxZ (map cols ms)
    

conformVs vs = map (conformVTo n) vs
  where
    n = maxZ (map dim vs)

conformMTo (r,c) m
    | size m == (r,c) = m
    | size m == (1,1) = matrixFromVector RowMajor r c (constantD (m@@>(0,0)) (r*c))
    | size m == (r,1) = repCols c m
    | size m == (1,c) = repRows r m
    | otherwise = error $ "matrix " ++ shSize m ++ " cannot be expanded to (" ++ show r ++ "><"++ show c ++")"

conformVTo n v
    | dim v == n = v
    | dim v == 1 = constantD (v@>0) n
    | otherwise = error $ "vector of dim=" ++ show (dim v) ++ " cannot be expanded to dim=" ++ show n

repRows n x = fromRows (replicate n (flatten x))
repCols n x = fromColumns (replicate n (flatten x))

size m = (rows m, cols m)

shSize m = "(" ++ show (rows m) ++"><"++ show (cols m)++")"

emptyM r c = matrixFromVector RowMajor r c (fromList[])

----------------------------------------------------------------------

instance (Storable t, NFData t) => NFData (Matrix t)
  where
    rnf m | d > 0     = rnf (v @> 0)
          | otherwise = ()
      where
        d = dim v
        v = xdat m

---------------------------------------------------------------

isT Matrix{order = ColumnMajor} = 1
isT Matrix{order = RowMajor} = 0

tt x@Matrix{order = ColumnMajor} = trans x
tt x@Matrix{order = RowMajor} = x


extractAux f m moder vr modec vc = unsafePerformIO $ do
    let nr = if moder == 0 then fromIntegral $ vr@>1 - vr@>0 + 1 else dim vr
        nc = if modec == 0 then fromIntegral $ vc@>1 - vc@>0 + 1 else dim vc
    r <- createMatrix RowMajor nr nc
    app4 (f moder modec (isT m)) vec vr vec vc mat (tt m) mat r "extractAux"
    return r

foreign import ccall unsafe "extractD" c_extractD
    :: CInt -> CInt -> CInt -> CIdxs (CIdxs (CM Double (CM Double (IO CInt))))

foreign import ccall unsafe "extractF" c_extractF
    :: CInt -> CInt -> CInt -> CIdxs (CIdxs (CM Float (CM Float (IO CInt))))

foreign import ccall unsafe "extractC" c_extractC
    :: CInt -> CInt -> CInt -> CIdxs (CIdxs (CM (Complex Double) (CM (Complex Double) (IO CInt))))

foreign import ccall unsafe "extractQ" c_extractQ
    :: CInt -> CInt -> CInt -> CIdxs (CIdxs (CM (Complex Float) (CM (Complex Float) (IO CInt))))

foreign import ccall unsafe "extractI" c_extractI
    :: CInt -> CInt -> CInt -> CIdxs (CIdxs (CM CInt (CM CInt (IO CInt))))

--------------------------------------------------------------------------------

sortG f v = unsafePerformIO $ do
    r <- createVector (dim v)
    app2 f vec v vec r "sortG"
    return r

sortIdxD = sortG c_sort_indexD
sortIdxF = sortG c_sort_indexF
sortIdxI = sortG c_sort_indexI

sortValD = sortG c_sort_valD
sortValF = sortG c_sort_valF
sortValI = sortG c_sort_valI

foreign import ccall unsafe "sort_indexD" c_sort_indexD :: CV Double (CV CInt (IO CInt))
foreign import ccall unsafe "sort_indexF" c_sort_indexF :: CV Float  (CV CInt (IO CInt))
foreign import ccall unsafe "sort_indexI" c_sort_indexI :: CV CInt   (CV CInt (IO CInt))

foreign import ccall unsafe "sort_valuesD" c_sort_valD :: CV Double (CV Double (IO CInt))
foreign import ccall unsafe "sort_valuesF" c_sort_valF :: CV Float  (CV Float (IO CInt))
foreign import ccall unsafe "sort_valuesI" c_sort_valI :: CV CInt   (CV CInt (IO CInt))

--------------------------------------------------------------------------------

compareG f u v = unsafePerformIO $ do
    r <- createVector (dim v)
    app3 f vec u vec v vec r "compareG"
    return r

compareD = compareG c_compareD
compareF = compareG c_compareF
compareI = compareG c_compareI

foreign import ccall unsafe "compareD" c_compareD :: CV Double (CV Double (CV CInt (IO CInt)))
foreign import ccall unsafe "compareF" c_compareF :: CV Float (CV Float  (CV CInt (IO CInt)))
foreign import ccall unsafe "compareI" c_compareI :: CV CInt (CV CInt   (CV CInt (IO CInt)))

--------------------------------------------------------------------------------

selectG f c u v w = unsafePerformIO $ do
    r <- createVector (dim v)
    app5 f vec c vec u vec v vec w vec r "selectG"
    return r

selectD = selectG c_selectD
selectF = selectG c_selectF
selectI = selectG c_selectI
selectC = selectG c_selectC
selectQ = selectG c_selectQ

type Sel x = CV CInt (CV x (CV x (CV x (CV x (IO CInt)))))

foreign import ccall unsafe "chooseD" c_selectD :: Sel Double
foreign import ccall unsafe "chooseF" c_selectF :: Sel Float
foreign import ccall unsafe "chooseI" c_selectI :: Sel CInt
foreign import ccall unsafe "chooseC" c_selectC :: Sel (Complex Double)
foreign import ccall unsafe "chooseQ" c_selectQ :: Sel (Complex Float)


