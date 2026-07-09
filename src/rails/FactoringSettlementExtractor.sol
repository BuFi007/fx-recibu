// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {BINV} from "../invoice/BINV.sol";
import {IReceiver} from "../interfaces/IReceiver.sol";

interface IInvoiceSettlementTarget {
    function settle(uint256 invoiceId) external returns (uint256 amount);
    function USDC() external view returns (address);
    function SHELF() external view returns (address);
    function ESCROW() external view returns (address);
}

interface IInvoiceShelfTarget {
    function USDC() external view returns (address);

    function lockInvoice(
        uint256 sellerAgentId,
        uint256 debtorAgentId,
        uint128 face,
        uint8 nInstallments,
        uint64 firstMaturity,
        uint32 interval,
        BINV.DocBundle calldata docs
    ) external returns (uint256 invoiceId);

    function markDefaulted(uint256 invoiceId) external;
}

interface IReceivableEscrowTokenView {
    function USDC() external view returns (address);
}

/// @title FactoringSettlementExtractor — CRE bridge for the fx-Recibu lifecycle.
/// @notice Receives a DON-signed report through Chainlink's IReceiver entrypoint,
///         validates its chain, workflow, replay key, target, token and memo, then
///         dispatches exactly one typed call to InvoiceSettlement or InvoiceShelf.
///
/// CRE report encoding:
///   abi.encode(address target, bytes innerReport)
///
/// innerReport encoding:
///   abi.encode(
///     uint8 action,
///     uint64 targetChainSelector,
///     bytes32 operationId,
///     uint64 validUntil,
///     bytes actionPayload
///   )
///
/// Action payloads:
///   SETTLE  (1): abi.encode(address token, uint256 invoiceId, uint8 installment, bytes32 memoId)
///   LOCK    (2): abi.encode(address token, uint256 sellerAgentId, uint256 debtorAgentId,
///                           uint128 face, uint8 nInstallments, uint64 firstMaturity,
///                           uint32 interval, BINV.DocBundle docs)
///   DEFAULT (3): abi.encode(uint256 invoiceId)
///
/// @dev `writeReport.receiver` MUST be this extractor. `target` belongs inside the
///      signed payload and is restricted to the immutable settlement/shelf pair.
contract FactoringSettlementExtractor is IReceiver, ERC165, Ownable2Step, Pausable, ReentrancyGuard {
    uint8 public constant ACTION_SETTLE = 1;
    uint8 public constant ACTION_LOCK = 2;
    uint8 public constant ACTION_DEFAULT = 3;

    uint64 public immutable TARGET_CHAIN_SELECTOR;
    IInvoiceShelfTarget public immutable SHELF;
    IInvoiceSettlementTarget public immutable SETTLEMENT;
    address public immutable SHELF_TOKEN;

    address public forwarder;
    /// @notice Optional production-only workflow binding. Zero disables the check
    ///         so MockKeystoneForwarder simulation (which omits metadata) still works.
    bytes32 public expectedWorkflowId;
    mapping(bytes32 operationId => bool) public processed;

    event ForwarderUpdated(address indexed previousForwarder, address indexed newForwarder);
    event ExpectedWorkflowIdUpdated(bytes32 indexed previousWorkflowId, bytes32 indexed newWorkflowId);
    event SettlementExecuted(bytes32 indexed operationId, address indexed target, uint256 indexed invoiceId);
    event InvoiceLockExecuted(bytes32 indexed operationId, address indexed target, uint256 indexed invoiceId);
    event InvoiceDefaultExecuted(bytes32 indexed operationId, address indexed target, uint256 indexed invoiceId);

    error ZeroAddress();
    error ZeroChainSelector();
    error NotForwarder(address caller);
    error InvalidMetadataLength(uint256 actualLength);
    error UnexpectedWorkflowId(bytes32 received, bytes32 expected);
    error CompatibilityExtractDisabled();
    error UnknownAction(uint8 action);
    error WrongTarget(uint8 action, address received, address expected);
    error WrongChainSelector(uint64 received, uint64 expected);
    error ZeroOperationId();
    error OperationAlreadyProcessed(bytes32 operationId);
    error ReportExpired(uint64 validUntil, uint256 currentTimestamp);
    error UnexpectedToken(uint8 action, address received, address expected);
    error MemoIdMismatch(bytes32 received, bytes32 expected);
    error SettlementShelfMismatch(address received, address expected);
    error SettlementEscrowTokenMismatch(address received, address expected);

    modifier onlyForwarder() {
        _checkForwarder();
        _;
    }

    constructor(
        address initialOwner,
        address initialForwarder,
        uint64 targetChainSelector,
        IInvoiceShelfTarget shelf,
        IInvoiceSettlementTarget settlement
    ) Ownable(initialOwner) {
        if (initialForwarder == address(0) || address(shelf) == address(0) || address(settlement) == address(0)) {
            revert ZeroAddress();
        }
        if (targetChainSelector == 0) revert ZeroChainSelector();

        address shelfToken = shelf.USDC();
        if (shelfToken == address(0)) revert ZeroAddress();

        address linkedShelf = settlement.SHELF();
        if (linkedShelf != address(shelf)) revert SettlementShelfMismatch(linkedShelf, address(shelf));

        address settlementToken = settlement.USDC();
        if (settlementToken != shelfToken) revert UnexpectedToken(ACTION_SETTLE, settlementToken, shelfToken);

        address settlementEscrow = settlement.ESCROW();
        if (settlementEscrow == address(0)) revert ZeroAddress();
        address escrowToken = IReceivableEscrowTokenView(settlementEscrow).USDC();
        if (escrowToken != shelfToken) revert SettlementEscrowTokenMismatch(escrowToken, shelfToken);

        forwarder = initialForwarder;
        TARGET_CHAIN_SELECTOR = targetChainSelector;
        SHELF = shelf;
        SETTLEMENT = settlement;
        SHELF_TOKEN = shelfToken;

        emit ForwarderUpdated(address(0), initialForwarder);
    }

    /// @inheritdoc IReceiver
    function onReport(bytes calldata metadata, bytes calldata report)
        external
        override
        onlyForwarder
        whenNotPaused
        nonReentrant
    {
        _validateWorkflow(metadata);
        (address target, bytes memory innerReport) = abi.decode(report, (address, bytes));
        _dispatch(target, innerReport);
    }

    /// @notice Compatibility entrypoint for local Foundry wiring and legacy callers.
    /// @dev Production should configure expectedWorkflowId and use {onReport}; doing
    ///      so intentionally disables this metadata-less compatibility route.
    function extract(address target, bytes calldata innerReport) external onlyForwarder whenNotPaused nonReentrant {
        if (expectedWorkflowId != bytes32(0)) revert CompatibilityExtractDisabled();
        _dispatch(target, innerReport);
    }

    function setForwarder(address newForwarder) external onlyOwner {
        if (newForwarder == address(0)) revert ZeroAddress();
        address previousForwarder = forwarder;
        forwarder = newForwarder;
        emit ForwarderUpdated(previousForwarder, newForwarder);
    }

    /// @notice Bind production delivery to one CRE workflow. Set zero for simulation.
    function setExpectedWorkflowId(bytes32 newWorkflowId) external onlyOwner {
        bytes32 previousWorkflowId = expectedWorkflowId;
        expectedWorkflowId = newWorkflowId;
        emit ExpectedWorkflowIdUpdated(previousWorkflowId, newWorkflowId);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function supportsInterface(bytes4 interfaceId) public view override(IERC165, ERC165) returns (bool) {
        return interfaceId == type(IReceiver).interfaceId || super.supportsInterface(interfaceId);
    }

    function _checkForwarder() internal view {
        if (msg.sender != forwarder) revert NotForwarder(msg.sender);
    }

    function _validateWorkflow(bytes calldata metadata) internal view {
        bytes32 expected = expectedWorkflowId;
        if (expected == bytes32(0)) return;
        if (metadata.length < 32) revert InvalidMetadataLength(metadata.length);

        bytes32 received;
        assembly ("memory-safe") {
            received := calldataload(metadata.offset)
        }
        if (received != expected) revert UnexpectedWorkflowId(received, expected);
    }

    function _dispatch(address target, bytes memory innerReport) internal {
        (uint8 action, uint64 targetChainSelector, bytes32 operationId, uint64 validUntil, bytes memory actionPayload) =
            abi.decode(innerReport, (uint8, uint64, bytes32, uint64, bytes));

        if (action != ACTION_SETTLE && action != ACTION_LOCK && action != ACTION_DEFAULT) {
            revert UnknownAction(action);
        }
        if (targetChainSelector != TARGET_CHAIN_SELECTOR) {
            revert WrongChainSelector(targetChainSelector, TARGET_CHAIN_SELECTOR);
        }
        if (operationId == bytes32(0)) revert ZeroOperationId();
        if (processed[operationId]) revert OperationAlreadyProcessed(operationId);
        if (block.timestamp > validUntil) revert ReportExpired(validUntil, block.timestamp);

        address expectedTarget = action == ACTION_SETTLE ? address(SETTLEMENT) : address(SHELF);
        if (target != expectedTarget) revert WrongTarget(action, target, expectedTarget);

        // Mark before the typed external call. Any downstream revert rolls this write
        // back atomically, allowing a corrected retry only while validUntil remains live.
        processed[operationId] = true;

        if (action == ACTION_SETTLE) {
            _settle(operationId, target, actionPayload);
        } else if (action == ACTION_LOCK) {
            _lock(operationId, target, actionPayload);
        } else {
            _markDefaulted(operationId, target, actionPayload);
        }
    }

    function _settle(bytes32 operationId, address target, bytes memory actionPayload) internal {
        (address token, uint256 invoiceId, uint8 installment, bytes32 memoId) =
            abi.decode(actionPayload, (address, uint256, uint8, bytes32));
        if (token != SHELF_TOKEN) revert UnexpectedToken(ACTION_SETTLE, token, SHELF_TOKEN);

        bytes32 expectedMemoId = keccak256(abi.encodePacked(invoiceId, installment));
        if (memoId != expectedMemoId) revert MemoIdMismatch(memoId, expectedMemoId);

        SETTLEMENT.settle(invoiceId);
        emit SettlementExecuted(operationId, target, invoiceId);
    }

    function _lock(bytes32 operationId, address target, bytes memory actionPayload) internal {
        (
            address token,
            uint256 sellerAgentId,
            uint256 debtorAgentId,
            uint128 face,
            uint8 nInstallments,
            uint64 firstMaturity,
            uint32 interval,
            BINV.DocBundle memory docs
        ) = abi.decode(actionPayload, (address, uint256, uint256, uint128, uint8, uint64, uint32, BINV.DocBundle));
        if (token != SHELF_TOKEN) revert UnexpectedToken(ACTION_LOCK, token, SHELF_TOKEN);

        uint256 invoiceId =
            SHELF.lockInvoice(sellerAgentId, debtorAgentId, face, nInstallments, firstMaturity, interval, docs);
        emit InvoiceLockExecuted(operationId, target, invoiceId);
    }

    function _markDefaulted(bytes32 operationId, address target, bytes memory actionPayload) internal {
        uint256 invoiceId = abi.decode(actionPayload, (uint256));
        SHELF.markDefaulted(invoiceId);
        emit InvoiceDefaultExecuted(operationId, target, invoiceId);
    }
}
