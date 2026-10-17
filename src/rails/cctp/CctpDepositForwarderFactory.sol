// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {CctpDepositForwarder} from "./CctpDepositForwarder.sol";

/**
 * @title CctpDepositForwarderFactory
 * @notice Ownerless factory that deploys deterministic CctpDepositForwarder clones.
 *
 *         Every clone's address is a commitment to all seven configuration parameters:
 *           - usdc              (fixed at factory level)
 *           - tokenMessenger    (fixed at factory level)
 *           - destinationDomain
 *           - mintRecipient
 *           - destinationCaller
 *           - maxFastFeeBps
 *           - documentCommitment
 *
 *         The salt additionally commits to the five user-supplied parameters, providing
 *         double-binding: the address is determined by both the salt and the full 142-byte
 *         immutable args embedded in the clone bytecode.
 *
 *         There is no owner, admin, upgrade or pause. Anyone may deploy any valid forwarder; the
 *         address alone decides where its USDC can ever go, so deploying "someone else's" forwarder
 *         (front-running) only does the deposit owner's work for them. `predict` reverts on invalid
 *         arguments so an undeployable address is never handed to a payer.
 *
 * @dev Supported destination domains: Avalanche (1), Arc (26).
 */
contract CctpDepositForwarderFactory {
    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    /// @notice CCTP domain for Avalanche.
    uint32 public constant DOMAIN_AVALANCHE = 1;

    /// @notice CCTP domain for Arc.
    uint32 public constant DOMAIN_ARC = 26;

    /// @notice Upper bound on maxFastFeeBps (100 bps = 1%); same value the forwarder documents.
    uint16 public constant MAX_FAST_FEE_BPS_CAP = 100;

    // -------------------------------------------------------------------------
    // Immutables
    // -------------------------------------------------------------------------

    /// @notice The CctpDepositForwarder implementation all clones delegate to.
    address public immutable implementation;

    /// @notice The USDC token address baked into every deployed forwarder.
    address public immutable usdc;

    /// @notice The Circle TokenMessengerV2 address baked into every deployed forwarder.
    address public immutable tokenMessenger;

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    /// @notice `implementation` constructor arg is the zero address or has no code.
    error InvalidImplementation();

    /// @notice `usdc` constructor arg is the zero address.
    error ZeroUsdc();

    /// @notice `tokenMessenger` constructor arg is the zero address.
    error ZeroTokenMessenger();

    /// @notice Destination domain is not in {DOMAIN_AVALANCHE, DOMAIN_ARC}.
    error UnsupportedDomain(uint32 domain);

    /// @notice mintRecipient must be non-zero.
    error ZeroMintRecipient();

    /// @notice documentCommitment must be non-zero.
    error ZeroDocumentCommitment();

    /// @notice maxFastFeeBps exceeds MAX_FAST_FEE_BPS_CAP (100 bps).
    error FeeBpsTooHigh(uint16 bps);

    /// @notice The clone landed somewhere other than the predicted address (unreachable).
    error DeployedAddressMismatch(address predicted, address deployed);

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /**
     * @notice Emitted when a new forwarder clone is deployed.
     * @param forwarder          Address of the newly deployed clone.
     * @param destinationDomain  CCTP destination domain.
     * @param mintRecipient      Destination mint recipient (bytes32, indexed).
     * @param documentCommitment Per-clone document commitment hash (indexed).
     */
    event ForwarderDeployed(
        address indexed forwarder,
        uint32 destinationDomain,
        bytes32 indexed mintRecipient,
        bytes32 indexed documentCommitment
    );

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /**
     * @param _implementation  CctpDepositForwarder implementation address (must have code).
     * @param _usdc            USDC token address.
     * @param _tokenMessenger  Circle TokenMessengerV2 address.
     */
    constructor(address _implementation, address _usdc, address _tokenMessenger) {
        if (_implementation == address(0) || _implementation.code.length == 0) {
            revert InvalidImplementation();
        }
        if (_usdc == address(0)) revert ZeroUsdc();
        if (_tokenMessenger == address(0)) revert ZeroTokenMessenger();

        implementation = _implementation;
        usdc = _usdc;
        tokenMessenger = _tokenMessenger;
    }

    // -------------------------------------------------------------------------
    // Public helpers
    // -------------------------------------------------------------------------

    /**
     * @notice Returns the packed 142-byte immutable args for a clone.
     *         Layout: abi.encodePacked(usdc, tokenMessenger, destinationDomain,
     *                                  mintRecipient, destinationCaller, maxFastFeeBps,
     *                                  documentCommitment)
     */
    function cloneArgs(
        uint32 destinationDomain,
        bytes32 mintRecipient,
        bytes32 destinationCaller,
        uint16 maxFastFeeBps,
        bytes32 documentCommitment
    ) public view returns (bytes memory) {
        return abi.encodePacked(
            usdc, // 20 bytes
            tokenMessenger, // 20 bytes
            destinationDomain, //  4 bytes
            mintRecipient, // 32 bytes
            destinationCaller, // 32 bytes
            maxFastFeeBps, //  2 bytes
            documentCommitment // 32 bytes
        ); // = 142 bytes
    }

    /**
     * @notice Returns the CREATE2 salt for a given parameter set.
     *         The salt commits to the five user-supplied parameters only (usdc and tokenMessenger
     *         are factory-level and are already in the args/address commitment).
     */
    function saltOf(
        uint32 destinationDomain,
        bytes32 mintRecipient,
        bytes32 destinationCaller,
        uint16 maxFastFeeBps,
        bytes32 documentCommitment
    ) public pure returns (bytes32) {
        return keccak256(
            abi.encode(destinationDomain, mintRecipient, destinationCaller, maxFastFeeBps, documentCommitment)
        );
    }

    /**
     * @notice Predicts the deterministic address of a forwarder clone.
     *         Reverts on invalid parameters so callers are never handed an undeployable address.
     */
    function predict(
        uint32 destinationDomain,
        bytes32 mintRecipient,
        bytes32 destinationCaller,
        uint16 maxFastFeeBps,
        bytes32 documentCommitment
    ) external view returns (address) {
        _validate(destinationDomain, mintRecipient, maxFastFeeBps, documentCommitment);
        return _predict(destinationDomain, mintRecipient, destinationCaller, maxFastFeeBps, documentCommitment);
    }

    /**
     * @notice Deploys a forwarder clone (idempotent: returns existing if already deployed).
     * @return forwarder  Address of the clone (new or existing).
     */
    function deploy(
        uint32 destinationDomain,
        bytes32 mintRecipient,
        bytes32 destinationCaller,
        uint16 maxFastFeeBps,
        bytes32 documentCommitment
    ) external returns (address forwarder) {
        _validate(destinationDomain, mintRecipient, maxFastFeeBps, documentCommitment);
        forwarder = _deploy(destinationDomain, mintRecipient, destinationCaller, maxFastFeeBps, documentCommitment);
    }

    /**
     * @notice Deploys (if needed) and immediately flushes the forwarder.
     * @return forwarder  Address of the clone.
     * @return amount     USDC amount flushed.
     * @return maxFee     maxFee passed to depositForBurnWithHook.
     */
    function deployAndFlush(
        uint32 destinationDomain,
        bytes32 mintRecipient,
        bytes32 destinationCaller,
        uint16 maxFastFeeBps,
        bytes32 documentCommitment,
        bool fast
    ) external returns (address forwarder, uint256 amount, uint256 maxFee) {
        _validate(destinationDomain, mintRecipient, maxFastFeeBps, documentCommitment);
        forwarder = _deploy(destinationDomain, mintRecipient, destinationCaller, maxFastFeeBps, documentCommitment);
        (amount, maxFee) = CctpDepositForwarder(forwarder).flush(fast);
    }

    // -------------------------------------------------------------------------
    // Internal
    // -------------------------------------------------------------------------

    function _validate(
        uint32 destinationDomain,
        bytes32 mintRecipient,
        uint16 maxFastFeeBps,
        bytes32 documentCommitment
    ) internal pure {
        if (destinationDomain != DOMAIN_AVALANCHE && destinationDomain != DOMAIN_ARC) {
            revert UnsupportedDomain(destinationDomain);
        }
        if (mintRecipient == bytes32(0)) revert ZeroMintRecipient();
        if (documentCommitment == bytes32(0)) revert ZeroDocumentCommitment();
        if (maxFastFeeBps > MAX_FAST_FEE_BPS_CAP) {
            revert FeeBpsTooHigh(maxFastFeeBps);
        }
    }

    function _predict(
        uint32 destinationDomain,
        bytes32 mintRecipient,
        bytes32 destinationCaller,
        uint16 maxFastFeeBps,
        bytes32 documentCommitment
    ) internal view returns (address) {
        bytes memory args = cloneArgs(
            destinationDomain, mintRecipient, destinationCaller, maxFastFeeBps, documentCommitment
        );
        bytes32 salt = saltOf(destinationDomain, mintRecipient, destinationCaller, maxFastFeeBps, documentCommitment);
        return Clones.predictDeterministicAddressWithImmutableArgs(implementation, args, salt);
    }

    function _deploy(
        uint32 destinationDomain,
        bytes32 mintRecipient,
        bytes32 destinationCaller,
        uint16 maxFastFeeBps,
        bytes32 documentCommitment
    ) internal returns (address forwarder) {
        forwarder = _predict(destinationDomain, mintRecipient, destinationCaller, maxFastFeeBps, documentCommitment);

        // Idempotent: if already deployed, just return it.
        if (forwarder.code.length > 0) {
            return forwarder;
        }

        bytes memory args =
            cloneArgs(destinationDomain, mintRecipient, destinationCaller, maxFastFeeBps, documentCommitment);
        bytes32 salt = saltOf(destinationDomain, mintRecipient, destinationCaller, maxFastFeeBps, documentCommitment);

        address deployed = Clones.cloneDeterministicWithImmutableArgs(implementation, args, salt);
        if (deployed != forwarder) revert DeployedAddressMismatch(forwarder, deployed);

        emit ForwarderDeployed(forwarder, destinationDomain, mintRecipient, documentCommitment);
    }
}
