// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @notice The only ledger hot reads a Files rule or `FilesFinalValidator` makes (`subjectCreatedAt`,
///         `recordHeader`, `realmOrigin`, `controller`, `noticePrincipal`), settable by the test. Any other read
///         reverts (no fallback), so a rule that reaches for more fails loudly.
contract FilesLedgerStub {
    struct Header {
        bytes32 typeId;
        uint64 firstAdmission;
        uint32 length;
    }

    mapping(bytes32 => uint64) public subjectCreatedAt;
    mapping(bytes32 => Header) internal _headers;
    bytes32 public realmOrigin;
    address public controller;
    bytes32 public noticePrincipal;

    function setSubject(bytes32 subjectId, uint64 createdAt) external {
        subjectCreatedAt[subjectId] = createdAt;
    }

    function setRecord(bytes32 recordId, bytes32 typeId, uint64 firstAdmission, uint32 length)
        external
    {
        _headers[recordId] = Header(typeId, firstAdmission, length);
    }

    function setRealm(bytes32 origin, address controller_, bytes32 noticePrincipal_) external {
        realmOrigin = origin;
        controller = controller_;
        noticePrincipal = noticePrincipal_;
    }

    function recordHeader(bytes32 recordId)
        external
        view
        returns (bytes32, uint64, uint32, uint64, uint8)
    {
        Header memory h = _headers[recordId];
        return (h.typeId, h.firstAdmission, h.length, h.firstAdmission == 0 ? 0 : 1, 0);
    }
}

/// @notice The one index read `FilesFinalValidator` makes of its caller: `ledger()`.
contract FilesIndexStub {
    address public ledger;

    constructor(address ledger_) {
        ledger = ledger_;
    }
}
