// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IKybReportReceiver {
    function onReport(bytes calldata metadata, bytes calldata report) external;
}

/// @title KybAttestationExtractor
/// @notice CRE receiver boundary for team-keyed KYB/DON reports.
/// @dev CRE must set this contract as `writeReport.receiver`. The extractor
///      forwards the signed report to BUAttestation, which remains responsible
///      for report-kind, TTL, workflow, chain, and replay validation.
contract KybAttestationExtractor is Ownable2Step, Pausable, ReentrancyGuard {
    IKybReportReceiver public immutable TARGET;
    uint64 public immutable TARGET_CHAIN_SELECTOR;
    address public forwarder;
    bytes32 public expectedWorkflowId;

    error ZeroAddress();
    error ZeroChainSelector();
    error NotForwarder(address caller);
    error InvalidMetadataLength(uint256 actualLength);
    error UnexpectedWorkflowId(bytes32 received, bytes32 expected);

    event ForwarderUpdated(address indexed previousForwarder, address indexed newForwarder);
    event ExpectedWorkflowIdUpdated(bytes32 indexed previousWorkflowId, bytes32 indexed newWorkflowId);
    event ReportForwarded(bytes32 indexed workflowId, address indexed target);

    modifier onlyForwarder() {
        if (msg.sender != forwarder) revert NotForwarder(msg.sender);
        _;
    }

    constructor(address initialOwner, address initialForwarder, uint64 targetChainSelector, IKybReportReceiver target)
        Ownable(initialOwner)
    {
        if (initialOwner == address(0) || initialForwarder == address(0) || address(target) == address(0)) {
            revert ZeroAddress();
        }
        if (targetChainSelector == 0) revert ZeroChainSelector();
        TARGET = target;
        TARGET_CHAIN_SELECTOR = targetChainSelector;
        forwarder = initialForwarder;
        emit ForwarderUpdated(address(0), initialForwarder);
    }

    function onReport(bytes calldata metadata, bytes calldata report)
        external
        onlyForwarder
        whenNotPaused
        nonReentrant
    {
        bytes32 workflowId = _validateMetadata(metadata);
        TARGET.onReport(metadata, report);
        emit ReportForwarded(workflowId, address(TARGET));
    }

    function setForwarder(address newForwarder) external onlyOwner {
        if (newForwarder == address(0)) revert ZeroAddress();
        emit ForwarderUpdated(forwarder, newForwarder);
        forwarder = newForwarder;
    }

    function setExpectedWorkflowId(bytes32 newWorkflowId) external onlyOwner {
        emit ExpectedWorkflowIdUpdated(expectedWorkflowId, newWorkflowId);
        expectedWorkflowId = newWorkflowId;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function _validateMetadata(bytes calldata metadata) internal view returns (bytes32 workflowId) {
        if (expectedWorkflowId == bytes32(0)) return bytes32(0);
        if (metadata.length < 32) revert InvalidMetadataLength(metadata.length);
        assembly ("memory-safe") {
            workflowId := calldataload(metadata.offset)
        }
        if (workflowId != expectedWorkflowId) revert UnexpectedWorkflowId(workflowId, expectedWorkflowId);
    }
}
