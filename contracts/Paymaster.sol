// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPaymaster, ExecutionResult, PAYMASTER_VALIDATION_SUCCESS_MAGIC} from "@matterlabs/zksync-contracts/l2/system-contracts/interfaces/IPaymaster.sol";
import {IPaymasterFlow} from "@matterlabs/zksync-contracts/l2/system-contracts/interfaces/IPaymasterFlow.sol";
import {TransactionHelper, Transaction} from "@matterlabs/zksync-contracts/l2/system-contracts/libraries/TransactionHelper.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "@matterlabs/zksync-contracts/l2/system-contracts/Constants.sol";
import "hardhat/console.sol";

contract Paymaster is IPaymaster, Ownable {
    using ECDSA for bytes32;

    address public verifier;
    bytes public signedMessagePublic;
    bytes32 public messageHashPublic;

    event dataReceived(bytes data);
    event signedMessageHash(bytes messageHash);

    modifier onlyBootloader() {
        require(
            msg.sender == BOOTLOADER_FORMAL_ADDRESS,
            "Only bootloader can call this method"
        );
        // Continue execution if called from the bootloader.
        _;
    }

    constructor(address _verifier) {
        verifier = _verifier;
    }

    function validateAndPayForPaymasterTransaction(
        bytes32,
        bytes32,
        Transaction calldata _transaction
    )
        external
        payable
        onlyBootloader
        returns (bytes4 magic, bytes memory context)
    {
        // By default we consider the transaction as accepted.
        magic = PAYMASTER_VALIDATION_SUCCESS_MAGIC;
        require(
            _transaction.paymasterInput.length >= 4,
            "The standard paymaster input must be at least 4 bytes long"
        );

        bytes4 paymasterInputSelector = bytes4(
            _transaction.paymasterInput[0:4]
        );
        if (paymasterInputSelector == IPaymasterFlow.approvalBased.selector) {
            // While the transaction data consists of address, uint256 and bytes data,
            // the data is not needed for this paymaster
            (address token, uint256 amount, bytes memory data) = abi.decode(
                _transaction.paymasterInput[4:],
                (address, uint256, bytes)
            );

            signedMessagePublic = data;
            emit dataReceived(data);

            // Unwrap  data
            // (bytes memory signedMessage,) = abi.decode(data, (bytes));
            // require(keccak256(signedMessage) == keccak256(data), "Different!");
            //Validate that the message was signed by the verifier
            console.log("verifier", verifier);
            // console.logBytes(data);
            // console.log("signedMessage", signedMessage);
            console.log("user", address(uint160(_transaction.from)));
            console.log("token", token);
            console.log("Allowance", amount);
            console.log("maxFeePerGas", _transaction.maxFeePerGas);
            console.log("gasLimit", _transaction.gasLimit);

            //Validate that the message was signed by Ondefy backend
            require(isValidSignature(data, token), "Invalid signature");

            // console.log("tx.origin", tx.origin);
            // console.logBytes(signedMessage);
            // console.log("Tx user", from);
            // console.log("User", user);
            // console.log("Expiration", expiration);

            // We verify that the user has provided enough allowance
            address userAddress = address(uint160(_transaction.from));

            address thisAddress = address(this);

            uint256 providedAllowance = IERC20(token).allowance(
                userAddress,
                thisAddress
            );

            require(providedAllowance >= amount, "Min allowance too low");

            // Note, that while the minimal amount of ETH needed is tx.gasPrice * tx.gasLimit,
            // neither paymaster nor account are allowed to access this context variable.
            uint256 requiredETH = _transaction.gasLimit *
                _transaction.maxFeePerGas;

            try
                IERC20(token).transferFrom(userAddress, thisAddress, amount)
            {} catch (bytes memory revertReason) {
                // If the revert reason is empty or represented by just a function selector,
                // we replace the error with a more user-friendly message
                if (revertReason.length <= 4) {
                    revert("Failed to transferFrom from users' account");
                } else {
                    assembly {
                        revert(add(0x20, revertReason), mload(revertReason))
                    }
                }
            }

            // The bootloader never returns any data, so it can safely be ignored here.
            (bool success, ) = payable(BOOTLOADER_FORMAL_ADDRESS).call{
                value: requiredETH
            }("");
            require(success, "Failed to transfer funds to the bootloader");
        } else {
            revert("Unsupported paymaster flow");
        }
    }

    function postTransaction(
        bytes calldata _context,
        Transaction calldata _transaction,
        bytes32,
        bytes32,
        ExecutionResult _txResult,
        uint256 _maxRefundedGas
    ) external payable override onlyBootloader {
        // Refunds are not supported yet.
    }

    function withdrawERC20(address _ERC20) external onlyOwner {
        IERC20 token = IERC20(_ERC20);
        token.transfer(msg.sender, token.balanceOf(address(this)));
    }

    function withdraw(address payable _to) external onlyOwner {
        // send paymaster funds to the owner
        uint256 balance = address(this).balance;
        (bool success, ) = _to.call{value: balance}("");
        require(success, "Failed to withdraw funds from paymaster.");
    }

    function isValidSignature(bytes memory _signature, address _token) public view returns (bool) {
        bytes32 messageHash = keccak256(abi.encodePacked(_token));
        bytes32 ethSignedMessageHash = ECDSA.toEthSignedMessageHash(messageHash);

        (address recoveredAddress, ECDSA.RecoverError error2) = ECDSA.tryRecover(ethSignedMessageHash, _signature);
        if (error2 != ECDSA.RecoverError.NoError) {
            return false;
        }
        return recoveredAddress == verifier;
    }

    receive() external payable {}
}
