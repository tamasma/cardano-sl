{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase        #-}

--
-- | Cryptographic & Data.X509 specialized methods for RSA with SHA256
--
module Data.X509.Extra
    (
    -- * RSA/SHA-256 Applied Constructors
      signAlgRSA256
    , signCertificate
    , genRSA256KeyPair
    , validateDefaultWithIP
    , validateCertificate

    -- * Utils
    , failIfReasons
    , parseSAN

    -- * RSA Encode PEM
    , EncodePEM (..)

    -- * Effectful IO Functions
    , writeCredentials
    , writeCertificate

    -- * Re-Export
    , module Data.X509
    , module Data.X509.Validation
    ) where

import           Universum

import           Crypto.Hash.Algorithms (SHA256 (..))
import           Crypto.PubKey.RSA (PrivateKey (..), PublicKey (..), generate)
import           Crypto.PubKey.RSA.PKCS15 (signSafer)
import           Crypto.Random.Types (MonadRandom)
import           Data.ASN1.BinaryEncoding (DER (..))
import           Data.ASN1.Encoding (encodeASN1)
import           Data.ASN1.Types (ASN1 (..), ASN1ConstructionType (..),
                     asn1CharacterToString)
import           Data.ByteString (ByteString)
import           Data.Default.Class
import           Data.List (intercalate)
import           Data.X509
import           Data.X509.CertificateStore (CertificateStore,
                     makeCertificateStore)
import           Data.X509.Validation
import           Net.IP (IP)

import qualified Crypto.PubKey.RSA.Types as RSA
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base64 as Base64
import qualified Data.ByteString.Char8 as B8
import qualified Data.ByteString.Lazy as BL
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Net.IP as IP
import qualified Net.IPv4 as IPv4
import qualified Net.IPv6 as IPv6


--
-- RSA/SHA-256 Applied Constructors
--

-- | Algorithm Signature for RSA with SHA256
signAlgRSA256 :: SignatureALG
signAlgRSA256 =
    SignatureALG HashSHA256 PubKeyALG_RSA


-- | Sign a X.509 certificate using RSA-PKCS1.5 with SHA256
signCertificate :: (MonadFail m, MonadRandom m) => PrivateKey -> Certificate -> m SignedCertificate
signCertificate key =
    objectToSignedExactF signSHA256
  where
    signSHA256 :: (MonadFail m, MonadRandom m) => ByteString -> m (ByteString, SignatureALG)
    signSHA256 =
        signSafer (Just SHA256) key >=> orFail

    orFail :: MonadFail m => Either RSA.Error ByteString -> m (ByteString, SignatureALG)
    orFail =
        either (fail . show) (return . (,signAlgRSA256))


-- | Drop-in replacement for 'validateDefault' but with support for IP SAN
validateDefaultWithIP
    :: CertificateStore
    -> ValidationCache
    -> ServiceID
    -> CertificateChain
    -> IO [FailedReason]
validateDefaultWithIP =
    validate HashSHA256 hooks checks
  where
    hooks  = defaultHooks { hookValidateName = validateCertificateName }
    checks = defaultChecks


-- | Validate a X.509 certificate using SHA256 hash and a given CA. This is
-- merely to verify that we aren't generating invalid certificates.
validateCertificate
    :: SignedCertificate
    -> ValidationChecks
    -> ServiceID
    -> SignedCertificate
    -> IO [FailedReason]
validateCertificate caCert checks sid cert =
    validate HashSHA256 hooks checks store def sid chain
  where
    hooks = defaultHooks { hookValidateName = validateCertificateName }
    store = makeCertificateStore [caCert]
    chain = CertificateChain [cert]


-- | Generate a new RSA-256 key pair
genRSA256KeyPair :: IO (PublicKey, PrivateKey)
genRSA256KeyPair =
    generate 256 65537


--
-- EncodePEM
--

-- | Encode an artifact to PEM (i.e. base64 DER with header & footer)
class EncodePEM a where
    encodePEM :: a -> ByteString
    encodePEMRaw :: (ByteString, a -> ByteString, ByteString) -> a -> ByteString
    encodePEMRaw (header, encodeDER, footer) a =
        BS.concat
            [ header
            , "\n"
            , BS.intercalate "\n" (mkGroupsOf 64 $ Base64.encode $ encodeDER a)
            , "\n"
            , footer
            ]
      where
        mkGroupsOf :: Int -> ByteString -> [ByteString]
        mkGroupsOf n xs
            | BS.length xs == 0 = []
            | otherwise         = (BS.take n xs) : mkGroupsOf n (BS.drop n xs)

instance EncodePEM PrivateKey where
    encodePEM = encodePEMRaw
        ( "-----BEGIN RSA PRIVATE KEY-----"
        , encodeDERRSAPrivateKey
        , "-----END RSA PRIVATE KEY-----"
        )

instance EncodePEM (SignedExact Certificate) where
    encodePEM = encodePEMRaw
        ( "-----BEGIN CERTIFICATE-----"
        , encodeSignedObject
        , "-----END CERTIFICATE-----"
        )

--
-- Utils
--

-- | Fail with the given reason if any, does nothing otherwise
failIfReasons
    :: MonadFail m
    => [FailedReason]
    -> m ()
failIfReasons = \case
    [] -> return ()
    xs -> fail $ "Generated invalid certificate: " ++ intercalate ", " (map show xs)


-- | Parse a Subject Alternative Name (SAN) from a raw string
parseSAN :: String -> AltName
parseSAN name =
    case IP.decode (toText name) of
        Just ip ->
            AltNameIP . T.encodeUtf8 $ IP.case_ IPv4.encode IPv6.encode ip

        Nothing ->
            AltNameDNS name


--
-- Effectful IO Functions
--

-- | Write a certificate and its private key to the given location
writeCredentials
    :: FilePath
    -> (PrivateKey, SignedCertificate)
    -> IO ()
writeCredentials filename (key, cert) = do
    BS.writeFile (filename <> ".pem") (BS.concat [keyBytes, "\n", certBytes])
    BS.writeFile (filename <> ".key") keyBytes
    BS.writeFile (filename <> ".crt") certBytes
  where
    keyBytes  = encodePEM key
    certBytes = encodePEM cert


-- | Write a certificate to the given location
writeCertificate
    :: FilePath
    -> SignedCertificate
    -> IO ()
writeCertificate filename cert =
    BS.writeFile (filename <> ".crt") (encodePEM cert)


--
-- Internals
--

-- | Encode a RSA private key as DER (Distinguished Encoding Rule) binary format
encodeDERRSAPrivateKey :: PrivateKey -> ByteString
encodeDERRSAPrivateKey =
    BL.toStrict . encodeASN1 DER . rsaToASN1
  where
    -- | RSA Private Key Syntax, see https://tools.ietf.org/html/rfc3447#appendix-A.1
    rsaToASN1 :: PrivateKey -> [ASN1]
    rsaToASN1 (PrivateKey (PublicKey _ n e) d p q dP dQ qInv) =
        [ Start Sequence
        , IntVal 0
        , IntVal n
        , IntVal e
        , IntVal d
        , IntVal p
        , IntVal q
        , IntVal dP
        , IntVal dQ
        , IntVal qInv
        , End Sequence
        ]


-- | Helper to decode an IP address from raw bytes
ipFromBytes :: ByteString -> Maybe IP
ipFromBytes =
    IP.decode . T.decodeUtf8


-- | Hook to validate a certificate name. It only validates DNS and IPs names
-- against the provided hostname. It fails otherwise.
validateCertificateName :: HostName -> Certificate -> [FailedReason]
validateCertificateName fqhn =
    case parseSAN fqhn of
        AltNameIP bytes ->
            case ipFromBytes bytes of
                Nothing -> const [InvalidName fqhn]
                Just ip -> validateCertificateIP ip
        _ ->
            validateCertificateDNS fqhn


-- | Hook to validate certificate DNS, using the default hook from
-- x509-validation which does exactly that.
validateCertificateDNS :: HostName -> Certificate -> [FailedReason]
validateCertificateDNS =
    hookValidateName defaultHooks


-- | Basic validation against the host if it turns out to be an IP address
validateCertificateIP :: IP -> Certificate -> [FailedReason]
validateCertificateIP ip cert =
    let
        commonName :: Maybe IP
        commonName =
            toCommonName =<< getDnElement DnCommonName (certSubjectDN cert)

        altNames :: [IP]
        altNames =
            maybe [] toAltName $ extensionGet $ certExtensions cert

        toAltName :: ExtSubjectAltName -> [IP]
        toAltName (ExtSubjectAltName sans) =
            catMaybes $ flip map sans $ \case
                AltNameIP bytes -> ipFromBytes bytes
                _               -> Nothing

        toCommonName :: ASN1CharacterString -> Maybe IP
        toCommonName =
            asn1CharacterToString >=> (ipFromBytes . B8.pack)
    in
        if any (== ip) (maybeToList commonName ++ altNames) then
            []
        else
            [NameMismatch $ T.unpack $ IP.encode ip]