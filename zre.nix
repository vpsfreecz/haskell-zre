{ mkDerivation, async, attoparsec, base, binary, binary-strict
, bytestring, config-ini, containers, data-default, directory, ekg
, filepath, lifted-async, monad-control, mtl, network, network-info
, network-multicast, optparse-applicative, process, random, repline
, sockaddr, stdenv, stm, text, time, transformers-base, uuid
, zeromq4-haskell
}:
mkDerivation {
  pname = "zre";
  version = "0.1.0.2";
  src = ./.;
  isLibrary = true;
  isExecutable = true;
  libraryHaskellDepends = [
    async attoparsec base binary binary-strict bytestring config-ini
    containers data-default directory ekg filepath monad-control mtl
    network network-info network-multicast optparse-applicative process
    random sockaddr stm text time transformers-base uuid
    zeromq4-haskell
  ];
  executableHaskellDepends = [
    async base bytestring lifted-async monad-control mtl repline stm
    time
  ];
  testHaskellDepends = [ base ];
  homepage = "https://github.com/vpsfreecz/haskell-zre/";
  description = "ZRE protocol implementation";
  license = stdenv.lib.licenses.bsd3;
}
