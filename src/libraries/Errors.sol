// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Action} from "../storage/GatewayStorage.sol";

/// @dev @title Errors library
/// @dev @notice A library for all errors that can be thrown in the Exocore contracts
/// @dev All errors in Exocore follow the following syntax: 'error ContractNameErrorName(arg1, arg2, ...)', where
/// @dev 'ContractName' is the name of the contract
/// @dev that the error originates from and 'ErrorName' is the name of the error. The arguments are optional and are
/// used to
/// @dev provide additional context to the error
/// @dev 'Global' errors are those that are thrown from various contracts throughout the protocol and do not have a
/// @dev 'ContractName' prefix

library Errors {

    /////////////////////
    //  Global Errors  //
    /////////////////////

    /// @dev Thrown when the passed-in address is the zero address, i.e. address(0)
    error ZeroAddress();

    /// @dev Thrown when passed-in amount is zero
    error ZeroAmount();

    /// @dev Thrown when the passed-in msg.value is not zero but should be
    error NonZeroValue();

    /// @dev Thrown when the passed-in msg.value is zero but should not be
    error ZeroValue();

    /// @dev Index out of array bounds
    error IndexOutOfBounds();

    /// @dev No TVL limit for native restaking.
    error NoTvlLimitForNativeRestaking();

    /// @dev Token not whitelisted.
    /// @param token The address of the token that is not whitelisted
    error TokenNotWhitelisted(address token);

    /// @dev Length mismatch for token and TVL limit arrays
    error ArrayLengthMismatch();
    /// @notice Error thrown when an unsupported request is made.
    /// @param act The unsupported action.
    error UnsupportedRequest(Action act);

    /// @notice Error thrown when a message is received from an unexpected source chain.
    /// @param unexpectedSrcEndpointId The unexpected source chain ID.
    error UnexpectedSourceChain(uint32 unexpectedSrcEndpointId);

    /// @notice Error thrown when the inbound nonce is not as expected.
    /// @param expectedNonce The expected nonce.
    /// @param actualNonce The actual nonce received.
    error UnexpectedInboundNonce(uint64 expectedNonce, uint64 actualNonce);

    ////////////////////////
    //  Bootstrap Errors  //
    ////////////////////////

    /// @dev Bootstrap: invalid immutable config, typically due to zero address or zero value
    error InvalidImmutableConfig();

    /// @dev Bootstrap: spawn time should be in the future
    error BootstrapSpawnTimeAlreadyPast();

    /// @dev Bootstrap: spawn time should be greater than offset duration
    error BootstrapSpawnTimeLessThanDuration();

    /// @dev Bootstrap: lock time should be in the future
    error BootstrapLockTimeAlreadyPast();

    /// @dev Bootstrap: operation not allowed after lock time
    error BootstrapBeforeLocked();

    /// @dev Bootstrap: token should be not whitelisted before
    /// @param token The address of the token already whitelisted
    error BootstrapAlreadyWhitelisted(address token);

    /// @dev Bootstrap: Ethereum address already linked to a validator
    /// @param validator The Ethereum address of the validator
    error BootstrapValidatorAlreadyHasAddress(address validator);

    /// @dev Bootstrap: Validator with this Exocore address is already registered
    error BootstrapValidatorAlreadyRegistered();

    /// @dev Bootstrap: Consensus public key already in use
    /// @param publicKey The public key that is already in use
    error BootstrapConsensusPubkeyAlreadyUsed(bytes32 publicKey);

    /// @dev Bootstrap: Validator name already in use
    error BootstrapValidatorNameAlreadyUsed();

    /// @dev Bootstrap: Invalid commission
    error BootstrapInvalidCommission();

    /// @dev Bootstrap: validator does not exist
    error BootstrapValidatorNotExist();

    /// @dev Bootstrap: Commission already edited once
    error BootstrapComissionAlreadyEdited();

    /// @dev Bootstrap: Rate exceeds max rate
    error BootstrapRateExceedsMaxRate();

    /// @dev Bootstrap: Rate change exceeds max change rate
    error BootstrapRateChangeExceedsMaxChangeRate();

    /// @dev Bootstrap: insufficient deposited balance
    error BootstrapInsufficientDepositedBalance();

    /// @dev Bootstrap: insufficient withdrawable balance
    error BootstrapInsufficientWithdrawableBalance();

    /// @dev Bootstrap: insufficient delegated balance
    error BootstrapInsufficientDelegatedBalance();

    /// @dev Bootstrap: no ether required for delegation/undelegation
    error BootstrapNoEtherForDelegation();

    /// @dev Bootstrap: client chain initialization data is malformed
    error BootstrapClientChainDataMalformed();

    /// @dev Bootstrap: validator name length is zero
    error BootstrapValidatorNameLengthZero();

    /// @dev Indicates an operation failed because the specified vault does not exist.
    error VaultDoesNotExist();

    /// @dev Indicates that an operation which is not yet supported is requested.
    error NotYetSupported();

    /// @notice This error is returned when the contract fails to execute a layer zero message due to an error in the
    /// execution process.
    /// @dev This error is returned when the execution of a layer zero message fails.
    /// @param act The action for which the selector or the response function was executed, but failed.
    /// @param nonce The nonce of the message that failed.
    /// @param reason The reason for the failure.
    error RequestOrResponseExecuteFailed(Action act, uint64 nonce, bytes reason);

    //////////////////////////////////
    //  BootstrapLzReceiver Errors  //
    //////////////////////////////////

    /// @dev BootstrapLzReceiver: could only be called from this contract itself with low level call
    error BootstrapLzReceiverOnlyCalledFromThis();

    /// @dev BootstrapLzReceiver: invalid action
    error BootstrapLzReceiverInvalidAction();

    /////////////////////////////////
    //  ClientChainGateway Errors  //
    /////////////////////////////////

    /// @dev ClientChainGateway: token should not be whitelisted before
    error ClientChainGatewayAlreadyWhitelisted(address token);

    /// @dev ClientChainGateway: token addition must happen via Exocore
    error ClientChainGatewayTokenAdditionViaExocore();
    /// @notice Error thrown when the ExoCapsule does not exist.
    error CapsuleDoesNotExist();

    //////////////////////////////////////
    //  ClientGatewayLzReceiver Errors  //
    //////////////////////////////////////

    /// @dev ClientChainLzReceiver: could only be called from this contract itself with low level call
    error ClientGatewayLzReceiverOnlyCalledFromThis();

    /// @dev Thrown when the response is unsupported, that is, no hook has been registered for it.
    /// @param act The action that was unsupported.
    error UnsupportedResponse(Action act);

    /// @dev Thrown when the response received is unexpected, that is, the request payload for the id cannot be
    /// retrieved.
    /// @param nonce The nonce of the request.
    error UnexpectedResponse(uint64 nonce);

    /// @dev Thrown when deposit fails on the Exocore end.
    /// @param token The token address.
    /// @param depositor The depositor address.
    error DepositShouldNotFailOnExocore(address token, address depositor);

    /// @dev Thrown when the whitelist tokens length is invalid.
    /// @param expectedLength The expected length of the request payload.
    /// @param actualLength The actual length of the request payload.
    error InvalidAddWhitelistTokensRequest(uint256 expectedLength, uint256 actualLength);

    /// @notice Emitted when withdrawal fails on the Exocore end.
    /// @param token The token address.
    /// @param withdrawer The withdrawer address.
    event WithdrawFailedOnExocore(address indexed token, address indexed withdrawer);

    ///////////////////////////////
    //  CustomProxyAdmin Errors  //
    ///////////////////////////////

    /// @dev CustomProxyAdmin: sender must be bootstrapper
    error CustomProxyAdminOnlyCalledFromBootstrapper();

    /// @dev CustomProxyAdmin: sender must be the proxy itself
    error CustomProxyAdminOnlyCalledFromProxy();

    /////////////////////////
    //  ExoCapsule Errors  //
    /////////////////////////

    /// @dev ExoCapsule: withdrawal amount is larger than staker's withdrawable balance
    error ExoCapsuleWithdrawalAmountExceeds();

    /// @dev ExoCapsule: withdrawNonBeaconChainETHBalance: amountToWithdraw is greater than nonBeaconChainETHBalance
    error ExoCapsuleNonBeaconChainWithdrawalAmountExceeds();

    /// @dev ExoCapsule: timestamp should be greater than beacon chain genesis timestamp
    error ExoCapsuleTimestampBeforeGenesis();

    /////////////////////////////
    //  ExocoreGateway Errors  //
    /////////////////////////////

    /// @dev ExocoreGateway: can only be called from this contract itself with a low-level call
    error ExocoreGatewayOnlyCalledFromThis();

    /// @dev ExocoreGateway: failed to get client chain ids
    error ExocoreGatewayFailedToGetClientChainIds();

    /// @dev ExocoreGateway: client chain should be registered before.
    error ExocoreGatewayNotRegisteredClientChainId();

    /// @dev ExocoreGateway: failed to check if the client id is registered
    error ExocoreGatewayFailedToCheckClientChainId();

    /// @dev ExocoreGateway: thrown when associateOperatorWithEVMStaker failed
    error AssociateOperatorFailed(uint32 clientChainId, address staker, string operator);

    /// @dev thrown when dissociateOperatorFromEVMStaker failed
    error DissociateOperatorFailed(uint32 clientChainId, address staker);

    /// @notice Thrown when the execution of a precompile call fails.
    /// @param selector_ The function selector of the precompile call.
    /// @param reason The reason for the failure.
    error PrecompileCallFailed(bytes4 selector_, bytes reason);

    /// @notice Thrown when the message length is invalid.
    error InvalidMessageLength();

    /// @notice Thrown when a deposit request fails.
    /// @param srcChainId The source chain ID.
    /// @param lzNonce The LayerZero nonce.
    /// @dev This is considered a critical error.
    error DepositRequestShouldNotFail(uint32 srcChainId, uint64 lzNonce);

    /// @notice Thrown when a client chain registration fails
    /// @param clientChainId The LayerZero chain ID of the client chain.
    error RegisterClientChainToExocoreFailed(uint32 clientChainId);

    /// @notice Thrown when a whitelist token addition fails
    /// @param clientChainId The LayerZero chain ID (or otherwise) of the client chain.
    /// @param token The address of the token.
    error AddWhitelistTokenFailed(uint32 clientChainId, bytes32 token);

    /// @notice Thrown when a whitelist token update fails
    /// @param clientChainId The LayerZero chain ID (or otherwise) of the client chain.
    /// @param token The address of the token.
    error UpdateWhitelistTokenFailed(uint32 clientChainId, bytes32 token);

    /// @notice Thrown when the whitelist tokens input is invalid.
    error InvalidWhitelistTokensInput();

    /// @notice Thrown when the whitelist tokens list is too long.
    error WhitelistTokensListTooLong();

    ////////////////////////////////////////
    //  NativeRestakingController Errors  //
    ////////////////////////////////////////

    /// @dev NativeRestakingController: native restaking is not enabled
    error NativeRestakingControllerNotWhitelisted();

    /// @dev NativeRestakingController: stake value must be exactly 32 ether
    error NativeRestakingControllerInvalidStakeValue();

    /// @dev NativeRestakingController: message sender has already created the capsule
    error NativeRestakingControllerCapsuleAlreadyCreated();

    ////////////////////
    //  Vault Errors  //
    ////////////////////

    /// @dev Vault: caller is not the gateway
    error VaultCallerIsNotGateway();

    /// @dev Vault: withdrawal amount is larger than depositor's withdrawable balance
    error VaultWithdrawalAmountExceeds();

    /// @dev Vault: total principal unlock amount is larger than the total deposited amount
    error VaultPrincipalExceedsTotalDeposit();

    /// @dev Vault: total principal unlock amount is larger than the total deposited amount
    error VaultTotalUnlockPrincipalExceedsDeposit();

    /// @dev Vault: TVL limit exceeded.
    error VaultTvlLimitExceeded();

    /// @dev Vault: forbid to deploy vault for the virtual token address representing natively staked ETH
    error ForbidToDeployVault();

    /* -------------------------------------------------------------------------- */
    /*                             RewardVault Errors                             */
    /* -------------------------------------------------------------------------- */

    /// @dev RewardVault: insufficient balance
    error InsufficientBalance();

}
