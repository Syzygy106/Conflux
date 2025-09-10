// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

library FunctionsRequest {
  enum Location {
    Inline,
    Remote
  }

  enum CodeLanguage {
    JavaScript,
    Python
  }

  struct Request {
    Location location;
    CodeLanguage language;
    string source;
    Location secretsLocation;
    bytes encryptedSecretsReference;
    string[] args;
    bytes[] bytesArgs;
  }

  function initializeRequest(
    Request memory self,
    Location location,
    CodeLanguage language,
    string memory source
  ) internal pure returns (Request memory) {
    self.location = location;
    self.language = language;
    self.source = source;
    return self;
  }

  function setArgs(Request memory self, string[] calldata args) internal pure {
    self.args = args;
  }

  function setBytesArgs(Request memory self, bytes[] calldata bytesArgs) internal pure {
    self.bytesArgs = bytesArgs;
  }

  function encodeCBOR(Request memory self) internal pure returns (bytes memory) {
    return
      abi.encode(
        self.location,
        self.language,
        self.source,
        self.secretsLocation,
        self.encryptedSecretsReference,
        self.args,
        self.bytesArgs
      );
  }
}
