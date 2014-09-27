{-# LANGUAGE Arrows #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE RecordWildCards #-}
module Main where

import Prelude hiding (any, floor, ceiling, (.), id)

import Control.Applicative
import Control.Arrow
import Control.Category
import Control.Lens hiding (indices)
import Control.Monad.Fix (MonadFix)
import Data.Distributive (distribute)
import Data.Foldable (any, for_)
import Data.Function (fix)
import Data.Int (Int32)
import Data.Monoid ((<>))
import Data.Time (getCurrentTime, diffUTCTime)
import Foreign (Ptr, Storable(..), alloca, castPtr, nullPtr, plusPtr, with)
import Foreign.C (CFloat, withCString)
import Graphics.Rendering.OpenGL (($=))
import Linear as L
import Unsafe.Coerce (unsafeCoerce)

import qualified Codec.Picture as JP
import qualified Codec.Picture.Types as JP
import qualified Data.IntMap.Strict as IM
import qualified Data.Text.Encoding as Text
import qualified Data.Text.IO as Text
import qualified Data.Vector as V
import qualified Data.Vector.Storable as SV
import qualified Graphics.Rendering.OpenGL as GL
import qualified Graphics.Rendering.OpenGL.Raw as GL
import qualified Graphics.UI.SDL.Basic as SDL
import qualified Graphics.UI.SDL.Enum as SDL
import qualified Graphics.UI.SDL.Event as SDL
import qualified Graphics.UI.SDL.Types as SDL
import qualified Graphics.UI.SDL.Video as SDL

import qualified FRP

import Paths_hadoom

data Material =
  Material {matDiffuse :: GL.TextureObject
           ,matNormalMap :: GL.TextureObject}

data Sector =
  Sector {sectorVertices :: IM.IntMap (V2 CFloat)
         ,sectorWalls :: V.Vector (Int,Int)
         ,sectorFloor :: CFloat
         ,sectorCeiling :: CFloat
         ,sectorFloorMaterial :: Material
         ,sectorCeilingMaterial :: Material
         ,sectorWallMaterial :: Material}

data Vertex =
  Vertex {vPos :: {-# UNPACK #-} !(V3 CFloat)
         ,vNorm :: {-# UNPACK #-} !(V3 CFloat)
         ,vTangent :: {-# UNPACK #-} !(V3 CFloat)
         ,vBitangent :: {-# UNPACK #-} !(V3 CFloat)
         ,vUV :: {-# UNPACK #-} !(V2 CFloat)}
  deriving (Show)

data SectorRenderer =
  SectorRenderer {srDrawWalls :: IO ()
                 ,srDrawFloor :: IO ()
                 ,srDrawCeiling :: IO ()
                 ,srFloorMaterial :: Material
                 ,srCeilingMaterial :: Material
                 ,srWallMaterial :: Material}

instance Storable Vertex where
  sizeOf ~(Vertex p n t bn uv) = sizeOf p + sizeOf n + sizeOf t + sizeOf bn +
                                 sizeOf uv
  alignment _ = 0
  peek ptr =
    Vertex <$>
    peek (castPtr ptr) <*>
    peek (castPtr $ ptr `plusPtr`
          sizeOf (vPos undefined)) <*>
    peek (castPtr $ ptr `plusPtr`
          sizeOf (vPos undefined) `plusPtr`
          sizeOf (vNorm undefined)) <*>
    peek (castPtr $ ptr `plusPtr`
          sizeOf (vPos undefined) `plusPtr`
          sizeOf (vNorm undefined) `plusPtr`
          sizeOf (vTangent undefined)) <*>
    peek (castPtr $ ptr `plusPtr`
          sizeOf (vPos undefined) `plusPtr`
          sizeOf (vNorm undefined) `plusPtr`
          sizeOf (vTangent undefined) `plusPtr`
          sizeOf (vBitangent undefined))
  poke ptr (Vertex p n t bn uv) =
    do poke (castPtr $ ptr) p
       poke (castPtr $ ptr `plusPtr` sizeOf p) n
       poke (castPtr $ ptr `plusPtr` sizeOf p `plusPtr` sizeOf n) t
       poke (castPtr $ ptr `plusPtr` sizeOf p `plusPtr` sizeOf n `plusPtr`
             sizeOf t)
            bn
       poke (castPtr $ ptr `plusPtr` sizeOf p `plusPtr` sizeOf n `plusPtr`
             sizeOf t `plusPtr` sizeOf bn)
            uv

triangleArea :: Fractional a => V2 a -> V2 a -> V2 a -> a
triangleArea a b c =
  let toV3 (V2 x y) = V3 x y 1
      det =
        det33 (V3 (toV3 a)
                  (toV3 b)
                  (toV3 c))
  in 0.5 * det

pointInTriangle :: (Fractional a, Ord a) => V2 a -> V2 a -> V2 a -> V2 a -> Bool
pointInTriangle p0@(V2 p0x p0y) p1@(V2 p1x p1y) p2@(V2 p2x p2y) (V2 px py) =
  let area = triangleArea p0 p1 p2
      s = 1 / (2 * area) * (p0y * p2x - p0x * p2y + (p2y - p0y) * px + (p0x - p2x) * py)
      t = 1 / (2 * area) * (p0x * p1y - p0y * p1x + (p0y - p1y) * px + (p1x - p0x) * py)
  in s > 0 && t > 0 && (1 - s - t) > 0

triangulate :: (Fractional a, Ord a) => V.Vector (V2 a) -> V.Vector Int
triangulate = go . addIndices
  where takeFirst f =
          V.take 1 .
          V.filter f
        isEar ((_,a),(_,b),(_,c),otherVertices) =
          let area = triangleArea a b c
              containsOther =
                any (pointInTriangle a b c .
                     snd)
                    otherVertices
          in area > 0 && not containsOther
        go s
          | V.length s < 3 = empty
          | otherwise =
            do (v0@(n0,_),(n1,_),v2@(n2,_),others) <- takeFirst isEar (separate s)
               [n0,n2,n1] <>
                 go (v0 `V.cons`
                     (v2 `V.cons` others))
        addIndices vertices =
          V.zip [0 .. V.length vertices] vertices
        separate vertices =
          let n = V.length vertices
              doubleVerts = vertices <> vertices
          in V.zip4 vertices
                    (V.drop 1 doubleVerts)
                    (V.drop 2 doubleVerts)
                    (V.imap (\i _ ->
                               V.take (n - 3) $
                               V.drop (i + 3) $
                               doubleVerts)
                            vertices)

realiseSector :: Sector -> IO SectorRenderer
realiseSector Sector{..} =
  do vao <- initializeVAO
     initializeVBO
     configureVertexAttributes
     initializeIBO
     return $
       SectorRenderer {srDrawWalls =
                         do GL.bindVertexArrayObject $=
                              Just vao
                            GL.drawElements GL.Triangles
                                            (fromIntegral $ V.length wallIndices)
                                            GL.UnsignedInt
                                            nullPtr
                      ,srDrawFloor =
                         do GL.bindVertexArrayObject $=
                              Just vao
                            GL.drawElements
                              GL.Triangles
                              (fromIntegral $ V.length floorIndices)
                              GL.UnsignedInt
                              (nullPtr `plusPtr`
                               fromIntegral
                                 (sizeOf (0 :: Int32) *
                                  V.length wallIndices))
                      ,srDrawCeiling =
                         do GL.bindVertexArrayObject $=
                              Just vao
                            GL.drawElements
                              GL.Triangles
                              (fromIntegral $ V.length ceilingIndices)
                              GL.UnsignedInt
                              (nullPtr `plusPtr`
                               fromIntegral
                                 (sizeOf (0 :: Int32) *
                                  (V.length wallIndices + V.length floorIndices)))
                      ,srWallMaterial = sectorWallMaterial
                      ,srFloorMaterial = sectorFloorMaterial
                      ,srCeilingMaterial = sectorCeilingMaterial}
  where initializeVAO =
          do vao <- GL.genObjectName :: IO (GL.VertexArrayObject)
             GL.bindVertexArrayObject $=
               Just vao
             return vao
        initializeVBO =
          do vbo <- GL.genObjectName
             GL.bindBuffer GL.ArrayBuffer $=
               Just vbo
             let vertices = wallVertices <> floorVertices <> ceilingVertices
             SV.unsafeWith (V.convert vertices) $
               \verticesPtr ->
                 GL.bufferData GL.ArrayBuffer $=
                 (fromIntegral
                    (V.length vertices *
                     sizeOf (undefined :: Vertex))
                 ,verticesPtr
                 ,GL.StaticDraw)
        configureVertexAttributes =
          do let stride =
                   fromIntegral $
                   sizeOf (undefined :: Vertex)
                 normalOffset =
                   fromIntegral $
                   sizeOf (0 :: V3 CFloat)
                 tangentOffset =
                   normalOffset +
                   fromIntegral (sizeOf (0 :: V3 CFloat))
                 bitangentOffset =
                   tangentOffset +
                   fromIntegral (sizeOf (0 :: V3 CFloat))
                 uvOffset =
                   bitangentOffset +
                   fromIntegral (sizeOf (0 :: V3 CFloat))
             GL.vertexAttribPointer positionAttribute $=
               (GL.ToFloat,GL.VertexArrayDescriptor 3 GL.Float stride nullPtr)
             GL.vertexAttribArray positionAttribute $= GL.Enabled
             GL.vertexAttribPointer normalAttribute $=
               (GL.ToFloat
               ,GL.VertexArrayDescriptor 3
                                         GL.Float
                                         stride
                                         (nullPtr `plusPtr` normalOffset))
             GL.vertexAttribArray normalAttribute $= GL.Enabled
             GL.vertexAttribPointer tangentAttribute $=
               (GL.ToFloat
               ,GL.VertexArrayDescriptor 3
                                         GL.Float
                                         stride
                                         (nullPtr `plusPtr` tangentOffset))
             GL.vertexAttribArray tangentAttribute $= GL.Enabled
             GL.vertexAttribPointer bitangentAttribute $=
               (GL.ToFloat
               ,GL.VertexArrayDescriptor 3
                                         GL.Float
                                         stride
                                         (nullPtr `plusPtr` bitangentOffset))
             GL.vertexAttribArray bitangentAttribute $= GL.Enabled
             GL.vertexAttribPointer uvAttribute $=
               (GL.ToFloat
               ,GL.VertexArrayDescriptor 2
                                         GL.Float
                                         stride
                                         (nullPtr `plusPtr` uvOffset))
             GL.vertexAttribArray uvAttribute $= GL.Enabled
        textureScaleFactor = 8.0e-2
        wallVertices =
          V.concatMap
            (\(s,e) ->
               expandEdge (sectorVertices IM.! s)
                          (sectorVertices IM.! e))
            sectorWalls
          where expandEdge start@(V2 x1 y1) end@(V2 x2 y2) =
                  let wallV = end ^-^ start
                      wallLen = norm wallV
                      scaledLen = wallLen * textureScaleFactor
                      n =
                        case perp (wallV ^* recip wallLen) of
                          V2 x y -> V3 x 0 y
                      v =
                        (sectorCeiling - sectorFloor) *
                        textureScaleFactor
                  in V.fromList $ getZipList $ Vertex <$>
                     ZipList [V3 x1 sectorFloor y1
                             ,V3 x1 sectorCeiling y1
                             ,V3 x2 sectorFloor y2
                             ,V3 x2 sectorCeiling y2] <*>
                     ZipList (repeat n) <*>
                     ZipList (repeat $
                              case n of
                                V3 x 0 y ->
                                  V3 y 0 x) <*>
                     ZipList (repeat $ V3 0 (-1) 0) <*>
                     ZipList [V2 0 0,V2 0 1,V2 scaledLen 0,V2 scaledLen 1]
        wallIndices =
          V.concatMap id $
          V.imap (\m _ ->
                    let n = m * 4
                    in V.map fromIntegral [n,n + 2,n + 1,n + 1,n + 2,n + 3])
                 sectorWalls
        floorVertices =
          V.map (\(V2 x y) ->
                   Vertex (V3 x sectorFloor y)
                          (V3 0 1 0)
                          (V3 1 0 0)
                          (V3 0 0 1)
                          (V2 x y ^*
                           textureScaleFactor))
                (V.fromList $ IM.elems sectorVertices)
        ceilingVertices =
          V.map (\(Vertex p n t bn uv) ->
                   Vertex (p & _y .~ sectorCeiling)
                          (negate n)
                          t
                          bn
                          uv)
                floorVertices
        floorIndices =
          let n = fromIntegral $ V.length wallVertices
          in fmap (fromIntegral . (+ n)) $
             triangulate (V.fromList $ IM.elems sectorVertices)
        ceilingIndices =
          let rotate v =
                case V.splitAt 3 v of
                  (h,t)
                    | V.length h == 3 ->
                      [h V.! 0,h V.! 2,h V.! 1] V.++
                      rotate t
                  _ -> []
          in V.map (+ (fromIntegral $ V.length floorVertices))
                   (rotate floorIndices)
        initializeIBO =
          do let indices :: V.Vector Int32
                 indices = wallIndices <> floorIndices <> ceilingIndices
             ibo <- GL.genObjectName
             GL.bindBuffer GL.ElementArrayBuffer $=
               Just ibo
             SV.unsafeWith (V.convert indices) $
               \indicesPtr ->
                 GL.bufferData GL.ElementArrayBuffer $=
                 (fromIntegral
                    (V.length indices *
                     sizeOf (0 :: Int32))
                 ,indicesPtr
                 ,GL.StaticDraw)

data Light =
  Light {lightPos :: V3 CFloat
        ,lightColor :: V3 CFloat
        ,lightDirection :: Quaternion CFloat
        ,lightRadius :: CFloat}
  deriving (Show)

shadowMapResolution = 1024

genLightDepthMap :: IO GL.TextureObject
genLightDepthMap =
  do lightDepthMap <- GL.genObjectName
     GL.textureBinding GL.Texture2D $=
       Just lightDepthMap
     GL.textureCompareMode GL.Texture2D $=
       Just GL.Lequal
     GL.textureFilter GL.Texture2D $=
       ((GL.Nearest,Nothing),GL.Nearest)
     GL.textureWrapMode GL.Texture2D GL.S $= (GL.Repeated, GL.Clamp)
     GL.texImage2D GL.Texture2D
                   GL.NoProxy
                   0
                   GL.DepthComponent16
                   (GL.TextureSize2D shadowMapResolution shadowMapResolution)
                   0
                   (GL.PixelData GL.DepthComponent GL.Float nullPtr)
     return lightDepthMap

genLightFramebufferObject :: IO GL.FramebufferObject
genLightFramebufferObject =
  do lightFBO <- GL.genObjectName
     GL.bindFramebuffer GL.Framebuffer $=
       lightFBO
     GL.drawBuffer $= GL.NoBuffers
     return lightFBO

instance Storable Light where
  sizeOf _ =
    sizeOf (undefined :: V4 CFloat) *
    3
  alignment _ = sizeOf (undefined :: V4 CFloat)
  peek ptr = error "peek Light"
  poke ptr (Light pos col dir r) =
    do poke (castPtr ptr) pos
       poke (castPtr $ ptr `plusPtr`
             fromIntegral (sizeOf (undefined :: V4 CFloat)))
            col
       poke (castPtr $ ptr `plusPtr`
             fromIntegral
               (sizeOf (undefined :: V4 CFloat) *
                2))
            (case (inv33 (fromQuaternion dir)) of
               Just m ->
                 m !*
                 V3 0 0 (-1) :: V3 CFloat)
       poke (castPtr $ ptr `plusPtr`
             fromIntegral
               (sizeOf (undefined :: V4 CFloat) *
                2 +
                sizeOf (undefined :: V3 CFloat)))
            r

main :: IO ()
main =
  alloca $ \winPtr ->
  alloca $ \rendererPtr -> do
    _ <- SDL.init SDL.initFlagEverything
    _ <- SDL.createWindowAndRenderer 800 600 0 winPtr rendererPtr
    win <- peek winPtr
    withCString "Hadoom" $ SDL.setWindowTitle win
    GL.clearColor $= GL.Color4 0 0 0 1

    wall1 <- Material <$> loadTexture "RoughBlockWall-ColorMap.jpg" <*> loadTexture "RoughBlockWall-NormalMap.jpg"
    wall2 <- return wall1 -- Material <$> loadTexture "wall-2.jpg" <*> loadTexture "flat.jpg"
    ceiling <- Material <$> loadTexture "CrustyConcrete-ColorMap.jpg" <*> loadTexture "CrustyConcrete-NormalMap.jpg"
    floor <- Material <$> loadTexture "AfricanEbonyBoards-ColorMap.jpg" <*> loadTexture "AfricanEbonyBoards-NormalMap.jpg"

    sector1 <-
      let vertices = IM.fromList $ zip [0 ..] [V2 (-50) (-50)
                                              ,V2 (-30) (-50)
                                              ,V2 (-30) (-30)
                                              ,V2 10 (-30)
                                              ,V2 10 (-50)
                                              ,V2 50 (-50)
                                              ,V2 50 50
                                              ,V2 30 50
                                              ,V2 30 60
                                              ,V2 10 60
                                              ,V2 10 61
                                              ,V2 (-10) 61
                                              ,V2 (-10) 60
                                              ,V2 (-40) 60
                                              ,V2 (-40) 50
                                              ,V2 (-50) 50]
      in realiseSector Sector {sectorVertices = vertices
                              ,sectorCeiling = 30
                              ,sectorFloor = (-10)
                              ,sectorWalls = [(0,1),(1,2),(2,3),(3,4),(4,5)
                                             ,(5,6),(6,7),(7,8),(8,9),(9,10)
                                             ,(11,12),(12,13),(13,14),(14,0)]
                              ,sectorFloorMaterial = floor
                              ,sectorCeilingMaterial = ceiling
                              ,sectorWallMaterial = wall1}
    sector2 <-
      let vertices = IM.fromList $ zip [0 ..] [V2 (-30) 61
                                              ,V2 (-10) 61
                                              ,V2 10 61
                                              ,V2 30 61
                                              ,V2 30 100
                                              ,V2 (-30) 100]
      in realiseSector Sector {sectorVertices = vertices
                              ,sectorCeiling = 30
                              ,sectorFloor = (-10)
                              ,sectorWalls = [(0,1),(2,3),(3,4),(4,5),(5,0)]
                              ,sectorFloorMaterial = floor
                              ,sectorCeilingMaterial = ceiling
                              ,sectorWallMaterial = wall2}

    shaderProg <- createShaderProgram "shaders/vertex/projection-model.glsl"
                                      "shaders/fragment/solid-white.glsl"

    shadowShader <- createShaderProgram "shaders/vertex/shadow.glsl" "shaders/fragment/depth.glsl"

    GL.currentProgram $= Just shaderProg

    let perspective =
          let fov = 75
              s = recip (tan $ fov * 0.5 * pi / 180)
              far = 100
              near = 1
          in [s ,0 ,0 ,0
             ,0 ,s ,0 ,0
             ,0 ,0 ,-(far / (far - near)) ,-1
             ,0 ,0 ,-((far * near) / (far - near)) ,1]

    let lPerspective =
          let fov = 130
              s = recip (tan $ fov * 0.5 * pi / 180)
              far = 100
              near = 1
          in [s ,0 ,0 ,0
             ,0 ,s ,0 ,0
             ,0 ,0 ,-(far / (far - near)) ,-1
             ,0 ,0 ,-((far * near) / (far - near)) ,1]

    SV.unsafeWith perspective $ \ptr -> do
      GL.UniformLocation loc1 <- GL.get (GL.uniformLocation shaderProg "projection")
      GL.currentProgram $= Just shaderProg
      GL.glUniformMatrix4fv loc1 1 0 ptr

    SV.unsafeWith lPerspective $ \ptr -> do
      GL.UniformLocation loc <- GL.get (GL.uniformLocation shaderProg "lightProjection")
      GL.currentProgram $= Just shaderProg
      GL.glUniformMatrix4fv loc 1 0 ptr

      GL.UniformLocation loc1 <- GL.get (GL.uniformLocation shadowShader "depthP")
      GL.currentProgram $= Just shadowShader
      GL.glUniformMatrix4fv loc1 1 0 ptr

    let bias = [ 0.5, 0, 0, 0
               , 0, 0.5, 0, 0
               , 0, 0, 0.5, 0
               , 0.5, 0.5, 0.5, 1
               ]
    SV.unsafeWith bias $ \ptr -> do
      GL.UniformLocation loc1 <- GL.get (GL.uniformLocation shaderProg "bias")
      GL.currentProgram $= Just shaderProg
      GL.glUniformMatrix4fv loc1 1 0 ptr

    do GL.UniformLocation loc <- GL.get (GL.uniformLocation shaderProg "tex")
       GL.glUniform1i loc 0

    do GL.UniformLocation loc <- GL.get (GL.uniformLocation shaderProg "depthMap")
       GL.glUniform1i loc 1

    do GL.UniformLocation loc <- GL.get (GL.uniformLocation shaderProg "nmap")
       GL.glUniform1i loc 2

    GL.depthFunc $= Just GL.Lequal

    lightsUBO <- GL.genObjectName
    shaderId <- unsafeCoerce shaderProg
    lightsUBI <- withCString "light" $ GL.glGetUniformBlockIndex shaderId
    GL.glUniformBlockBinding shaderId lightsUBI 0
    GL.bindBufferRange GL.IndexedUniformBuffer 0 $= Just (lightsUBO, 0, fromIntegral (sizeOf (undefined :: Light) * 1))
    GL.bindBuffer GL.UniformBuffer $= Just lightsUBO

    tstart <- getCurrentTime
    lightFBO <- genLightFramebufferObject
    lightTextures <- V.replicateM 2 genLightDepthMap

    fix (\again (w, currentTime) -> do
      newTime <- getCurrentTime
      let frameTime = newTime `diffUTCTime` currentTime

      events <- unfoldEvents
      let FRP.Out (Scene viewMat lights) w' = runIdentity $
            FRP.stepWire (realToFrac frameTime) events w

      with (distribute viewMat) $ \ptr -> do
        GL.UniformLocation loc1 <- GL.get (GL.uniformLocation shaderProg "view")
        GL.currentProgram $= Just shaderProg
        GL.glUniformMatrix4fv loc1 1 0 (castPtr (ptr :: Ptr (M44 CFloat)))

      GL.blend $= GL.Disabled
      GL.depthMask $= GL.Enabled
      GL.depthFunc $= Just GL.Lequal
      GL.colorMask $= GL.Color4 GL.Disabled GL.Disabled GL.Disabled GL.Disabled

      GL.currentProgram $= Just shadowShader
      GL.bindFramebuffer GL.Framebuffer $= lightFBO
      GL.viewport $= (GL.Position 0 0, GL.Size shadowMapResolution shadowMapResolution)
      GL.cullFace $= Just GL.Front
      lights' <- flip V.mapM (V.zip lights lightTextures) $ \(l, t) -> do
        GL.framebufferTexture2D GL.Framebuffer GL.DepthAttachment GL.Texture2D t 0
        GL.clear [GL.DepthBuffer]

        let v = m33_to_m44 (fromQuaternion (lightDirection l)) !*! mkTransformation 0 (negate (lightPos l))
        with (distribute v) $ \ptr -> do
          GL.UniformLocation loc <- GL.get (GL.uniformLocation shadowShader "depthV")
          GL.glUniformMatrix4fv loc 1 0 (castPtr (ptr :: Ptr (M44 CFloat)))

        case sector1 of SectorRenderer{..} -> srDrawWalls >> srDrawFloor
        case sector2 of SectorRenderer{..} -> srDrawWalls >> srDrawFloor
        return (l, t, distribute v)

      GL.bindFramebuffer GL.Framebuffer $= GL.defaultFramebufferObject
      GL.cullFace $= Just GL.Back
      GL.viewport $= (GL.Position 0 0, GL.Size 800 600)
      GL.clear [GL.DepthBuffer]

      GL.currentProgram $= Just shaderProg
      drawSectorTextured sector1
      drawSectorTextured sector2

      GL.blend $= GL.Enabled
      GL.blendFunc $= (GL.One, GL.One)
      GL.colorMask $= GL.Color4 GL.Enabled GL.Enabled GL.Enabled GL.Enabled
      GL.clear [GL.ColorBuffer]
      GL.depthFunc $= Just GL.Equal
      GL.depthMask $= GL.Disabled
      GL.currentProgram $= Just shaderProg
      flip V.mapM_ lights' $ \(l, t, v) -> do
        with v $ \ptr -> do
          GL.currentProgram $= Just shaderProg
          GL.UniformLocation loc <- GL.get (GL.uniformLocation shaderProg "camV")
          GL.glUniformMatrix4fv loc 1 0 (castPtr (ptr :: Ptr (M44 CFloat)))

        GL.activeTexture $= GL.TextureUnit 1
        GL.textureBinding GL.Texture2D $= Just t

        with l $ \ptr ->
          GL.bufferData GL.UniformBuffer $= (fromIntegral (sizeOf (undefined :: Light)), ptr, GL.StreamDraw)

        drawSectorTextured sector1
        drawSectorTextured sector2

      SDL.glSwapWindow win
      again (w', newTime)) (scene, tstart)

drawSectorTextured :: SectorRenderer -> IO ()
drawSectorTextured SectorRenderer{..} =
  do activateMaterial srWallMaterial
     srDrawWalls
     activateMaterial srFloorMaterial
     srDrawFloor
     activateMaterial srCeilingMaterial
     srDrawCeiling

activateMaterial :: Material -> IO ()
activateMaterial Material{..} =
  do GL.activeTexture $=
       GL.TextureUnit 0
     GL.textureBinding GL.Texture2D $=
       Just matDiffuse
     GL.activeTexture $=
       GL.TextureUnit 2
     GL.textureBinding GL.Texture2D $=
       Just matNormalMap

loadTexture :: FilePath -> IO GL.TextureObject
loadTexture path =
  do x <- JP.readImage path
     case x of
       Right (JP.ImageYCbCr8 img) ->
         do t <- GL.genObjectName
            GL.textureBinding GL.Texture2D $=
              Just t
            GL.textureFilter GL.Texture2D $=
              ((GL.Linear',Just GL.Linear'),GL.Linear')
            let toRgb8 =
                  JP.convertPixel :: JP.PixelYCbCr8 -> JP.PixelRGB8
                toRgbF =
                  JP.promotePixel :: JP.PixelRGB8 -> JP.PixelRGBF
            case JP.pixelMap (toRgbF . toRgb8)
                             img of
              JP.Image w h d ->
                do SV.unsafeWith d $
                     \ptr ->
                       GL.texImage2D
                         GL.Texture2D
                         GL.NoProxy
                         0
                         GL.RGB32F
                         (GL.TextureSize2D (fromIntegral w)
                                           (fromIntegral h))
                         0
                         (GL.PixelData GL.RGB GL.Float ptr)
                   GL.generateMipmap' GL.Texture2D
                   GL.textureMaxAnisotropy GL.Texture2D $=
                     16
                   return t
       Left e -> error e
       _ -> error "Unknown image format"

unfoldEvents :: IO [SDL.Event]
unfoldEvents =
  alloca $
  \evtPtr ->
    do r <- SDL.pollEvent evtPtr
       case r of
         0 -> return []
         _ -> (:) <$> peek evtPtr <*> unfoldEvents

positionAttribute, uvAttribute, normalAttribute, tangentAttribute, bitangentAttribute :: GL.AttribLocation
positionAttribute = GL.AttribLocation 0
normalAttribute = GL.AttribLocation 1
tangentAttribute = GL.AttribLocation 2
bitangentAttribute = GL.AttribLocation 3
uvAttribute = GL.AttribLocation 4

createShaderProgram :: FilePath -> FilePath -> IO GL.Program
createShaderProgram vertexShaderPath fragmentShaderPath =
  do vertexShader <- GL.createShader GL.VertexShader
     compileShader vertexShaderPath vertexShader
     fragmentShader <- GL.createShader GL.FragmentShader
     compileShader fragmentShaderPath fragmentShader
     shaderProg <- GL.createProgram
     GL.attachShader shaderProg vertexShader
     GL.attachShader shaderProg fragmentShader
     GL.attribLocation shaderProg "in_Position" $=
       positionAttribute
     GL.attribLocation shaderProg "in_Normal" $=
       normalAttribute
     GL.attribLocation shaderProg "in_Tangent" $=
       tangentAttribute
     GL.attribLocation shaderProg "in_Bitangent" $=
       bitangentAttribute
     GL.attribLocation shaderProg "in_UV" $=
       uvAttribute
     GL.linkProgram shaderProg
     return shaderProg
  where compileShader path shader =
          do src <- getDataFileName path >>= Text.readFile
             GL.shaderSourceBS shader $= Text.encodeUtf8 src
             GL.compileShader shader
             GL.get (GL.shaderInfoLog shader) >>=
               putStrLn

data Scene =
  Scene {sceneCamera :: M44 CFloat
        ,sceneLights :: V.Vector Light}

scene :: FRP.Wire Identity [SDL.Event] Scene
scene =
  Scene <$> camera <*>
  (FRP.time <&>
   \t ->
     [Light (V3 0 0 0)
            1
            (axisAngle (V3 0 1 0) $ pi + (pi / 8) * sin (realToFrac t))
            1000
     ,Light (V3 0 15 ((sin (realToFrac t) * 50 * 0.5 + 0.5) + 20))
            1
            (axisAngle (V3 0 1 0) 0)
            1000])

camera :: FRP.Wire Identity [SDL.Event] (M44 CFloat)
camera = proc events -> do
  goForward <- keyHeld SDL.scancodeUp -< events
  goBack <- keyHeld SDL.scancodeDown -< events

  turnLeft <- keyHeld SDL.scancodeLeft -< events
  turnRight <- keyHeld SDL.scancodeRight -< events
  theta <- (FRP.integralWhen -< (-2, turnLeft)) + (FRP.integralWhen -< (2, turnRight))
  let quat = axisAngle (V3 0 1 0) theta

  rec position <- if goForward
                   then FRP.integral -< over _x negate $ rotate quat (V3 0 0 1) * 10
                   else returnA -< position'
      position' <- FRP.delay 0 -< position

  returnA -< m33_to_m44 (fromQuaternion quat) !*! mkTransformation 0 (position - V3 0 10 0)

keyPressed :: (Applicative m, MonadFix m) => SDL.Scancode -> FRP.Wire m [SDL.Event] Bool
keyPressed scancode = proc events -> do
  rec pressed <- FRP.delay False -<
                   pressed ||
                     (filter ((== SDL.eventTypeKeyDown) . SDL.eventType) events
                        `hasScancode` scancode)
  returnA -< pressed

keyReleased :: (Applicative m, MonadFix m) => SDL.Scancode -> FRP.Wire m [SDL.Event] Bool
keyReleased scancode =
  proc events ->
  do rec released <- FRP.delay False -<
                       released ||
                         (filter ((== SDL.eventTypeKeyUp) . SDL.eventType) events
                            `hasScancode` scancode)
     returnA -< released

keyHeld :: (Applicative m, MonadFix m) => SDL.Scancode -> FRP.Wire m [SDL.Event] Bool
keyHeld scancode =
  proc events ->
  do pressed <- keyPressed scancode -< events
     if pressed then
       do released <- keyReleased scancode -< events
          if released then FRP.delay False . keyHeld scancode -< events else
            returnA -< True
       else returnA -< False

hasScancode :: [SDL.Event] -> SDL.Scancode -> Bool
events `hasScancode` s =
  case events of
    (SDL.KeyboardEvent _ _ _ _ _ (SDL.Keysym scancode _ _)) : xs -> scancode == s || xs `hasScancode` s
    _ : xs -> xs `hasScancode` s
    [] -> False
