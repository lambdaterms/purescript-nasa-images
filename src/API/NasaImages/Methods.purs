module API.NasaImages.Methods where

import Prelude

import API.NasaImages.Asset (Asset, withDimensions)
import API.NasaImages.Search (Item(Item), Request, Result(Result), toUrlEncoded)
import API.NasaImages.Validation (affjaxJson, asset, dimensions, findStr, searchResult, stringifyErrs)
import Control.Monad.Aff (Aff)
import Control.Monad.Error.Class (catchError)
import Control.Parallel (parTraverse)
import Data.Either (Either(..))
import Data.FormURLEncoded (encode)
import Data.HTTP.Method (Method(..))
import Data.Maybe (Maybe(..), maybe)
import Data.Record.Fold (rMap)
import Data.Traversable (sequence)
import Network.HTTP.Affjax (AJAX, AffjaxRequest, affjax, defaultRequest, get)
import Polyform.Validation (V(Valid, Invalid), Validation, hoistFnMV, hoistFnV, runValidation)
import Validators.Json (arrayOf, field, string)

buildRequest :: Request -> AffjaxRequest Unit
buildRequest r =
  let url = r # toUrlEncoded # encode
  in defaultRequest { url = "https://images-api.nasa.gov/search?" <> url, method = Left GET }

search :: forall e. Validation (Aff (ajax :: AJAX | e)) (Array String) Request (Result String)
search = hoistFnMV $ \req -> do
  resp <- (Just <$> affjax (buildRequest req)) `catchError` \_ → pure Nothing
  runValidation (affjaxRequest >>> affjaxJson >>> stringifyErrs (field "collection" (searchResult req))) resp
  where
  affjaxRequest = hoistFnV (maybe (Invalid ["AJAX request failed"]) (Valid []))

getDimensions
  :: forall e
   . Validation (Aff (ajax :: AJAX | e)) (Array String) String { width :: Int, height :: Int }
getDimensions = hoistFnMV $ \url -> do
  resp <- get url
  runValidation (affjaxJson >>> stringifyErrs dimensions) resp

retrieve :: forall e. Validation (Aff (ajax :: AJAX | e)) (Array String) String (Asset (Maybe Int))
retrieve = hoistFnMV $ \url -> do
  resp <- get url
  links <- runValidation (affjaxJson >>> (arrayOf string # stringifyErrs)) resp
  dimensions <- runValidation (hoistFnV (const links) >>> findStr "metadata" >>> getDimensions) unit
  let
    dims = case dimensions of
      Invalid _ -> { width: Nothing, height: Nothing }
      Valid _ v -> rMap Just v
  a <- runValidation (hoistFnV (const links) >>> asset) unit
  pure $ withDimensions dims <$> a

searchAndRetrieve
  :: forall e
   . Validation (Aff (ajax :: AJAX | e)) (Array String) Request (Result (Asset (Maybe Int)))
searchAndRetrieve = search >>> (hoistFnMV $ \(Result r) -> do
  assets <- sequence <$> parTraverse (\(Item i) -> do
    asset <- runValidation retrieve i.asset
    pure $ Item <$> (i { asset = _ }) <$> asset) r.items
  pure $ (\arr -> Result $ r { items = arr }) <$> assets)
