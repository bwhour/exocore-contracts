// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {WorkerOptions} from "@layerzerolabs/lz-evm-messagelib-v2/contracts/SendLibBase.sol";
import {IExecutorFeeLib} from "@layerzerolabs/lz-evm-messagelib-v2/contracts/interfaces/IExecutorFeeLib.sol";
import {DVNOptions} from "@layerzerolabs/lz-evm-messagelib-v2/contracts/uln/libs/DVNOptions.sol";
import {UlnOptions} from "@layerzerolabs/lz-evm-messagelib-v2/contracts/uln/libs/UlnOptions.sol";
import {Origin} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/OAppReceiver.sol";
import {OFTMsgCodec} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/libs/OFTMsgCodec.sol";
import {ExecutionState} from "@layerzerolabs/lz-evm-protocol-v2/contracts/EndpointV2ViewUpgradeable.sol";
import {MessagingContext} from "@layerzerolabs/lz-evm-protocol-v2/contracts/MessagingContext.sol";
import {
    ILayerZeroEndpointV2,
    MessagingFee,
    MessagingParams,
    MessagingReceipt,
    Origin
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {ILayerZeroReceiver} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroReceiver.sol";
import {SetConfigParam} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/IMessageLibManager.sol";
import {Packet} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ISendLib.sol";

import {CalldataBytesLib} from "@layerzerolabs/lz-evm-protocol-v2/contracts/libs/CalldataBytesLib.sol";
import {Errors} from "@layerzerolabs/lz-evm-protocol-v2/contracts/libs/Errors.sol";
import {GUID} from "@layerzerolabs/lz-evm-protocol-v2/contracts/libs/GUID.sol";
import {ExecutorOptions} from "@layerzerolabs/lz-evm-protocol-v2/contracts/messagelib/libs/ExecutorOptions.sol";
import {PacketV1Codec} from "@layerzerolabs/lz-evm-protocol-v2/contracts/messagelib/libs/PacketV1Codec.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

contract NonShortCircuitEndpointV2Mock is ILayerZeroEndpointV2, MessagingContext {

    using ExecutorOptions for bytes;
    using OFTMsgCodec for bytes;
    using OFTMsgCodec for bytes32;
    using OFTMsgCodec for address;
    using SafeCast for uint256;
    using CalldataBytesLib for bytes;

    bytes32 public constant EMPTY_PAYLOAD_HASH = bytes32(0);

    uint32 public immutable eid;
    mapping(address => address) public lzEndpointLookup;

    mapping(address receiver => mapping(uint32 srcEid => mapping(bytes32 sender => uint64 nonce))) public
        lazyInboundNonce;
    mapping(
        address receiver
            => mapping(uint32 srcEid => mapping(bytes32 sender => mapping(uint64 inboundNonce => bytes32 payloadHash)))
    ) public inboundPayloadHash;
    mapping(address sender => mapping(uint32 dstEid => mapping(bytes32 receiver => uint64 nonce))) public outboundNonce;

    RelayerFeeConfig public relayerFeeConfig;
    ProtocolFeeConfig protocolFeeConfig;
    uint256 public verifierFee;

    struct ProtocolFeeConfig {
        uint256 zroFee;
        uint256 nativeBP;
    }

    struct RelayerFeeConfig {
        uint128 dstPriceRatio; // 10^10
        uint128 dstGasPriceInWei;
        uint128 dstNativeAmtCap;
        uint64 baseGas;
        uint64 gasPerByte;
    }

    uint8 internal constant _NOT_ENTERED = 1;
    uint8 internal constant _ENTERED = 2;
    uint8 internal _receive_entered_state = 1;
    address owner;

    modifier receiveNonReentrant() {
        require(_receive_entered_state == _NOT_ENTERED, "LayerZeroMock: no receive reentrancy");
        _receive_entered_state = _ENTERED;
        _;
        _receive_entered_state = _NOT_ENTERED;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "only authorized to owner");
        _;
    }

    event ValueTransferFailed(address indexed to, uint256 indexed quantity);
    event NewPacket(uint32, address, bytes32, uint64, bytes);
    event PayloadStored(
        uint32 srcChainId, bytes32 srcAddress, address dstAddress, uint64 nonce, bytes payload, bytes reason
    );

    constructor(uint32 _eid, address _owner) {
        require(_owner != address(0), "owner address should not be empty");

        owner = _owner;
        eid = _eid;
        // init config
        relayerFeeConfig = RelayerFeeConfig({
            dstPriceRatio: 1e10, // 1:1, same chain, same native coin
            dstGasPriceInWei: 1e10,
            dstNativeAmtCap: 1e19,
            baseGas: 100,
            gasPerByte: 1
        });
        protocolFeeConfig = ProtocolFeeConfig({zroFee: 1e18, nativeBP: 1000}); // BP 0.1
        verifierFee = 1e16;
    }

    function send(MessagingParams calldata _params, address _refundAddress)
        public
        payable
        sendContext(_params.dstEid, msg.sender)
        returns (MessagingReceipt memory receipt)
    {
        if (_params.payInLzToken) {
            revert Errors.LZ_LzTokenUnavailable();
        }

        address lzEndpoint = lzEndpointLookup[_params.receiver.bytes32ToAddress()];
        require(lzEndpoint != address(0), "LayerZeroMock: destination LayerZero Endpoint not found");

        // get the correct outbound nonce
        uint64 latestNonce = _outbound(msg.sender, _params.dstEid, _params.receiver);

        Packet memory packet = Packet({
            nonce: latestNonce,
            srcEid: eid,
            sender: msg.sender,
            dstEid: _params.dstEid,
            receiver: _params.receiver,
            guid: GUID.generate(latestNonce, eid, msg.sender, _params.dstEid, _params.receiver),
            message: _params.message
        });
        receipt.guid = packet.guid;
        receipt.nonce = packet.nonce;
        receipt.fee = _quote(_params, msg.sender);
        require(msg.value >= receipt.fee.nativeFee, "LayerZeroMock: not enough native for fees");

        // refund if they send too much
        uint256 amount = msg.value - receipt.fee.nativeFee;
        if (amount > 0) {
            (bool success,) = _refundAddress.call{value: amount}("");
            require(success, "LayerZeroMock: failed to refund");
        }

        uint256 totalGas;
        uint256 dstAmount;
        (totalGas, dstAmount) = executeNativeAirDropAndReturnLzGas(_params.options);

        // TODO fix
        // composed calls with correct gas

        // Origin memory origin = Origin({
        //     srcEid: packet.srcEid,
        //     sender: packet.sender.addressToBytes32(),
        //     nonce: packet.nonce
        // });

        // bytes memory payload = PacketV1Codec.encodePayload(packet);
        // bytes32 payloadHash = keccak256(payload);

        _sendMessage(packet.dstEid, msg.sender, packet.receiver, packet.nonce, packet.message);
    }

    function _sendMessage(uint32 dstChainId, address srcAddress, bytes32 dstAddr, uint64 nonce, bytes memory payload)
        internal
    {
        emit NewPacket(dstChainId, srcAddress, dstAddr, nonce, payload);
    }

    function lzReceive(
        Origin calldata _origin,
        address _receiver,
        bytes32 _guid,
        bytes calldata _message,
        bytes calldata
    ) external payable receiveNonReentrant {
        require(
            _origin.nonce == lazyInboundNonce[_receiver][_origin.srcEid][_origin.sender] + 1,
            "nonce should match expected inbound nonce"
        );
        if (msg.value > 0) {
            try ILayerZeroReceiver(_receiver).lzReceive{value: msg.value}(_origin, _guid, _message, address(0), "") {
                lazyInboundNonce[_receiver][_origin.srcEid][_origin.sender]++;
            } catch (bytes memory reason) /*reason*/ {
                inboundPayloadHash[_receiver][_origin.srcEid][_origin.sender][_origin.nonce] = keccak256(_message);
                emit PayloadStored(_origin.srcEid, _origin.sender, _receiver, _origin.nonce, _message, reason);
            }
        } else {
            try ILayerZeroReceiver(_receiver).lzReceive(_origin, _guid, _message, address(0), "") {
                lazyInboundNonce[_receiver][_origin.srcEid][_origin.sender]++;
            } catch (bytes memory reason) /*reason*/ {
                inboundPayloadHash[_receiver][_origin.srcEid][_origin.sender][_origin.nonce] = keccak256(_message);
                emit PayloadStored(_origin.srcEid, _origin.sender, _receiver, _origin.nonce, _message, reason);
            }
        }
    }

    function _hasPayloadHash(address _receiver, uint32 _srcEid, bytes32 _sender, uint64 _nonce)
        internal
        view
        returns (bool)
    {
        return inboundPayloadHash[_receiver][_srcEid][_sender][_nonce] != EMPTY_PAYLOAD_HASH;
    }

    function getExecutorFee(uint256 _payloadSize, bytes calldata _options) public view returns (uint256) {
        uint256 nativeFee;
        // 2) get Executor fee
        //  a) decodeLzReceiveOption
        //  b) decodeNativeDropOption
        //  c) decodeLzComposeOption
        (uint256 totalDstAmount, uint256 totalGas) = _decodeExecutorOptions(_options);
        uint256 remoteGasTotal = relayerFeeConfig.dstGasPriceInWei * (relayerFeeConfig.baseGas + totalGas);
        nativeFee += totalDstAmount + remoteGasTotal;

        // tokenConversionRate = dstPrice / localPrice
        // basePrice = totalRemoteToken * tokenConversionRate
        uint256 basePrice = (nativeFee * relayerFeeConfig.dstPriceRatio) / 10 ** 10;

        // pricePerByte = (dstGasPriceInWei * gasPerBytes) * tokenConversionRate
        uint256 pricePerByte = (
            (relayerFeeConfig.dstGasPriceInWei * relayerFeeConfig.gasPerByte * relayerFeeConfig.dstPriceRatio)
                / 10 ** 10
        ) * _payloadSize;

        return basePrice + pricePerByte;
    }

    function _quote(MessagingParams calldata _params, address /*_sender*/ )
        internal
        view
        returns (MessagingFee memory messagingFee)
    {
        (bytes memory executorOptions,) = splitOptions(_params.options);

        // 2) get Executor fee
        uint256 executorFee = this.getExecutorFee(_params.message.length, executorOptions);

        // 1) get Verifier fee
        // 3) get Treasury fee
        uint256 treasuryAndVerifierFee = _getTreasuryAndVerifierFees(executorFee, verifierFee);

        messagingFee.lzTokenFee = 0;
        messagingFee.nativeFee = executorFee + treasuryAndVerifierFee;
    }

    function _getTreasuryAndVerifierFees(uint256 _executorFee, uint256 _verifierFee) internal view returns (uint256) {
        return ((_executorFee + _verifierFee) * protocolFeeConfig.nativeBP) / 10_000;
    }

    function _outbound(address _sender, uint32 _dstEid, bytes32 _receiver) internal returns (uint64 nonce) {
        unchecked {
            nonce = ++outboundNonce[_sender][_dstEid][_receiver];
        }
    }

    function getInboundNonce(address _receiver, uint32 _srcEid, bytes32 _sender) external view returns (uint64) {
        return lazyInboundNonce[_receiver][_srcEid][_sender];
    }

    function resetInboundNonce(address _receiver, uint32 _srcEid, bytes32 _sender, uint64 _nonce) external onlyOwner {
        lazyInboundNonce[_receiver][_srcEid][_sender] = _nonce;
    }

    function getOutboundNonce(address _sender, uint32 _dstEid, bytes32 _receiver) external view returns (uint64) {
        return outboundNonce[_sender][_dstEid][_receiver];
    }

    function resetOutboundNonce(address _sender, uint32 _dstEid, bytes32 _receiver, uint64 _nonce) external onlyOwner {
        outboundNonce[_sender][_dstEid][_receiver] = _nonce;
    }

    function setDestLzEndpoint(address destAddr, address lzEndpointAddr) external {
        lzEndpointLookup[destAddr] = lzEndpointAddr;
    }

    function _decodeExecutorOptions(bytes calldata _options)
        internal
        view
        returns (uint256 dstAmount, uint256 totalGas)
    {
        if (_options.length == 0) {
            revert IExecutorFeeLib.Executor_NoOptions();
        }

        uint64 _baseGas = relayerFeeConfig.baseGas;
        uint128 _nativeCap = relayerFeeConfig.dstNativeAmtCap;
        bool _v1Eid = false;

        uint256 cursor = 0;
        bool ordered = false;
        totalGas = _baseGas;

        uint256 lzReceiveGas;
        while (cursor < _options.length) {
            (uint8 optionType, bytes calldata option, uint256 newCursor) = _options.nextExecutorOption(cursor);
            cursor = newCursor;

            if (optionType == ExecutorOptions.OPTION_TYPE_LZRECEIVE) {
                (uint128 gas, uint128 value) = ExecutorOptions.decodeLzReceiveOption(option);

                // endpoint v1 does not support lzReceive with value
                if (_v1Eid && value > 0) {
                    revert IExecutorFeeLib.Executor_UnsupportedOptionType(optionType);
                }

                dstAmount += value;
                lzReceiveGas += gas;
            } else if (optionType == ExecutorOptions.OPTION_TYPE_NATIVE_DROP) {
                (uint128 nativeDropAmount,) = ExecutorOptions.decodeNativeDropOption(option);
                dstAmount += nativeDropAmount;
            } else if (optionType == ExecutorOptions.OPTION_TYPE_LZCOMPOSE) {
                // endpoint v1 does not support lzCompose
                if (_v1Eid) {
                    revert IExecutorFeeLib.Executor_UnsupportedOptionType(optionType);
                }

                (, uint128 gas, uint128 value) = ExecutorOptions.decodeLzComposeOption(option);
                dstAmount += value;
                totalGas += gas;
            } else if (optionType == ExecutorOptions.OPTION_TYPE_ORDERED_EXECUTION) {
                ordered = true;
            } else {
                revert IExecutorFeeLib.Executor_UnsupportedOptionType(optionType);
            }
        }
        if (cursor != _options.length) {
            revert IExecutorFeeLib.Executor_InvalidExecutorOptions(cursor);
        }
        if (dstAmount > _nativeCap) {
            revert IExecutorFeeLib.Executor_NativeAmountExceedsCap(dstAmount, _nativeCap);
        }
        if (lzReceiveGas == 0) {
            revert IExecutorFeeLib.Executor_ZeroLzReceiveGasProvided();
        }
        totalGas += lzReceiveGas;

        if (ordered) {
            totalGas = (totalGas * 102) / 100;
        }
    }

    function splitOptions(bytes calldata _options) internal pure returns (bytes memory, WorkerOptions[] memory) {
        (bytes memory executorOpts, bytes memory dvnOpts) = decode(_options);

        if (dvnOpts.length == 0) {
            return (executorOpts, new WorkerOptions[](0));
        }

        WorkerOptions[] memory workerOpts = new WorkerOptions[](1);
        workerOpts[0] = WorkerOptions(DVNOptions.WORKER_ID, dvnOpts);
        return (executorOpts, workerOpts);
    }

    function decode(bytes calldata _options)
        internal
        pure
        returns (bytes memory executorOptions, bytes memory dvnOptions)
    {
        // at least 2 bytes for the option type, but can have no options
        if (_options.length < 2) {
            revert UlnOptions.LZ_ULN_InvalidWorkerOptions(0);
        }

        uint16 optionsType = uint16(bytes2(_options[0:2]));
        uint256 cursor = 2;

        // type3 options: [worker_option][worker_option]...
        // worker_option: [worker_id][option_size][option]
        // worker_id: uint8, option_size: uint16, option: bytes
        if (optionsType == UlnOptions.TYPE_3) {
            unchecked {
                uint256 start = cursor;
                uint8 lastWorkerId; // worker_id starts from 1, so 0 is an invalid worker_id

                // heuristic: we assume that the options are mostly EXECUTOR options only
                // checking the workerID can reduce gas usage for most cases
                while (cursor < _options.length) {
                    uint8 workerId = uint8(bytes1(_options[cursor:cursor + 1]));
                    if (workerId == 0) {
                        revert UlnOptions.LZ_ULN_InvalidWorkerId(0);
                    }

                    // workerId must equal to the lastWorkerId for the first option
                    // so it is always skipped in the first option
                    // this operation slices out options whenever the the scan finds a different workerId
                    if (lastWorkerId == 0) {
                        lastWorkerId = workerId;
                    } else if (workerId != lastWorkerId) {
                        bytes calldata op = _options[start:cursor]; // slice out the last worker's options
                        (executorOptions, dvnOptions) =
                            _insertWorkerOptions(executorOptions, dvnOptions, lastWorkerId, op);

                        // reset the start cursor and lastWorkerId
                        start = cursor;
                        lastWorkerId = workerId;
                    }

                    ++cursor; // for workerId

                    uint16 size = uint16(bytes2(_options[cursor:cursor + 2]));
                    if (size == 0) {
                        revert UlnOptions.LZ_ULN_InvalidWorkerOptions(cursor);
                    }
                    cursor += size + 2;
                }

                // the options length must be the same as the cursor at the end
                if (cursor != _options.length) {
                    revert UlnOptions.LZ_ULN_InvalidWorkerOptions(cursor);
                }

                // if we have reached the end of the options and the options are not empty
                // we need to process the last worker's options
                if (_options.length > 2) {
                    bytes calldata op = _options[start:cursor];
                    (executorOptions, dvnOptions) = _insertWorkerOptions(executorOptions, dvnOptions, lastWorkerId, op);
                }
            }
        } else {
            executorOptions = decodeLegacyOptions(optionsType, _options);
        }
    }

    function _insertWorkerOptions(
        bytes memory _executorOptions,
        bytes memory _dvnOptions,
        uint8 _workerId,
        bytes calldata _newOptions
    ) private pure returns (bytes memory, bytes memory) {
        if (_workerId == ExecutorOptions.WORKER_ID) {
            _executorOptions =
                _executorOptions.length == 0 ? _newOptions : abi.encodePacked(_executorOptions, _newOptions);
        } else if (_workerId == DVNOptions.WORKER_ID) {
            _dvnOptions = _dvnOptions.length == 0 ? _newOptions : abi.encodePacked(_dvnOptions, _newOptions);
        } else {
            revert UlnOptions.LZ_ULN_InvalidWorkerId(_workerId);
        }
        return (_executorOptions, _dvnOptions);
    }

    function decodeLegacyOptions(uint16 _optionType, bytes calldata _options)
        internal
        pure
        returns (bytes memory executorOptions)
    {
        if (_optionType == UlnOptions.TYPE_1) {
            if (_options.length != 34) {
                revert UlnOptions.LZ_ULN_InvalidLegacyType1Option();
            }

            // execution gas
            uint128 executionGas = uint256(bytes32(_options[2:2 + 32])).toUint128();

            // dont use the encode function in the ExecutorOptions lib for saving gas by calling abi.encodePacked once
            // the result is a lzReceive option: [executor_id][option_size][option_type][execution_gas]
            // option_type: uint8, execution_gas: uint128
            // option_size = len(option_type) + len(execution_gas) = 1 + 16 = 17
            executorOptions = abi.encodePacked(
                ExecutorOptions.WORKER_ID,
                uint16(17), // 16 + 1, 16 for option_length, + 1 for option_type
                ExecutorOptions.OPTION_TYPE_LZRECEIVE,
                executionGas
            );
        } else if (_optionType == UlnOptions.TYPE_2) {
            // receiver size <= 32
            if (_options.length <= 66 || _options.length > 98) {
                revert UlnOptions.LZ_ULN_InvalidLegacyType2Option();
            }

            // execution gas
            uint128 executionGas = uint256(bytes32(_options[2:2 + 32])).toUint128();

            // nativeDrop (amount + receiver)
            uint128 amount = uint256(bytes32(_options[34:34 + 32])).toUint128(); // offset 2 + 32
            bytes32 receiver;
            unchecked {
                uint256 receiverLen = _options.length - 66; // offset 2 + 32 + 32
                receiver = bytes32(_options[66:]);
                receiver = receiver >> (8 * (32 - receiverLen)); // padding 0 to the left
            }

            // dont use the encode function in the ExecutorOptions lib for saving gas by calling abi.encodePacked once
            // the result has one lzReceive option and one nativeDrop option:
            //      [executor_id][lzReceive_option_size][option_type][execution_gas] +
            //      [executor_id][nativeDrop_option_size][option_type][nativeDrop_amount][receiver]
            // option_type: uint8, execution_gas: uint128, nativeDrop_amount: uint128, receiver: bytes32
            // lzReceive_option_size = len(option_type) + len(execution_gas) = 1 + 16 = 17
            // nativeDrop_option_size = len(option_type) + len(nativeDrop_amount) + len(receiver) = 1 + 16 + 32 = 49
            executorOptions = abi.encodePacked(
                ExecutorOptions.WORKER_ID,
                uint16(17), // 16 + 1, 16 for option_length, + 1 for option_type
                ExecutorOptions.OPTION_TYPE_LZRECEIVE,
                executionGas,
                ExecutorOptions.WORKER_ID,
                uint16(49), // 48 + 1, 32 + 16 for option_length, + 1 for option_type
                ExecutorOptions.OPTION_TYPE_NATIVE_DROP,
                amount,
                receiver
            );
        } else {
            revert UlnOptions.LZ_ULN_UnsupportedOptionType(_optionType);
        }
    }

    // NOT IMPLEMENTING
    function burn(address _oapp, uint32 _srcEid, bytes32 _sender, uint64 _nonce, bytes32 _payloadHash) external {}

    function clear(address _oapp, Origin calldata _origin, bytes32 _guid, bytes calldata _message) external {}

    mapping(
        address from => mapping(address to => mapping(bytes32 guid => mapping(uint16 index => bytes32 messageHash)))
    ) public composeQueue;

    function defaultReceiveLibrary(uint32 /*_eid*/ ) external pure returns (address) {
        return address(0);
    }

    function defaultReceiveLibraryTimeout(uint32 /*_eid*/ ) external pure returns (address lib, uint256 expiry) {
        return (address(0), 0);
    }

    function defaultSendLibrary(uint32 /*_eid*/ ) external pure returns (address) {
        return address(0);
    }

    function executable(Origin calldata, /*_origin*/ address /*receiver*/ ) external pure returns (ExecutionState) {
        return ExecutionState.NotExecutable;
    }

    function getConfig(
        address,
        /*_oapp*/
        address,
        /*_lib*/
        uint32,
        /*_eid*/
        uint32 /*_configType*/
    ) external pure returns (bytes memory config) {
        return bytes("0x");
    }

    function getReceiveLibrary(
        address,
        /*receiver*/
        uint32 /*_eid*/
    ) external pure returns (address lib, bool isDefault) {
        return (address(0), false);
    }

    function getRegisteredLibraries() external pure returns (address[] memory) {
        address[] memory addresses = new address[](1);
        addresses[0] = address(0);
        return addresses;
    }

    function getSendLibrary(address, /*_sender*/ uint32 /*_eid*/ ) external pure returns (address lib) {
        return address(0);
    }

    function inboundNonce(address _receiver, uint32 _srcEid, bytes32 _sender) external view returns (uint64) {
        return lazyInboundNonce[_receiver][_srcEid][_sender];
    }

    function isDefaultSendLibrary(address, /*_sender*/ uint32 /*_eid*/ ) external pure returns (bool) {
        return false;
    }

    function isRegisteredLibrary(address /*_lib*/ ) external pure returns (bool) {
        return false;
    }

    function isSupportedEid(uint32 /*_eid*/ ) external pure returns (bool) {
        return false;
    }

    function lzCompose(
        address, /*_from,*/
        address, /*_to,*/
        bytes32, /*_guid,*/
        uint16, /*_index,*/
        bytes calldata, /*_message,*/
        bytes calldata /*_extraData*/
    ) external payable {}

    // function lzReceive(
    //     Origin calldata /*_origin,*/,
    //     address /*_receiver,*/,
    //     bytes32 /*_guid,*/,
    //     bytes calldata /*_message,*/,
    //     bytes calldata /*_extraData*/
    // ) external payable {}

    function lzToken() external pure returns (address) {
        return address(0);
    }

    function nativeToken() external pure returns (address) {
        return address(0);
    }

    function nextGuid(
        address,
        /*_sender,*/
        uint32,
        /*_dstEid,*/
        bytes32 /*_receiver*/
    ) external pure returns (bytes32) {
        return 0;
    }

    function nilify(
        address, /*_oapp,*/
        uint32, /*_srcEid,*/
        bytes32, /*_sender,*/
        uint64, /*_nonce,*/
        bytes32 /*_payloadHash*/
    ) external {}

    function quote(MessagingParams calldata _params, address _sender) external view returns (MessagingFee memory) {
        return _quote(_params, _sender);
    }

    mapping(address receiver => mapping(uint32 srcEid => Timeout)) public receiveLibraryTimeout;

    function registerLibrary(address /*_lib*/ ) public {}

    function sendCompose(address, /*_to*/ bytes32, /*_guid*/ uint16, /*_index*/ bytes calldata /*_message*/ )
        external
    {}

    function setConfig(address, /*_oapp*/ address, /*_lib*/ SetConfigParam[] calldata /*_params*/ ) external {}

    function setDefaultReceiveLibrary(uint32, /*_eid*/ address, /*_newLib*/ uint256 /*_gracePeriod*/ ) external {}

    function setDefaultReceiveLibraryTimeout(uint32, /*_eid*/ address, /*_lib*/ uint256 /*_expiry*/ ) external {}

    function setDefaultSendLibrary(uint32, /*_eid*/ address /*_newLib*/ ) external {}

    function setDelegate(address /*_delegate*/ ) external {}

    function setLzToken(address /*_lzToken*/ ) external {}

    function setReceiveLibrary(
        address,
        /*_oapp*/
        uint32,
        /*_eid*/
        address,
        /*_newLib*/
        uint256 /*_gracePeriod*/
    ) external {}

    function setReceiveLibraryTimeout(
        address,
        /*_oapp*/
        uint32,
        /*_eid*/
        address,
        /*_lib*/
        uint256 /*_gracePeriod*/
    ) external {}

    function setSendLibrary(address, /*_oapp*/ uint32, /*_eid*/ address /*_newLib*/ ) external {}

    function skip(address, /*_oapp*/ uint32, /*_srcEid*/ bytes32, /*_sender*/ uint64 /*_nonce*/ ) external {}

    function verifiable(
        Origin calldata, /*_origin*/
        address, /*_receiver*/
        address, /*_receiveLib*/
        bytes32 /*_payloadHash*/
    ) external pure returns (bool) {
        return false;
    }

    function verify(Origin calldata, /*origin*/ address, /*_receiver*/ bytes32 /*_payloadHash*/ ) external {}

    // Helper Functions
    function executeNativeAirDropAndReturnLzGas(bytes calldata _options)
        public
        returns (uint256 totalGas, uint256 dstAmount)
    {
        (bytes memory executorOpts,) = decode(_options);
        return this._executeNativeAirDropAndReturnLzGas(executorOpts);
    }

    function _executeNativeAirDropAndReturnLzGas(bytes calldata _options)
        public
        returns (uint256 totalGas, uint256 dstAmount)
    {
        if (_options.length == 0) {
            revert IExecutorFeeLib.Executor_NoOptions();
        }

        uint256 cursor = 0;
        while (cursor < _options.length) {
            (uint8 optionType, bytes calldata option, uint256 newCursor) = _options.nextExecutorOption(cursor);
            cursor = newCursor;

            if (optionType == ExecutorOptions.OPTION_TYPE_LZRECEIVE) {
                (uint128 gas, uint128 value) = ExecutorOptions.decodeLzReceiveOption(option);
                totalGas += gas;
                dstAmount += value;
            } else if (optionType == ExecutorOptions.OPTION_TYPE_NATIVE_DROP) {
                (uint128 nativeDropAmount, bytes32 receiver) = ExecutorOptions.decodeNativeDropOption(option);
                (bool success,) = receiver.bytes32ToAddress().call{value: nativeDropAmount}("");
                if (!success) {
                    emit ValueTransferFailed(receiver.bytes32ToAddress(), nativeDropAmount);
                }
            } else if (optionType == ExecutorOptions.OPTION_TYPE_ORDERED_EXECUTION) {
                // ordered = true;
            } else {
                revert IExecutorFeeLib.Executor_UnsupportedOptionType(optionType);
            }
        }

        if (cursor != _options.length) {
            revert IExecutorFeeLib.Executor_InvalidExecutorOptions(cursor);
        }
    }

    function _initializable(Origin calldata _origin, address _receiver, uint64 _lazyInboundNonce)
        internal
        view
        returns (bool)
    {
        return _lazyInboundNonce > 0 // allowInitializePath already checked
            || ILayerZeroReceiver(_receiver).allowInitializePath(_origin);
    }

    /// @dev bytes(0) payloadHash can never be submitted
    function _verifiable(Origin calldata _origin, address _receiver, uint64 _lazyInboundNonce)
        internal
        view
        returns (bool)
    {
        return _origin.nonce > _lazyInboundNonce // either initializing an empty slot or reverifying
            || inboundPayloadHash[_receiver][_origin.srcEid][_origin.sender][_origin.nonce] != EMPTY_PAYLOAD_HASH; // only
            // allow reverifying if it hasn't been executed
    }

    // ========================= VIEW FUNCTIONS FOR OFFCHAIN ONLY =========================
    // Not involved in any state transition function.
    // ====================================================================================
    function initializable(Origin calldata _origin, address _receiver) external view returns (bool) {
        return _initializable(_origin, _receiver, lazyInboundNonce[_receiver][_origin.srcEid][_origin.sender]);
    }

    function verifiable(Origin calldata _origin, address _receiver) external view returns (bool) {
        return _verifiable(_origin, _receiver, lazyInboundNonce[_receiver][_origin.srcEid][_origin.sender]);
    }

    /// @dev called when the endpoint checks if the msgLib attempting to verify the msg is the configured msgLib of the
    /// Oapp
    /// @dev this check provides the ability for Oapp to lock in a trusted msgLib
    /// @dev it will fist check if the msgLib is the currently configured one. then check if the msgLib is the one in
    /// grace period of msgLib versioning upgrade
    function isValidReceiveLibrary(
        address,
        /*_receiver*/
        uint32,
        /*_srcEid*/
        address /*_actualReceiveLib*/
    ) public pure returns (bool) {
        return true;
    }

}
