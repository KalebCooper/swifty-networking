#if WebSocketPortable
import NIOSSL

enum TLSFixture {
  static let certificate = """
    -----BEGIN CERTIFICATE-----
    MIIDHzCCAgegAwIBAgIUOq9nxKmN0zDcQ157KYfmI4MUT1cwDQYJKoZIhvcNAQEL
    BQAwFDESMBAGA1UEAwwJbG9jYWxob3N0MB4XDTI2MDkyMTIxMTEyN1oXDTM2MDkx
    ODIxMTEyN1owFDESMBAGA1UEAwwJbG9jYWxob3N0MIIBIjANBgkqhkiG9w0BAQEF
    AAOCAQ8AMIIBCgKCAQEAsMabiq6GwEEzbq/8EqxbjAjurKMGeloGrSGB++ZlCR2m
    6R1raoJeYyykJUjtY+gPfrjz8Q7JTB/fF2v7IHp9sgiomLZCHhVtK6KAP158XWzN
    Y02k755qfPc3TS71smRqOjbRs/UzW2MvvzziIuPnRAjhuMCW3vqbifAuLzXrqa5q
    egVYwDaHyRoF8gCPtNagoa03MhygazmwiHX04W3ickV4njyvpMWhOf2+SWWKiaGt
    /FnzxT3/PV9t2Yg0uVyjKA9hiuN+MbT35e/o6O8r42jFDuloBtciSiV3R+R3PNXZ
    MZreDbmUot+AKET2hws7RAeMsONSNiK+qM/jZ93EZwIDAQABo2kwZzAdBgNVHQ4E
    FgQUp4NBei75XDiVv/No1Ep8y5wU7XUwHwYDVR0jBBgwFoAUp4NBei75XDiVv/No
    1Ep8y5wU7XUwDwYDVR0TAQH/BAUwAwEB/zAUBgNVHREEDTALgglsb2NhbGhvc3Qw
    DQYJKoZIhvcNAQELBQADggEBACDzcOBDXvI05f6ebwrUI3UnHqSmxNIN3yu2QUU2
    2IhSnGfgSDxMJY3QrrDWk1YZtX0H0jtwP7LeC62Af+Gi8W/Ip7h6WVWGMd6Scnxu
    +si29M0lXG4zho9b/NC62g4b/8MLoll6rlLMaKkKy+lB7YrI7zfE+D9bJC/1aVZa
    DecEIEaWVf+6yHMMW/gbxpFkk7jnmOkpNmod6w8QJzz78heUlnABAPqMcx+RlW42
    tSwG0/O2CtNlDU8pYjacmqZqI1h9XuUDh2YyusQZUC/IsZ8URupjAgnLd1OymLEc
    eOyc2u0roR4mHf9rrOIZwRSRQ9ZKMuqnotTpaSaDuA6jh1c=
    -----END CERTIFICATE-----
    """
  // This key belongs only to the checked-in loopback certificate.
  static let key = """
    -----BEGIN PRIVATE KEY-----
    MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQCwxpuKrobAQTNu
    r/wSrFuMCO6sowZ6WgatIYH75mUJHabpHWtqgl5jLKQlSO1j6A9+uPPxDslMH98X
    a/sgen2yCKiYtkIeFW0rooA/XnxdbM1jTaTvnmp89zdNLvWyZGo6NtGz9TNbYy+/
    POIi4+dECOG4wJbe+puJ8C4vNeuprmp6BVjANofJGgXyAI+01qChrTcyHKBrObCI
    dfThbeJyRXiePK+kxaE5/b5JZYqJoa38WfPFPf89X23ZiDS5XKMoD2GK434xtPfl
    7+jo7yvjaMUO6WgG1yJKJXdH5Hc81dkxmt4NuZSi34AoRPaHCztEB4yw41I2Ir6o
    z+Nn3cRnAgMBAAECggEAN1OZt+BitUZS0hhLVQ7TwjLDfI2zh9SoVURw+cWEpsM8
    i6ZVCatO3kxI/ZBjGAs32koJs08U6nnpKVv255XexDtYhR85909ucSM1b1/jnZvh
    dmyFLCfRHVaEXOhPJqut4ZVpsaCTF82l0n08K35X0d/Twa6pKZWW26er1MPUA7FY
    42H0439cMQjsqXno+qTvcGw8T4NdBYOHc4qqfX84ogvk9U9svr338UWkkJyl85/3
    lfuvFlf+sx2J9yAZHGKkU9kfUWeDL/oC7icXsHRH9tHL8AhWP4hnO3z/XXShlq32
    0eCHqcTJvVwHoE/L1OBn9Y1PP2IR/yvLwU/UqhNeoQKBgQDn1gy/r43Mx1BOLisF
    bUADckIo9tpWX/mT58jBSG/oz0UDz0Tog4N3MZTDYSbxfSM9wVKkqWivS9uim5S8
    WPBsqF3FnuO80QWpddruhFLRVsuq+XrJyrBfmvTTAWpdZ01PqdiR4DCfJHE6DzKH
    s21XcUv2s0fUGDV82rXYjaubIQKBgQDDM2o2qScXDEhqDFpa7UJ0dLWc7Xn1nONn
    pINQycbjtfp/I9hU70n0xjX5HO+RkCraEYOXjAWswwO9Z6xwY57x148sJlLuu6k/
    hW4ZaD/Q2OlszwF4UEy+FIzLqLg61FjV6jDSIW96sxvelyKkyQSAvq3Sc5WfNoXV
    9p6dIOY2hwKBgQCawgRYoPPjUtmElsUZJkipBEit17sAFakg1oTooVYy7sl/NYkm
    PUQw+OP5WI0KfyJbQwXL7Vp4SgcfkQPEhwpXPjz6goo7rLw+1vGCbspp+6qRQ2B3
    +9mouGPdxwAdwauWFib/mcxbL5R10VdFxryitnqjACJerppl8gmZuVhogQKBgBQq
    EYTIAIO+/xQFZqgR7lV9YO1vErQumscwFWiZD3SibdgIaeaMOYWRnC25sX3F+MdC
    G+fhzQxFsPM17HhHsjmlXOLgqpyCwj8Pl4oEXONEJQjacXpuQR85nDnFmhJpsSuX
    36c1UQDJ080wq6F+KnrqN6aPzhr+VOD/cu8kYOOtAoGARgpqv1LK+cDIIz7uFw2Y
    mPGTGkW8rej+gP6Ik2+NVrWuEWSNaLA5CRmLPa3iwIQUGrlC+nJz7GrZAu0HA3xX
    HTOn/Xu49kwPT2mJoZL9iDfBgU35Nk0d9IJnaGM/L+HUx0hIXhn3RxnAy/Fbx3/e
    hkV3aagavMXvITyQ83z3DA4=
    -----END PRIVATE KEY-----
    """
  // Parsing the PEM pair is synchronous work, so every server shares one context built on first
  // use. The result is kept rather than trapped so a bad fixture fails the test that reads it.
  static let serverContext = Result { () throws -> NIOSSLContext in
    try NIOSSLContext(
      configuration: .makeServerConfiguration(
        certificateChain: try NIOSSLCertificate.fromPEMBytes(Array(certificate.utf8)).map {
          .certificate($0)
        },
        privateKey: .privateKey(try NIOSSLPrivateKey(bytes: Array(key.utf8), format: .pem))))
  }

  static func client() throws -> TLSConfiguration {
    var configuration = TLSConfiguration.makeClientConfiguration()
    configuration.trustRoots = .certificates(
      try NIOSSLCertificate.fromPEMBytes(Array(certificate.utf8)))
    return configuration
  }

}
#endif
